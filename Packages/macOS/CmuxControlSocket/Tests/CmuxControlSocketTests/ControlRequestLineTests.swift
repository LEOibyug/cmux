@testable import CmuxControlSocket
import Darwin
import Foundation
import Testing

@Suite("Control request line encoding")
struct ControlRequestLineTests {
    /// Larger than the reader's 4 KiB route classification window, and small
    /// enough for one socketpair buffer so the test can write before reading.
    private static let padding = String(repeating: "x", count: 2_500)

    private static func largeRequest(extraKey: String) -> [String: Any] {
        [
            "id": "request-\(extraKey)",
            "method": "surface.respawn",
            "params": [
                "surface_id": "44444444-4444-4444-8444-444444444444",
                "command": Self.padding,
                "tmux_start_command": Self.padding,
                extraKey: true,
            ] as [String: Any],
        ]
    }

    @Test func methodIsTheFirstKeyAndTheRequestRoundTrips() throws {
        let request = Self.largeRequest(extraKey: "focus")
        let line = try ControlRequestLine.encode(request)

        #expect(line.hasPrefix(#"{"method":"surface.respawn","#))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary
        )
        #expect(decoded.isEqual(to: request))
    }

    

    

    

    @Test func requestWithOnlyAMethodIsOneKeyObject() throws {
        #expect(try ControlRequestLine.encode(["method": "system.ping"]) == #"{"method":"system.ping"}"#)
    }

    @Test func requestWithoutAMethodKeepsSortedKeys() throws {
        #expect(try ControlRequestLine.encode(["b": 1, "a": 2]) == #"{"a":2,"b":1}"#)
    }

    @Test func invalidJSONObjectThrows() {
        #expect(throws: ControlRequestLine.EncodingError.self) {
            try ControlRequestLine.encode(["method": "x", "params": Date()])
        }
    }

    private static func writeAll(_ value: String, to descriptor: Int32) throws {
        let data = Data(value.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                try #require(count > 0)
                offset += count
            }
        }
    }
}
