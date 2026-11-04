#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/project-env.sh" || exit 1
set -euo pipefail

# Preview or remove only this checkout's tagged development artifacts.
apply=0
older_than_days=0
keep_tags=" "
usage() {
  echo "Usage: scripts/cleanup-dev-builds.sh [--apply] [--older-than DAYS] [--keep TAG]"
  echo "Only project cache/xcode tagged apps and tmp runtime files are considered. Running tags are preserved."
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --older-than) older_than_days="${2:?missing DAYS}"; shift 2 ;;
    --keep) keep_tags="$keep_tags${2:?missing TAG} "; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$older_than_days" =~ ^[0-9]+$ ]] || { echo "DAYS must be nonnegative" >&2; exit 2; }

artifact_paths() {
  local tag="$1"
  printf '%s\n' \
    "$CMUX_DERIVED_DATA/Build/Products/Debug/cmux DEV ${tag}.app" \
    "$CMUX_DERIVED_DATA/Build/Products/Release/cmux DEV ${tag}.app" \
    "$CMUX_RUNTIME_DIR/cmux-${tag}" \
    "$CMUX_RUNTIME_DIR/cmux-debug-${tag}.log" \
    "$CMUX_RUNTIME_DIR/cmux-reload-${tag}.log" \
    "$CMUX_TMP_DIR/homes/${tag}" \
    "$(cmux_dev_socket_path "$tag")" \
    "$(cmux_dev_socket_path "daemon-${tag}")"
}

seen=" "
for app in "$CMUX_DERIVED_DATA"/Build/Products/{Debug,Release}/cmux\ DEV\ *.app; do
  [[ -d "$app" ]] || continue
  tag="${app##*/cmux DEV }"
  tag="${tag%.app}"
  [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || continue
  [[ "$seen" != *" $tag "* ]] || continue
  seen="$seen$tag "
  if [[ "$keep_tags" == *" $tag "* ]] || pgrep -f "cmux DEV ${tag}.app/Contents/MacOS" >/dev/null; then
    echo "keep $tag (requested or running)"
    continue
  fi
  mtime="$(stat -f %m "$app")"
  age=$(( ($(date +%s) - mtime) / 86400 ))
  [[ "$age" -ge "$older_than_days" ]] || continue
  while IFS= read -r path; do
    [[ -e "$path" || -L "$path" ]] || continue
    # A compatibility symlink is removed, not followed into its target.
    cmux_require_project_path "$(dirname "$path")" || exit 1
    if [[ -L "$path" ]]; then
      if [[ "$apply" -eq 1 ]]; then rm -f -- "$path"; fi
    else
      cmux_require_project_path "$path" || exit 1
      if [[ -S "$path" ]]; then
        echo "keep socket $path (runtime ownership requires explicit cleanup)"
        continue
      fi
      if [[ "$apply" -eq 1 ]]; then rm -rf -- "$path"; fi
    fi
    printf '%s %s\n' "$([[ "$apply" -eq 1 ]] && echo removed || echo preview)" "$path"
  done < <(artifact_paths "$tag")
done
