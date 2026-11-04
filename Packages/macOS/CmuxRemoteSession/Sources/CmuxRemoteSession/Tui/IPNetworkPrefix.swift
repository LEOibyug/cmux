import Darwin
import Foundation

/// Literal-address CIDR arithmetic used to validate user-controlled remote browser routes.
struct IPNetworkPrefix: Sendable, Equatable {
    private let network: [UInt8]
    private let prefixLength: Int

    /// Parses an IPv4/IPv6 network; a bare address denotes one host.
    init?(cidr: String) {
        let parts = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", maxSplits: 1)
        guard let addressText = parts.first,
              let address = Self.bytes(of: String(addressText)) else { return nil }
        let bits = address.count * 8
        let prefix: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...bits).contains(parsed) else { return nil }
            prefix = parsed
        } else {
            prefix = bits
        }
        prefixLength = prefix
        network = Self.masked(address, prefixLength: prefix)
    }

    private func contains(_ host: String) -> Bool {
        guard let address = Self.bytes(of: host), address.count == network.count else { return false }
        return Self.masked(address, prefixLength: prefixLength) == network
    }

    /// RFC 1918 IPv4 and RFC 4193 IPv6 private ranges, without public or loopback addresses.
    private static let privateRanges = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7",
    ].compactMap(IPNetworkPrefix.init(cidr:))

    static func isPrivateAddress(_ host: String) -> Bool {
        privateRanges.contains { $0.contains(host) }
    }

    /// Extracts a route host, removing URL-only IPv6 brackets before literal-IP validation.
    static func routeHost(_ route: String) -> String? {
        guard let components = URLComponents(string: route), var host = components.host,
              !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    private static func bytes(of address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    private static func masked(_ address: [UInt8], prefixLength: Int) -> [UInt8] {
        var result = address
        for index in result.indices {
            let bits = max(0, min(8, prefixLength - index * 8))
            let mask: UInt8 = bits == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            result[index] &= mask
        }
        return result
    }
}
