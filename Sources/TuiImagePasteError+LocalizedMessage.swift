import CmuxTui
import Foundation

extension TuiImagePasteError {
    /// Explains the actual SSH image-transfer failure without falling back to a local path.
    var localizedMessage: String {
        switch self {
        case .unavailable:
            return String(localized: "tui.imagePaste.unavailable", defaultValue: "The SSH terminal is unavailable. Reconnect before pasting the image.")
        case .unsupported:
            return String(localized: "tui.imagePaste.unsupported", defaultValue: "The SSH host does not support image paste. Install a compatible cmux-tui and reconnect.")
        case .sizeLimit:
            return String(localized: "tui.imagePaste.sizeLimit", defaultValue: "The image exceeds the image-transfer size limit.")
        case .unsupportedType:
            return String(localized: "tui.imagePaste.unsupportedType", defaultValue: "This image format is not supported.")
        case .capacity:
            return String(localized: "tui.imagePaste.capacity", defaultValue: "The SSH host has no temporary image storage available. Free space and retry.")
        case .tooManyImages:
            return String(localized: "tui.imagePaste.tooManyImages", defaultValue: "Paste between one and eight images at a time.")
        case .storage:
            return String(localized: "tui.imagePaste.storage", defaultValue: "The image file could not be read or stored safely.")
        case .timedOut:
            return String(localized: "tui.imagePaste.timedOut", defaultValue: "The image transfer timed out. Check the SSH connection before retrying.")
        case .deliveryUncertain:
            return String(localized: "tui.imagePaste.deliveryUncertain", defaultValue: "The image may have reached the terminal, but delivery was not acknowledged. Check the terminal before retrying.")
        case .useTerminal:
            return String(localized: "tui.imagePaste.useTerminal", defaultValue: "Paste the image directly into a compatible SSH terminal.")
        case .busy:
            return String(localized: "tui.imagePaste.busy", defaultValue: "Another image transfer is still in progress. Wait for it to finish before pasting again.")
        }
    }
}
