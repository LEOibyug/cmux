public import Foundation

public enum ControlCenterCommandError: Error, LocalizedError, Sendable {
    case invalidArguments

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Commands require 1–128 literal arguments, a nonempty executable, at most 16 KiB, and no NUL bytes."
        }
    }
}

/// Workspace arguments are literal argv entries, not shell source.
public struct ControlCenterCommand: Sendable {
    public let arguments: [String]

    public init(arguments: [String]) throws {
        guard let requested = arguments.first, !requested.isEmpty, arguments.count <= 128 else {
            throw ControlCenterCommandError.invalidArguments
        }
        var byteCount = 0
        for argument in arguments {
            byteCount += argument.utf8.count
            guard byteCount <= 16_384,
                  !argument.utf8.contains(0) else {
                throw ControlCenterCommandError.invalidArguments
            }
        }
        self.arguments = arguments
    }
}
