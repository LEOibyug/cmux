import AppKit

/// Shared rendering, measurement, and visible-glyph geometry for sidebar text.
@MainActor
struct SidebarRowTextLinkLayout {
    let attributedString: NSAttributedString
    let textRectSize: NSSize
    let lineBreakMode: NSLineBreakMode
    let maximumNumberOfLines: Int
    private let visibleCharacterLimit: Int
    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer

    init(
        attributedString: NSAttributedString,
        textRectSize: NSSize,
        lineBreakMode: NSLineBreakMode,
        maximumNumberOfLines: Int
    ) {
        self.attributedString = attributedString
        self.textRectSize = textRectSize
        self.lineBreakMode = lineBreakMode
        self.maximumNumberOfLines = maximumNumberOfLines
        let rendered = NSMutableAttributedString(attributedString: attributedString)
        var visibleCharacterLimit = rendered.length
        if maximumNumberOfLines > 0 {
            var offset = 0
            var lineEnd = 0
            var contentEnd = 0
            for _ in 0..<maximumNumberOfLines {
                guard offset < rendered.length else { break }
                rendered.mutableString.getLineStart(
                    nil, end: &lineEnd, contentsEnd: &contentEnd,
                    for: NSRange(location: offset, length: 0)
                )
                offset = lineEnd
            }
            if offset < rendered.length {
                // TextKit omits its truncation token when another paragraph overflows.
                visibleCharacterLimit = contentEnd
                let attributes = rendered.attributes(at: max(0, contentEnd - 1), effectiveRange: nil)
                rendered.replaceCharacters(
                    in: NSRange(location: contentEnd, length: rendered.length - contentEnd), with: "…"
                )
                rendered.setAttributes(attributes, range: NSRange(location: contentEnd, length: 1))
            }
        }
        self.visibleCharacterLimit = visibleCharacterLimit
        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let paragraph = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            // The container truncates only the final visible line. Paragraphs
            // still wrap, including tokens without spaces and CJK text.
            paragraph.lineBreakMode = maximumNumberOfLines == 1 ? .byTruncatingTail : .byWordWrapping
            rendered.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        storage = NSTextStorage(attributedString: rendered)
        layoutManager = NSLayoutManager()
        textContainer = NSTextContainer(size: textRectSize)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = maximumNumberOfLines
        // Truncate only the final line after the container's line cap.
        textContainer.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
    }

    var usedSize: NSSize {
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).size
    }

    func draw(at origin: NSPoint) {
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
    }

    func characterIndex(at point: NSPoint) -> Int? {
        layoutManager.ensureLayout(for: textContainer)
        guard layoutManager.usedRect(for: textContainer).contains(point) else { return nil }
        let index = layoutManager.glyphIndex(for: point, in: textContainer)
        guard index < layoutManager.numberOfGlyphs else { return nil }
        let range = NSRange(location: index, length: 1)
        guard layoutManager.boundingRect(forGlyphRange: range, in: textContainer).contains(point),
              !visibleGlyphRanges(in: range).isEmpty else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: index)
        return characterIndex < visibleCharacterLimit ? characterIndex : nil
    }

    func frame(forCharacterRange range: NSRange) -> NSRect {
        layoutManager.ensureLayout(for: textContainer)
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: visibleCharacterLimit))
        guard bounded.length > 0 else { return .zero }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: bounded, actualCharacterRange: nil)
        let containerBounds = NSRect(origin: .zero, size: textContainer.size)
        var frame: NSRect?
        for visibleRange in visibleGlyphRanges(in: glyphRange) {
            let part = layoutManager.boundingRect(forGlyphRange: visibleRange, in: textContainer)
                .intersection(containerBounds)
            guard !part.isEmpty else { continue }
            frame = frame.map { $0.union(part) } ?? part
        }
        return frame ?? .zero
    }

    private func visibleGlyphRanges(in glyphRange: NSRange) -> [NSRange] {
        let containerGlyphRange = layoutManager.glyphRange(for: textContainer)
        let candidateRange = NSIntersectionRange(glyphRange, containerGlyphRange)
        guard candidateRange.length > 0 else { return [] }
        var result: [NSRange] = []
        layoutManager.enumerateLineFragments(forGlyphRange: candidateRange) {
            _, _, _, lineGlyphRange, _ in
            let lineCandidate = NSIntersectionRange(candidateRange, lineGlyphRange)
            guard lineCandidate.length > 0 else { return }
            let truncatedRange = layoutManager.truncatedGlyphRange(
                inLineFragmentForGlyphAt: lineGlyphRange.location
            )
            guard truncatedRange.location != NSNotFound, truncatedRange.length > 0 else {
                result.append(lineCandidate)
                return
            }
            let hiddenRange = NSIntersectionRange(lineCandidate, truncatedRange)
            guard hiddenRange.length > 0 else {
                result.append(lineCandidate)
                return
            }
            if lineCandidate.location < hiddenRange.location {
                result.append(NSRange(
                    location: lineCandidate.location,
                    length: hiddenRange.location - lineCandidate.location
                ))
            }
            let hiddenEnd = NSMaxRange(hiddenRange)
            let lineEnd = NSMaxRange(lineCandidate)
            if hiddenEnd < lineEnd {
                result.append(NSRange(location: hiddenEnd, length: lineEnd - hiddenEnd))
            }
        }
        return result
    }
}
