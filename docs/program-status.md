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
`blocked`, then `error`, `working`, `done`, and explicitly reported `idle`. Both `done`
and `idle` present as a green Done badge; there is no persistent Idle badge. A pane
without a report has no badge. Sidebar and terminal tabs share the same labels:
in Chinese, working is “工作中”, blocked is “等待输入”, and completion is “已完成”.
The original app name, message, title and progress remain in the badge's hover help.

The row uses the same prominent colored badges as hook-integrated agents: blue
with a rotating indicator for working, amber for blocked, red for error, and green
for completion. Settings > Sidebar controls completed badges, sidebar/tab visibility,
and animation; Reduce Motion always keeps symbols static. The sidebar status sits directly
below the workspace title, before configurable information rows. Native OMP reports use
this path without a hook PID; conversation age does not affect the presentation.

When the same terminal also has a hook report for that agent, its live native report
owns both status displays, even if a delayed hook arrives later. Done and numeric completion
indicators remain visible while viewing the workspace; leaving after viewing acknowledges
completion in both channels. Completion received while already focused counts as viewed
and clears on the first exit. A background completion stays on entry and clears on the
later exit. Explicitly marking the workspace read also acknowledges completion. A new task
in the same pane replaces Done with Working and clears that pane's completion indicator.
A late completion report cannot restore an acknowledged badge; a new working or blocked
report makes the next completion eligible again. Unrelated programs and other panes remain independent.

OMP 18.16 reports an `ask` prompt as `blocked:kind=question` and an approval prompt as
`blocked:kind=permission`. cmux already handles both as needs-input; no text matching
or extra OMP extension is needed. Finishing a turn is distinct from a blocking question.

- `working` and `blocked` records are removed when a new shell prompt starts (OSC 133 A or cmux
  shell integration) and when the pane's process exits.
- Completion badges and numeric indicators stay while viewing the workspace and clear
  when you leave after viewing, explicitly mark it read, or the same pane starts a new
  task and Working replaces Done. This acknowledges presentation only; raw protocol
  records and agent activity remain unchanged. Waiting-for-input and error reports
  are not completion acknowledgements.
- A full terminal reset (RIS) removes every record of the pane.
- `msg` and `title` are plain text. cmux strips invisible formatting characters, such as text
  direction overrides, and shortens long text before display.

Program status rows are terminal state, not agent state: they do not change agent hibernation,
agent detection, or desktop notifications. Use `cmux notify` or OSC 9/99/777 for notifications.

One exception keeps agent rows honest. Claude Code reports its turns as `app=claude-code`
records. When such a `working` or `blocked` record ends (a `done`, `idle`, `error` or `clear`
report, a prompt start, or the process exiting) while that pane's Claude Code row still says
Running, and no Claude Code hook reports anything for 3 seconds, cmux marks the turn finished and
shows Done. This covers turns that end without a Stop hook, such as an Esc interrupt or a Stop hook
that timed out. It never sends a notification, and only settles a pane that is still Running.
