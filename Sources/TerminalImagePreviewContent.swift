import CoreGraphics
import Foundation

struct TerminalImagePreviewIdentity: Equatable {
    let surfaceId: UUID
    let runtimeGeneration: UInt64
    let imageId: UInt32
    let imageGeneration: UInt64
}

struct TerminalImagePreviewContent {
    let identity: TerminalImagePreviewIdentity
    let image: CGImage
}

enum FilePreviewSource {
    case file(String)
    case terminalImage(TerminalImagePreviewContent)
}
