# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

The canonical schema is local `schemas/cmux.schema.json` and is embedded in the
app for offline validation. Newly created configs omit `$schema`; no remote
schema URL is required. Existing files retain their editor-selected schema URLs
when copied from the legacy settings path.

For themes, fonts, transparency, and other appearance settings across Ghostty config and `cmux.json`, see [Customizing cmux's look](customizing-appearance.md).

## Control Center

Select the permanent **Control Center** item in the left workspace sidebar, use
**Command-Shift-J**, or choose **File → Control Center**. Chat replaces the central
content of that same main window; it does not open another window, create a
workspace or use the right sidebar. Sessions, favorites and configuration stay
inside that central page under Browse. The `openControlCenter` shortcut remains
configurable; explicit overrides and unbindings take priority.

Sessions, favorites, named launch collections, explicit preferences, settings
and operation receipts work without a model. Sessions default to OMP; the
source picker lists agents whose history is enabled in Vault settings. Searches
and exact opens stay within that source and never enable disabled histories.
The Saved button toggles the persisted bookmark, identified by agent and session
ID rather than a temporary search-result ID. Identical session IDs from different
agents remain separate favorites, including after restart.
OMP discovery follows its own conversation layout: project-bucket journals and
supported flat-root journals are conversations; nested task/artifact journals are
not. User forks remain visible even when their header has `parentSession`, and
symbolic-link session roots use the same admission rule.

The installed OMP executable is a separate runtime dependency; Connection can
select an absolute installed path and a default directory. Exact OMP opens use
the indexed journal, never `--continue`: an already running session is focused,
known-held/unknown ownership is blocked, and cmux serializes pending resumes.
OMP does not expose an atomic lease-transfer/no-fork launch protocol; an external
writer racing the final probe-to-launch gap remains an upstream boundary. Other
agents use their existing Vault resume adapters and installed runtime; their
sessions are not passed through OMP's journal or lease checks. The controller
never steals a lease, deliberately forks, or automatically retries a failed resume.

The controller enters the journal's recorded logical directory before executing
OMP, passing that same path as `--cwd` and the exact journal as `--session`.
Startup uses the terminal's initial command, not shell-prompt typeahead, and runs
even while the Control Center page covers the terminal. Success requires a live
OMP process in that pane's foreground process group with matching arguments,
directory and cmux scope; exit or observation timeout leaves the workspace open
with a blocked receipt rather than reporting an empty shell as success.
Exact opens revalidate current-source journal headers instead of searching the
transcript corpus again, and reject duplicate session IDs. OMP searches prune
nested artifact directories before content scanning; body-text search remains
available for admitted conversation journals.


Saved collections contain ordered target snapshots with stable item IDs.
Opening a collection reuses existing targets where possible; independent failed
items do not close successful ones. Failed-only retry carries prior successes
forward without executing them again. Native workspace groups have one owner
per workspace; conflicting group anchors can prevent grouping and are reported
without closing or duplicating existing work. Logical paths remain visible and
are passed to OMP's `--cwd`; dangling symlinks and missing volumes block creation.

The model connection is configured in **Control Center → Connection**:

- Base URL: an OpenAI-compatible Responses base; Codexpress defaults to
  `http://127.0.0.1:17865/v1`. The client sends `/responses` and queries `/models`
  only on explicit request. The `17867` management API and its Key are separate.
- Model: entered manually or chosen from the returned list; no fixed model.
- API Key: stored in the controller's private connection file, not `cmux.json`,
  UserDefaults, prompts, SQLite records, or operation history. No keychain/login
  integration is required.
- Default Directory: the existing logical directory used when a launch omits `cwd`.
  New configurations start with `~/Work/temp`; an explicitly saved directory is
  preserved. A request's explicit directory takes precedence, followed by relevant
  directory memory/context, then this configured default. Missing paths are not
  silently created or replaced.

**Import from Codexpress** reads the running chat ingress address and client API
key through the local read-only `chatbot.status` and `chatbot.key` control calls.
The socket is `control.sock` under `CODEXPRESS_STATE_DIR`, or under
`~/Library/Application Support/Codexpress` by default. Import saves the address
and client key while preserving the model, OMP executable and default directory.
It does not use the management Key, enable or restart the ingress, query models,
or send a model request. An unavailable or disabled ingress leaves the saved
connection unchanged.

The production data directory is
`~/Library/Application Support/com.cmuxterm.app/ControlCenter/`:
`control-center.sqlite3` contains favorites, collections, preferences and actual
step receipts; `connection.json` is an owner-only `0600` file. Tagged builds use
their own bundle-ID namespace. Neither data nor runtime resources depend on the
development checkout.

Chat uses a native multiline composer and a mounted Markdown transcript. Text,
public reasoning summaries and individual tool calls/results appear in their
actual order as the stream arrives. Provisional tool arguments are display-only:
execution still requires a fully validated completed response and host approval.
The transport consumes network chunks and returns on `response.completed`, even
if the HTTP connection remains open. UI publication is coalesced rather than
rebuilding the transcript on every token. Stop retains partial output, never
retries uncertain actions, and does not roll back completed effects.

The composer includes model and reasoning-effort menus. **Default** omits the
reasoning override; explicit choices send `reasoning.effort`. Refresh the model
list explicitly. Images can be selected, pasted or dropped and removed before
sending. They are normalized locally to PNG at up to 2048 pixels, with bounded
input/payload size, and sent as Responses `input_image` parts alongside text.
Sending shares that message's context and images with the configured provider.
Remote or model-supplied Markdown images are not loaded automatically.

Messages include the exact earlier model outputs and actual tool results,
including opaque encrypted reasoning when supplied by the API. **New Chat**,
`/new` and `/clear` reset the visible conversation and model context, not durable
logs or saved favorites/memories. User bubbles size to their content; **Edit** and
**Retry from here** icons sit outside the bubble and appear on hover or keyboard
focus, with reserved toolbar space to keep the layout stable. These actions
replace that turn and later context; they make a fresh request, do not replay
cached tool calls, and cannot undo previous actions. Enter sends, Shift-Enter
inserts a line, and Command-Enter also sends. IME composition is respected.
Up/Down at the input boundary recall prior prompts and restore an unsent draft.

Complete messages, images, request JSON bodies, model outputs, tool arguments and
results, approvals, errors and lifecycle timestamps are kept in the separate
owner-only `chat-logs.sqlite3`. API keys and authentication headers are excluded.
The latest conversation and its exact context restore after relaunch; interrupted
work is marked as such and never automatically executed again. **Browse → cmux Settings**
shows conversation/event counts, database-plus-sidecar bytes (disk, not RAM), and
a confirmed cleanup button. Cleanup preserves connection configuration, favorites,
collections, explicit memories and separate ordinary operation history.

OMP navigation uses a persistent metadata table at
`~/Library/Application Support/com.cmuxterm.app/Vault/OMPMetadata/metadata.sqlite3`.
Startup initializes or refreshes it off the main thread; filesystem events update
changed journals and reconcile directory changes. Warm searches query the saved
snapshot immediately, including after relaunch, while reconciliation runs in the
background. A failed scan preserves the last committed snapshot.

The table contains bounded display titles, native session IDs, logical working
directories, branches, journal paths, modification dates and file fingerprints.
Namespaces follow the effective Vault registration and source root; disabled
history sources stop their watchers. Journal metadata uses the existing bounded
header/title-slot reader, and task/artifact directories remain excluded.

Control Center restricts session discovery and operations to Connection's default
directory and its descendants, using canonical component boundaries. The default
directory may be a symlink; escaping child aliases and destinations are excluded.
The session-storage root is independent of this working-directory boundary.
OMP metadata search filters the full table before pagination: 50 results by default,
up to 100 per page, with an absolute `next_offset` cursor. Other sources retain
their recent-500 metadata window. `search_content: true` streams admitted OMP
transcripts only when explicitly requested. Opening still revalidates the native
header, source, exact identity, transfer state, lease and live ownership.

**Browse → Sessions** provides Active, Archived, Trash and Pending lists plus manual
refresh. `refresh_sessions` reconciles the native index and managed manifests;
filesystem events remain the normal incremental update path. Manual refresh also
recanonicalizes unchanged records after directory/symlink changes. Partial manifest
errors do not hide unrelated recoverable records.

`update_session_directory`, `archive_session`, `trash_session` and `restore_session`
operate on an opaque exact `target_id` returned by the latest search. Ask Before
Changes displays native identity, physical paths, scope and fingerprints; Full
Access omits that prompt, not the ownership/scope checks. Running conversations,
duplicate IDs and changed approval snapshots are refused. Cwd changes migrate the
native journal/artifacts, not physical project folders; destination directories
must exist inside the same scope. Trash is reversible; no permanent purge exists.

For physical project archival, ask in chat, for example “Archive `~/Work/ProjectA`
and `~/Work/ProjectB` into `~/Work/Archived`” when `~/Work` is the configured
default directory. `archive_directories` accepts `paths` (1–32 explicit absolute
directory paths, with `~` expansion) and optional `destination` (archive parent,
default `default_directory/Archived`). No workspace name or user-selected opaque
session IDs are required. The worker discovers every associated top-level OMP
conversation by canonical cwd membership, including descendants, historical
missing subdirectories and normal forks; task-artifact journals remain excluded.
It first produces a read-only plan. One approval shows exact folder moves,
conversation IDs, journal paths, cwd remapping, counts and plan digest. Execution
binds the current connection, registered history source and canonical scope to
that approval, and the worker rebuilds the digest before mutation. Full Access
skips only the prompt. Neither planning nor execution changes Connection settings.

Folder archival refuses symlink leaf sources, overlaps, the scope root, escaping
destinations, existing targets, protected worker/session data, busy ownership and
cross-filesystem moves. It uses a same-filesystem atomic no-overwrite rename,
then archives related journals with their cwd mapped under the new folder.
Native IDs, titles, history, artifacts and images are preserved. A durable batch
manifest is kept at `ManagedSessions/DirectoryArchives/<requestID>`; normal
per-session archive/pending manifests remain authoritative for recovery. Exact
structured per-project/session receipts and request files are retained, including
partial or unknown outcomes. Started mutations always trigger native-index and
managed-manifest reconciliation, including remapped cwd. Incomplete/unknown
results block further mutations in the same model turn; no automatic retry,
compensation or fabricated rollback occurs. Refresh is read-only and does not
replay a batch. `archive_session` remains a single-conversation journal archive;
`restore_session` restores a conversation, not a physically archived project folder.

Mutations require the independently installed `cmux-omp-extension` worker from the
sibling project of that name. It bundles OMP data SDK/native addon 18.18.0 and uses
the installed macOS arm64 OMP 18.18.x executable's Bun runtime, without model setup,
provider requests, dummy credentials or automatic extension loading. Build and
install with `sh scripts/run-local.sh run build` and `sh scripts/run-local.sh run
install-local` in that project. The installed payload under
`~/.local/share/cmux-omp-extension/` is independent of development directories.

Archive records live under Control Center's `ManagedSessions` directory and contain a
durable manifest, journal, task artifacts and referenced image bytes. Native ID,
title, entry lineage and conversation content are retained; native serialization
may materialize image references as equivalent inline bytes. Journals normalized
lossily by the pinned SDK are refused before relocation. Successful cwd/restore
migrations retarget only matching OMP favorites and collection entries, once per
migration. Interrupted/unknown results preserve recovery paths in Pending and are
never automatically retried. Refresh reconciles state without replaying operations.

Context/request size and tool-round budgets remain bounded; oversized context is
reported rather than silently truncated.
The chat stays mounted across workspace and Browse page switches, preserving
scroll position, draft and expanded tool cards. Image data is sent to the renderer
once per attachment UUID, not with every token update. Hidden chat input cannot
take focus or consume terminal shortcuts. Initial renderer colors match the page.

The composer permission selector defaults to **Ask Before Changes**. Read-only
typed tools and `read_file` do not prompt; model-invoked changes show exact arguments
and resolved targets. Every Bash script, including inspection, requires approval
of the script, resolved logical cwd and output disclosure; background commands
also show their timeout. Reject executes nothing and creates no workspace.
Stop cancels pending approval and remaining work, not completed effects.
A changed target requires a new review. **Full Access**, enabled through explicit
inline confirmation, skips per-action approvals without a command denylist.
Neither mode elevates OS permissions or authorizes external sending, purchases or account/security changes.
The mode is saved locally and cannot be changed by a model tool or memory record.
Direct native buttons are already explicit user actions and do not add this model
approval step.

Use `open_command_workspace` for a new terminal running a requested command, for
example `command: ["ssh", "lab-computer"]` and an optional `cwd`. It never reuses
an existing workspace or starts OMP. The child changes to the validated logical
directory before executing the command; a missing directory prevents execution.
SSH uses existing user aliases/configuration. Authentication and host verification
remain in the terminal. After the command exits, an interactive shell remains.
The receipt confirms workspace creation and command **submission**, not completion
or a successful remote connection. Stop does not terminate an already launched
terminal command, and an uncertain launch is never retried automatically.
The `name` field is optional for both `open_command_workspace` and
`create_workspace`. Omit it, send `null`, or leave it blank to retain cmux's
automatic terminal title. A supplied nonblank name becomes the workspace title.

`open_command_workspace` accepts literal argument arrays; `bash.command` accepts
actual Bash source, including pipelines, redirection and scripts. Bash is never
classified read-only. It runs `/bin/bash --noprofile --norc -c` with stdin closed,
the inherited user environment and installed executable search paths (including
user runtime directories and Homebrew), without injecting model connection keys.
`cwd` defaults to the Connection directory; missing paths never trigger fallback
or implicit creation. `timeout_seconds` is 1–300, default 60. Bounded stdout/stderr,
exit status, signal, timeout and partial cancelled output are retained in receipts
and sent to the configured model. Stop terminates the owned command group, not
terminal workspaces. Shell state does not persist. Unknown outcomes are not
automatically retried or compensated.

`read_file` reads an explicit user-accessible path, with byte `offset` and `limit`
(default 12,000), accurate UTF-8 or base64 encoding, hash and continuation offset.
Generic paths are not restricted to the typed session default-directory scope.
`write_file` accepts UTF-8/base64; `edit_file` replaces exact unique UTF-8 text
unless `replace_all` is explicit. Both plan resolved targets, hashes and previews
before approval, then revalidate source bytes and symlink binding. Parent directories
must exist. Original overwritten bytes and metadata are retained privately under
`ControlCenter/FileBackups`; receipts disclose exact backup paths. The optional
`expected_sha256` detects stale input. Existing streaming tool UI shows these actions.

Files and tool output are untrusted data, not authorization. Only explicit user
requests authorize edits, risky operations or generic fallback. A malformed journal
can be inspected with `read_file`, then explicitly backed up, corrected or quarantined
with generic tools; never invent historical headers, IDs, cwd or conversation content.
Archive discovery returns structured issues, warnings and exact opaque record IDs.
Only an explicit user-selected `exclude_records` list leaves those files untouched;
approval and receipts retain exclusions and report `user_selected_partial` coverage.
A trustworthy `preflight_failed` receipt with `mutationStarted:false` permits repair;
partial or unknown operations retain the same-turn mutation barrier.

Only relevant explicit memories are loaded, with directory scopes covering their
descendants but not similarly prefixed neighbors. No automatic inferred-habit
database is maintained. The CLI's `control-center ask` also keeps chat context by
default; `--fresh` starts without it. The local `control_center.ask` RPC accepts
`follow_up: false` for the same context reset. An ask may wait for approval in the
central chat page; `status` exposes current partial output without credentials.

Function requests explicitly set `strict: false` so Responses does not promote
optional parameters to required ones. For `memory_save`, `save_favorite` and
`save_collection`, an omitted, `null` or empty `id` creates a host-generated UUID;
a nonempty edit ID must be a valid UUID of an existing record. Invalid or unknown
edit IDs never fall back to creating records. Open/delete IDs remain mandatory.

Settings edits use the existing typed runtime and JSONC mutation receipts.
Unrelated content is preserved; conditional undo refuses to overwrite a newer
external edit. Cancellation stops remaining work, not completed actions. Model
transport timeouts and unknown outcomes are never automatically replayed: read
the actual operation receipt before retrying.

## Automation socket trust boundary

`cmuxOnly` allows the cmux CLI and programs started from cmux terminals. This
uses the process ancestry of the caller, so a program launched inside a cmux
terminal is trusted even when it later starts another process or leaves the
terminal's original process group. Use `password` or `cmuxOnly` when untrusted
code may run inside a cmux terminal. `allowAll` also grants
access to other local macOS users and is unsafe on a shared Mac.

## Ghostty config live reload

cmux reads terminal settings from the Ghostty config: `~/.config/ghostty/config` and
`~/.config/ghostty/config.ghostty` (under `$XDG_CONFIG_HOME/ghostty/` when that is set),
`~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
(or its legacy `config`), and the cmux config under
`~/Library/Application Support/com.cmuxterm.app/`. cmux watches these files, every file
pulled in with `config-file`, and user theme files named by `theme` (an absolute path, or
`$XDG_CONFIG_HOME/ghostty/themes/<name>`, which defaults to `~/.config/ghostty/themes/<name>`,
for each side of a `light:…,dark:…` pair). Saving one of them reloads the
configuration the same way as Reload Configuration (Cmd+Shift+,), about 300 ms after
the last write. Atomic saves, Vim-style saves that move the old file aside, files
created after launch, and newly added includes are all picked up. A save that leaves
the contents unchanged, or a file cmux already reloaded itself (for example after
`cmux themes set` or a `cmux themes` preview), does not trigger another reload. A save
made while a reload is still applying reloads once more after it. Themes bundled with cmux or Ghostty.app
are not watched.

When Ghostty reports errors for the config (an unknown key, an invalid value, a missing
theme), cmux shows a notice in the corner of the window listing the first three, with a
button that opens the file at the offending line. The notice appears once per distinct set
of errors: reloads that keep the same errors stay quiet, fixing them hides the notice, and
reintroducing an error shows it again. `cmux config doctor` validates `cmux.json` only.

## `paneBorderColor` and `activePaneBorderColor`

Customize split-workspace pane boundaries controlled by cmux.

```json
{
  "paneBorderColor": "#6B7280",
  "activePaneBorderColor": "#3B82F6"
}
```

- `paneBorderColor`: overrides the divider color between cmux panes in split workspaces.
- `activePaneBorderColor`: draws a border around the focused cmux pane in split workspaces.

Both settings accept 6-digit hex colors (`#RRGGBB`). Omit a key, or set it to `null`, to use the default. These settings apply to cmux's multi-surface pane layout. When `paneBorderColor` is unset, the divider uses Ghostty's `split-divider-color` if one is configured.

## `app.windowTitleTemplate`

Opt-in template for the macOS `NSWindow.title`. Leave it unset or set it to an empty string to keep the default behavior, where the title follows the active workspace title or current directory.

```json
{
  "app": {
    "windowTitleTemplate": "[cmux:{windowToken}] {activeWorkspace}"
  }
}
```

Supported placeholders:

- `{windowId}`: the persisted per-window UUID.
- `{windowToken}`: the first 8 characters of the persisted window UUID.
- `{activeWorkspace}`: the active workspace title, falling back to the default title when the workspace title is blank.
- `{activeDirectory}`: the active workspace's current directory.
- `{defaultTitle}`: the title cmux would have used without a template. For `cmux ssh` workspaces it ends with the host, as in `build · big-red`.
- `{appName}`: `cmux`.

For tiling window managers such as AeroSpace or yabai, match on the stable token in the title. For example, the template above gives each restored macOS window a title containing `[cmux:abcd1234]`, so a rule can match `\\[cmux:abcd1234\\]`. The token is stable across relaunches for restored windows because it comes from the persisted window UUID.

## `app.confirmQuit`

Controls when cmux asks before quitting:

- `always`: show the quit confirmation on Cmd+Q or app quit.
- `dirty-only`: show it only when a workspace has a terminal or panel that reports close confirmation is needed.
- `never`: quit immediately.

Default: `always` for stable, nightly, and RC builds. DEV builds always behave as `never`, regardless of the file setting, so tagged development builds can be replaced without a full-screen quit dialog.

The older boolean `app.warnBeforeQuit` still works as a fallback when `app.confirmQuit` is not set. `true` maps to `always`; `false` maps to `never`.

## `app.forkConversationDefaultDestination`

Controls what the tab right-click `Fork Conversation` item does. The submenu still exposes every destination.

Values: `right`, `left`, `top`, `bottom`, `newTab`, `newWorkspace`.

Default: `right`.

## `terminal.agentHibernation`

Routine Agent Hibernation is opt-in. cmux hibernates idle background agent
processes to free RAM and CPU, then resumes each one with its saved session
when you visit its tab. Independently, memory pressure (critical system pressure,
or aggregate pressure below) can use the same lossless hibernation lifecycle even
when routine hibernation is disabled.
See [agent-hooks.md](agent-hooks.md#agent-hibernation) for the full eligibility
rules, confirmation settle window, and resume behavior.

```json
{
  "terminal": {
    "agentHibernation": {
      "enabled": true,
      "idleSeconds": 5,
      "maxLiveTerminals": 12
    }
  }
}
```

- `enabled`: turn routine Agent Hibernation on. Default: `false`. Aggregate-pressure safety hibernation remains available when this is `false`.
- `idleSeconds`: seconds a background idle agent terminal must be quiet before it can hibernate. A ~60s confirmation settle window still applies on top of this. Default: `5`. Range: `5`-`604800`.
- `maxLiveTerminals`: the target used only by opt-in routine hibernation before it hibernates the oldest idle background terminals. It is not a global memory or agent limit, and aggregate-pressure handling does not use it. Default: `12`. Range: `1`-`256`.

### Aggregate memory-pressure safety policy

cmux prefers macOS's resource-coalition physical footprint, which includes the
cmux process and its descendants. The private coalition layout is enabled only
on OS releases with a validated ABI; if the API or validation is unavailable,
cmux uses a complete, de-duplicated descendant process tree. An incomplete
listing is treated as unavailable and cannot authorize hibernation. Relative
percentages (warning at 50% and critical at 70% of installed physical memory,
with an optional 20%/10% available-memory corroboration) decide only when to
offer the idle-only pass. They are signals, not a memory ceiling or a limit on cmux.

While the same complete pressure remains through the existing
confirmation window, cmux considers every currently eligible idle, non-visible
agent through the ordinary lossless Agent Hibernation lifecycle. The scheduled
routine pass retains its oldest-activity ordering; the pressure pass considers
all eligible agents, so its encounter order does not limit or prioritize which
agents are eligible. The existing `idle` lifecycle state, terminal-input check,
transcript/process identity validation, and visible-panel protection remain
required; if those proofs are unavailable, that candidate is left running. This
policy never caps memory use, caps the number of agents/panes/processes,
throttles or blocks new work, or terminates active or visible work. Hibernated
agents resume from their saved session exactly as routine Agent Hibernation does.

Enable routine hibernation from the command palette (`⌘⇧P` -> Enable Agent Hibernation), from **Settings > Terminal > Agent Hibernation**, or with `cmux agent-hibernation on`.

## `sidebar.showAgentActivity`

Shows a loading spinner on sidebar workspace rows that currently have running coding agents or active manual loaders (`cmux workspace loading on`).

```json
{
  "sidebar": {
    "showAgentActivity": true,
    "loadingSpinnerPosition": "leading",
    "notificationBadgePosition": "leading"
  }
}
```

- `showAgentActivity`: show the spinner at all. Default: `true`. It is a live status signal, so it stays visible even when `sidebar.hideAllDetails` is on. Toggle it from **Settings > Sidebar > Show Loading Spinner**.
- `loadingSpinnerPosition`: `leading` (left, sharing the unread-badge slot) or `trailing` (right, in the close-button corner). Default: `leading`.
- `notificationBadgePosition`: which side the unread notification badge sits on, `leading` or `trailing`. Default: `leading`.

The spinner is compositor-driven (a Core Animation transform run by the render server), so it costs no per-frame CPU and pauses automatically while the window is occluded or Reduce Motion is on. Toggle it manually per workspace with `cmux workspace loading <on|off> [--id <name>]`; each `--id` is a separate loader and the command prints the workspace state as `before=ON;after=OFF`.

## `sidebar.compactAgentStatus`

Puts the workspace's own status on one line, like the Claude desktop session list: one small colored glyph, then the title. Agent hooks report each coding agent's state as a status entry (for example Claude Code's "Running" or "Needs input"), and by default every one gets its own row under the workspace title, next to the branch and directory line and the pull request rows. With `compactAgentStatus` on, those rows fold into the glyph, along with the notification preview, the unread count badge and the loading spinner, and a long title stops wrapping. Hover the glyph for the agent, pull request, branch, and directory details, plus the config profile an agent launched under when it isn't the default (`CLAUDE_CONFIG_DIR=~/.claude-outlook` shows as `outlook`).

Lines you added yourself stay where they are: the workspace description, your own `cmux set-status` keys, logs, progress, ports, the checklist, and a remote workspace's connection row with its Reconnect button. So `cmux set-status` under your own key is still the way to keep a line of your own in compact mode.

```json
{
  "sidebar": {
    "compactAgentStatus": true
  }
}
```

The glyph shows the loudest state that applies:

| State | Glyph |
| --- | --- |
| An agent reported an error | red warning triangle |
| An agent needs input | amber dot |
| An agent is running through subagents | pulsing gray connected-points glyph |
| An agent is waiting on a background command, a scheduled wakeup or a CI run | gray hourglass |
| An agent is running | pulsing gray dot, in place of the loading spinner |
| An agent is starting (no state reported yet) | dashed ring |
| Unread notifications | blue dot, in place of the unread count badge |
| Open pull request | gray pull request glyph |
| Merged pull request | purple merge glyph |
| Closed pull request | gray pull request glyph with a minus badge |
| Agent idle (done, seen) | gray checkmark |
| Branch, no pull request | gray branch glyph |
| Plain terminal | none; the title starts at the row's edge |

The hourglass only goes up when every running agent in the workspace reported that it is waiting, so a second agent still working keeps the row running.

cmux does not fetch a pull request's checks or mergeability, so an open pull request is gray whatever CI says. A pull request whose state repeated refresh failures could not confirm does not set the glyph at all.

Change any of them with `sidebar.compactStatusIcons`, a map from state to an [SF Symbol](https://developer.apple.com/sf-symbols/) name. The states are `error`, `needsInput`, `subagents`, `running`, `waiting`, `starting`, `unseen`, `pullRequestOpen`, `pullRequestMerged`, `pullRequestClosed`, `idle`, `branch` and `terminal`. Colors stay the same; a configured symbol replaces the badge too, draws at full size, and a name that does not render falls back to the built-in symbol. The built-in pull request and merge glyphs are drawn by cmux, since the SF Symbols ones are too narrow at sidebar size; name them `cmux.pullrequest` and `cmux.merge` to use them for another state.

```json
{
  "sidebar": {
    "compactAgentStatus": true,
    "compactStatusIcons": {
      "terminal": "apple.terminal",
      "needsInput": "hand.raised.fill",
      "idle": "moon.zzz"
    }
  }
}
```

- Default: `false`.
- Only agent-owned status keys lose their rows (`claude_code`, `codex`, and the other built-in agent integrations). Status set with `cmux set-status` under any other key keeps its row.
- The notification preview moves to the top of the tooltip too. Rows you added yourself (a workspace description, `cmux set-status` under other keys, logs, progress, ports) keep their lines.
- Workspace group headers show a glyph, after the group name, for the workspaces without a row of their own: the anchor workspace while the group is expanded, and every member once it is collapsed. Only states that ask for attention appear there (error, needs input, running, unread), the loudest first; hover it to see which workspace each comes from. It replaces the header's unread count.
- The pulse is a Core Animation opacity loop capped at 30 Hz. It stops while the window is hidden or occluded, and Reduce Motion keeps the dot still.
- A pull request glyph shows whether the pull request is open, merged or closed, and nothing about its checks. cmux does not fetch CI status or mergeability for a pull request, so there is no passing, failing or conflict glyph: adding one would advertise a color no user could see. An open pull request shows gray, merged shows purple, and closed shows gray with a minus badge. See [#12807](https://github.com/manaflow-ai/cmux/issues/12807).
- Pull request and branch details follow `sidebar.showPullRequests` and the git branch toggle: turn either off and the glyph ignores it. Toggle compact status from **Settings > Sidebar > Compact Agent Status**.

## `terminal.showTextBoxOnNewTerminals` and `terminal.focusTextBoxOnNewTerminals`

`terminal.showTextBoxOnNewTerminals` opens the TextBox on newly-created terminal sessions without moving keyboard focus into it.

`terminal.focusTextBoxOnNewTerminals` opens the TextBox and focuses it for foreground terminal sessions created from the app UI, such as new terminal workspaces, tabs, and splits. Terminals created through the cmux CLI/control socket do not auto-focus the TextBox, even when this setting is enabled, so background automation does not steal keyboard focus.

## Workspace terminal font size shortcuts

Cmd+Ctrl+= and Cmd+Ctrl+- increase or decrease every terminal in the selected workspace by one point. Cmd+Ctrl+0 resets them to the current Ghostty font size. Hidden, hibernated, and Dock terminals change with visible terminals, and newly created terminals inherit the workspace size. Rebind them with `shortcuts.bindings.increaseWorkspaceTerminalFontSize`, `shortcuts.bindings.decreaseWorkspaceTerminalFontSize`, and `shortcuts.bindings.resetWorkspaceTerminalFontSize`.

## New Workspace shortcut and the plus-button menu

Cmd+N creates a local workspace on this Mac. Rebind or unbind it from Settings > Keyboard Shortcuts or with `shortcuts.bindings.newTab`.

When `ui.newWorkspace.contextMenu` is not set, the plus-button menu lists `cmux.newWorkspace` (Cmd+N), `cmux.newTerminal` (Cmd+T), and `cmux.newBrowser` (Cmd+Shift+L). Each row shows its current shortcut, so a rebind in Settings or `cmux.json` appears the next time the menu opens; unbound and chord shortcuts show no hint. A configured menu keeps your order and still shows hints for built-in rows and for actions with a `shortcut`.

## `terminal.textBoxSubmitActions`

Controls what the TextBox submit button does for new terminal sessions. Active agent sessions such as Claude, Codex, OpenCode, and Pi always use plain Text Entry so prompts go into the running agent instead of launching another command.

Press Shift-Tab in the TextBox to cycle the default action. This shortcut is `shortcuts.bindings.cycleTextBoxSubmitAction`; rebind or disable it from Settings > Keyboard Shortcuts or `cmux.json`. Right-click the submit button to pick any configured action or open this documentation.

```json
{
  "terminal": {
    "textBoxDefaultSubmitAction": "codex",
    "textBoxSubmitActions": [
      {
        "id": "codex",
        "title": "Codex --yolo",
        "kind": "commandTemplate",
        "commandTemplate": "codex --yolo -- {{prompt}}",
        "systemImage": "sparkles",
        "assetName": "AgentIcons/Codex",
        "backgroundColorHex": "#8FDBFF"
      },
      {
        "id": "custom-router",
        "title": "Custom Router",
        "kind": "commandTemplate",
        "commandTemplate": "agent-router --plan {{prompt}}",
        "systemImage": "wand.and.stars",
        "imagePath": "~/Pictures/router.png",
        "backgroundColorHex": "#3DDC97"
      }
    ]
  }
}
```

Built-in action IDs: `claude`, `codex`, `opencode`, `pi`.

Set `textBoxDefaultSubmitAction` to `text-entry` to force plain Text Entry for new terminals.
Built-in provider actions shell-quote `{{prompt}}` before pasting the command. Claude may still show its workspace trust prompt before processing the prompt. Built-ins run `claude --dangerously-skip-permissions -- {{prompt}}`, `codex --yolo -- {{prompt}}`, `opencode --prompt {{prompt}}`, and `pi -- {{prompt}}`.

Action fields:

- `id`: stable action ID.
- `title`: menu label for custom actions.
- `kind`: `textEntry` or `commandTemplate`.
- `commandTemplate`: shell command for `commandTemplate`. Include `{{prompt}}` where the prompt should be shell-quoted into the command line.
- `preservePromptAfterLaunch`: optional boolean for custom launch-only actions. When `true`, cmux submits `commandTemplate` as a provider launch command while keeping the TextBox prompt intact for the active agent session.
- `systemImage`: fallback SF Symbol name shown on the submit button.
- `assetName`: optional app asset catalog image name, for example `AgentIcons/Codex`.
- `imagePath`: optional PNG or image path for the submit button.
- `backgroundColorHex`: action color metadata as RGB or RGBA hex. The submit button fill stays white and only changes opacity between enabled and disabled states.

## `terminal.uploadCommands`

Replace the built-in `scp` for terminal file drops and pastes over SSH with a
command you choose. When you drop or paste a file into a terminal running an SSH
session, cmux normally `scp`s it into a private directory on the host,
`~/.cache/cmux/paste/<session>/cmux-paste-<uuid>.<ext>`, and types the remote
path. `terminal.uploadCommands` is an ordered list of host-scoped
rules; when the ssh destination matches a rule, cmux runs that rule's command
instead and inserts what the command prints.

```json
{
  "terminal": {
    "uploadCommands": [
      {
        "hostPattern": "*.example.com",
        "command": "my-upload \"$CMUX_UPLOAD_LOCAL_PATH\" \"$CMUX_UPLOAD_DESTINATION:$CMUX_UPLOAD_REMOTE_PATH\""
      }
    ]
  }
}
```

- `hostPattern`: an fnmatch glob matched against the ssh destination (`user@` and
  IPv6 brackets stripped, then lowercased) — the same glob style as a single
  `ssh_config` `Host` pattern (`*`, `?`; no pattern lists or `!` negation). Omit
  it, or set it to `null`, for a catch-all. When the session carries a `HostName`
  ssh option (for example a connection through a ProxyCommand broker dialled as
  `localhost`), a rule also matches that resolved host, so a pattern written
  against either the alias or the real host works.
- `command`: run through `/bin/sh -c`, **once per file**. It receives the file and
  endpoint on its environment: `CMUX_UPLOAD_LOCAL_PATH`, `CMUX_UPLOAD_REMOTE_PATH`
  (the `/tmp/cmux-drop-<uuid>.<ext>` path cmux picked;
  see below), `CMUX_UPLOAD_DESTINATION`,
  `CMUX_UPLOAD_PORT`, `CMUX_UPLOAD_IDENTITY_FILE`, and `CMUX_UPLOAD_SSH_OPTIONS`
  (newline-separated; the last three are unset when the session has none). The
  rest of the environment is inherited, so a one-liner resolves tools on `PATH`.
- `enabled`: set to `false` to keep a rule in the list but skip it. Defaults to
  `true`.

**First matching enabled rule wins.** If no rule matches, the built-in `scp` runs
unchanged, so other hosts are untouched.

### The custom command owns the upload

`CMUX_UPLOAD_REMOTE_PATH` is an absolute path under `/tmp`, with a random name
and a lowercased file extension. Its parent already exists, so a command can
copy to it without creating a session directory:

```sh
scp "$CMUX_UPLOAD_LOCAL_PATH" "$CMUX_UPLOAD_DESTINATION:$CMUX_UPLOAD_REMOTE_PATH"
```

The example uses your ssh configuration. If the session supplies
`CMUX_UPLOAD_PORT`, `CMUX_UPLOAD_IDENTITY_FILE` or `CMUX_UPLOAD_SSH_OPTIONS`,
the command must pass those settings to its transport as needed.

The command owns file permissions and cleanup. For sensitive files, use a
private destination and set appropriate permissions through your upload tool.
A command that stores the file somewhere else can ignore the suggested path
and print where it put the file. cmux does not open an extra SSH connection
before running the command, so authentication wrappers and non-SSH upload
services can work independently.

The built-in transport uses a private per-session directory under
`~/.cache/cmux/paste`, creates it with mode `0700`, sets uploaded files to `0600`,
and removes old or excess files. These directory and cleanup rules apply to
built-in uploads; custom commands manage their own destinations.

### How the command's output is used

cmux inserts the command's **stdout** at the cursor:

- Non-empty stdout is inserted **verbatim** (with control characters stripped),
  so a rule can emit a remote path, a URL, or any reference — for example a line
  an agent in the terminal will read.
- If the command prints **nothing**, cmux inserts the shell-escaped remote path it
  chose, so the simplest rule just moves the file and behaves like the built-in.
- For a multi-file drop, each file's output is joined with spaces.

The output is **inserted, not executed** — nothing auto-submits, and you review it
before pressing Enter. Because it is inserted verbatim (rather than shell-escaped
like the built-in path), a rule's stdout should be trusted: it can land at a shell
prompt. A non-zero exit, a timeout, or cancelling from the transfer indicator
inserts nothing — exactly like an `scp` failure.

## `automation.workspaceAutoNaming`

Opt-in AI auto-naming of workspaces and tabs from agent conversation content. When enabled, cmux summarizes supported agent sessions into short sidebar and tab names using each agent's own binary, and refreshes them as the conversation topic shifts. See [workspace-auto-naming.md](workspace-auto-naming.md) for the supported adapter list and full behavior.

```json
{
  "automation": {
    "workspaceAutoNaming": true
  }
}
```

Default: `false`. Manual renames (sidebar, command palette, CLI, or `/rename`) always win: a workspace or tab you renamed yourself is never auto-named again until you clear its custom name. Enable it from **Settings > Automation > Workspace Auto-Naming**.

## `automation.agentAutoResume`

Sends `continue` to a cmux-launched agent whose turn ended on a retryable upstream error, such as the model being at capacity, an overloaded API, or a lost connection. Retries back off between attempts. When the error says when capacity returns, as Subrouter's `retry after <N>s` does once every pooled account is exhausted, the resume waits at least until then plus 30 seconds to 3 minutes, so machines sharing one pool do not all resume at once. The sidebar's **Auto-resumed ×N** marker clears once the agent finishes a turn on its own. A turn that ended waiting on a human (a question, a permission prompt, or a normal finish) is never resumed.

```json
{
  "automation": {
    "agentAutoResume": false
  }
}
```

Default: `true`. Toggle it from **Settings > Automation > Auto-Resume Agents After Errors** or the command palette.

## `agentMessages.enabled`

The app-wide switch for `cmux agent message`. When `false`, sends fail with "Agent messages are turned off (agentMessages.enabled is false).", nothing is stored, and messages already queued are marked `failed` instead of being delivered. Turning it back on does not resend them.

```json
{
  "agentMessages": {
    "enabled": false
  }
}
```

Default: `true`. Toggle it from **Settings > Automation > Agent Messages**. To turn messages off for one agent or workspace instead, see [Turning messages off](agent-messages.md#turning-messages-off).

## `diffViewer.defaultLayout`

Controls the initial layout for newly opened diff viewers.

Values: `unified`, `split`.

Default: `unified`.

```json
{
  "diffViewer": {
    "defaultLayout": "unified"
  }
}
```

The toolbar layout toggle persists the last user choice for future generated diff viewers. Passing `cmux diff --layout split` or `cmux diff --layout unified` overrides both the saved toolbar choice and this default for that invocation.

## `sidebar.beta.workspaceTodos.checklistStyle`

Workspace todos are always available. Status is inferred from live signals (agent needs input / agent running / open PR / merged PRs / dirty tree) and can be pinned manually from the glyph's status popover, the row's context menu (Status submenu, Mark as Done), the command palette, or `cmux workspace status set <lane|auto>`; checklists are managed from the row, the workspace todo pane (`cmux todo open`), `cmux todo ...`, or by agents over the control socket.

`checklistStyle` picks how a row's checklist opens from its summary line: `popover` (default) anchors a checklist popover to the summary line; `inline` expands the items under the row like round one.

```json
{
  "sidebar": {
    "beta": {
      "workspaceTodos": {
        "checklistStyle": "popover"
      }
    }
  }
}
```

Default: `enabled: false`. The setting turns on automatically the first time a status or checklist mutation succeeds from any entrypoint.

Three keyboard shortcuts drive the todo state, all editable in **Settings > Keyboard Shortcuts** or `shortcuts.bindings`:

- `markWorkspaceDone` (default `cmd+;`) pins the selected workspace's status to done.
- `cycleWorkspaceStatus` (default `cmd+shift+;`) advances the status one lane forward (todo → working → needs-attention → review → done → todo).
- `toggleChecklistItemComplete` (default `cmd+return`) toggles the highlighted checklist item in the focused todo pane or checklist popover.

cmux also posts a notification when a workspace's status first reaches done, and when its checklist first becomes fully complete, so you can watch agent progress without keeping the pane open.

## `agents.launchers`

cmux resolves resume commands for the wrapper launchers it owns (`cmux claude-teams`, `cmux codex-teams`, `cmux omo`, …). A launcher cmux does not own is invisible to that resolution: a multi-account router such as [`teamclaude`](https://www.npmjs.com/package/@karpeleslab/teamclaude), an LLM-gateway front end, or any `<wrapper> run -- <agent argv>` shim execs the real agent as a child, so the capture records the inner `claude` and restore replays a bare `claude --resume <id>`. The wrapper is dropped, and whatever it provided — account fallback, quota spreading, request logging — is gone from the restored pane.

Declare the wrapper here and cmux re-supplies it whenever that session resumes.

```json
{
  "agents": {
    "launchers": [
      {
        "id": "teamclaude",
        "kinds": ["claude"],
        "detect": { "argvExecutables": ["teamclaude"] },
        "resumeArgvPrefix": ["teamclaude", "run", "--auto-fallback", "--"]
      }
    ]
  }
}
```

- `id`: stable identifier recorded on the launch capture. Letters, numbers, dots, underscores, and hyphens.
- `kinds` (or `kind` for a single value, never both): built-in agent kinds the launcher wraps, e.g. `["claude"]`. Omit the key to match every kind — an empty array is treated as a mistake, not as "every kind".
- `detect.argvExecutables`: executable names or paths that identify the launcher. A match requires the **executable** of an ancestor process — or its last path component — to equal an entry exactly, so `claude --add-dir ~/src/teamclaude-notes` never matches. Env prefixes, package runners, and interpreters are followed, up to two levels, so all of these are identified as `teamclaude`: `teamclaude run`, `node /usr/local/bin/teamclaude run`, `env VAR=1 VAR2=2 teamclaude run`, `npx --yes teamclaude run`. Only options whose shape cmux knows are skipped, and anything else ends the search rather than being guessed at — a runner option that takes a value (`npx --package <pkg> wrapper`) would otherwise make the value look like the launcher. An interpreter's own options decide what its program even is (`-e`/`-c` supply it inline, `-m` names a module, `-` reads it from stdin), so the search stops at the first option after an interpreter. In short: a wrapper is recognized in its plain forms (`wrapper run`, `node /path/to/wrapper run`, `env VAR=1 wrapper run`, `npx --yes wrapper run`), and a more exotic invocation simply resumes unwrapped. Detection walks the agent's ancestors at capture time, nearest first, and stops after 8 levels.
- `resumeArgvPrefix`: argv words placed in front of the agent's own resume argv. cmux keeps every option it would have passed to the agent directly, so the wrapper never has to restate them.
- `includesAgentExecutable`: keep the agent's `argv[0]` after the prefix. Default `false`, which suits wrappers that re-exec their own agent binary after a `--` separator; set it to `true` for `env`-style wrappers that take a full command.

Behavior notes:

- A project-level `cmux.json` (or `.cmux/cmux.json`) overrides a user-level declaration with the same `id`. The project file is resolved from the agent session's directory, not from wherever a CLI process happened to start.
- Only resume is wrapped. Fresh launches already run under the wrapper because you started them there, and `cmux restore <kind> <checkpoint-id>` in direct mode is left untouched.
- Declarations fail closed. A missing detection entry, an empty `resumeArgvPrefix`, a blank `kinds` array, or a value of the wrong type makes that one declaration unusable — the session then resumes exactly as it did before, without the wrapper. The rest of the file still applies.
- Removing a declaration is safe, and has the same effect: the capture keeps the recorded id, but nothing is re-supplied.
- Hooks keep working for the wrapped agent. When the prefix replaces the agent executable, cmux puts its per-surface agent shim first on `PATH` for the restored process, so the wrapper's own `claude` lookup still finds the hook-injecting shim. A wrapper that ignores `PATH` (an absolute path to the real binary, for example) needs the global fallback instead: `cmux hooks setup --agent claude`.
