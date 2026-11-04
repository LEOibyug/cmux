#!/usr/bin/env python3
"""Sign with a persistent local PEM identity, without accessing a keychain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tarfile

from project_paths import ROOT, configure_project_paths, require_project_path

STORE = ROOT / ".cmux/signing"
CERTIFICATE = STORE / "cmux.crt"
PRIVATE_KEY = STORE / "cmux.key"
PIN = STORE / "identity.json"
TOOL_CACHE = ROOT / "cache/tools/apple-codesign-0.29.0"
TOOL_DIRECTORY = "apple-codesign-0.29.0-aarch64-apple-darwin"
TOOL_SHA256 = "d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a"


def run(*args, data=None, timeout=60):
    # Explicit config and a clean tool environment exclude implicit keychain sources.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("RCODESIGN_")}
    result = subprocess.run(args, input=data, capture_output=True, env=environment, timeout=timeout)
    if result.returncode:
        raise ValueError(f"{Path(args[0]).name} failed: " + result.stderr.decode(errors="replace"))
    return result.stdout


def signing_tool():
    binary = TOOL_CACHE / TOOL_DIRECTORY / "rcodesign"
    if not binary.is_file():
        TOOL_CACHE.mkdir(parents=True, exist_ok=True)
        archive = TOOL_CACHE / "download.tar.gz"
        run("/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "120",
            "--header", "Accept: application/octet-stream",
            "https://api.github.com/repos/indygreg/apple-platform-rs/releases/assets/209933446",
            "--output", str(archive), timeout=150)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != TOOL_SHA256:
            raise ValueError("rcodesign archive checksum does not match its pinned release")
        with tarfile.open(archive) as package:
            for name in ("rcodesign", "COPYING"):
                member = package.getmember(f"{TOOL_DIRECTORY}/{name}")
                if not member.isfile():
                    raise ValueError("Unexpected rcodesign archive entry")
                package.extract(member, TOOL_CACHE)
        archive.unlink()
    return str(binary)


def initialize_identity():
    if STORE.exists():
        return resolve_identity()
    STORE.mkdir(mode=0o700, parents=True)
    mask = os.umask(0o077)
    try:
        run(signing_tool(), "--config-file", "/dev/null", "generate-self-signed-certificate",
            "--person-name", "cmux Local Signing", "--validity-days", "7300",
            "--pem-filename", str(STORE / "cmux"))
        PIN.write_text(json.dumps({"fingerprint": certificate_fingerprint()}) + "\n")
    finally:
        os.umask(mask)
    return resolve_identity()


def resolve_identity():
    files = (CERTIFICATE, PRIVATE_KEY, PIN)
    if STORE.is_symlink() or any(path.is_symlink() or not path.is_file() for path in files):
        raise ValueError("Local signing files are missing; restore them instead of generating another identity")
    if any(path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077 for path in files):
        raise ValueError("Local signing files must be owned by the current user with mode 0600")
    fingerprint = certificate_fingerprint()
    if json.loads(PIN.read_text())["fingerprint"] != fingerprint:
        raise ValueError("Local certificate differs from its pinned identity")
    run("/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-checkend", "0", "-noout")
    public_key = run("/usr/bin/openssl", "pkey", "-in", str(PRIVATE_KEY), "-pubout", "-passin", "pass:")
    if public_key.strip() != run("/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-pubkey", "-noout").strip():
        raise ValueError("Local certificate and private key do not match")
    return fingerprint


def certificate_fingerprint():
    details = run("/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-noout", "-fingerprint", "-sha1").decode()
    return re.search(r"Fingerprint=([0-9A-Fa-f:]+)", details)[1].replace(":", "").upper()


def sign_code(path, identifier=None, entitlements=None, deep=False):
    path = require_project_path(path)
    identity = resolve_identity()
    if identifier is None:
        for location in ("Contents/Info.plist", "Resources/Info.plist", "Info.plist"):
            info = path / location
            if info.is_file():
                identifier = plistlib.loads(info.read_bytes())["CFBundleIdentifier"]
                break
        else:
            identifier = path.name
    if not re.fullmatch(r"[A-Za-z0-9._-]+", identifier):
        raise ValueError("Unsupported signing identifier")
    requirements = ROOT / "cache/local-signing"
    requirements.mkdir(parents=True, exist_ok=True)
    requirement_file = requirements / f"{identity}-{identifier}.csreq"
    if not requirement_file.exists():
        expression = f'=identifier "{identifier}" and certificate leaf = H"{identity}"'
        run("/usr/bin/csreq", "-r", expression, "-b", str(requirement_file))
    arguments = [signing_tool(), "--config-file", "/dev/null", "sign", "--pem-file", str(CERTIFICATE),
                 "--pem-file", str(PRIVATE_KEY), "--timestamp-url", "none", "--binary-identifier", identifier,
                 "--code-requirements-file", str(requirement_file), "--code-signature-flags", "runtime"]
    if entitlements is not None:
        arguments.extend(["--entitlements-xml-file", str(entitlements)])
    if not deep:
        arguments.extend(["--exclude", "**"])
    run(*arguments, str(path), timeout=180)


if __name__ == "__main__":
    try:
        configure_project_paths()
        if len(sys.argv) == 1:
            print(resolve_identity())
        elif sys.argv[1:] == ["init"]:
            initialize_identity()
            print("Local file signing identity initialized.")
        else:
            parser = argparse.ArgumentParser(description=__doc__)
            parser.add_argument("command", choices=["sign"])
            parser.add_argument("path", type=Path)
            parser.add_argument("--identifier")
            parser.add_argument("--entitlements", type=Path)
            parser.add_argument("--deep", action="store_true")
            args = parser.parse_args()
            sign_code(args.path, args.identifier, args.entitlements, args.deep)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f"Local signing: {error}")
