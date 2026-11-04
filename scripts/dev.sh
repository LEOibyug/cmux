#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/project-env.sh"
if [[ $# -eq 0 ]]; then
  echo "Usage: scripts/dev.sh <command> [arguments...]" >&2
  exit 2
fi
if [[ "$1" == swift && $# -gt 1 ]]; then
  shift
  action="$1"
  shift
  case "$action" in
    build|test|run|package)
      exec swift "$action" --cache-path "$CMUX_CACHE_DIR/swiftpm/cache" \
        --config-path "$CMUX_CACHE_DIR/swiftpm/config" \
        --security-path "$CMUX_CACHE_DIR/swiftpm/security" "$@"
      ;;
    *) exec swift "$action" "$@" ;;
  esac
fi
exec "$@"
