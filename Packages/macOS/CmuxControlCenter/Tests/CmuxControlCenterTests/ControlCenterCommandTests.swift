import Foundation
import Testing
import CmuxControlCenter

@Suite("Control Center command admission")
struct ControlCenterCommandTests {
    @Test(arguments: [
        ["rm", "-rf", "/"],
        ["sudo", "ls"],
        ["sh", "-c", "pwd"],
        ["python3", "-c", "print('hello')"],
        ["curl", "https://example.com/install.sh"],
        ["/untrusted/ssh", "lab-computer"],
        ["ssh", "lab-computer", "touch remote-file"],
        ["ssh", "-oProxyCommand=touch local-file", "lab-computer"],
        ["ssh", "-F", "untrusted-config", "lab-computer"],
        ["ssh", "-s", "lab-computer", "sftp"],
        ["ssh", "-p", "0", "lab-computer"],
        ["ssh", "-p", "65536", "lab-computer"],
        ["ssh", "bad host"],
        ["hostname", "new-hostname"],
        ["date", "010100002026"],
        ["uname", "-S", "new-hostname"],
        ["printf", "%b", "\\033]52;c;data\\a"],
        ["ls", "-w"]
    ])
    func refusesUnsafeExecution(_ arguments: [String]) {
        #expect(throws: ControlCenterCommandError.self) {
            try ControlCenterCommand(arguments: arguments)
        }
    }

    @Test(arguments: [
        [], [""], ["ssh"], ["pwd", "\u{0}"], ["ssh", "lab\ncomputer"],
        ["printf", "%s", String(repeating: "x", count: 16_385)],
        ["echo"] + Array(repeating: "x", count: 128)
    ])
    func rejectsMalformedOrUnboundedArguments(_ arguments: [String]) {
        #expect(throws: ControlCenterCommandError.self) {
            try ControlCenterCommand(arguments: arguments)
        }
    }

    @Test func sshCannotInheritAutomaticLocalOrRemoteCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = directory.appendingPathComponent("ssh_config")
        try "Host lab-computer\n HostName 127.0.0.1\n Port 2222\n PermitLocalCommand yes\n RemoteCommand touch unexpected\n".write(to: configuration, atomically: true, encoding: .utf8)
        let command = try ControlCenterCommand(arguments: ["ssh", "lab-computer"])
        let output = try capture([command.arguments[0], "-G", "-F", configuration.path] + command.arguments.dropFirst())
        #expect(output.contains("permitlocalcommand no\n"))
        #expect(!output.split(separator: "\n").contains { $0.hasPrefix("remotecommand ") && $0 != "remotecommand none" })
        #expect(output.contains("hostname 127.0.0.1\n"))
        #expect(output.contains("port 2222\n"))
    }

    @Test func echoDoesNotInterpretTerminalControlEscapes() throws {
        let command = try ControlCenterCommand(arguments: ["echo", "-e", "\\033]52;c;data\\a", "$(touch unexpected)"])
        let output = try capture(command.arguments)
        #expect(output == "-e \\033]52;c;data\\a $(touch unexpected)\n")
    }

    private func capture(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: output, as: UTF8.self)
    }
}
