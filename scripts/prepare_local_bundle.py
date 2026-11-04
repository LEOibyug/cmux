#!/usr/bin/env python3
"""Turn a copied tagged Release bundle into clean, local production metadata."""
from pathlib import Path
import plistlib
import re
import subprocess

from project_paths import require_project_path

APP_ID = "com.cmuxterm.app"
SIDEBAR_POINT = APP_ID + ".cmux.sidebar"
CUA_PATH = Path("Contents/Library/cmux Computer Use.app/Contents/Info.plist")
CUA_ENVIRONMENT = {
    "CMUX_CUA_PERMISSIONS_GATE": "0",
    "CMUX_CUA_EXTERNAL_PERMISSION_FLOW": "1",
    "CMUX_CUA_TELEMETRY_ENABLED": "false",
    "CMUX_CUA_UPDATE_CHECK": "false"
}


def load(path):
    return plistlib.loads(path.read_bytes())


def normalize_bundle(bundle: Path) -> None:
    bundle = require_project_path(bundle)
    root_path = bundle / "Contents/Info.plist"
    old_id = load(root_path)["CFBundleIdentifier"]
    for path in bundle.rglob("Info.plist"):
        if not path.resolve().is_relative_to(bundle):
            raise ValueError("Bundle metadata points outside the copied candidate")
        info = load(path)
        identifier = info.get("CFBundleIdentifier", "")
        if path == root_path:
            info.update(CFBundleIdentifier=APP_ID, CFBundleName="cmux", CFBundleDisplayName="cmux")
            info["CMUXSidebarExtensionPointIdentifier"] = SIDEBAR_POINT
            info["NSDockTilePlugIn"] = "CmuxDockTilePlugin.plugin"
            info["CFBundleURLTypes"] = [
                {"CFBundleTypeRole": "Viewer", "CFBundleURLName": APP_ID + ".web", "CFBundleURLSchemes": ["http", "https"], "LSHandlerRank": "Default"},
                {"CFBundleTypeRole": "Viewer", "CFBundleURLName": APP_ID + ".local", "CFBundleURLSchemes": ["cmux"], "LSHandlerRank": "Default"},
                {"CFBundleTypeRole": "Viewer", "CFBundleURLName": "SSH URL", "CFBundleURLSchemes": ["ssh"], "LSHandlerRank": "Alternate"}
            ]
        elif path == bundle / CUA_PATH:
            info.update(CFBundleIdentifier="com.cmuxterm.cua", CFBundleName="cmux Computer Use", CFBundleDisplayName="cmux Computer Use")
        elif path == bundle / "Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/Info.plist":
            info["CFBundleIdentifier"] = APP_ID + ".docktileplugin"
        elif identifier == old_id:
            name = re.sub(r"[^a-z0-9-]", "-", info.get("CFBundleName", path.parent.parent.stem).lower())
            info["CFBundleIdentifier"] = APP_ID + ".resources." + name
        elif identifier.startswith(old_id + "."):
            info["CFBundleIdentifier"] = APP_ID + identifier[len(old_id):]
        info.pop("LSEnvironment", None)
        if path == bundle / CUA_PATH:
            # Product integration/privacy policy, not a development launch override.
            info["LSEnvironment"] = CUA_ENVIRONMENT
        path.write_bytes(plistlib.dumps(info))
    points = bundle / "Contents/Extensions"
    points.mkdir(exist_ok=True)
    for path in points.glob("*.appextensionpoint"):
        path.unlink()
    (points / (SIDEBAR_POINT + ".appextensionpoint")).write_bytes(plistlib.dumps({SIDEBAR_POINT: {
        "_EXScopeRestriction": "none", "EXExtensionPointIsPublic": True, "EXPresentsUserInterface": True
    }}))
    for path in bundle.rglob("*"):
        if path.name in [".DS_Store", "Icon\r"] and path.is_file():
            path.unlink()
    subprocess.run(["/usr/bin/xattr", "-cr", str(bundle)], check=True, capture_output=True)
    validate_bundle(bundle)


def validate_bundle(bundle: Path) -> None:
    root = load(bundle / "Contents/Info.plist")
    if any(root.get(key) != value for key, value in {
        "CFBundleIdentifier": APP_ID, "CFBundleName": "cmux", "CFBundleDisplayName": "cmux",
        "CMUXSidebarExtensionPointIdentifier": SIDEBAR_POINT
    }.items()):
        raise ValueError("Bundle does not have the production cmux identity")
    schemes = {scheme for group in root.get("CFBundleURLTypes", []) for scheme in group.get("CFBundleURLSchemes", [])}
    if schemes != {"http", "https", "cmux", "ssh"}:
        raise ValueError("Bundle contains unexpected URL schemes")
    for path in bundle.rglob("Info.plist"):
        info = load(path)
        environment = info.get("LSEnvironment")
        if environment and (path != bundle / CUA_PATH or environment != CUA_ENVIRONMENT):
            raise ValueError("Bundle retains a development launch environment")
        text = plistlib.dumps(info).decode()
        if any(marker in text for marker in [".debug.", "cmux-dev-", "cmux DEV", "CMUX_TAG", "CMUX_SOCKET_PATH", "CFFIXED_USER_HOME"]):
            raise ValueError("Bundle retains development metadata")
    helper = load(bundle / CUA_PATH)
    plugin = load(bundle / "Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/Info.plist")
    if helper.get("CFBundleIdentifier") != "com.cmuxterm.cua" or plugin.get("CFBundleIdentifier") != APP_ID + ".docktileplugin":
        raise ValueError("Nested app or Dock plugin has the wrong identity")
    points = list((bundle / "Contents/Extensions").glob("*.appextensionpoint"))
    if len(points) != 1 or set(load(points[0])) != {SIDEBAR_POINT}:
        raise ValueError("Sidebar extension point is not production-scoped")
