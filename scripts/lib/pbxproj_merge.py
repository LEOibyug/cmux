"""Conservative three-way merge primitives for Xcode project files."""
from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

MARKER_SIZE = 32
PBX_ENTRY_RE = re.compile(r"^\s*[0-9A-Za-z]+ /\* .* \*/(,| = \{.*\};)\s*$")
PBX_ID_RE = re.compile(r"^\s*([0-9A-Za-z]+) /\*")
PBX_TOKEN_RE = re.compile(
    r'(?P<comment>/\*.*?\*/|//[^\n]*)|(?P<string>"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')|'
    r'(?P<data><[0-9A-Fa-f\s]*>)|(?P<punctuation>[{}=;(),])|(?P<scalar>[^\s{}=;(),"\']+)',
    re.DOTALL,
)


def marker_line(line: str) -> bool:
    return line.startswith(("<" * MARKER_SIZE, "|" * MARKER_SIZE, "=" * MARKER_SIZE, ">" * MARKER_SIZE))


def split_conflicts(text: str) -> list[str | tuple[list[str], list[str], list[str]]]:
    """Split diff3 output into clean lines and (ours, base, theirs) hunks."""
    ours_mark, base_mark = "<" * MARKER_SIZE, "|" * MARKER_SIZE
    split_mark, theirs_mark = "=" * MARKER_SIZE, ">" * MARKER_SIZE
    parts: list[str | tuple[list[str], list[str], list[str]]] = []
    state = None
    ours: list[str] = []
    base: list[str] = []
    theirs: list[str] = []
    for line in text.splitlines(keepends=True):
        if line.startswith(ours_mark) and state is None:
            state, ours, base, theirs = "ours", [], [], []
        elif line.startswith(base_mark) and state == "ours":
            state = "base"
        elif line.rstrip("\r\n") == split_mark and state == "base":
            state = "theirs"
        elif line.startswith(theirs_mark) and state == "theirs":
            parts.append((ours, base, theirs))
            state = None
        elif state == "ours":
            ours.append(line)
        elif state == "base":
            base.append(line)
        elif state == "theirs":
            theirs.append(line)
        else:
            parts.append(line)
    if state is not None:
        raise ValueError("unterminated conflict hunk")
    return parts


def insertions(base: list[str], side: list[str]) -> list[list[str]] | None:
    """Return inserted lines per base slot, or None for a change/removal."""
    slots: list[list[str]] = [[] for _ in range(len(base) + 1)]
    index = 0
    for line in side:
        if index < len(base) and line == base[index]:
            index += 1
        else:
            slots[index].append(line)
    return slots if index == len(base) else None


def inserted_ids(slots: list[list[str]]) -> dict[str, list]:
    ids: dict[str, list] = {}
    for slot, lines in enumerate(slots):
        for line in lines:
            if match := PBX_ID_RE.match(line):
                ids.setdefault(match.group(1), []).append((slot, line))
    return ids


def collides(ours_slots: list[list[str]], theirs_slots: list[list[str]]) -> bool:
    """Reject the same object ID inserted differently by the two sides."""
    ours_ids, theirs_ids = inserted_ids(ours_slots), inserted_ids(theirs_slots)
    return any(ours_ids[key] != theirs_ids[key] for key in ours_ids.keys() & theirs_ids.keys())


def duplicate_keys(text: str) -> list[str]:
    """Find repeated keys within a dictionary, at any depth."""
    tokens = [m.group() for m in PBX_TOKEN_RE.finditer(text) if m.lastgroup != "comment"]
    stack: list[set[str] | None] = []
    duplicates: list[str] = []
    for index, token in enumerate(tokens):
        if token == "{":
            stack.append(set())
        elif token == "(":
            stack.append(None)
        elif token in "})" and stack:
            stack.pop()
        elif token == "=" and index and stack and stack[-1] is not None:
            key = tokens[index - 1].strip("\"'")
            if key in stack[-1]:
                duplicates.append(key)
            stack[-1].add(key)
    return duplicates


def union_hunk(ours: list[str], base: list[str], theirs: list[str]) -> list[str] | None:
    ours_slots, theirs_slots = insertions(base, ours), insertions(base, theirs)
    if ours_slots is None or theirs_slots is None or collides(ours_slots, theirs_slots):
        return None
    merged: list[str] = []
    for slot, (ours_lines, theirs_lines) in enumerate(zip(ours_slots, theirs_slots)):
        merged.extend(ours_lines)
        merged.extend(
            line for line in theirs_lines
            if not (line in ours_lines and PBX_ENTRY_RE.match(line))
        )
        if slot < len(base):
            merged.append(base[slot])
    return merged


def merge_file(base: str, ours: str, theirs: str) -> str:
    """Run git merge-file with wide diff3 conflict markers."""
    with tempfile.TemporaryDirectory() as scratch:
        files = []
        for name, text in (("ours", ours), ("base", base), ("theirs", theirs)):
            path = Path(scratch) / name
            path.write_text(text, encoding="utf-8")
            files.append(str(path))
        completed = subprocess.run(
            ["git", "merge-file", "-p", "--diff3", f"--marker-size={MARKER_SIZE}",
             "-L", "ours", "-L", "base", "-L", "theirs", *files],
            capture_output=True,
        )
    if completed.returncode < 0 or completed.returncode > 127:
        raise ValueError(f"git merge-file failed: {completed.stderr.decode(errors='replace').strip()}")
    return completed.stdout.decode("utf-8")


def union_pbxproj(base: str, ours: str, theirs: str) -> str:
    """Merge only distinct additions and reject duplicate dictionary keys."""
    if any(marker_line(line) for text in (base, ours, theirs) for line in text.splitlines()):
        raise ValueError("a side has conflict-marker lines")
    out: list[str] = []
    for part in split_conflicts(merge_file(base, ours, theirs)):
        if isinstance(part, str):
            out.append(part)
            continue
        merged = union_hunk(*part)
        if merged is None:
            raise ValueError(
                "both sides changed the same lines or added the same entry differently;"
                " only distinct added lines can be merged"
            )
        out.extend(merged)
    result = "".join(out)
    if duplicates := duplicate_keys(result):
        raise ValueError("the union repeats a key: " + ", ".join(sorted(set(duplicates))[:5]))
    return result
