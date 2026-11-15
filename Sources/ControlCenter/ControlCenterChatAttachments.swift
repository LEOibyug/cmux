import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ControlCenterChatAttachment: Identifiable {
    let id: UUID
    let name: String
    let dataURL: String
    let preview: NSImage

    init(id: UUID = UUID(), name: String, dataURL: String, previewData: Data? = nil) throws {
        let data: Data
        if let previewData {
            data = previewData
        } else {
            guard let comma = dataURL.firstIndex(of: ","),
                  let decoded = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { throw ControlCenterChatImageError.invalid }
            data = decoded
        }
        guard let image = NSImage(data: data) else { throw ControlCenterChatImageError.invalid }
        self.id = id
        self.name = name
        self.dataURL = dataURL
        preview = image
    }
}

private enum ControlCenterChatImageError: Error, Equatable {
    case invalid, tooLarge
}

extension ControlCenterCoordinator {
    func addChatImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard chatAttachments.count + urls.count <= 8 else {
            chatComposerError = ControlCenterStrings.text("chatImageLimit")
            return
        }
        importChatImages {
            try urls.map { url in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
                guard data.count <= 32 * 1024 * 1024 else { throw ControlCenterChatImageError.tooLarge }
                return (url.lastPathComponent, try Self.normalizedChatImage(data))
            }
        }
    }

    func addChatImageData(_ data: Data, name: String) {
        guard chatAttachments.count < 8 else {
            chatComposerError = ControlCenterStrings.text("chatImageLimit")
            return
        }
        importChatImages { [(name, try Self.normalizedChatImage(data))] }
    }

    private func importChatImages(_ load: @escaping @Sendable () throws -> [(String, Data)]) {
        let generation = chatDraftGeneration
        chatImageImportCount += 1
        chatImagesLoading = true
        chatComposerError = nil
        Task { @MainActor in
            defer {
                if generation == chatDraftGeneration {
                    chatImageImportCount -= 1
                    chatImagesLoading = chatImageImportCount > 0
                }
            }
            do {
                let values = try await Task.detached(priority: .userInitiated, operation: load).value
                guard generation == chatDraftGeneration else { return }
                guard chatAttachments.count + values.count <= 8 else { throw ControlCenterChatImageError.tooLarge }
                let total = chatAttachments.reduce(0) { $0 + $1.dataURL.utf8.count }
                    + values.reduce(0) { $0 + (($1.1.count + 2) / 3) * 4 + 22 }
                guard total <= 12 * 1024 * 1024 else { throw ControlCenterChatImageError.tooLarge }
                let attachments = try values.map {
                    try ControlCenterChatAttachment(name: $0.0, dataURL: "data:image/png;base64," + $0.1.base64EncodedString(), previewData: $0.1)
                }
                chatAttachments.append(contentsOf: attachments)
            } catch {
                guard generation == chatDraftGeneration else { return }
                chatComposerError = ControlCenterStrings.text(error as? ControlCenterChatImageError == .tooLarge ? "chatImagesTooLarge" : "chatImageInvalid")
            }
        }
    }

    func removeChatImage(_ id: UUID) {
        chatAttachments.removeAll { $0.id == id }
    }

    nonisolated private static func normalizedChatImage(_ data: Data) throws -> Data {
        guard data.count <= 32 * 1024 * 1024 else { throw ControlCenterChatImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ControlCenterChatImageError.invalid }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw ControlCenterChatImageError.invalid
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ControlCenterChatImageError.invalid }
        guard encoded.length <= 8 * 1024 * 1024 else { throw ControlCenterChatImageError.tooLarge }
        return encoded as Data
    }
}
