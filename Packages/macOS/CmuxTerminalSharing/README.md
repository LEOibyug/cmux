# Terminal sharing (macOS)

The Mac side of shared terminal sizing (`docs/shared-terminal-sizing.md`).
`TerminalSharingStore` is the one owner of per-terminal size state and user
actions. `LocalTerminalSizingHost` runs `TerminalSizingEngine` for a local
terminal, where the Mac is the host. `TuiTerminalSizingState` tracks negotiated
capabilities and generation-ordered sizing state for user-controlled SSH views.
Phone and official device-service relay paths are not part of this package.
