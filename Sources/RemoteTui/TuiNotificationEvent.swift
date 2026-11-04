import Foundation

/// Bounded content admitted from one SSH daemon notification row.
struct TuiNotificationEvent: Equatable, Sendable {
    static let maxTitleBytes = 128
    static let maxBodyBytes = 1024
    static let maxLineBytes = 64 * 1024

    let id: String
    let terminalID: String?
    let title: String
    let body: String
}
