"""Shared project-local process paths for portable development commands."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def require_project_path(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if resolved != ROOT and ROOT not in resolved.parents:
        raise ValueError(f"Refusing development output outside the project: {resolved}")
    return resolved


def configure_project_paths() -> None:
    result = subprocess.run(
        ["/bin/bash", "-c", 'source "$1" || exit 1; /usr/bin/env -0', "project-env", str(ROOT / "scripts/project-env.sh")],
        capture_output=True, check=True
    )
    for item in result.stdout.split(b"\0"):
        if item:
            key, value = item.split(b"=", 1)
            os.environ[os.fsdecode(key)] = os.fsdecode(value)
    tempfile.tempdir = os.environ["CMUX_TMP_DIR"]
