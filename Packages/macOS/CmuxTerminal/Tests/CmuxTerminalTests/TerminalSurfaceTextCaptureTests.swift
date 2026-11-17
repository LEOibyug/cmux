import Testing

@testable import CmuxTerminal

@MainActor
@Suite("Terminal surface text capture")
struct TerminalSurfaceTextCaptureTests {
    @Test("nonpositive bounded capture limits fail closed")
    func nonpositiveLimitsFailClosed() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }

        #expect(fixture.surface.readBoundedScreenTailVT(maxRows: 0, maxBytes: 1) == nil)
        #expect(fixture.surface.readBoundedScreenTailVT(maxRows: 1, maxBytes: 0) == nil)
    }

    @Test("physical ranges skip newest rows and clamp at history start")
    func physicalRowRanges() {
        #expect(TerminalScreenOutputCapture.absoluteRows(total: 120, maxRows: 10, offsetRows: 30) == 80..<90)
        #expect(TerminalScreenOutputCapture.absoluteRows(total: 6, maxRows: 10, offsetRows: 2) == 0..<4)
        #expect(TerminalScreenOutputCapture.absoluteRows(total: 6, maxRows: 10, offsetRows: 6) == 0..<0)
        #expect(TerminalScreenOutputCapture.absoluteRows(total: UInt64(UInt32.max) + 1, maxRows: 1, offsetRows: 0) == nil)
    }

    @Test("formatted VT ranges preserve order and exclude skipped newest rows")
    func formattedRowRanges() {
        let tail = "old\r\n\u{1B}[31molder-red\r\n\r\nnew\r\nnewest\r\n"
        #expect(TerminalScreenOutputCapture.formattedRange(
            tail, maxRows: 2, offsetRows: 2, maxBytes: 1_000
        ) == "\u{1B}[31molder-red\r\n")
        #expect(TerminalScreenOutputCapture.formattedRange(
            tail, maxRows: 20, offsetRows: 5, maxBytes: 1_000
        ) == "")
        #expect(TerminalScreenOutputCapture.formattedRange(
            "a\r\nb", maxRows: 1, offsetRows: 0, maxBytes: 1_000
        ) == "b")
        #expect(TerminalScreenOutputCapture.formattedRange(
            "\u{1B}[31mred-before\r\nstill-red\r\nnewest", maxRows: 1, offsetRows: 1, maxBytes: 1_000
        ) == "\u{1B}[31mstill-red")
    }

    @Test("plain capture removes terminal controls without deleting message text")
    func plainControlRemoval() {
        let value = "\u{1B}[31m你好\u{1B}[0m\u{1B}]10;rgb:ffff/aaaa/0000\u{07} "
            + "\u{1B}]8;;https://example.test\u{1B}\\link\u{1B}]8;;\u{1B}\\\n"
            + "\u{1B}Pprivate\ncontrol\u{1B}\\\u{1B}[2J\u{1B}[3 q"
            + "\u{1B}(Bactual [31m rgb:ffff/aaaa/0000\t😀"
            + "\u{009D}hidden\u{009C}\u{0000}\u{1B}]unterminated"
        #expect(TerminalScreenOutputCapture.plainPrefix(value, maxBytes: 1_000)
            == "你好 link\nactual [31m rgb:ffff/aaaa/0000\t😀")
    }

    @Test("byte budgets never split UTF8 scalars or VT sequences")
    func byteBoundaries() {
        let value = "A界😀e\u{301}"
        for (budget, expected) in [(1, "A"), (3, "A"), (4, "A界"), (7, "A界"),
                                   (8, "A界😀"), (9, "A界😀e"), (10, "A界😀e"),
                                   (11, "A界😀e\u{301}")] {
            #expect(TerminalScreenOutputCapture.plainPrefix(value, maxBytes: budget) == expected)
        }
        #expect(TerminalScreenOutputCapture.formattedRange(
            "A\u{1B}[31m界", maxRows: 1, offsetRows: 0, maxBytes: 5
        ) == "A")
        #expect(TerminalScreenOutputCapture.formattedRange(
            "A\u{1B}[31m界", maxRows: 1, offsetRows: 0, maxBytes: 8
        ) == "A\u{1B}[31m")
    }

    @Test("bounded output rejects invalid ranges before native access")
    func invalidOutputLimits() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        for (rows, offset, bytes) in [(0, 0, 1), (1_001, 0, 1), (1, -1, 1),
                                      (1, 10_000, 1), (1, Int.max, 1), (1, 0, 0),
                                      (1, 0, 1_048_577)] {
            #expect(fixture.surface.readBoundedScreenOutput(
                maxRows: rows, offsetRows: offset, maxBytes: bytes, plainText: true
            ) == nil)
        }
        #expect(TerminalScreenOutputCapture.validLimits(maxRows: 1_000, offsetRows: 9_000, maxBytes: 1_048_576))
    }
}
