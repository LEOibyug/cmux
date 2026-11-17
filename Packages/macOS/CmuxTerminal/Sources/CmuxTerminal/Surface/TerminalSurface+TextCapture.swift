import Foundation
import GhosttyKit

extension TerminalSurface {
    /// Captures one semantic text region from the live Ghostty surface.
    ///
    /// - Parameter region: The terminal region to capture.
    /// - Returns: UTF-8 text, an empty string for an empty region, or `nil` when
    ///   the runtime is unavailable or Ghostty refuses the capture.
    @MainActor
    public func readText(region: TerminalTextRegion) -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(
            reason: "readText"
        ) else { return nil }
        return readText(surface: surface, region: region)
    }

    /// Captures a bounded VT reconstruction of the newest terminal rows.
    ///
    /// Ghostty formats only the requested tail while it holds the surface
    /// lock, so callers that already have a row and byte budget do not need to
    /// export the entire scrollback and trim it afterward.
    ///
    /// - Parameters:
    ///   - maxRows: Maximum number of physical history/current-screen rows.
    ///   - maxBytes: Hard maximum for the formatted VT output.
    /// - Returns: UTF-8 VT text, or `nil` when the runtime cannot provide it.
    @MainActor
    public func readBoundedScreenTailVT(maxRows: Int, maxBytes: Int) -> String? {
        guard maxRows > 0,
              maxBytes > 0,
              let maxRows = UInt(exactly: maxRows),
              let maxBytes = UInt(exactly: maxBytes),
              let surface = liveSurfaceForGhosttyAccess(
                reason: "readBoundedScreenTailVT"
              ) else {
            return nil
        }

        var text = ghostty_text_s()
        guard ghostty_surface_read_screen_tail_vt(
            surface,
            maxRows,
            maxBytes,
            &text
        ) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let pointer = text.text,
              let byteCount = Int(exactly: text.text_len),
              byteCount > 0 else {
            return ""
        }
        let rawData = Data(bytes: pointer, count: byteCount)
        return String(decoding: rawData, as: UTF8.self)
    }

    /// Captures an older bounded range without exporting the entire scrollback.
    ///
    /// Plain text selects physical rows using Ghostty's bounded clipboard formatter
    /// (including its soft-wrap joining and clipboard codepoint-map settings).
    /// VT uses a bounded tail overscan: its offsets count *formatted* rows, because
    /// the native VT API omits trailing blank rows and can shorten its suffix to fit.
    /// Both paths cap native scratch space at 8 MiB; unavailable/oversized captures
    /// fail closed. The returned prefix never splits UTF-8 or a VT control sequence.
    @MainActor
    public func readBoundedScreenOutput(
        maxRows: Int,
        offsetRows: Int,
        maxBytes: Int,
        plainText: Bool
    ) -> String? {
        guard TerminalScreenOutputCapture.validLimits(
            maxRows: maxRows, offsetRows: offsetRows, maxBytes: maxBytes
        ), let surface = liveSurfaceForGhosttyAccess(reason: "readBoundedScreenOutput") else {
            return nil
        }

        let captureBytes = 8 * 1_024 * 1_024
        if !plainText {
            guard let tail = readBoundedScreenTailVT(
                maxRows: maxRows + offsetRows, maxBytes: captureBytes
            ) else { return nil }
            return TerminalScreenOutputCapture.formattedRange(
                tail, maxRows: maxRows, offsetRows: offsetRows, maxBytes: maxBytes
            )
        }

        var before = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &before),
              let rows = TerminalScreenOutputCapture.absoluteRows(
                total: before.total, maxRows: maxRows, offsetRows: offsetRows
              ) else { return nil }
        if rows.isEmpty { return "" }

        var text = ghostty_text_s()
        guard ghostty_surface_read_screen_clipboard_text(
            surface, rows.lowerBound, rows.upperBound - 1, UInt(captureBytes), &text
        ) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        // The available ABI cannot select relative rows and read in one lock.
        // Reject a changed row space instead of returning a mislabeled range.
        var after = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &after),
              before.total == after.total,
              before.row_space_revision == after.row_space_revision else { return nil }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        guard let byteCount = Int(exactly: text.text_len), byteCount <= captureBytes,
              let value = String(bytes: UnsafeBufferPointer(
                start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                count: byteCount
              ), encoding: .utf8) else { return nil }
        return TerminalScreenOutputCapture.plainPrefix(value, maxBytes: maxBytes)
    }

    private func readText(
        surface: ghostty_surface_t,
        region: TerminalTextRegion
    ) -> String? {
        let topLeft = ghostty_point_s(
            tag: region.pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: region.pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let pointer = text.text, text.text_len > 0 else { return "" }
        let rawData = Data(bytes: pointer, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }
}
