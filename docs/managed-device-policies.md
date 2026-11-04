# Managed device policies (MDM)

cmux supports MDM-enforceable policies for managed Macs. Administrators
deliver them as **forced preference values** through a macOS configuration
profile (a "Custom Settings" / `com.apple.ManagedClient.preferences`
payload). Forced values are tier 0: they win over environment variables,
user settings, `~/.config/cmux/cmux.json` imports, and built-in defaults,
and they cannot be changed from inside the app — the Settings UI shows the
control as "Managed by your organization", the command palette hides the
matching commands, and the `cmux` CLI refuses with a managed-policy error.

## Payload domain

Target the preference domain:

```text
com.cmuxterm.app
```

This is the release app's bundle identifier. Channel builds (debug,
nightly, rc, staging) run under their own bundle identifiers but also honor
profiles targeting `com.cmuxterm.app`, so one profile governs every
channel. A profile may additionally target a channel's own domain (for
example `com.cmuxterm.app.nightly`); a value forced in the app's own
domain wins over the release-domain fallback.

## Policy keys

| Key | Type | Default | Behavior when forced to `true` |
| --- | --- | --- | --- |
| `DisableEmbeddedBrowser` | Boolean | `false` | Disables every embedded-browser surface: browser panes and tabs, terminal-link interception, browser creation from automation/CLI, saved and `cmux.json` layouts, and session restore. Live browser panes are closed when the policy activates. Links open in the system default browser instead. Local viewers that ride the same browser gate are also unavailable. |
| `DisableRemoteConnections` | Boolean | `false` | Disables cmux-created SSH, Mosh, remote tmux and remote-registry connections from every entry point. The socket refuses with `remote_connections_disabled`; a profile pushed mid-session disconnects live remote workspaces and mirrors. Local terminals and user-entered shell `ssh` commands are unaffected. |
| `DisableFileTransfer` | Boolean | `false` | Disables cmux-mediated drag-and-drop and pasted-image uploads into remote terminals, configured `terminal.uploadCommands`, and remote-file previews in the SSH file explorer. Local drops and user-entered `scp` or `rsync` commands are unaffected. |
| `DisableAutomationWebhooks` | Boolean | `false` | Disables the `webhook` action of automation rules (`~/.cmuxterm/automations.json`, `cmux automation`), which posts event payloads with caller-supplied headers to any http(s) URL. The action fails with a managed-policy message in the automation log; `run` and `notify` actions are unaffected. |
| `DisableTLSTrustBypass` | Boolean | `false` | Disables the embedded browser's click-through on certificate errors: the error page offers no bypass and no earlier 24-hour grant is honored. |
| `DisableComputerUse` | Boolean | `false` | Disables cmux Computer Use: new agent launches never receive the cmux-cua tools, the bundled helper stops (also when the policy is pushed mid-session), and Settings → cmux Computer Use locks the toggle. Lifting the policy re-applies the user's own setting. |
| `DisableCustomSidebars` | Boolean | `false` | Disables interpreted custom sidebars from `~/.config/cmux/sidebars` (user- or agent-authored `.js`/`.swift`/`.json` that can dispatch `cmux(...)` commands): none are listed or mounted, and Settings → Beta Features locks the toggle. |
| `SocketControlMode` | String | `cmuxOnly` | Forces the local automation Unix socket to `cmuxOnly` or `off`. A forced value wins over Settings, `cmux.json`, `CMUX_SOCKET_MODE`, and `CMUX_SOCKET_PASSWORD`; Settings locks the picker and shows the effective mode. Existing clients are revoked when the mode changes, including password-authenticated and event-stream clients. |
| `BrowserURLAllowlist` | Array of strings | unset (allow all web origins) | Restricts every embedded-browser top-level navigation to matching URL patterns. Address-bar loads, links, redirects, `window.open`, automation, deep links, and restored panes are checked. A forced empty array denies all external web origins while cmux-owned internal documents (such as `about:blank` and diff pages), localhost, and local files remain available unless the two allow keys below turn them off. See [Browser allowlist](#browser-allowlist). |
| `BrowserAllowLocalhost` | Boolean | `true` | Allow-style key. While `true`, a managed `BrowserURLAllowlist` permits `localhost`, `*.localhost`, `127.0.0.1`, `::1`, and `0.0.0.0` on any HTTP(S) port without a rule, so local development servers keep working. Forced to `false`, loopback origins are blocked in the embedded browser — even ones the list names, and even when no list is forced. |
| `BrowserAllowLocalFiles` | Boolean | `true` | Allow-style key. While `true`, local `file:` documents opened through cmux (the address bar, `cmux browser open`, terminal links, a file dropped onto a browser pane, or a link from another local file) stay available under a managed list. Forced to `false`, local files are blocked whether or not a list is forced. |

Notes:

- `DisableEmbeddedBrowser`, `DisableRemoteConnections`, `DisableFileTransfer`,
  `DisableAutomationWebhooks`, `DisableTLSTrustBypass`, `DisableComputerUse`,
  and `DisableCustomSidebars` values must be Boolean.
  A Boolean key forced to `false` (or to a non-Boolean value) does not enforce
  the policy, but the key still counts as managed for write-locking purposes.
  `BrowserAllowLocalhost` and `BrowserAllowLocalFiles` are the two allow-style
  keys: only a forced Boolean `false` changes behavior, and a forced `true` or
  non-Boolean value leaves the capability allowed.
  `BrowserURLAllowlist` must be an array of strings; a forced empty array is a
  valid policy that blocks all external web origins.
- `SocketControlMode` is a restrictive enum. The only valid forced strings are
  `cmuxOnly` and `off` (case, hyphen, and underscore normalization is accepted).
  A forced value of another type or a broader mode such as `allowAll` is still
  managed but fails closed to `off`; it never falls back to a password or an
  environment override. Removing the profile restores the user's effective
  setting and environment behavior. A regular `defaults write` of either
  `SocketControlMode` or `socketControlMode` is not an MDM force and cannot
  impersonate this policy.
- Only **forced** (profile-delivered) values are honored as policy. A plain
  `defaults write` of these keys has no effect; this is deliberate, since
  an unmanaged value would not be enforceable anyway.
- `BrowserURLAllowlist` entries are host rules or URL-shaped rules. An exact
  host (`internal.example.com`) matches that host; a wildcard
  (`*.example.com`) matches subdomains; `https://git.example.com` restricts
  the scheme; and `http://localhost:3000` restricts both scheme and port.
  A bare `localhost` entry matches any HTTP(S) port. A managed list does not
  need loopback entries: `localhost`, `*.localhost`, `127.0.0.1`, `::1`, and
  `0.0.0.0` are allowed on any port while `BrowserAllowLocalhost` is not
  forced to `false`. Paths, queries, fragments, credentials, and non-HTTP(S)
  pattern schemes are rejected.
- The same syntax is available to unmanaged users as the `browser.urlAllowlist`
  setting in Settings → Browser or `cmux.json`. Settings shows a suggested
  loopback list (`localhost`, `*.localhost`, `127.0.0.1`, `::1`, `0.0.0.0`,
  and `*.localtest.me`); saving that list opts into the restriction, and
  removing individual entries blocks those origins. An absent or cleared user
  value leaves ordinary browsing unrestricted. A non-empty value containing
  only invalid rules fails closed and is called out in Settings. A forced `BrowserURLAllowlist`
  always wins and locks that editor; an administrator may also force the
  user-level `browserURLAllowlist` key directly, and the importer skips the
  setting while either key is managed.
- Policy changes are applied at app launch, on preference-change
  notifications, whenever the app becomes active, and on a periodic
  re-check (about once a minute) while the app runs — a profile pushed
  mid-session takes effect within roughly a minute even if the user never
  leaves cmux.
- `SocketControlMode` uses the same roughly 60-second managed-policy
  re-check. A live mode change rotates the socket authorization generation and
  closes clients admitted under the old mode, including idle connections and
  event subscriptions. The compliance command reads the profile directly and
  never opens the socket merely to report status.

## Lockability

Configuration-profile forced values are locked by macOS itself: no
user-level write (including "Reset All Settings") can change the effective
value, and removing the profile restores normal behavior. cmux additionally
suppresses its own writers: the `cmux.json` importer skips every
profile-forced key, and for managed local feature controls
the Settings UI shows the managed state, the command palette hides the
matching commands, and the CLI refuses with a managed-policy error —
including when an administrator forces the user-level
`browserDisabledOverride` key directly instead of the dedicated policy key.

`DisableEmbeddedBrowser` takes precedence over `BrowserURLAllowlist`: when the
disable policy is forced, no embedded browser surface is created and the URL
allowlist is not consulted. If the disable policy is later removed, the
allowlist becomes effective without requiring a restart.

The capability keys compose rather than override one another: each is a
separate gate, and a capability is unavailable when any key covering it is
forced. Every `Disable…` key
defaults to `false` and the two `BrowserAllow…` keys default to `true`: an
unmanaged Mac, and a managed Mac whose profile omits the key, behave exactly
as an unmanaged install.

When `DisableRemoteConnections` activates mid-session, live cmux-created
remote workspaces disconnect (their configuration is dropped so no reconnect
affordance can redial), remote tmux mirrors detach and close, and the SSH
control masters cmux opened exit. Remote tmux sessions stay alive on their
hosts; only cmux's connections end.

## Automation socket deployment

Use the minimal profile entry below when the supported automation channel must
remain available only to cmux descendants:

```xml
<key>SocketControlMode</key>
<string>cmuxOnly</string>
```

Set the value to `off` to remove the listener entirely. The forced value is
resolved before Settings, `cmux.json` import/reload, `CMUX_SOCKET_MODE`, and
`CMUX_SOCKET_PASSWORD`; possession of a password never bypasses forced
`cmuxOnly`. A profile update is picked up by the existing 60-second policy
re-check, and the listener revokes all connections from the previous
generation before admitting clients under the new value. This covers idle
clients and event/stream subscriptions as well as ordinary requests.

For administrator compliance, run `cmux socket-status --json`. It reads the
forced preference from `com.cmuxterm.app` (including release-domain inheritance
for tagged builds), reports the effective mode, source, and whether the forced
value was valid, and observes the socket path without connecting. The
`live_enforcement` field is therefore `not_observed`: it distinguishes profile
intent and path state from a claim that a running server applied the value.
The command is still usable when the policy is `off` or cmux is not running.

Install, change, and remove the profile through the MDM's normal Custom
Settings workflow. On removal, cmux returns to the user's existing mode and
environment behavior without requiring a restart. If a malformed value is
deployed, cmux treats it as managed and fails closed to `off`; correct the
profile, then wait for the next re-check or relaunch. These controls govern
cmux's supported local automation channel and do not prevent arbitrary native
code running as the same macOS user.

### Verification matrix

The focused behavior and socket tests exercise the following matrix; the
managed-profile row is the one that requires an isolated MDM test Mac or a
controller-hosted profile lane.

The package tests inject the existing forced-value probe for deterministic
resolution and revocation checks. They do not install a profile on a
maintainer Mac. A real `objectIsForced`/configuration-profile run remains an
explicit controller-hosted verification step; this documentation does not
claim that unit tests alone prove deployed MDM delivery.

| Scenario | Forced `cmuxOnly` | Forced `off` | Expected evidence |
| --- | --- | --- | --- |
| Settings/UserDefaults, imported `cmux.json`, `CMUX_SOCKET_MODE=allowAll`, and password env all conflict | Descendants admitted; outside clients rejected; password is ignored | Listener absent; all clients rejected | `SocketControlSettingsTests`, Settings picker lock, `socket-status --json` |
| Forced value is malformed or broader (`allowAll`, `password`) | Fails closed to `off` and remains managed | Fails closed to `off` and remains managed | Resolver test and status `forced_value_status: invalid` |
| Profile changes while clients, idle sockets, or event streams are live | Old generation revoked before new admissions | All old clients revoked and listener stopped | `SocketControlServerManagedPolicyTests` and generation signal |
| Profile removed, then app restarted | User/defaults and environment behavior returns | User/defaults and environment behavior returns | Resolver removal test plus restart run |
| No profile | Existing user behavior is preserved | Existing user behavior is preserved | Unmanaged regression tests |

## Browser allowlist

`BrowserURLAllowlist` restricts the embedded browser to the sites you list.
Most deployments only need the list of company domains, because a managed
list still permits what never leaves the Mac:

- **localhost** — `localhost`, `*.localhost`, `127.0.0.1`, `::1`, and
  `0.0.0.0` on any HTTP(S) port, so local development servers keep working.
  Force `BrowserAllowLocalhost` to `false` to block loopback origins; then
  list any loopback origin you still want with a port-qualified rule such as
  `http://localhost:3000`.
- **local files** — `file:` documents opened through cmux, dropped onto a
  browser pane, or linked from another local file. Force
  `BrowserAllowLocalFiles` to `false` to block them (with or without a list).

Each entry is a host or an HTTP(S) URL pattern:

```text
git.example.com          # exactly this host, any port, http or https
*.example.com            # every subdomain of example.com (not example.com itself)
https://issues.example.com
http://localhost:3000    # only needed when BrowserAllowLocalhost is false
```

The allowlist governs page navigations (address bar, links, redirects,
`window.open`, automation, deep links, restored panes). It does not filter
subresource requests such as images, scripts, or `fetch`. A blocked
navigation shows an in-page explanation with the blocked origin and the next
step; Settings → Browser shows the effective rules and whether localhost and
local files are allowed; and `cmux browser status --json` reports
`url_allowlist`, `url_allowlist_managed`, `url_allowlist_allows_localhost`,
and `url_allowlist_allows_local_files`.

## Supported platforms and versions

- macOS 14 (Sonoma) and later, matching the cmux system requirements.
- cmux for macOS 1.x builds that include this feature (see the changelog
  entry that shipped it). All release channels honor the release payload
  domain as described above.
- Do not deploy `SocketControlMode` until the installed artifact contains this
  key; this change does not promise a stable or NIGHTLY version before one is
  actually published.

## Sample configuration profile

Deploy via your MDM as a Custom Settings payload for `com.cmuxterm.app`,
or install the profile below manually for testing (System Settings →
General → Device Management). This sample keeps the embedded browser enabled
so the allowlist is exercised; use the `DisableEmbeddedBrowser` policy from the
table above when a full browser disable is desired.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.example.cmux.managed-policies</string>
            <key>PayloadUUID</key>
            <string>6D4A3E9C-1B2F-4C8D-9E0A-5F6B7C8D9E0F</string>
            <key>PayloadDisplayName</key>
            <string>cmux managed policies</string>
            <key>PayloadContent</key>
            <dict>
                <key>com.cmuxterm.app</key>
                <dict>
                    <key>Forced</key>
                    <array>
                        <dict>
                            <key>mcx_preference_settings</key>
                            <dict>
                                <key>DisableRemoteConnections</key>
                                <true/>
                                <key>DisableFileTransfer</key>
                                <true/>
                                <key>DisableAutomationWebhooks</key>
                                <true/>
                                <key>DisableTLSTrustBypass</key>
                                <true/>
                                <key>DisableComputerUse</key>
                                <true/>
                                <key>DisableCustomSidebars</key>
                                <true/>
                                <key>SocketControlMode</key>
                                <string>cmuxOnly</string>
                                <!-- localhost and local files need no entries;
                                     force BrowserAllowLocalhost / BrowserAllowLocalFiles
                                     to false to block them. -->
                                <key>BrowserURLAllowlist</key>
                                <array>
                                    <string>https://git.example.com</string>
                                    <string>*.example.com</string>
                                </array>
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadIdentifier</key>
    <string>com.example.cmux.managed-policies.profile</string>
    <key>PayloadUUID</key>
    <string>2A1B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D</string>
    <key>PayloadDisplayName</key>
    <string>cmux Managed Policies</string>
    <key>PayloadScope</key>
    <string>System</string>
</dict>
</plist>
```

## Verifying on a managed Mac

```bash
# Shows the effective (forced) values for the release domain:
defaults read com.cmuxterm.app DisableEmbeddedBrowser
defaults read com.cmuxterm.app DisableRemoteConnections
defaults read com.cmuxterm.app DisableFileTransfer
defaults read com.cmuxterm.app DisableAutomationWebhooks
defaults read com.cmuxterm.app DisableTLSTrustBypass
defaults read com.cmuxterm.app DisableComputerUse
defaults read com.cmuxterm.app DisableCustomSidebars
defaults read com.cmuxterm.app BrowserURLAllowlist
defaults read com.cmuxterm.app BrowserAllowLocalhost     # absent or 1 = allowed
defaults read com.cmuxterm.app BrowserAllowLocalFiles    # absent or 1 = allowed

# The CLI reports browser availability and URL-policy metadata:
cmux browser status --json   # url_allowlist, url_allowlist_managed,
                             # url_allowlist_allows_localhost, url_allowlist_allows_local_files

# Reliable socket-policy compliance check. It works while the app is quit or
# the socket is forced off and never sends a request to the automation socket:
cmux socket-status --json
# Example (no password or token is emitted):
# {
#   "configured_mode" : "allowAll",
#   "effective_mode" : "cmuxOnly",
#   "forced_value_status" : "valid",
#   "live_enforcement" : "not_observed",
#   "managed" : true,
#   "managed_source" : "managed_app_domain",
#   "observation_scope" : "profile_and_socket_path",
#   "policy_key" : "SocketControlMode",
#   "socket_path_state" : "present"
# }
# `live_enforcement` is intentionally not inferred from a separate process
# reading defaults; use the app's own tagged verification run for live socket
# admission evidence. When `SocketControlMode` is `off`, the same command
# reports `socket_path_state: absent` without weakening the policy to answer.
```

In cmux, Settings → Browser shows the enable toggle disabled with
"Managed by your organization". The Computer Use and Custom Sidebars toggles
lock the same way under their corresponding policies.
