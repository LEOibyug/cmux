#!/usr/bin/env bash
# Source this file before invoking development tools; all writable paths stay in this checkout.
_cmux_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

cmux_require_project_path() {
  python3 -S -B - "$CMUX_PROJECT_ROOT" "$@" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1]).resolve()
for value in sys.argv[2:]:
    path = pathlib.Path(value).expanduser().resolve()
    if path != root and root not in path.parents:
        sys.exit("Refusing development output outside the project: " + str(path))
PY
}

export CMUX_PROJECT_ROOT="$_cmux_project_root"
export CMUX_CACHE_DIR="$CMUX_PROJECT_ROOT/cache"
export CMUX_TMP_DIR="$CMUX_PROJECT_ROOT/tmp"
export CMUX_RUNTIME_DIR="$CMUX_TMP_DIR/runtime"
_cmux_short_root="$CMUX_PROJECT_ROOT"
if [[ -d "$HOME/Work" ]]; then
  _cmux_work_root="$(cd "$HOME/Work" && pwd -P)"
  case "$CMUX_PROJECT_ROOT/" in
    "$_cmux_work_root/"*) _cmux_short_root="$HOME/Work/${CMUX_PROJECT_ROOT#"$_cmux_work_root/"}" ;;
  esac
fi
export CMUX_SOCKET_DIR="$_cmux_short_root/tmp/s"

cmux_dev_socket_path() {
  local digest LC_ALL=C
  digest="$(printf '%s' "$1" | shasum -a 256)"
  local path="$CMUX_SOCKET_DIR/${digest:0:12}.sock"
  if [[ ${#path} -gt 103 ]]; then
    echo "Project socket path is too long; use an existing shorter project symlink." >&2
    return 1
  fi
  printf '%s\n' "$path"
}
export TMPDIR="$CMUX_TMP_DIR/" TMP="$CMUX_TMP_DIR" TEMP="$CMUX_TMP_DIR"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPYCACHEPREFIX="$CMUX_CACHE_DIR/python"
export CFFIXED_USER_HOME="$CMUX_CACHE_DIR/home"
export XDG_CACHE_HOME="$CMUX_CACHE_DIR/xdg"
export CARGO_HOME="$CMUX_CACHE_DIR/cargo"
export RUSTUP_HOME="$CMUX_CACHE_DIR/rustup"
export CARGO_TARGET_DIR="$CMUX_CACHE_DIR/cargo-target"
export CMUX_TUI_CLIENT_LOCAL="${CMUX_TUI_CLIENT_LOCAL:-$CARGO_TARGET_DIR/release/cmux-tui}"
if [[ -x "$CMUX_PROJECT_ROOT/.git/toolchains/zig-aarch64-macos-0.16.0/zig" ]]; then
  export CMUX_ZIG="${CMUX_ZIG:-$CMUX_PROJECT_ROOT/.git/toolchains/zig-aarch64-macos-0.16.0/zig}"
fi
export ZIG_GLOBAL_CACHE_DIR="$CMUX_CACHE_DIR/zig/global"
export ZIG_LOCAL_CACHE_DIR="$CMUX_CACHE_DIR/zig/local"
export GOCACHE="$CMUX_CACHE_DIR/go/build"
export GOMODCACHE="$CMUX_CACHE_DIR/go/mod"
export GOPATH="$CMUX_CACHE_DIR/go"
export CLANG_MODULE_CACHE_PATH="$CMUX_CACHE_DIR/swift-modules"
export SWIFT_MODULECACHE_PATH="$CMUX_CACHE_DIR/swift-modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$CMUX_CACHE_DIR/swift-modules"
export npm_config_cache="$CMUX_CACHE_DIR/npm"
export BUN_INSTALL_CACHE_DIR="$CMUX_CACHE_DIR/bun"
export PIP_CACHE_DIR="$CMUX_CACHE_DIR/pip"
export HOMEBREW_CACHE="$CMUX_CACHE_DIR/homebrew"
export HOMEBREW_LOGS="$CMUX_TMP_DIR/homebrew-logs"
export HOMEBREW_NO_AUTO_UPDATE=1
export CMUX_DERIVED_DATA="${CMUX_DERIVED_DATA:-$CMUX_CACHE_DIR/xcode}"
export CMUX_SOURCE_PACKAGES_DIR="${CMUX_SOURCE_PACKAGES_DIR:-$CMUX_CACHE_DIR/swiftpm/SourcePackages}"
export CMUX_CUA_CACHE_DIR="${CMUX_CUA_CACHE_DIR:-$CMUX_CACHE_DIR/cmux-cua}"
export CMUX_GHOSTTY_HELPER_CACHE_DIR="${CMUX_GHOSTTY_HELPER_CACHE_DIR:-$CMUX_CACHE_DIR/ghostty-cli-helper}"
export CMUX_GHOSTTYKIT_CACHE_DIR="${CMUX_GHOSTTYKIT_CACHE_DIR:-$CMUX_CACHE_DIR/ghosttykit}"
export GHOSTTYKIT_ARCHIVE_CACHE_DIR="${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-$CMUX_CACHE_DIR/downloads/ghosttykit}"
export CMUX_UI_LAB_CACHE="${CMUX_UI_LAB_CACHE:-$CMUX_CACHE_DIR/ui-lab}"
export CMUX_RELOAD_NO_GLOBAL_CLI_LINKS=1
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

cmux_require_project_path "$CMUX_CACHE_DIR" "$CMUX_TMP_DIR" "$CMUX_DERIVED_DATA" \
  "$CMUX_SOURCE_PACKAGES_DIR" "$CMUX_CUA_CACHE_DIR" "$CMUX_GHOSTTY_HELPER_CACHE_DIR" \
  "$CMUX_GHOSTTYKIT_CACHE_DIR" "$GHOSTTYKIT_ARCHIVE_CACHE_DIR" "$CMUX_UI_LAB_CACHE" \
  "$CFFIXED_USER_HOME" "$CMUX_SOCKET_DIR" "$CLANG_MODULE_CACHE_PATH" \
  "$CARGO_HOME" "$RUSTUP_HOME" "$CARGO_TARGET_DIR" "$PYTHONPYCACHEPREFIX" \
  "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR" "$GOCACHE" "$GOMODCACHE" "$GOPATH" \
  "$npm_config_cache" "$BUN_INSTALL_CACHE_DIR" "$PIP_CACHE_DIR" \
  "$HOMEBREW_CACHE" "$HOMEBREW_LOGS" "$XDG_CACHE_HOME" || return 1
mkdir -p "$CMUX_CACHE_DIR" "$CMUX_TMP_DIR" "$CMUX_RUNTIME_DIR" "$CMUX_SOCKET_DIR" "$CLANG_MODULE_CACHE_PATH" "$CFFIXED_USER_HOME"
unset _cmux_project_root _cmux_short_root _cmux_work_root
