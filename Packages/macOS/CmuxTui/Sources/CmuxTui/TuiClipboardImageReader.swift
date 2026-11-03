import Darwin
public import Foundation

/// Reads and validates a materialized clipboard image off the main actor.
public actor TuiClipboardImageReader {
    /// Creates a reader for bounded clipboard image files.
    public init() {}

    /// Reads one regular file without following symlinks.
    ///
    /// - Parameter url: A file URL produced by the clipboard materialization
    ///   service.
    /// - Returns: A bounded, signature-validated image payload.
    /// - Throws: ``TuiImagePasteError`` when the file cannot be safely read.
    public func read(_ url: URL) throws -> TuiClipboardImage {
        try Task.checkCancellation()
        guard url.isFileURL else { throw TuiImagePasteError.unsupportedType }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw TuiImagePasteError.storage }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw TuiImagePasteError.unsupportedType
        }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(TuiClipboardImage.maximumBytes) else {
            throw TuiImagePasteError.sizeLimit
        }
        let data: Data
        do {
            data = try file.read(upToCount: TuiClipboardImage.maximumBytes + 1) ?? Data()
        } catch {
            throw TuiImagePasteError.storage
        }
        try Task.checkCancellation()
        return try TuiClipboardImage(data: data)
    }
}
