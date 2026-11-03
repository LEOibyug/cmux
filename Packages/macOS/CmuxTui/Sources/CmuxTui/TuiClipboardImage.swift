public import Foundation

/// A bounded, signature-validated image payload ready for an SSH terminal transfer.
public struct TuiClipboardImage: Sendable {
    /// The maximum number of bytes accepted from the clipboard.
    public static let maximumBytes = 20 * 1024 * 1024
    /// The validated image bytes.
    public let data: Data
    /// The MIME type derived from the image signature.
    public let mime: String

    /// Validates an image payload and derives its supported MIME type.
    ///
    /// - Parameter data: The complete clipboard image payload.
    /// - Throws: ``TuiImagePasteError/sizeLimit`` or
    ///   ``TuiImagePasteError/unsupportedType`` when the payload is not
    ///   supported by the remote terminal daemon.
    public init(data: Data) throws {
        guard !data.isEmpty else { throw TuiImagePasteError.unsupportedType }
        guard data.count <= Self.maximumBytes else { throw TuiImagePasteError.sizeLimit }
        mime = try Self.mime(forSignature: data)
        self.data = data
    }

    /// Checks an image file's size and signature without reading the payload.
    ///
    /// This is the cheap check a composer runs when an image is attached, so an
    /// unsupported file is refused before it can be submitted. Upload still
    /// reads the file through ``TuiClipboardImageReader``, which repeats both
    /// checks on the bytes it sends.
    ///
    /// - Parameter url: The attached image file.
    /// - Throws: ``TuiImagePasteError/sizeLimit``,
    ///   ``TuiImagePasteError/unsupportedType`` or
    ///   ``TuiImagePasteError/storage`` when the file cannot be sent.
    public static func validateFile(at url: URL) throws {
        guard url.isFileURL else { throw TuiImagePasteError.unsupportedType }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let values else { throw TuiImagePasteError.storage }
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw TuiImagePasteError.unsupportedType
        }
        guard size <= maximumBytes else { throw TuiImagePasteError.sizeLimit }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 12) ?? Data()
        } catch {
            throw TuiImagePasteError.storage
        }
        _ = try mime(forSignature: header)
    }

    /// The MIME type for a payload's leading bytes. Only the first 12 bytes
    /// are read.
    private static func mime(forSignature data: Data) throws -> String {
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]) {
            return "image/png"
        } else if data.starts(with: [0xff, 0xd8, 0xff]) {
            return "image/jpeg"
        } else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return "image/gif"
        } else if data.starts(with: Data("RIFF".utf8)), data.count >= 12,
                  data.subdata(in: data.startIndex + 8..<data.startIndex + 12) == Data("WEBP".utf8) {
            return "image/webp"
        }
        throw TuiImagePasteError.unsupportedType
    }
}
