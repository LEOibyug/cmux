import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SurfaceCLIArgumentTests {
    final class BundleProbe {}


    @Test(arguments: ["open", "project"], ["--left", "--right", "--up", "--down"])
    func surfaceOpenRejectsTabAndSideBeforeMutation(subcommand: String, side: String) throws {
        let result = try runWithoutMutationRequests(["surface", subcommand, "local/terminal/test", "--pane", "pane:1", "--tab", side])
        #expect(result.status != 0, "\(result.text)")
        #expect(result.text.contains("--tab and a pane side"), "\(result.text)")
    }


    @Test(arguments: ["--help", "-h"])
    func topLevelAgentHelpDoesNotConnect(help: String) throws {
        for command in [["agent", help]] {
            let result = try runWithoutMutationRequests(command)
            #expect(result.status == 0, "\(result.text)")
            #expect(result.text.contains("Usage:") && result.text.contains("cmux agent"), "\(result.text)")
            #expect(!result.connected, "Help unexpectedly connected to the app socket")
        }
    }

    private func runWithoutMutationRequests(_ arguments: [String]) throws -> (status: Int32, text: String, connected: Bool) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-agent-help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try BundledCLITestSupport.bundledCLIURL(for: BundleProbe.self)
        let socketPath = "/tmp/cmux-args-\(UUID().uuidString).sock"
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { Darwin.close(listener); unlink(socketPath) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: socketPath.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 1) == 0)
        try #require(fcntl(listener, F_SETFL, O_NONBLOCK) == 0)
        do {
            let output = directory.appendingPathComponent("output")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--socket", socketPath] + arguments
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
            environment["HOME"] = directory.path
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            let finished = ended.wait(timeout: .now() + 10) == .success
            if !finished { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let text = try String(contentsOf: output, encoding: .utf8)
            #expect(finished, "\(arguments): \(text)")
            let connection = Darwin.accept(listener, nil, nil)
            if connection >= 0 {
                defer { Darwin.close(connection) }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let received = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.recv(connection, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
                }
                #expect(received == 0, "Unexpected socket request: \(String(decoding: buffer.prefix(max(received, 0)), as: UTF8.self))")
            }
            return (process.terminationStatus, text, connection >= 0)
        }
    }


    @Test func focusFlagValueAcceptsOnlyBooleanWords() {
        for token in ["true", "TRUE", "1", "yes"] { #expect(CmuxTuiRemoteRouting.focusFlagValue(token) == true) }
        for token in ["false", "0", "No"] { #expect(CmuxTuiRemoteRouting.focusFlagValue(token) == false) }
        for token in ["", "fix", "truely", "on"] { #expect(CmuxTuiRemoteRouting.focusFlagValue(token) == nil) }
    }
}

