import AppKit
import GhosttyKit

struct TerminalImagePointerPress {
    let identity: TerminalImagePreviewIdentity
    let point: NSPoint
    let opensPreview: Bool
    var dragged = false
}

extension GhosttyNSView {
    func beginTerminalImagePress(with event: NSEvent, surface: ghostty_surface_t, point: NSPoint) -> Bool {
        terminalImagePointerPress = nil
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty, bounds.contains(point), let terminalSurface else {
            terminalImageLastClick = nil
            return false
        }
        var hit = ghostty_surface_image_hit_s()
        guard ghostty_surface_image_at_point(surface, point.x, bounds.height - point.y, &hit) else {
            terminalImageLastClick = nil
            return false
        }
        let identity = TerminalImagePreviewIdentity(
            surfaceId: terminalSurface.id, runtimeGeneration: terminalSurface.runtimeSurfaceGeneration,
            imageId: hit.image_id, imageGeneration: hit.image_generation
        )
        terminalImagePointerPress = TerminalImagePointerPress(
            identity: identity, point: point,
            opensPreview: event.clickCount == 2 && terminalImageLastClick == identity
        )
        terminalImageLastClick = nil
        return true
    }

    func dragTerminalImagePress(with event: NSEvent) -> Bool {
        guard var press = terminalImagePointerPress else { return false }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - press.point.x, point.y - press.point.y) > 3 { press.dragged = true }
        terminalImagePointerPress = press
        return true
    }

    func completeTerminalImagePress(with event: NSEvent) -> Bool {
        guard let press = terminalImagePointerPress else { return false }
        terminalImagePointerPress = nil
        guard !press.dragged, let terminalSurface,
              terminalSurface.id == press.identity.surfaceId,
              terminalSurface.runtimeSurfaceGeneration == press.identity.runtimeGeneration,
              let surface = terminalSurface.liveSurfaceForGhosttyAccess(reason: "imagePreview"),
              let workspace = terminalSurface.owningWorkspace() else { return true }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return true }
        var hit = ghostty_surface_image_hit_s()
        guard ghostty_surface_image_at_point(surface, point.x, bounds.height - point.y, &hit),
              hit.image_id == press.identity.imageId,
              hit.image_generation == press.identity.imageGeneration else {
            if press.opensPreview { presentTerminalImagePreviewFailure() }
            return true
        }
        terminalImageLastClick = press.identity
        guard press.opensPreview else { return true }
        if let existing = workspace.panels.values.lazy.compactMap({ ($0 as? FilePreviewPanel)?.terminalImage })
            .first(where: { $0.identity == press.identity }) {
            _ = workspace.openOrFocusTerminalImagePreview(from: terminalSurface.id, content: existing)
            return true
        }
        guard let image = readTerminalImage(surface: surface, hit: hit),
              workspace.openOrFocusTerminalImagePreview(
                from: terminalSurface.id, content: TerminalImagePreviewContent(identity: press.identity, image: image)
              ) else {
            presentTerminalImagePreviewFailure()
            return true
        }
        return true
    }

    private func readTerminalImage(surface: ghostty_surface_t, hit: ghostty_surface_image_hit_s) -> CGImage? {
        var snapshot = ghostty_surface_image_s()
        guard ghostty_surface_read_image(surface, hit, &snapshot) else { return nil }
        guard let pixels = snapshot.data,
              let provider = CGDataProvider(dataInfo: nil, data: pixels, size: Int(snapshot.len), releaseData: { _, data, size in
                  var owned = ghostty_surface_image_s()
                  owned.data = UnsafeMutablePointer(mutating: data.assumingMemoryBound(to: UInt8.self))
                  owned.len = UInt(size)
                  ghostty_surface_free_image(&owned)
              }) else {
            ghostty_surface_free_image(&snapshot)
            return nil
        }
        let alpha = snapshot.bytes_per_pixel == 4 ? CGImageAlphaInfo.last : .none
        return CGImage(
            width: Int(snapshot.width), height: Int(snapshot.height), bitsPerComponent: 8,
            bitsPerPixel: Int(snapshot.bytes_per_pixel) * 8,
            bytesPerRow: Int(snapshot.width) * Int(snapshot.bytes_per_pixel),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private func presentTerminalImagePreviewFailure() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "terminalImagePreview.failed.title", defaultValue: "Unable to Preview Image")
        alert.informativeText = String(
            localized: "terminalImagePreview.failed.message",
            defaultValue: "The image data is no longer available, or the preview could not be opened."
        )
        alert.beginSheetModal(for: window)
    }
}
