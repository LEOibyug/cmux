import Darwin
import Foundation
import XCTest
@testable import cmux

final class ControlCenterSessionValidationTests: XCTestCase {
    func testOMPTitleSlotDoesNotHideIdentityOrTransferState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.jsonl")
        let title = #"{"type":"title","title":"Conversation"}"#
        let header = #"{"type":"session","id":"root-session","version":3,"cwd":"/project"}"#
        for prefix in ["", title + "\n"] {
            try Data((prefix + header + "\n").utf8).write(to: journal)
            try ControlCenterCoordinator.checkSessionFile(journal, sessionID: "root-session")
            XCTAssertThrowsError(try ControlCenterCoordinator.checkSessionFile(journal, sessionID: "another-session"))
            let transfer = #"{"type":"custom_message","customType":"session-transfer","details":{"kind":"departed"}}"#
            try Data((prefix + header + "\n" + transfer + "\n").utf8).write(to: journal)
            XCTAssertThrowsError(try ControlCenterCoordinator.checkSessionFile(journal, sessionID: "root-session"))
        }
        try Data((title + "\n").utf8).write(to: journal)
        XCTAssertThrowsError(try ControlCenterCoordinator.checkSessionFile(journal, sessionID: "root-session"))
    }

    func testOMPStartupEntersLogicalDirectoryBeforeFreshAndExactLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let physical = directory.appendingPathComponent("physical", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        let logical = directory.appendingPathComponent("logical project's directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: physical)
        let executable = directory.appendingPathComponent("record-omp")
        let receipt = directory.appendingPathComponent("argv")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > \(SessionEntry.shellQuote(receipt.path))\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let journal = directory.appendingPathComponent("exact journal's session.jsonl")

        for selectedJournal in [nil, journal] as [URL?] {
            let launch = ControlCenterOMPLaunch(executable: executable, directory: logical.path, journal: selectedJournal)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", launch.initialCommand]
            process.currentDirectoryURL = directory
            process.environment = ["HOME": directory.path, "ZDOTDIR": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let recorded = try String(contentsOf: receipt, encoding: .utf8).components(separatedBy: "\n")
            let expected = [logical.path, "--cwd", logical.path] + (selectedJournal.map { ["--session", $0.path] } ?? []) + [""]
            XCTAssertEqual(recorded, expected)
            try FileManager.default.removeItem(at: receipt)
        }

        try FileManager.default.removeItem(at: logical)
        let launch = ControlCenterOMPLaunch(executable: executable, directory: logical.path, journal: journal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launch.initialCommand]
        process.currentDirectoryURL = directory
        process.environment = ["HOME": directory.path, "ZDOTDIR": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testOMPObservationFindsChildOfForegroundGroupLeaderAndRejectsOtherScopes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-omp")
        try Data("#!/bin/sh\nprintf '%s\\n' $$\nread -r line\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let launch = ControlCenterOMPLaunch(executable: executable, directory: directory.path, journal: nil)
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launch.arguments.map(SessionEntry.shellQuote).joined(separator: " ") + " <&0 & wait"]
        process.currentDirectoryURL = directory
        process.environment = ["PWD": directory.path, "CMUX_WORKSPACE_ID": workspaceID.uuidString, "CMUX_SURFACE_ID": surfaceID.uuidString]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let ready = try XCTUnwrap(try output.fileHandleForReading.read(upToCount: 64))
        let childID = try XCTUnwrap(Int(String(decoding: ready, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer {
            _ = kill(pid_t(childID), SIGTERM)
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        let foregroundID = Int(getpgid(process.processIdentifier))
        XCTAssertFalse(launch.isRunning(processID: Int(process.processIdentifier), workspaceID: workspaceID, surfaceID: surfaceID))
        XCTAssertEqual(launch.runningProcessID(foregroundID: foregroundID, workspaceID: workspaceID, surfaceID: surfaceID), childID)
        XCTAssertNil(launch.runningProcessID(foregroundID: foregroundID, workspaceID: UUID(), surfaceID: surfaceID))
        XCTAssertNil(launch.runningProcessID(foregroundID: foregroundID, workspaceID: workspaceID, surfaceID: UUID()))
    }
}
