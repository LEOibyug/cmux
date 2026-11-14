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
}
