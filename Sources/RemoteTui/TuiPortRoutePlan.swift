import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

/// Resolves explicit SSH service URLs without falling back to a public preview.
enum TuiPortRoutePlan: Equatable, Sendable {
    case privateDirect(remoteURL: String)
    case unsupported(String)

    static func blocker(supportsPreviews: Bool, privateAddress: String?, allowLoopback: Bool = false) -> TuiPortDiscoveryState? {
        guard supportsPreviews else { return .unsupported }
        guard let address = privateAddress,
              RemotePortRoutePolicy().privateURL("http://localhost", address: address, allowLoopback: allowLoopback) != nil else {
            return .unavailable(.privateAddress)
        }
        return nil
    }

    static func plan(resource: SurfaceResource, privateAddress: String?) -> TuiPortRoutePlan {
        guard let port = resource.id.forwardedPort ?? resource.port,
              (1...65_535).contains(port) else {
            return .unsupported(String(format: String(localized: "remote.port.noPort", defaultValue: "%@ has no port to open."), resource.id.rawValue))
        }
        guard blocker(supportsPreviews: true, privateAddress: privateAddress, allowLoopback: resource.machine.isSSH) == nil,
              let address = privateAddress else {
            return .unsupported(String(format: String(localized: "remote.port.noAddress", defaultValue: "%@ has no reachable address. Reconnect the SSH host and retry."), resource.machine.rawValue))
        }
        var direct = URLComponents()
        direct.scheme = "http"
        direct.host = address
        direct.port = port
        let raw = resource.url ?? direct.string ?? ""
        guard let url = RemotePortRoutePolicy().privateURL(raw, address: address, allowLoopback: resource.machine.isSSH) else {
            return .unsupported(String(localized: "remote.port.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
        }
        if let port = resource.id.forwardedPort, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.port = port
            guard let canonical = parts.url else {
                return .unsupported(String(localized: "remote.port.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
            }
            return .privateDirect(remoteURL: canonical.absoluteString)
        }
        return .privateDirect(remoteURL: url.absoluteString)
    }
}
