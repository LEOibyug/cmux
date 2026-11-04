import Foundation

/// Why an SSH port scan or its in-app route is currently unavailable.
public enum TuiPortDiscoveryUnavailableReason: String, Codable, Hashable, Sendable {
    case link
    case transport
    case privateAddress = "private_address"
}
