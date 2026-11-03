import CmuxTui
import Foundation
import Testing

@Suite("SSH image paste package")
struct TuiImagePasteTests {
    @Test
    func validatesSupportedSignatures() throws {
        let png = try TuiClipboardImage(data: Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]))
        #expect(png.mime == "image/png")
    }

    @Test
    func rejectsUnsupportedAndOversizePayloads() {
        #expect(throws: TuiImagePasteError.unsupportedType) {
            try TuiClipboardImage(data: Data("<svg/>".utf8))
        }
        #expect(throws: TuiImagePasteError.sizeLimit) {
            try TuiClipboardImage(data: Data(repeating: 0, count: TuiClipboardImage.maximumBytes + 1))
        }
    }

    /// Attach-time validation refuses what upload would refuse, from the
    /// header and file size alone.
    @Test
    func validatesAttachedFilesBeforeUpload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-image-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let webp = directory.appendingPathComponent("image.webp")
        try (Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8)).write(to: webp)
        try TuiClipboardImage.validateFile(at: webp)

        let svg = directory.appendingPathComponent("image.svg")
        try Data("<svg/>".utf8).write(to: svg)
        #expect(throws: TuiImagePasteError.unsupportedType) {
            try TuiClipboardImage.validateFile(at: svg)
        }

        let oversize = directory.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: oversize.path, contents: Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]))
        let handle = try FileHandle(forWritingTo: oversize)
        try handle.truncate(atOffset: UInt64(TuiClipboardImage.maximumBytes + 1))
        try handle.close()
        #expect(throws: TuiImagePasteError.sizeLimit) {
            try TuiClipboardImage.validateFile(at: oversize)
        }

        #expect(throws: TuiImagePasteError.storage) {
            try TuiClipboardImage.validateFile(at: directory.appendingPathComponent("missing.png"))
        }
    }
}
