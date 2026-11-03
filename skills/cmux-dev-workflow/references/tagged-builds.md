# Tagged Builds

Tagged builds isolate app name, bundle ID, debug socket, and DerivedData path so multiple agents and the user's normal app do not collide.

For this local-only personal fork, build the explicit local helper first:

```bash
(cd cmux-tui && cargo build --release --locked -p cmux-tui --bin cmux-tui)
./scripts/reload.sh --tag <tag> --no-global-cli-links
./scripts/reload.sh --tag <tag> --launch --no-global-cli-links
./scripts/reload.sh --tag <tag> --build-only --no-global-cli-links
```

No backend, account, service credentials or official helper download is required.
`CMUX_TUI_CLIENT_LOCAL` may select another compatible local executable. Zig 0.16.0
and the pinned Rust toolchain remain build prerequisites. See [contributor setup](../../../CONTRIBUTING.md#getting-started).

A normal reload builds, then terminates the running app with the same tag; `--launch`
also opens the replacement. `--build-only` validates a separately staged bundle
without replacing the app or changing its daemon or tag state, then removes that
validation artifact. It cannot be combined with `--launch`.

For an optimized native-architecture build, use `reload.sh --release --tag <tag>`.
Reuse the tag and `--derived-data` cache; no full tests or release/fleet pipeline
is implied. Stable installation remains subject to the restrictions below.

## The user's running cmux

The installed cmux (`/Applications/cmux.app`, bundle id `com.cmuxterm.app`, process `cmux`) holds the user's live agent sessions. Never quit, kill (`pkill -x cmux`, `killall cmux`), relaunch or profile it with `xctrace --launch` or Instruments, and never launch a locally built Release app or any other bundle that uses `com.cmuxterm.app` while it runs. To reproduce the user's state, copy their session into the tagged build instead of touching the running app. Profile only by attaching to a tagged build's pid.

`reloadp.sh` refuses to run while another stable-id cmux is running;
`reload.sh --bundle-id` accepts only `com.cmuxterm.app.debug.*` IDs. A different
bundle with the stable ID also exits instead of replacing the running app
(`SingleInstanceConflictPolicy`). Never bypass these protections;
`CMUX_ALLOW_REPLACING_RUNNING_CMUX=1` is an override only the user may set.

## Prebuilt GhosttyKit

For prebuilt GhosttyKit, run `./scripts/download-prebuilt-ghosttykit.sh` (it verifies the pinned artifact), then use `CMUX_GHOSTTYKIT_PREPROVISIONED=1` with the tagged reload.

## Compile-only checks

Use the tagged `reload.sh --build-only` command above. Reuse the same tag to retain
its DerivedData cache. Tags must contain 1–40 ASCII letters, digits, underscores
or hyphens; socket slugs lowercase letters and replace underscores with hyphens.

An app build does not compile or execute the test targets; use the
[test verification guide](../../cmux-testing/references/local-vs-ci-validation.md#native-app-versus-test-compilation)
for those checks. For GhosttyKit source builds, follow the
[Ghostty workflow](../../cmux-ghostty/SKILL.md).

## App path links

A normal `reload.sh` build prints an `App path:` line with the absolute path to the built `.app`. Use it to confirm the tag built. Never put a `file://` URL, a raw `.app` or DerivedData path, or a `/tmp/cmux-<tag>/...` link in chat output.

## Tagged CLI and socket

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, uses the matching tagged CLI from DerivedData (or, for a fleet build restored with `publish-hq`, from `~/Library/Application Support/cmux/tag-app-cache`), scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for that tag.

`/tmp/cmux-cli` points at the most recently reloaded build and can target the user's main app socket, so it is never safe for tagged dogfood.

## Cleanup

Before launching a new tagged run, quit older tagged apps you started this session and remove their stale `/tmp` sockets. Remove derived data only when no active task needs it.
