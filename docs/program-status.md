# Program status (OSC 7501)

cmux supports the [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status)
(OSC 7501, rev 0.3). A program writes its state to the terminal and cmux shows it in the sidebar
and that terminal's surface tab. It works over SSH and inside containers because it travels
through the pty.

```bash
status() {
  printf '\e]7501;state=%s:msg=%s\e\\' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}
status working "Syncing photos"
rsync -a ~/Photos backup:/photos && status done "Photos synced" || status error "rsync failed"
```

Programs can detect support with `printf '\e]7501;?\e\\'`; cmux answers with the same bytes. The
`xterm-ghostty` terminfo entry also carries the `Pst` capability.

## What cmux shows

cmux keeps each terminal pane's records separately and selects the most urgent status:
`blocked`, then `error`, `working`, `done`, and explicitly reported `idle`. Idle means the
program is ready; it is not relabeled as Done. A pane without a report has no badge.
Native and hook idle states share the same display policy. The sidebar and terminal tab
use the same short label: in Chinese, working is “工作中” and blocked is “等待输入”.
The original app name, message, title and progress remain in the badge's hover help.

The row uses the same prominent colored badges as hook-integrated agents: blue
with a rotating indicator for working, amber for blocked, red for error, and green
for done or idle. Settings > Sidebar controls inactive badges, sidebar/tab visibility,
and animation; Reduce Motion always keeps symbols static. The sidebar status sits directly
below the workspace title, before configurable information rows. Native OMP reports use
this path without a hook PID; conversation age does not affect the presentation.

When the same terminal also has a hook report for that agent, its live native report
owns both status displays, even if a delayed hook arrives later. The hook is retained
and becomes visible again when native status is removed. Unrelated program reports
and hook reports from other terminals are not hidden.

OMP 18.16 reports an `ask` prompt as `blocked:kind=question` and an approval prompt as
`blocked:kind=permission`. cmux already handles both as needs-input; no text matching
or extra OMP extension is needed. Finishing a turn is distinct from a blocking question.

- `working` and `blocked` records are removed when a new shell prompt starts (OSC 133 A or cmux
  shell integration) and when the pane's process exits.
- `done` and `error` records stay until you focus that pane again.
- A full terminal reset (RIS) removes every record of the pane.
- `msg` and `title` are plain text. cmux strips invisible formatting characters, such as text
  direction overrides, and shortens long text before display.

Program status rows are terminal state, not agent state: they do not change agent hibernation,
agent detection, or desktop notifications. Use `cmux notify` or OSC 9/99/777 for notifications.

One exception keeps agent rows honest. Claude Code reports its turns as `app=claude-code`
records. When such a `working` or `blocked` record ends (a `done`, `idle`, `error` or `clear`
report, a prompt start, or the process exiting) while that pane's Claude Code row still says
Running, and no Claude Code hook reports anything for 3 seconds, cmux marks the turn finished and
shows Idle. This covers turns that end without a Stop hook, such as an Esc interrupt or a Stop hook
that timed out. It never sends a notification, and it only moves a pane from Running to Idle.
