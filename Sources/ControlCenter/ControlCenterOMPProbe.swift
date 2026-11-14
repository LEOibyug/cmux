import Darwin
import Foundation

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
