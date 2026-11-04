public import Foundation

/// Shared copy for drag feedback and rejected catalog/socket mutations.
public enum SurfaceTransferRejection: Error, LocalizedError, Equatable, Sendable {
    case remoteMachineMismatch

    public var errorDescription: String? { message }

    public var message: String {
        String(
            localized: "surfaceDrop.remoteMachineMismatch",
            defaultValue: "SSH workspaces can only hold terminals from their own SSH host. Browser tabs can move freely. Open a local workspace to move other splits there."
        )
    }
}
