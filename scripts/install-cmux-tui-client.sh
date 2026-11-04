#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/project-env.sh" || exit 1
# Bundle an explicitly supplied SSH TUI client. Never fetch or upgrade artifacts.
set -euo pipefail

APP_PATH=""
REQUIRED_CAPABILITIES=()
while (( $# )); do
  case "$1" in
    --require-capability)
      [[ $# -ge 2 ]] || { echo 'error: --require-capability needs a value' >&2; exit 64; }
      REQUIRED_CAPABILITIES+=("$2")
      shift 2
      ;;
    -h|--help)
      printf '%s\n' 'Usage: CMUX_TUI_CLIENT_LOCAL=/path/to/cmux-tui scripts/install-cmux-tui-client.sh <app-path> [--require-capability <name>]...'
      exit 0
      ;;
    -*) echo "error: unknown option: $1" >&2; exit 64 ;;
    *)
      [[ -z "$APP_PATH" ]] || { echo 'error: only one app path is accepted' >&2; exit 64; }
      APP_PATH="$1"
      shift
      ;;
  esac
done
[[ -n "$APP_PATH" && -d "$APP_PATH/Contents" ]] || { echo 'error: app bundle is required' >&2; exit 64; }
cmux_require_project_path "$APP_PATH" || exit 1
CLIENT="$CMUX_TUI_CLIENT_LOCAL"
[[ -f "$CLIENT" && -x "$CLIENT" ]] || {
  echo 'error: build the local SSH TUI client or set CMUX_TUI_CLIENT_LOCAL to an existing executable; this personal build never downloads it' >&2
  exit 1
}
PROBE="$("$CLIENT" remote-probe --json)"
python3 -c '
import json, sys
probe = json.loads(sys.argv[1])
if probe.get("app") != "cmux-tui":
    raise SystemExit("error: local executable is not a cmux-tui client")
missing = set(sys.argv[2:]) - set(probe.get("capabilities", []))
if missing:
    raise SystemExit("error: local client lacks required capabilities: " + ", ".join(sorted(missing)))
' "$PROBE" ${REQUIRED_CAPABILITIES[@]+"${REQUIRED_CAPABILITIES[@]}"}
DEST_DIR="$APP_PATH/Contents/Resources/bin"
mkdir -p "$DEST_DIR"
install -m 755 "$CLIENT" "$DEST_DIR/cmux-tui"
printf '%s\n' 'Bundled the local SSH TUI client without network acquisition.'
