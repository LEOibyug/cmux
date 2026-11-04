#!/usr/bin/env python3
"""Prepare a certificate-signed local update; install only after the user exits cmux."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import subprocess
import sys
import uuid

from local_signing import resolve_identity, sign_code
from prepare_local_bundle import normalize_bundle
from project_paths import ROOT, configure_project_paths, require_project_path

RUNTIME = ROOT / "tmp/local-update"
CACHE = ROOT / "cache/local-update"
TARGET = Path("/Applications/cmux.app")
CURRENT = RUNTIME / "current.json"


def private_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "w") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")


def command(arguments, log=None, env=None):
    result = subprocess.run(arguments, cwd=ROOT, env=env, capture_output=True)
    if log:
        log.write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError(f"{Path(arguments[0]).name} failed" + (f"; see {log.relative_to(ROOT)}" if log else ""))
    return (result.stdout + result.stderr).decode(errors="replace")


def codesign_info(bundle):
    return command(["/usr/bin/codesign", "--display", "--verbose=4", str(bundle)])


def requirement(bundle):
    text = command(["/usr/bin/codesign", "--display", "--requirements", "-", str(bundle)])
    match = re.search(r"designated => (.+)", text)
    if not match:
        raise ValueError("Code has no designated requirement")
    return "=" + match[1]


def executable(bundle):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    return bundle / "Contents/MacOS" / info["CFBundleExecutable"]


def compile_installer(identity):
    CACHE.mkdir(parents=True, exist_ok=True)
    source = ROOT / "scripts/local-update-waiter.swift"
    binary = CACHE / "installer"
    if not binary.exists() or binary.stat().st_mtime_ns < source.stat().st_mtime_ns:
        command(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "6", "-module-cache-path", str(ROOT / "cache/swift-modules"), str(source), "-o", str(binary)], RUNTIME / "installer-build.log")
        sign_code(binary, "com.cmuxterm.local-update.installer")
    command(["/usr/bin/codesign", "--verify", "-R", f'=certificate leaf = H"{identity}" and identifier "com.cmuxterm.local-update.installer"', str(binary)])
    return binary


def status():
    if not CURRENT.exists():
        return {"state": "none"}
    current = json.loads(CURRENT.read_text())
    receipt = Path(current["receipt"])
    return json.loads(receipt.read_text()) if receipt.exists() else {"state": "preparing"}


def prepare(source, work, identity):
    source = require_project_path(source)
    if "Release" not in source.parts or not (source / "Contents/MacOS/cmux").is_file():
        raise ValueError("Use a previously verified project-local Release artifact")
    if TARGET.is_symlink() or not TARGET.is_dir():
        raise ValueError("The existing normal cmux installation must be a regular app directory")
    old_info = plistlib.loads((TARGET / "Contents/Info.plist").read_bytes())
    if old_info.get("CFBundleIdentifier") != "com.cmuxterm.app":
        raise ValueError("Installed application has an unexpected bundle identifier")
    candidate = work / "candidate.app"
    command(["/bin/cp", "-cR", str(source), str(candidate)])
    normalize_bundle(candidate)
    permissions = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(TARGET)], capture_output=True, check=True).stdout
    entitlement_file = work / "ordinary.entitlements"
    entitlement_file.write_bytes(permissions)
    command([str(ROOT / "scripts/sign-cmux-bundle.sh"), str(candidate), str(entitlement_file), identity], work / "sign.log")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", f'=certificate leaf = H"{identity}" and identifier "com.cmuxterm.app"', str(candidate)], work / "candidate-check.log")
    actual = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(candidate)], capture_output=True, check=True).stdout
    if plistlib.loads(actual) != plistlib.loads(permissions):
        raise ValueError("Prepared update changed the permission declarations")
    old_signature = codesign_info(TARGET)
    migration = "Signature=adhoc" in old_signature
    if not migration:
        # Inspect executable identity without Finder's unrelated bundle icon metadata.
        command(["/usr/bin/codesign", "--verify", "-R", requirement(TARGET), str(executable(candidate))], work / "forward-identity.log")
        command(["/usr/bin/codesign", "--verify", "-R", requirement(candidate), str(executable(TARGET))], work / "backward-identity.log")
    old_hash = re.search(r"^CDHash=(\w+)$", old_signature, re.M)
    if not old_hash:
        raise ValueError("Installed application has no code identity hash")
    stage_parent = TARGET.parent / (".cmux-local-update-" + uuid.uuid4().hex)
    stage_parent.mkdir(mode=0o700)
    staged = stage_parent / "cmux.app"
    try:
        command(["/usr/bin/ditto", "--noqtn", str(candidate), str(staged)], work / "stage.log")
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged)], work / "stage-check.log")
    except Exception:
        shutil.rmtree(stage_parent)
        raise
    info = plistlib.loads((candidate / "Contents/Info.plist").read_bytes())
    shutil.rmtree(candidate)
    return {
        "target": str(TARGET), "staged": str(staged), "bundleIdentifier": "com.cmuxterm.app",
        "certificate": identity, "previousCDHash": old_hash[1], "sourceCommit": info.get("CMUXCommit", ""),
        "receipt": str(work / "receipt.json"), "lock": str(RUNTIME / "install.lock"),
    }, migration


def launch_installer(plan, work, installer):
    private_json(work / "plan.json", plan)
    private_json(work / "receipt.json", {"state": "preparing", "sourceCommit": plan["sourceCommit"]})
    read_fd, write_fd = os.pipe()
    try:
        environment = {key: os.environ[key] for key in ["TMPDIR", "TMP", "TEMP", "CFFIXED_USER_HOME", "XDG_CACHE_HOME"]}
        environment.update(HOME=os.environ["CFFIXED_USER_HOME"], PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        log_fd = os.open(work / "installer.log", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(log_fd, "ab") as log:
            process = subprocess.Popen(
                [str(installer), str(work / "plan.json"), str(write_fd)],
                cwd=ROOT, env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                start_new_session=True, close_fds=True, pass_fds=(write_fd,)
            )
        os.close(write_fd)
        write_fd = -1
        readable, _, _ = select.select([read_fd], [], [], 60)
        if not readable or os.read(read_fd, 6) != b"READY\n":
            if process.poll() is not None:
                private_json(work / "receipt.json", {"state": "failed", "error": "Local installer did not start"})
            raise ValueError("Local installer has not reported readiness; inspect its project-local log")
        return process.pid
    finally:
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-artifact", type=Path, help="Reuse an already verified project-local Release artifact")
    parser.add_argument("--status", action="store_true", help="Show the last local update state")
    args = parser.parse_args()
    configure_project_paths()
    RUNTIME.mkdir(parents=True, exist_ok=True)
    if args.status:
        print(json.dumps(status(), ensure_ascii=False))
        return
    with (RUNTIME / "prepare.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        previous = status()
        if previous["state"] in ["preparing", "waiting_for_exit", "installing"]:
            print("An update is already pending; exit cmux normally to finish it. No app was stopped.")
            return
        identity = resolve_identity()
        installer = compile_installer(identity)
        work = RUNTIME / uuid.uuid4().hex[:12]
        work.mkdir(mode=0o700)
        source = args.reuse_artifact
        if source is None:
            environment = os.environ.copy()
            environment["CMUX_GHOSTTYKIT_PREPROVISIONED"] = "1"
            client = Path(environment["CMUX_TUI_CLIENT_LOCAL"])
            if not client.is_file():
                client = TARGET / "Contents/Resources/bin/cmux-tui"
                if not client.is_file():
                    raise ValueError("Build the project-local SSH helper first")
                copied = CACHE / "cmux-tui"
                shutil.copy2(client, copied)
                client = copied
            environment["CMUX_TUI_CLIENT_LOCAL"] = str(client)
            command([str(ROOT / "scripts/reload.sh"), "--release", "--tag", "local-update", "--no-global-cli-links"], work / "build.log", environment)
            source = Path(environment["CMUX_DERIVED_DATA"]) / "Build/Products/Release/cmux DEV local-update.app"
        plan, migration = prepare(source, work, identity)
        launch_installer(plan, work, installer)
        private_json(CURRENT, {"receipt": plan["receipt"], "plan": str(work / "plan.json")})
        print("Signed production update prepared. Keep using cmux; it installs after you exit. Reopen it yourself when ready.")
        if migration:
            print("First certificate-signed installation: macOS may request privacy permissions once more.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f"Local update: {error}")
