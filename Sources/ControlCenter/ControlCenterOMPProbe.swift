import CmuxFoundation
import Darwin
import Foundation

/// Starts OMP as the terminal process, never as prompt-dependent typeahead.
struct ControlCenterOMPLaunch: Sendable {
    let executable: URL
    let directory: String
    let journal: URL?

    var arguments: [String] {
        [executable.path, "--cwd", directory] + (journal.map { ["--session", $0.path] } ?? [])
    }

    var initialCommand: String {
        // Ghostty may start elsewhere if its cwd disappears. Recheck in the
        // child before exec, preserving the logical path and never falling back.
        let command = "cd -L -- \(SessionEntry.shellQuote(directory)) && exec " +
            arguments.map(SessionEntry.shellQuote).joined(separator: " ")
        return WorkspaceInitialCommandLoginShell.wrap("exec /bin/sh -c \(SessionEntry.shellQuote(command))")
    }

    func runningProcessID(foregroundID: Int, workspaceID: UUID, surfaceID: UUID) -> Int? {
        if isRunning(processID: foregroundID, workspaceID: workspaceID, surfaceID: surfaceID) { return foregroundID }
        guard foregroundID > 0, foregroundID <= Int(Int32.max) else { return nil }
        // macOS login can remain the foreground group leader after its child execs OMP.
        let size = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(foregroundID), nil, 0)
        guard size > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 8)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(foregroundID), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, Int(bytes) < pids.count * MemoryLayout<pid_t>.stride else { return nil }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).lazy.map(Int.init).first {
            $0 != foregroundID && getpgid(pid_t($0)) == pid_t(foregroundID)
                && isRunning(processID: $0, workspaceID: workspaceID, surfaceID: surfaceID)
        }
    }

    func isRunning(processID: Int, workspaceID: UUID, surfaceID: UUID) -> Bool {
        guard processID > 0, processID <= Int(Int32.max),
              let identity = AgentPIDProcessIdentity(pid: pid_t(processID)),
              let process = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(
                for: processID, expectedIdentity: identity
              ),
              process.environment["CMUX_WORKSPACE_ID"]?.lowercased() == workspaceID.uuidString.lowercased(),
              process.environment["CMUX_SURFACE_ID"]?.lowercased() == surfaceID.uuidString.lowercased(),
              process.environment["PWD"] == directory,
              let executableIndex = process.arguments.firstIndex(where: {
                $0.hasPrefix("/") && URL(fileURLWithPath: $0).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
              }) else { return false }
        return process.arguments.dropFirst(executableIndex + 1).elementsEqual(arguments.dropFirst())
    }
}

/// Only fixed, read-only OMP CLI probes use this runner; model text never becomes argv.
final class ControlCenterOMPProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        let process = process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func capture(executable: URL, arguments: [String], directory: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let pipe = Pipe()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    var environment = ProcessInfo.processInfo.environment
                    environment["TMPDIR"] = directory.path
                    environment["TMP"] = directory.path
                    environment["TEMP"] = directory.path
                    process.environment = environment
                    process.currentDirectoryURL = directory
                    self.lock.lock()
                    if self.stopped {
                        self.lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try process.run()
                        self.process = process
                        self.lock.unlock()
                    } catch {
                        self.lock.unlock()
                        continuation.resume(throwing: error)
                        return
                    }
                    let deadline = DispatchWorkItem { self.stop() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
                    var output = Data()
                    while true {
                        let chunk = pipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        if output.count + chunk.count > 262_144 { self.stop(); break }
                        output.append(chunk)
                    }
                    process.waitUntilExit()
                    deadline.cancel()
                    self.lock.lock()
                    let stopped = self.stopped
                    self.process = nil
                    self.lock.unlock()
                    if stopped {
                        continuation.resume(throwing: ControlCenterHostError.blocked("OMP probe was cancelled, timed out, or exceeded its output limit. No session was started."))
                    } else if process.terminationStatus != 0 {
                        continuation.resume(throwing: ControlCenterHostError.blocked("Installed OMP could not inspect session ownership. Resume is blocked; update or select an OMP executable supporting 'session lease --json'."))
                    } else {
                        continuation.resume(returning: output)
                    }
                }
            }
        } onCancel: {
            self.stop()
        }
    }
}
