import CmuxFoundation
import Foundation

// Readability callbacks and process termination race across queues. The lock
// protects the bounded buffers and one-shot completion of this synchronous seam.
final class ProcessOutputCollector: @unchecked Sendable {
    private enum Stream {
        case stdout
        case stderr
    }

    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let lock = NSLock()
    private let byteLimit = 32 * 1024
    private var stdout = Data()
    private var stderr = Data()
    private var isFinished = false

    private let onOutput: ((Data) -> Void)?

    init(stdout: Pipe, stderr: Pipe, onOutput: ((Data) -> Void)? = nil) {
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
        self.onOutput = onOutput
    }

    func start() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stdout)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stderr)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
    }

    @discardableResult
    func finish() -> String {
        lock.lock()
        guard !isFinished else {
            let output = formattedOutputLocked()
            lock.unlock()
            return output
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        append(stdoutHandle.readDataToEndOfFileOrEmpty(), to: .stdout)
        append(stderrHandle.readDataToEndOfFileOrEmpty(), to: .stderr)
        try? stdoutHandle.close()
        try? stderrHandle.close()

        lock.lock()
        let output = formattedOutputLocked()
        lock.unlock()
        return output
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    private func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }
        onOutput?(data)
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout:
            appendBounded(data, to: &stdout)
        case .stderr:
            appendBounded(data, to: &stderr)
        }
    }

    private func appendBounded(_ data: Data, to buffer: inout Data) {
        guard data.count < byteLimit else {
            buffer = Data(data.suffix(byteLimit))
            return
        }

        let overflow = buffer.count + data.count - byteLimit
        if overflow > 0 {
            buffer.removeSubrange(0..<overflow)
        }
        buffer.append(data)
    }

    private func formattedOutputLocked() -> String {
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let error = String(data: stderr, encoding: .utf8) ?? ""
        return [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
