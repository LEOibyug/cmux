public import Foundation

public enum ControlCenterCommandError: Error, LocalizedError, Sendable {
    case invalidArguments
    case refused

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Commands require 1–128 literal arguments, at most 16 KiB, without control characters."
        case .refused:
            return "Automatic execution refused: only supported read-only system commands and SSH connections without remote commands are allowed. Shells, scripts, destructive operations, executable overrides and unsafe options are not supported, even in Full Access. Do not retry through another tool."
        }
    }
}

/// Model arguments are data, never shell syntax. System binaries and existing user SSH configuration are trusted.
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
                  !argument.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ControlCenterCommandError.invalidArguments
            }
        }
        let name = (requested as NSString).lastPathComponent
        let executable: String
        switch name {
        case "ls", "pwd", "echo", "hostname", "date": executable = "/bin/" + name
        case "ssh", "printf", "whoami", "uname", "uptime": executable = "/usr/bin/" + name
        default: throw ControlCenterCommandError.refused
        }
        guard requested == name || requested == executable else { throw ControlCenterCommandError.refused }
        let options = arguments.dropFirst()
        switch name {
        case "ssh":
            try Self.validateSSH(options)
            self.arguments = [executable, "-oPermitLocalCommand=no", "-oRemoteCommand=none"] + options
        case "ls":
            var operands = false
            for option in options {
                if option == "--" { operands = true; continue }
                if !operands && option.hasPrefix("-") && option != "-" {
                    guard option.dropFirst().allSatisfy({ "aAlhFLRrtd1q".contains($0) }) else {
                        throw ControlCenterCommandError.refused
                    }
                }
            }
            self.arguments = [executable, "-q"] + options
        case "echo":
            self.arguments = ["/usr/bin/printf", "%s\\n", options.joined(separator: " ")]
        case "uname":
            guard options.allSatisfy({ $0.hasPrefix("-") && $0.count > 1 && $0.dropFirst().allSatisfy({ "amnprsv".contains($0) }) }) else {
                throw ControlCenterCommandError.refused
            }
            self.arguments = [executable] + options
        case "pwd":
            guard options.allSatisfy({ $0 == "-L" || $0 == "-P" }) else { throw ControlCenterCommandError.refused }
            self.arguments = [executable] + options
        case "hostname", "whoami", "uptime":
            guard options.isEmpty else { throw ControlCenterCommandError.refused }
            self.arguments = [executable]
        case "date":
            guard options.isEmpty || (options.count == 1 && options.first?.hasPrefix("+") == true) else {
                throw ControlCenterCommandError.refused
            }
            self.arguments = [executable] + options
        case "printf":
            guard options.first == "%s" || options.first == "%s\\n" else { throw ControlCenterCommandError.refused }
            self.arguments = [executable] + options
        default:
            self.arguments = [executable] + options
        }
    }

    private static func validateSSH(_ arguments: ArraySlice<String>) throws {
        var index = arguments.startIndex
        while index < arguments.endIndex, arguments[index].hasPrefix("-") {
            switch arguments[index] {
            case "-4", "-6", "-v", "-vv", "-vvv", "-t", "-tt", "-T":
                index += 1
            case "-p":
                index += 1
                guard index < arguments.endIndex, let port = Int(arguments[index]), (1...65_535).contains(port) else {
                    throw ControlCenterCommandError.refused
                }
                index += 1
            default:
                throw ControlCenterCommandError.refused
            }
        }
        guard index == arguments.endIndex - 1 else { throw ControlCenterCommandError.refused }
        let destination = arguments[index]
        guard !destination.isEmpty, !destination.hasPrefix("-"), destination.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || "._-@[]:%".utf8.contains(byte)
        }) else { throw ControlCenterCommandError.refused }
    }
}
