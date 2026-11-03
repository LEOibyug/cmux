# Sourced by Xcode script phases that look up external tools (cargo, rustup,
# go, zig). A caller may pass its PATH as CMUX_CALLER_PATH when building
# through Xcode. Restore it after Xcode's own tool directories. Without the
# setting (normal local builds and Xcode.app), this does nothing.
if [ -n "${CMUX_CALLER_PATH:-}" ]; then
  export PATH="${PATH%:/usr/bin:/bin:/usr/sbin:/sbin}:${CMUX_CALLER_PATH}"
fi

# Prevent dyld misaligned Mach-O LINKEDIT string pool crashes on macOS 27+ when host
# proc-macro dylibs or build scripts are stripped during cargo --release builds.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP:-none}"

