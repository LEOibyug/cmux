import Foundation
import Testing
import CmuxControlCenter

@Suite("Control Center workspace argv")
struct ControlCenterCommandTests {
    @Test(arguments: [
        [], [""], ["pwd", "\u{0}"],
        ["printf", "%s", String(repeating: "x", count: 16_385)],
        ["echo"] + Array(repeating: "x", count: 128)
    ])
    func rejectsMalformedOrUnboundedArguments(_ arguments: [String]) {
        #expect(throws: ControlCenterCommandError.self) {
            try ControlCenterCommand(arguments: arguments)
        }
    }

    @Test func permitsRequestedShellAndPassesItsOperandsLiterally() throws {
        let directory = controlCenterTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let operand = "$(touch unexpected); 'quoted'\nsecond line"
        let command = try ControlCenterCommand(arguments: ["/bin/sh", "-c", "printf '%s' \"$1\"", "workspace", operand])
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.arguments[0])
        process.arguments = Array(command.arguments.dropFirst())
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output, as: UTF8.self) == operand)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("unexpected").path))
    }
}
