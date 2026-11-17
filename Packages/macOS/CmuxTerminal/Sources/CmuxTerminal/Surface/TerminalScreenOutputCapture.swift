/// Shared range/encoding policy for the live native capture, independent of runtime access.
enum TerminalScreenOutputCapture {
    static func validLimits(maxRows: Int, offsetRows: Int, maxBytes: Int) -> Bool {
        (1...1_000).contains(maxRows) && (0...10_000).contains(offsetRows)
            && offsetRows <= 10_000 - maxRows && (1...1_048_576).contains(maxBytes)
    }

    static func absoluteRows(total: UInt64, maxRows: Int, offsetRows: Int) -> Range<UInt32>? {
        guard total <= UInt64(UInt32.max) else { return nil }
        let end = total > UInt64(offsetRows) ? total - UInt64(offsetRows) : 0
        let start = end > UInt64(maxRows) ? end - UInt64(maxRows) : 0
        return UInt32(start)..<UInt32(end)
    }

    static func plainPrefix(_ value: String, maxBytes: Int) -> String {
        prefix(value, maxBytes: maxBytes, plainText: true)
    }

    /// Native VT tail output uses CRLF for physical row separators. A final
    /// separator terminates a row rather than adding a phantom newest row.
    static func formattedRange(
        _ value: String, maxRows: Int, offsetRows: Int, maxBytes: Int
    ) -> String {
        var rows = value.split(separator: "\r\n", omittingEmptySubsequences: false)
        if rows.last == "" { rows.removeLast() }
        let end = max(0, rows.count - offsetRows)
        let start = max(0, end - maxRows)
        guard start < end else { return "" }
        // A style can start on a skipped older row and remain active in the
        // requested range. Replay controls, never its text, before the fragment.
        let inherited = start == 0 ? "" : prefix(
            String(value[..<rows[start].startIndex]), maxBytes: value.utf8.count,
            plainText: false, controlsOnly: true
        )
        return prefix(inherited + rows[start..<end].joined(separator: "\r\n"),
                      maxBytes: maxBytes, plainText: false)
    }

    /// Tokenize ECMA-48 controls, not just SGR: CSI, OSC, DCS, SOS, PM,
    /// APC, ST and intermediate ESC sequences. A malformed/unclosed control
    /// is discarded in plain mode and never emitted partially in VT mode.
    private static func prefix(
        _ value: String, maxBytes: Int, plainText: Bool, controlsOnly: Bool = false
    ) -> String {
        let scalars = value.unicodeScalars
        var index = scalars.startIndex
        var result = String()
        var byteCount = 0
        while index < scalars.endIndex {
            let start = index
            let scalar = scalars[index].value
            index = scalars.index(after: index)
            var control = false
            var complete = true
            var kind: UInt32? = nil
            if scalar == 0x1B {
                control = true
                if index == scalars.endIndex { break }
                kind = scalars[index].value
                index = scalars.index(after: index)
            } else if (0x80...0x9F).contains(scalar) {
                control = true
                kind = scalar
            } else if scalar < 0x20 || scalar == 0x7F {
                control = scalar != 0x0A && scalar != 0x09 && scalar != 0x0D
            }

            if let kind {
                switch kind {
                case 0x5B, 0x9B: // CSI: parameters/intermediates end at a final byte.
                    complete = false
                    while index < scalars.endIndex {
                        let next = scalars[index].value
                        index = scalars.index(after: index)
                        if (0x40...0x7E).contains(next) { complete = true; break }
                    }
                case 0x5D, 0x9D, 0x50, 0x90, 0x58, 0x98, 0x5E, 0x9E, 0x5F, 0x9F:
                    complete = false
                    let osc = kind == 0x5D || kind == 0x9D
                    while index < scalars.endIndex {
                        let next = scalars[index].value
                        index = scalars.index(after: index)
                        if next == 0x9C || (osc && next == 0x07) {
                            complete = true; break
                        }
                        if next == 0x1B, index < scalars.endIndex, scalars[index].value == 0x5C {
                            index = scalars.index(after: index)
                            complete = true; break
                        }
                    }
                case 0x20...0x2F: // ESC intermediates and their final byte.
                    complete = false
                    while index < scalars.endIndex {
                        let next = scalars[index].value
                        index = scalars.index(after: index)
                        if (0x30...0x7E).contains(next) { complete = true; break }
                    }
                default: break
                }
            }
            if plainText && control { continue }
            if controlsOnly && !control { continue }
            guard complete else { break }
            let token = scalars[start..<index]
            let length = token.reduce(0) { $0 + $1.utf8.count }
            guard length <= maxBytes - byteCount else { break }
            result.unicodeScalars.append(contentsOf: token)
            byteCount += length
        }
        return result
    }
}
