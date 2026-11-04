public import Foundation
public import Darwin
public import os

nonisolated private let browserProxyLog = Logger(subsystem: "com.cmuxterm.app", category: "RemoteBrowserProxy")

/// Owns one SSH browser carrier until shutdown or child exit.
public actor RemoteBrowserProxyProcess {
    private static let secretEnvironmentKeys: Set<String> = [
        "CMUX_AUTH_CREDENTIALS_FILE",
        "CMUX_DOGFOOD_STACK_EMAIL",
        "CMUX_DOGFOOD_STACK_PASSWORD",
        "CMUX_UITEST_STACK_EMAIL",
        "CMUX_UITEST_STACK_PASSWORD",
        "CMUX_SOCKET_PASSWORD",
    ]

    private var process: Process?
    private var exit: RemoteLinkFirstValue<Int32>?
    private var endpoint: RemoteBrowserProxyEndpoint?
    private var stopped = false
    public nonisolated let addresses: [String]

    public init(addresses: [String]) { self.addresses = addresses }

    /// The browser carrier authenticates with its generated proxy credential
    /// and its explicit state directory. It must not inherit app login material
    /// or dogfood passwords from the GUI process environment.
    public nonisolated static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !secretEnvironmentKeys.contains($0.key) }
    }

    public var readyEndpoint: RemoteBrowserProxyEndpoint? {
        process?.isRunning == true && !stopped ? endpoint : nil
    }

    public func start(client: URL, arguments: [String], environment: [String: String]? = nil) async throws -> RemoteBrowserProxyEndpoint {
        guard !stopped else { throw CancellationError() }
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let ended = RemoteLinkFirstValue<Int32>()
        let ready = RemoteLinkFirstValue<RemoteBrowserProxyEndpoint>()
        child.executableURL = client
        child.arguments = arguments
        child.environment = Self.sanitizedEnvironment(environment ?? ProcessInfo.processInfo.environment)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { terminated in
            ended.resolve(terminated.terminationStatus)
            ready.resolve(nil)
        }
        do { try child.run() } catch {
            throw error
        }
        process = child
        exit = ended
        let lines = RemoteLinkPipe.lines(from: output.fileHandleForReading)
        Task {
            for await line in lines {
                // The readiness record contains a credential. Never log stdout, including failures.
                if let data = line.data(using: .utf8),
                   let record = try? JSONDecoder().decode(RemoteBrowserProxyEndpoint.self, from: data),
                   record.host == "127.0.0.1", record.port != 0,
                   !record.username.isEmpty, !record.password.isEmpty {
                    ready.resolve(record)
                }
            }
            ready.resolve(nil)
        }
        // Drain stderr concurrently so a reconnecting child cannot block on its pipe.
        let errorLines = RemoteLinkPipe.lines(from: errors.fileHandleForReading)
        Task {
            for await line in errorLines {
                browserProxyLog.debug("browser carrier: \(line, privacy: .private)")
            }
        }
        Task { [weak self] in
            _ = await ended.result
            await self?.didExit()
        }
        do {
            let value = try await withThrowingTaskGroup(of: RemoteBrowserProxyEndpoint?.self) { group in
                group.addTask { await ready.result }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw RemoteMachineLink.LinkError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            try Task.checkCancellation()
            guard !stopped, child.isRunning, let value else {
                throw RemoteMachineLink.LinkError.spawnFailed(String(localized: "cloud.browser.connectionEnded", defaultValue: "The Cloud connection ended. Reload to reconnect."))
            }
            endpoint = value
            return value
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        stopped = true
        endpoint = nil
        if let process, let exit {
            // Retain Process until the termination callback has fired, even when our caller cancels.
            let finished = Task.detached { await exit.result }
            if process.isRunning { process.terminate() }
            let forceStop = Task.detached {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                // Process remains retained until its real exit, so this PID cannot be reused here.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            _ = await finished.value
            forceStop.cancel()
        }
        process = nil
        exit = nil
    }

    private func didExit() async {
        endpoint = nil
    }

}
