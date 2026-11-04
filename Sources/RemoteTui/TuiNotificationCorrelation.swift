import Foundation

/// Correlation keys tie a local notification back to its SSH machine and
/// daemon row so reads can be acknowledged without guessing from text.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
enum TuiNotificationCorrelation: Sendable {
    static let prefix = "ssh-notification:"
    private static let versionedPrefix = "v2:"

    static func key(machineID: String, notificationID: String) -> String {
        "\(prefix)\(versionedPrefix)\(encode(machineID)):\(encode(notificationID))"
    }

    static func parse(_ key: String) -> (machineID: String, notificationID: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard rest.hasPrefix(versionedPrefix) else { return nil }
        let components = rest.dropFirst(versionedPrefix.count)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let machineID = decode(String(components[0])),
              let notificationID = decode(String(components[1])),
              !machineID.isEmpty,
              !notificationID.isEmpty else { return nil }
        return (machineID, notificationID)
    }

    /// Matches a persisted local record to an SSH daemon event.
    static func matches(_ key: String, machineID: String, notificationIDs: Set<String>) -> Bool {
        guard let source = parse(key) else { return false }
        return source.machineID == machineID && notificationIDs.contains(source.notificationID)
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decode(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
