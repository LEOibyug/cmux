# CmuxTui

The cmux-tui client transport for user-controlled SSH hosts: daemon requests and argv builders, manual terminal I/O, resize coalescing, attachment deadlines, replay colors, and client paths. The package also owns clipboard image validation, safe file reading, and acknowledged image transfer; no managed service or separate image-paste product is required.

```swift
import CmuxTui

var scheduler = TuiManualIOResizeScheduler()
if let grid = TuiManualIOGrid(columns: 120, rows: 40),
   let send = scheduler.sample(grid, canSend: true) {
    connection.send(TuiManualIOCommand().resize(surfaceID: id, columns: send.columns, rows: send.rows))
}
```

Image transfers accept PNG, JPEG, GIF, and WebP signatures up to 20 MiB. `TuiImagePasteCoordinator(deadline:clock:)` binds an injected leased command sender; it never accepts a caller-selected remote path or opens a network connection. Its clock-controlled deadline is cancelled on completion, cancellation, and disconnect. `TuiImagePasteCoordinatorTests` exercises chunk acknowledgement, reconnect fencing, cancellation, uncertain delivery, and deadline handling through that command boundary.

The app owns `TuiManualMirrorSession` and its terminal surface. `CmuxRemoteSession` owns the SSH carrier, browser routing, and remote mutation coordination. The local and remote cmux-tui executables must be installed explicitly; this transport does not download or upgrade them.
