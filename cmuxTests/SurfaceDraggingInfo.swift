import AppKit

/// Immutable native drag input for the retained pane ownership tests.
final class SurfaceDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingLocation: NSPoint
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    // AppKit's protocol is nonisolated; these immutable values are consumed only on MainActor.
    nonisolated(unsafe) let draggingPasteboard: NSPasteboard
    nonisolated(unsafe) let draggingSource: Any?
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    @MainActor
    init(source: NSView, pasteboard: NSPasteboard, location: NSPoint) {
        draggingDestinationWindow = source.window
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingLocation = location
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
