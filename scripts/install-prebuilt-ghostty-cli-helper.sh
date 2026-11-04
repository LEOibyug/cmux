#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/install-prebuilt-ghostty-cli-helper.sh <helper-path> <app-path> [--archs "arm64 x86_64"]
EOF
}

if [[ $# -ne 2 && ( $# -ne 4 || "${3:-}" != --archs ) ]]; then
  usage >&2
  exit 1
fi

HELPER_PATH="$1"
APP_PATH="$2"
EXPECTED_ARCHS="${4-arm64 x86_64}"
case "$EXPECTED_ARCHS" in
  arm64|x86_64|"arm64 x86_64"|"x86_64 arm64") ;;
  *) echo "error: unsupported helper architectures: $EXPECTED_ARCHS" >&2; exit 1 ;;
esac
DEST_PATH="$APP_PATH/Contents/Resources/bin/ghostty"

if [[ ! -f "$HELPER_PATH" ]]; then
  echo "error: Ghostty CLI helper not found at $HELPER_PATH" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST_PATH")"
install -m 755 "$HELPER_PATH" "$DEST_PATH"

EXPECTED_SORTED="$(printf '%s\n' $EXPECTED_ARCHS | sort | xargs)"
ACTUAL_ARCHS="$(lipo -archs "$DEST_PATH" | tr ' ' '\n' | sort | xargs)"
if [[ "$ACTUAL_ARCHS" != "$EXPECTED_SORTED" ]]; then
  echo "error: $DEST_PATH slices are '$ACTUAL_ARCHS', expected exactly '$EXPECTED_SORTED'" >&2
  exit 1
fi
echo "Installed Ghostty CLI helper ($EXPECTED_ARCHS) at $DEST_PATH"
