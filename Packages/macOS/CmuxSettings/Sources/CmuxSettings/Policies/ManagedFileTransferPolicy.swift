import AppKit
import Foundation

/// Resolves the managed policy for cmux-mediated transfers to user-controlled hosts.
public struct ManagedFileTransferPolicy: Sendable {
    private let policy: ManagedDevicePolicy
    private static let refusalErrorDomain = "cmux.managedPolicy.fileTransfer"

    /// Creates a file-transfer policy resolver.
    /// - Parameter policy: The managed-device preference source.
    public init(policy: ManagedDevicePolicy = ManagedDevicePolicy()) {
        self.policy = policy
    }

    /// Whether an administrator disables cmux-mediated file transfer.
    public var isDisabled: Bool { policy.isEnforced(.disableFileTransfer) }

    /// Whether cmux-mediated file transfer may proceed.
    public var isEnabled: Bool { !isDisabled }

    /// The explanation shown when a transfer is refused.
    public var disabledMessage: String {
        String(localized: "managedPolicy.fileTransfer.disabled", defaultValue: "File transfer is disabled by your organization.")
    }

    /// Creates the error passed through existing upload failure paths.
    /// - Returns: An error carrying the managed-policy refusal message.
    public func refusalError() -> NSError {
        NSError(domain: Self.refusalErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: disabledMessage])
    }

    /// Distinguishes policy refusals from transport failures.
    /// - Parameter error: The failure reported by an upload operation.
    /// - Returns: Whether the failure was produced by this policy.
    public func isRefusal(_ error: Error) -> Bool {
        (error as NSError).domain == Self.refusalErrorDomain
    }

    /// Explains a refused drop or paste on the main actor.
    public func presentRefusal() {
        let message = disabledMessage
        if Thread.isMainThread {
            MainActor.assumeIsolated { Self.present(message: message) }
        } else {
            Task { @MainActor in Self.present(message: message) }
        }
    }

    @MainActor
    private static func present(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = String(localized: "managedPolicy.fileTransfer.refusalDetail", defaultValue: "cmux did not upload the file. Your organization's device policy disables file transfer through cmux.")
        alert.alertStyle = .informational
        alert.runModal()
    }
}
