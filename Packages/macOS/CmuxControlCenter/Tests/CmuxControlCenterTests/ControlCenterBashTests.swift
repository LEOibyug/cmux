import Foundation
import Darwin
import Testing
import CmuxControlCenter

@Suite("Control Center Bash")
struct ControlCenterBashTests {
    @Test func runsNoninteractiveBashWithLogicalDirectoryAndRuntimeEnvironment() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let physical = directory.appendingPathComponent("physical directory", isDirectory: true)
        let logical = directory.appendingPathComponent("logical directory", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: physical)
        let command = """
        [[ $- != *i* ]] || exit 91
        values=(first second)
        printf '%s\n' "${values[1]}" "$(printf '%s' {a,b,c} | /usr/bin/tr a-z A-Z)"
        printf '%s\n' "$PWD" "$(pwd -L)" "$(pwd -P)" "$PATH"
        if IFS= read -r input; then printf 'unexpected input'; exit 92; else printf 'stdin EOF\n'; fi
        """
        let result = try await ControlCenterBash.run(command: command, directory: logical)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        #expect(result.stdout == "second\nABC\n\(logical.path)\n\(logical.path)\n\(physical.resolvingSymlinksInPath().path)\n\(path)\nstdin EOF\n")
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
        #expect(result.terminationSignal == nil)
        #expect(!result.timedOut && !result.cancelled && !result.outputTruncated)
    }

    @Test func mergesExplicitEnvironmentWithoutLosingDirectoryBinding() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ControlCenterBash.run(
            command: "printf '%s\\n' \"$PATH\" \"$CMUX_FILE_TEST\" \"$PWD\"",
            directory: directory,
            environment: ["PATH": "/explicit/bin:/usr/bin:/bin", "CMUX_FILE_TEST": "literal $(not executed)", "PWD": "/not-the-directory"]
        )
        #expect(result.stdout == "/explicit/bin:/usr/bin:/bin\nliteral $(not executed)\n\(directory.path)\n")
        #expect(result.exitCode == 0 && !result.cancelled && !result.timedOut)
    }

    @Test func preservesSeparateOutputExitStatusAndTerminationSignal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exited = try await ControlCenterBash.run(
            command: "printf 'ordinary output'; printf 'error output' >&2; exit 7",
            directory: directory
        )
        #expect(exited.stdout == "ordinary output")
        #expect(exited.stderr == "error output")
        #expect(exited.exitCode == 7)
        #expect(exited.terminationSignal == nil)
        #expect(!exited.timedOut && !exited.cancelled && !exited.outputTruncated)

        let signalled = try await ControlCenterBash.run(
            command: "printf 'before signal'; kill -USR1 $$",
            directory: directory
        )
        #expect(signalled.stdout == "before signal")
        #expect(signalled.exitCode == 128 + SIGUSR1)
        #expect(signalled.terminationSignal == SIGUSR1)
        #expect(!signalled.timedOut && !signalled.cancelled)
    }

    @Test func boundsBothStreamsWhileContinuingToDrainThem() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ControlCenterBash.run(
            command: "printf '%0200000d' 1; printf '%0200000d' 2 >&2; printf finished > completed",
            directory: directory,
            timeout: 5
        )
        #expect(result.stdout == String(repeating: "0", count: 32 * 1024))
        #expect(result.stderr == String(repeating: "0", count: 32 * 1024))
        #expect(result.outputTruncated)
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(try String(contentsOf: directory.appendingPathComponent("completed"), encoding: .utf8) == "finished")
    }

    @Test func boundsReplacementTextForNonUTF8Output() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ControlCenterBash.run(
            command: #"printf '%040000d' 0 | LC_ALL=C /usr/bin/tr 0 '\377'"#,
            directory: directory,
            timeout: 5
        )
        #expect(result.stdout == String(repeating: "\u{fffd}", count: (32 * 1024) / 3))
        #expect(result.stdout.utf8.count <= 32 * 1024)
        #expect(result.outputTruncated)
        #expect(result.exitCode == 0)
    }

    @Test func timeoutStopsOnlyItsJobIncludingTermIgnoringPipelineChildren() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let survivor = Task {
            try await ControlCenterBash.run(command: "/bin/sleep 1.5; printf unaffected", directory: directory, timeout: 5)
        }
        defer { survivor.cancel() }
        let result = try await ControlCenterBash.run(command: pipelineCommand, directory: directory, timeout: 1)
        #expect(result.timedOut)
        #expect(!result.cancelled)
        #expect(result.stdout == "ready\n")
        #expect(result.stderr.contains("term"))
        #expect(result.durationSeconds >= 1 && result.durationSeconds < 4)
        try await expectProcessesReaped(in: directory)
        let unaffected = try await survivor.value
        #expect(unaffected.stdout == "unaffected")
        #expect(unaffected.exitCode == 0)
        #expect(!unaffected.timedOut && !unaffected.cancelled)
    }

    @Test func cancellationReturnsPartialReceiptAndStopsOwnedPipeline() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            try await ControlCenterBash.run(command: pipelineCommand, directory: directory, timeout: 10)
        }
        defer { task.cancel() }
        try await waitForFile(directory.appendingPathComponent("ready"))
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        #expect(!result.timedOut)
        #expect(result.stdout == "ready\n")
        #expect(result.stderr.contains("term"))
        #expect(result.durationSeconds < 4)
        try await expectProcessesReaped(in: directory)
    }

    @Test func rejectsInvalidRequestsAndPrelaunchCancellationWithoutExecuting() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = "printf launched > launched"
        for invalid in ["", " \n\t", command + "\0", String(repeating: "x", count: 16 * 1024 + 1)] {
            await #expect(throws: ControlCenterBashError.self) {
                try await ControlCenterBash.run(command: invalid, directory: directory)
            }
        }
        for timeout in [0.0, -1.0, 300.1, Double.infinity, Double.nan] {
            await #expect(throws: ControlCenterBashError.self) {
                try await ControlCenterBash.run(command: command, directory: directory, timeout: timeout)
            }
        }
        for invalidDirectory in [
            directory.appendingPathComponent("missing"),
            try #require(URL(string: "https://example.invalid/"))
        ] {
            await #expect(throws: ControlCenterBashError.self) {
                try await ControlCenterBash.run(command: command, directory: invalidDirectory)
            }
        }
        let file = directory.appendingPathComponent("not a directory")
        try Data().write(to: file)
        await #expect(throws: ControlCenterBashError.self) {
            try await ControlCenterBash.run(command: command, directory: file)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ControlCenterBash.run(command: command, directory: directory)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("launched").path))
    }

    private var pipelineCommand: String {
        """
        trap 'printf "term\\n" >&2' TERM
        printf '%s\\n' "$$" > shell.pid
        /bin/bash --noprofile --norc -c 'trap "" TERM; printf "%s\\n" "$$" > first.pid; /bin/sleep 30 & printf "%s\\n" "$!" > first-child.pid; wait' |
            /bin/bash --noprofile --norc -c 'trap "" TERM; printf "%s\\n" "$$" > second.pid; /bin/sleep 30 & printf "%s\\n" "$!" > second-child.pid; wait' &
        while [[ ! -s first-child.pid || ! -s second-child.pid ]]; do /bin/sleep 0.01; done
        printf 'ready\\n'
        printf ready > ready
        wait
        """
    }

    private func makeDirectory() throws -> URL {
        let directory = controlCenterTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: file.path), "Bash did not reach its readiness marker")
        _ = try Data(contentsOf: file)
    }

    private func expectProcessesReaped(in directory: URL) async throws {
        for name in ["shell.pid", "first.pid", "second.pid", "first-child.pid", "second-child.pid"] {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while kill(pid, 0) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = kill(pid, 0)
            let code = errno
            #expect(result == -1 && code == ESRCH, "Bash retained process \(pid) from \(name)")
        }
    }
}
