public import CmuxTui
public import CmuxSurfaceCatalogModel
public import Foundation
public import CmuxCore
public import Darwin

/// One headless cmux-tui carrier for a user-controlled SSH machine.
/// Native panes and control requests share its daemon-owned session and local socket.
///
/// Lifecycle: `connect` spawns the client and resolves once the first
/// `connection-snapshot` line names the socket; the process is kept until `disconnect`
/// or until it exits on its own (machine slept, route expired), which flips the state
/// and ends the `changes` stream so the owner can re-link on demand.
public actor RemoteMachineLink {
    /// Current carrier state and its real diagnostic, independent of a hosting provider.
    public struct Status: Sendable, Equatable {
        /// The current connection state.
        public let state: SurfaceLinkState
        /// The most recent transport failure, if any.
        public let error: String?

        /// Creates a snapshot of one SSH carrier.
        ///
        /// - Parameters:
        ///   - state: Current carrier state.
        ///   - error: Most recent transport failure, if any.
        public init(state: SurfaceLinkState, error: String?) {
            self.state = state
            self.error = error
        }
    }

    /// Stable reason emitted when the bounded event-feed recovery budget is spent.
    /// Providers use the same value when deciding whether a later healthy stream
    /// has cleared the transport warning.
    public nonisolated static let eventsRecoveryExhaustedReason = "events_recovery_exhausted"

    /// Recovery state is one phase so an exhausted stream cannot be mistaken for
    /// a snapshot-only stream or a fresh connection. The attempt is consecutive
    /// until an accepted stream stays healthy for the policy's stability window.
    public enum EventsRecoveryPhase: Equatable, Sendable {
        case healthy
        case recovering(attempt: Int)
        /// The retry budget is spent, but one authoritative full snapshot may
        /// make one final stream-start attempt without resetting that budget.
        case exhausted(canResumeFromSnapshot: Bool)
        /// A snapshot consumed the one-shot restart allowance. It must become
        /// healthy before another failure can be forgiven.
        case snapshotRecovery
        case snapshotOnly
    }

    /// A manual reader restart is a transport operation, not a new connection.
    /// It may preserve a healthy or in-progress recovery phase, but it cannot
    /// bypass an exhausted budget or resume an unversioned snapshot stream.
    public nonisolated static func canRestartEventsSubscription(for phase: EventsRecoveryPhase) -> Bool {
        switch phase {
        case .healthy, .recovering, .snapshotRecovery:
            return true
        case .exhausted, .snapshotOnly:
            return false
        }
    }

    /// One notification from the daemon session stream. The provider validates
    /// its cursor before it can replace the installed `TuiState`.
    public enum Change: Sendable, Equatable {
        case connected
        case snapshot(cursor: TuiCursor, resetReason: String?, payload: Data)
        case delta(cursor: TuiCursor, previousRevision: UInt64, revision: UInt64, payload: Data)
        case streamEnded(reason: String, cursor: TuiCursor?)
        /// An unknown item is a synchronization barrier. Ignoring it could make
        /// the following known delta appear valid after a state change was lost.
        case unknown(cursor: TuiCursor?)
    }

    public struct Connected: Sendable, Equatable {
        public let socketPath: String
        public let session: String

        public init(
            socketPath: String,
            session: String
        ) {
            self.socketPath = socketPath
            self.session = session
        }
    }

    /// The first thing the link process tells us: a socket line, stdout closing
    /// without one, or the connect deadline passing.
    private enum LinkFirstLine: Sendable {
        case socket(String)
        case ended
        case timedOut
    }

    public enum LinkError: Error, LocalizedError {
        /// Stable classification used by callers that need to choose recovery
        /// behavior without inspecting localized diagnostics.
        public enum Category: String, Equatable, Sendable {
            /// The SSH host's daemon did not become available.
            case daemonUnavailable = "daemon_unavailable"
            /// The local cmux-tui client could not be started.
            case clientUnavailable = "client_unavailable"
            /// The request could not be sent because its input was invalid.
            case requestRejected = "request_rejected"
            /// The caller supplied a status or message without a stable class.
            case other
        }

        case clientMissing
        case spawnFailed(String)
        case failureMessage(String)
        case exited(status: Int32, output: String)
        /// The local client exited before it reported a socket, for example
        /// an older local client rejecting a flag before connecting to the SSH host.
        case exitedBeforeSocket(status: Int32, output: String)
        case timedOut
        case requestTimedOut
        case inputTooLarge

        /// Stable recovery category for this link failure.
        public var category: Category {
            switch self {
            case .exited(_, let output):
                // A structured error's code is authoritative. A reachable daemon
                // rejecting the request (`revision.conflict`, `selector.not_found`)
                // answered; only transport codes mean it is unavailable.
                guard let code = Self.structuredErrorCode(output) else { return .daemonUnavailable }
                return Self.transportErrorCodes.contains(code) ? .daemonUnavailable : .other
            case .timedOut:
                return .daemonUnavailable
            case .clientMissing, .spawnFailed, .exitedBeforeSocket:
                return .clientUnavailable
            case .inputTooLarge:
                return .requestRejected
            case .failureMessage, .requestTimedOut:
                return .other
            }
        }

        public var errorDescription: String? {
            switch self {
            case .inputTooLarge:
                return String(localized: "cloud.link.inputTooLarge", defaultValue: "The machine input chunk is too large. Split it into smaller chunks and retry.")
            case .clientMissing:
                return String(localized: "remote.link.clientMissing", defaultValue: "A local cmux-tui client is required. Build or install it explicitly and set CMUX_TUI_CLIENT to its executable path. Install a compatible cmux-tui on the SSH host before connecting; cmux will not download or upgrade it.")
            case .spawnFailed(let detail):
                return String(
                    format: String(
                        localized: "remote.link.spawnFailed",
                        defaultValue: "The SSH terminal connection could not be started: %@"
                    ),
                    detail
                )
            case .failureMessage(let detail):
                return detail
            case .exited(let status, let output), .exitedBeforeSocket(let status, let output):
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                let message = String(
                    format: String(
                        localized: "remote.link.exited",
                        defaultValue: "The SSH terminal connection exited with status %@"
                    ),
                    String(status)
                )
                return message + (tail.isEmpty ? "" : ": \(tail)")
            case .timedOut:
                return String(localized: "remote.link.timedOut", defaultValue: "The SSH terminal connection did not report a socket before the connection deadline.")
            case .requestTimedOut:
                return String(localized: "remote.link.requestTimedOut", defaultValue: "The SSH host did not answer before the request deadline. Check the connection before retrying.")
            }
        }

        /// Error codes the daemon or link report when the transport, not the
        /// request, failed.
        static let transportErrorCodes: Set<String> = ["transport.closed", "transport.timeout"]

        /// The code of a structured error object, or nil when `output` is not one.
        /// An object without a code is still a daemon answer and yields "".
        private static func structuredErrorCode(_ output: String) -> String? {
            guard let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let detail = (object["details"] as? [String: Any])?["error"] as? String,
               transportErrorCodes.contains(detail) {
                return detail
            }
            return (object["code"] as? String) ?? (object["error_code"] as? String) ?? ""
        }

    }

    public nonisolated let machineID: String
    private let clientURL: URL
    private let paths: TuiClientPaths
    private let deadlineClock: any Clock<Duration>

    public private(set) var state: SurfaceLinkState = .connecting
    public private(set) var lastError: String?

    /// Human-readable text for a link failure. Typed cmux errors describe
    /// themselves (`VMClientError` is `CustomStringConvertible`, the link and
    /// manager errors are `LocalizedError`); only foreign errors fall back to
    /// Foundation's "The operation couldn't be completed. (… error 1.)".
    public nonisolated static func errorText(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        // Swift errors print their `description` (or case name) here; a real
        // NSError prints "Error Domain=… Code=…", where localizedDescription
        // is the readable form.
        let described = String(describing: error)
        if described.isEmpty || described.hasPrefix("Error Domain=") {
            return error.localizedDescription
        }
        return described
    }
    public private(set) var connected: Connected?

    // The link process and its pipes are actor-isolated state; its exit observer hops
    // back into the actor through a Task, so nothing else touches them.
    private var process: RemoteLinkProcess?
    private var processExit: RemoteLinkFirstValue<Int32>?
    /// One local JSON resource connection shared by every control request for
    /// this machine. Terminal attachment streams are still allowed to subscribe
    /// separately while they migrate onto this same multiplexer.
    private var resourceConnection: TuiPersistentResourceConnection?
    private var eventStreamID: String?
    private var eventsSubscriptionID: UUID?
    private var eventsReaderTask: Task<Void, Never>?
    private var eventsCursor: TuiCursor?
    private let eventsRecoveryClock: any Clock<Duration>
    private let eventsRecoveryPolicy: RemoteMachineLinkEventsRecoveryPolicy
    private var eventsRecoveryTask: Task<Void, Never>?
    private var eventsStabilityTask: Task<Void, Never>?
    private var eventsRecoveryPhase: EventsRecoveryPhase = .healthy
    private var stderrTail: [String] = []
    /// Stderr belongs to one spawned client. A late line from an exited client
    /// must never contaminate a retry's diagnostics.
    private var stderrDrainTask: Task<Void, Never>?
    private var stderrGeneration: UUID?

    /// The newest change is buffered. If pressure drops an earlier delta, the next
    /// `previous_revision` check detects the gap and forces a complete snapshot.
    public nonisolated let changes: AsyncStream<Change>
    private let changesContinuation: AsyncStream<Change>.Continuation

    public init(
        machineID: String,
        clientURL: URL,
        paths: TuiClientPaths,
        deadlineClock: any Clock<Duration> = ContinuousClock(),
        eventsRecoveryClock: any Clock<Duration> = ContinuousClock(),
        eventsRecoveryPolicy: RemoteMachineLinkEventsRecoveryPolicy = .standard
    ) {
        self.machineID = machineID
        self.clientURL = clientURL
        self.paths = paths
        self.deadlineClock = deadlineClock
        self.eventsRecoveryClock = eventsRecoveryClock
        self.eventsRecoveryPolicy = eventsRecoveryPolicy
        (changes, changesContinuation) = AsyncStream<Change>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public var isConnected: Bool { connected != nil && state == .connected }

    /// Starts an SSH carrier using a locally installed client.
    ///
    /// - Parameters:
    ///   - ssh: Exact SSH identity, owner, and launch environment to retain.
    ///   - timeout: Deadline for the client to publish its local socket.
    /// - Returns: The connected daemon session and local socket.
    /// - Throws: The real client or SSH failure; no helper is acquired or upgraded.
    public func connect(
        ssh: SSHTuiConnection,
        timeout: Duration = .seconds(60)
    ) async throws -> Connected {
        if let connected, state == .connected { return connected }
        stderrDrainTask?.cancel()
        stderrDrainTask = nil
        let stderrGeneration = UUID()
        self.stderrGeneration = stderrGeneration
        stderrTail.removeAll(keepingCapacity: true)
        eventsCursor = nil
        resetEventsRecovery()
        try paths.ensureStateDir()
        guard FileManager.default.isExecutableFile(atPath: clientURL.path) else { throw LinkError.clientMissing }
        let arguments = ssh.arguments(
            stateDirectory: paths.stateDir.path,
            deviceName: TuiClientPaths.deviceName()
        )
        var environment = ssh.sshProcessEnvironment
        environment["CMUX_REMOTE_STATE_DIR"] = paths.stateDir.path
        state = .connecting
        lastError = nil
        let process: RemoteLinkProcess
        do {
            process = try RemoteLinkProcess.spawn(
                executableURL: clientURL,
                arguments: arguments,
                environment: environment,
                // See RemoteLinkProcess: an SSH link's group can hold the
                // ProxyCommand of a shared ControlMaster.
                sweepsGroup: false
            )
        } catch {
            state = .error
            lastError = Self.errorText(error)
            throw LinkError.spawnFailed(error.localizedDescription)
        }
        let processExit = process.exit
        self.process = process
        self.processExit = processExit
        let stderrDrain = drainStderr(process.standardError.fileHandleForReading, generation: stderrGeneration)
        stderrDrainTask = stderrDrain
        Task.detached { [weak self] in
            guard let status = await processExit.result else { return }
            // Helpers of a client that exited on its own get a bounded chance to
            // finish its last stderr lines; then the rest of its group goes.
            // Independent of the actor hop, so a slow teardown cannot delay it.
            Task.detached {
                await RemoteMachineLink.awaitStderrDrain(stderrDrain)
                await process.killGroup()
            }
            await self?.linkProcessDidExit(process, status: status)
        }

        // The first connection-snapshot line names the socket; later lines only update
        // transport topology and are ignored — but stdout keeps draining for the
        // process's whole life so the client never blocks on a full pipe.
        let firstSocket = RemoteLinkFirstValue<String>()
        let stdoutLines = RemoteLinkPipe.lines(from: process.standardOutput.fileHandleForReading)
        Task.detached {
            for await line in stdoutLines {
                if let socket = CmuxTuiSnapshotParser.localSocket(fromLinkLine: line) {
                    firstSocket.resolve(socket)
                }
            }
            firstSocket.resolve(nil)
        }
        let socketPath: String
        do {
            socketPath = try await withThrowingTaskGroup(of: LinkFirstLine.self) { group in
                group.addTask { (await firstSocket.result).map(LinkFirstLine.socket) ?? .ended }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                }
                defer { group.cancelAll() }
                let firstLine = try await group.next()
                // Cancellation closes the first-value waiter as well as the
                // timeout task. Its EOF must not be reported as a client exit.
                try Task.checkCancellation()
                switch firstLine {
                case .socket(let socket)?:
                    return socket
                case .ended?:
                    // stdout closed before a socket line: the client exited (an older
                    // client rejecting a flag, a refused dial). Report that exit and its
                    // stderr, not the deadline it never reached.
                    await Self.terminateAndWait(process, exit: processExit, clock: deadlineClock, draining: stderrDrain)
                    let status = await processExit.result ?? -1
                    throw LinkError.exitedBeforeSocket(status: status, output: stderrTail.joined(separator: "\n"))
                case .timedOut?, nil:
                    throw LinkError.timedOut
                }
            }
            guard process.isRunning else {
                await Self.awaitStderrDrain(stderrDrain)
                let status = await processExit.result ?? -1
                throw LinkError.exited(status: status, output: stderrTail.joined(separator: "\n"))
            }
        } catch {
            state = .error
            lastError = Self.errorText(error)
            await Self.terminateAndWait(process, exit: processExit, clock: deadlineClock)
            if self.process === process {
                self.process = nil
                self.processExit = nil
            }
            try Task.checkCancellation()
            throw error
        }
        let connected = Connected(socketPath: socketPath, session: ssh.session)
        self.connected = connected
        self.resourceConnection = TuiPersistentResourceConnection(socketPath: socketPath, clock: deadlineClock)
        state = .connected
        await startEventsSubscription(socketPath: socketPath, cursor: nil)
        changesContinuation.yield(.connected)
        return connected
    }

    public func disconnect() async {
        let oldResource = resourceConnection
        let oldProcess = process
        let oldProcessExit = processExit
        let oldEventStreamID = eventStreamID
        resourceConnection = nil
        process = nil
        processExit = nil
        eventStreamID = nil
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .healthy
        state = .unavailable
        connected = nil
        stderrDrainTask?.cancel()
        stderrDrainTask = nil
        stderrGeneration = nil
        stderrTail.removeAll(keepingCapacity: true)
        changesContinuation.finish()
        if let oldEventStreamID { await oldResource?.cancelStream(oldEventStreamID) }
        if let oldProcess, let oldProcessExit {
            await Self.terminateAndWait(oldProcess, exit: oldProcessExit, clock: deadlineClock)
        }
        await oldResource?.close()
    }

    /// Records a cursor only after the owner has accepted the corresponding
    /// snapshot or delta. The transport must not advance this value while it
    /// is merely decoding a line: a malformed or dropped event is not state.
    public func setEventsCursor(_ cursor: TuiCursor?) {
        guard let cursor else { return }
        if let current = eventsCursor,
           current.generation == cursor.generation,
           current.revision >= cursor.revision {
            return
        }
        let acceptedFromActiveStream = eventsSubscriptionID != nil
        eventsCursor = cursor
        // The owner accepted a valid event. It starts the success window, but one
        // event is not enough to forgive a repeatedly dying child process.
        if acceptedFromActiveStream, let subscriptionID = eventsSubscriptionID {
            scheduleEventsStabilityReset(subscriptionID: subscriptionID)
        }
    }

    /// Replaces the resume point exactly at a recovery boundary. Unlike
    /// `setEventsCursor`, this also accepts nil and a lower revision because a
    /// new generation or an explicit snapshot is authoritative.
    private func replaceEventsCursor(_ cursor: TuiCursor?) {
        eventsCursor = cursor
    }

    /// Reopens the event reader from the last accepted cursor. A stream can end
    /// on journal overflow, daemon restart, or a transient local socket close.
    func restartEventsSubscription(from cursor: TuiCursor? = nil) async {
        guard state == .connected, let socketPath = connected?.socketPath else { return }
        guard Self.canRestartEventsSubscription(for: eventsRecoveryPhase) else { return }
        // Cancel a delayed retry owned by the old reader, but keep its phase and
        // attempt count. The next failed reader must consume the next budget slot.
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        replaceEventsCursor(cursor ?? eventsCursor)
        _ = await startEventsSubscription(socketPath: socketPath, cursor: eventsCursor)
    }

    /// Marks a snapshot as the new synchronization boundary and resumes the event
    /// feed when the previous feed exhausted its recovery budget. A healthy active
    /// feed is left in place, so accepting a normal snapshot does not create a
    /// second reader or lose events between two subscriptions.
    @discardableResult
    public func resumeEventsSubscription(from cursor: TuiCursor) async -> Bool {
        // A versioned snapshot is allowed to leave snapshot-only mode. Routine
        // refreshes must not reset an exhausted recovery budget, or a broken
        // daemon would be respawned forever by each refresh.
        let leavingSnapshotOnly = eventsRecoveryPhase == .snapshotOnly
        let hasSnapshotRecoveryAllowance: Bool
        if case .exhausted(canResumeFromSnapshot: true) = eventsRecoveryPhase {
            hasSnapshotRecoveryAllowance = true
        } else {
            hasSnapshotRecoveryAllowance = false
        }
        if leavingSnapshotOnly { resetEventsRecovery() }
        replaceEventsCursor(cursor)
        guard state == .connected, let socketPath = connected?.socketPath else { return false }
        // A live reader is already a healthy synchronization path. Returning
        // true lets the owner clear a stale warning without starting a second
        // process or dropping the current stream.
        if eventsSubscriptionID != nil { return true }
        guard eventsRecoveryTask == nil else { return false }
        if hasSnapshotRecoveryAllowance {
            // A full snapshot is an ordering boundary, not a reason to erase
            // the transport failure budget. Consume the one-shot restart now.
            eventsRecoveryPhase = .snapshotRecovery
        }
        guard eventsRecoveryPhase == .healthy || eventsRecoveryPhase == .snapshotRecovery else { return false }
        return await startEventsSubscription(socketPath: socketPath, cursor: eventsCursor)
    }

    /// Stops the journal reader when the daemon only provides an unversioned
    /// snapshot. The command socket remains usable for reads, while the missing
    /// cursor prevents safe delta ordering and compare-and-swap mutations. A
    /// later versioned snapshot can call `resumeEventsSubscription` to re-enable
    /// the feed. Recovery remains bounded until a stable stream or a new link
    /// connection establishes a fresh boundary.
    public func suspendEventsSubscription() async {
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        await cancelEventsStream()
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .snapshotOnly
    }

    /// Commands are immutable protocol messages on one machine-owned socket.
    /// No child process, CLI parsing, automatic mutation replay or re-authentication.
    public func run(arguments: TuiRequest, timeout: Duration = .seconds(30)) async throws -> Data {
        let channel = try await controlConnection()
        do {
            return try await channel.request(arguments, timeout: timeout)
        } catch LinkError.requestTimedOut {
            // A caller's deadline is not proof that the shared link is wedged.
            // Probe the same channel before retiring it; terminal.wait and
            // wait_exit are expected to outlive short request budgets.
            guard timeout > .zero, resourceConnection === channel else {
                throw LinkError.requestTimedOut
            }
            do {
                _ = try await channel.request(TuiRequest("session.ping"), timeout: .seconds(2))
            } catch {
                // Never replay the original request: its remote outcome is
                // ambiguous. Retire only this link so a manager can establish
                // a replacement while durable workspace/terminal state stays
                // on the machine.
                guard resourceConnection === channel else { throw LinkError.requestTimedOut }
                await disconnect()
            }
            throw LinkError.requestTimedOut
        }
    }

    /// Sends a request on the authenticated persistent channel without waiting
    /// for its response. This is used for PTY input whose ordering and echo are
    /// owned by the remote terminal itself.
    public func sendUntrackedTuiCommand(arguments: TuiRequest) async throws {
        let channel = try await controlConnection()
        try await channel.sendUntracked(arguments)
    }

    private func controlConnection() async throws -> TuiPersistentResourceConnection {
        guard state == .connected, let connected else {
            throw LinkError.exited(status: 3, output: "transport closed: machine link is unavailable")
        }
        if let resourceConnection, !(await resourceConnection.isClosed) { return resourceConnection }
        let channel = TuiPersistentResourceConnection(socketPath: connected.socketPath, clock: deadlineClock)
        resourceConnection = channel
        return channel
    }

    private func cancelEventsStream() async {
        guard let id = eventStreamID else { return }
        eventStreamID = nil
        await resourceConnection?.cancelStream(id)
    }

    // MARK: - internals

    @discardableResult
    private func startEventsSubscription(socketPath: String, cursor: TuiCursor?) async -> Bool {
        guard !socketPath.isEmpty else { return false }
        cancelEventsStabilityReset()
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        await cancelEventsStream()
        let subscriptionID = UUID()
        eventsSubscriptionID = subscriptionID
        do {
            let channel = try await controlConnection()
            let opened = try await channel.events(cursor: cursor)
            guard eventsSubscriptionID == subscriptionID, state == .connected else {
                await channel.cancelStream(opened.id)
                return false
            }
            eventStreamID = opened.id
            eventsReaderTask = Task { [weak self] in
                var receivedStreamEnd = false
                for await data in opened.stream {
                    let change = Self.parseChangeLine(String(decoding: data, as: UTF8.self))
                    if case .streamEnded = change { receivedStreamEnd = true }
                    await self?.eventChange(change, subscriptionID: subscriptionID)
                }
                await self?.eventReaderDidEnd(subscriptionID: subscriptionID, receivedStreamEnd: receivedStreamEnd)
            }
            return true
        } catch {
            guard eventsSubscriptionID == subscriptionID else { return false }
            eventsSubscriptionID = nil
            changesContinuation.yield(.streamEnded(reason: "events_open_failed", cursor: eventsCursor))
            scheduleEventsRecovery()
            return false
        }
    }

    private func eventChange(_ change: Change, subscriptionID: UUID) async {
        guard eventsSubscriptionID == subscriptionID else { return }
        switch change {
        case .snapshot, .delta:
            // The provider decides whether the payload is valid and contiguous.
            // It calls `setEventsCursor` after installing the derived state.
            break
        case .streamEnded(let reason, let cursor):
            // A stream-end cursor is only a transport observation. Advancing to
            // it here could skip journal entries when recovery is required.
            changesContinuation.yield(.streamEnded(reason: reason, cursor: cursor))
            await finishEventsSubscription(subscriptionID: subscriptionID, reason: nil)
            return
        case .unknown:
            // Unknown data is a barrier. Its cursor cannot be trusted because the
            // missing item may itself have changed the graph.
            break
        case .connected:
            break
        }
        changesContinuation.yield(change)
    }

    private func eventReaderDidEnd(subscriptionID: UUID, receivedStreamEnd: Bool) async {
        guard eventsSubscriptionID == subscriptionID else { return }
        await finishEventsSubscription(
            subscriptionID: subscriptionID,
            reason: receivedStreamEnd ? nil : "eof"
        )
    }

    /// Ends one event child and schedules its single bounded recovery owner. The subscription
    /// UUID makes late reader callbacks harmless after a replacement has started.
    private func finishEventsSubscription(subscriptionID: UUID, reason: String?) async {
        guard eventsSubscriptionID == subscriptionID else { return }
        cancelEventsStabilityReset()
        eventsSubscriptionID = nil
        eventsReaderTask = nil
        await cancelEventsStream()
        if let reason {
            changesContinuation.yield(.streamEnded(reason: reason, cursor: eventsCursor))
        }
        scheduleEventsRecovery()
    }

    private func resetEventsRecovery() {
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .healthy
    }

    private func scheduleEventsRecovery() {
        guard state == .connected,
              connected != nil,
              eventsSubscriptionID == nil,
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: true),
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: false),
              eventsRecoveryPhase != .snapshotOnly,
              eventsRecoveryTask == nil
        else { return }

        let nextAttempt: Int
        if case .snapshotRecovery = eventsRecoveryPhase {
            eventsRecoveryPhase = .exhausted(canResumeFromSnapshot: false)
            changesContinuation.yield(.streamEnded(reason: Self.eventsRecoveryExhaustedReason, cursor: eventsCursor))
            return
        } else if case .recovering(let attempt) = eventsRecoveryPhase {
            nextAttempt = attempt + 1
        } else {
            nextAttempt = 1
        }
        guard let delay = eventsRecoveryPolicy.delay(forAttempt: nextAttempt) else {
            // The first capped run may be retried once after a valid full
            // snapshot. A later capped run has already consumed that allowance.
            let canResumeFromSnapshot: Bool
            if case .recovering(let attempt) = eventsRecoveryPhase {
                canResumeFromSnapshot = attempt == eventsRecoveryPolicy.delays.count
            } else {
                canResumeFromSnapshot = false
            }
            eventsRecoveryPhase = .exhausted(canResumeFromSnapshot: canResumeFromSnapshot)
            changesContinuation.yield(.streamEnded(reason: Self.eventsRecoveryExhaustedReason, cursor: eventsCursor))
            return
        }
        eventsRecoveryPhase = .recovering(attempt: nextAttempt)
        let clock = eventsRecoveryClock
        let socketPath = connected!.socketPath
        eventsRecoveryTask = Task { [weak self, clock, delay, socketPath] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recoverEventsSubscription(socketPath: socketPath)
        }
    }

    private func recoverEventsSubscription(socketPath: String) async {
        eventsRecoveryTask = nil
        guard state == .connected,
              connected?.socketPath == socketPath,
              eventsSubscriptionID == nil,
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: true),
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: false),
              eventsRecoveryPhase != .snapshotRecovery,
              eventsRecoveryPhase != .snapshotOnly
        else { return }
        _ = await startEventsSubscription(socketPath: socketPath, cursor: eventsCursor)
    }

    /// Starts a cancellable healthy-stream window after the owner accepts an
    /// event. The subscription ID prevents a late timer from forgiving a newer
    /// stream after this one has ended.
    private func scheduleEventsStabilityReset(subscriptionID: UUID) {
        guard eventsStabilityTask == nil,
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: true),
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: false),
              eventsRecoveryPhase != .snapshotOnly
        else { return }
        let clock = eventsRecoveryClock
        let stabilityWindow = eventsRecoveryPolicy.stabilityWindow
        eventsStabilityTask = Task { [weak self, clock, stabilityWindow, subscriptionID] in
            do {
                try await clock.sleep(for: stabilityWindow)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.markEventsStable(subscriptionID: subscriptionID)
        }
    }

    private func cancelEventsStabilityReset() {
        eventsStabilityTask?.cancel()
        eventsStabilityTask = nil
    }

    private func markEventsStable(subscriptionID: UUID) {
        guard eventsSubscriptionID == subscriptionID else { return }
        eventsStabilityTask = nil
        eventsRecoveryPhase = .healthy
    }

    private func drainStderr(_ handle: FileHandle, generation: UUID) -> Task<Void, Never> {
        let lines = RemoteLinkPipe.lines(from: handle)
        return Task.detached { [weak self] in
            for await line in lines {
                await self?.recordStderr(line, generation: generation)
            }
        }
    }

    private func recordStderr(_ line: String, generation: UUID) {
        guard stderrGeneration == generation else { return }
        stderrTail.append(line)
        if stderrTail.count > 20 { stderrTail.removeFirst(stderrTail.count - 20) }
    }

    private func linkProcessDidExit(_ exitedProcess: RemoteLinkProcess, status: Int32) async {
        guard process === exitedProcess else { return }
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .healthy
        await cancelEventsStream()
        process = nil
        processExit = nil
        connected = nil
        let stderrGeneration = self.stderrGeneration
        let stderrDrain = self.stderrDrainTask
        if state != .unavailable {
            state = status == 0 ? .unavailable : .error
            if status == 0 {
                lastError = nil
            } else {
                lastError = LinkError.exited(status: status, output: stderrTail.joined(separator: "\n")).errorDescription
                if let stderrGeneration, let stderrDrain {
                    // Publish streamEnded and release the lease immediately;
                    // refine only the diagnostic after the pipe has had a bounded
                    // chance to deliver its final lines.
                    Task { [weak self] in
                        await Self.awaitStderrDrain(stderrDrain)
                        guard !Task.isCancelled else { return }
                        await self?.refineExitError(generation: stderrGeneration, status: status)
                    }
                }
            }
        }
        await resourceConnection?.close()
        resourceConnection = nil
        changesContinuation.yield(.streamEnded(reason: "link_exit", cursor: nil))
        changesContinuation.finish()
    }

    private func refineExitError(generation: UUID, status: Int32) {
        guard stderrGeneration == generation, state == .error else { return }
        lastError = LinkError.exited(
            status: status,
            output: stderrTail.joined(separator: "\n")
        ).errorDescription
    }

    /// Asks the client to stop, escalates to SIGKILL for its group, waits for the
    /// leader's exit, then kills whatever is left of the group (after a bounded
    /// stderr drain when `stderrDrain` is given). The waiter is detached because the caller can
    /// already be cancelled when cleanup starts.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private nonisolated static func terminateAndWait(
        _ process: RemoteLinkProcess,
        exit: RemoteLinkFirstValue<Int32>,
        clock: any Clock<Duration>,
        draining stderrDrain: Task<Void, Never>? = nil
    ) async {
        // Cleanup outlives caller cancellation and retains the process until its exit.
        let cleanup = Task.detached {
            // The client closes its own helpers on SIGTERM (an SSH child gets EOF
            // rather than a signal); the group is swept after the leader exits.
            process.signalLeader(SIGTERM)
            // A genuine escalation deadline; process exit owns and cancels this timer.
            let escalation = Task {
                do { try await clock.sleep(for: .seconds(5)) } catch { return }
                if process.isRunning { process.signal(SIGKILL) }
            }
            _ = await exit.result
            escalation.cancel()
            await escalation.value
            if let stderrDrain { await awaitStderrDrain(stderrDrain) }
            await process.killGroup()
        }
        await cleanup.value
    }


    /// Parses the public `session current events --jsonl` envelope. Complete
    /// snapshot and delta items are retained as canonical JSON so new daemon fields
    /// survive until this app learns their typed form.
    public nonisolated static func parseChangeLine(_ line: String) -> Change {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown(cursor: nil) }

        if (root["type"] as? String) == "stream_end" {
            let cursor = (root["cursor"] as? [String: Any]).flatMap(TuiCursor.init(wire:))
            return .streamEnded(reason: (root["reason"] as? String) ?? "unknown", cursor: cursor)
        }

        // The documented form wraps the event in `item`. Older JSONL clients
        // emitted the inner item, so accepting both preserves wire compatibility.
        let item = (root["item"] as? [String: Any]) ?? root
        let cursor = (item["cursor"] as? [String: Any]).flatMap(TuiCursor.init(wire:))
            ?? (root["cursor"] as? [String: Any]).flatMap(TuiCursor.init(wire:))
        guard let kind = item["kind"] as? String else { return .unknown(cursor: cursor) }

        switch kind {
        case "snapshot":
            guard var snapshot = item["snapshot"] as? [String: Any],
                  let cursor else { return .unknown(cursor: cursor) }
            // Some client versions put the cursor only on the event envelope.
            // Materialize it into the snapshot bytes so the state parser sees
            // one self-describing document.
            if snapshot["cursor"] == nil || snapshot["cursor"] is NSNull {
                snapshot["cursor"] = [
                    "generation": cursor.generation,
                    "revision": String(cursor.revision),
                ] as [String: Any]
            }
            guard let payload = canonicalJSONData(snapshot) else {
                return .unknown(cursor: cursor)
            }
            return .snapshot(cursor: cursor, resetReason: item["reset_reason"] as? String, payload: payload)
        case "delta":
            guard let cursor,
                  let previousRevision = decimal(item["previous_revision"]),
                  let revision = decimal(item["revision"]),
                  item["changes"] is [[String: Any]],
                  let payload = canonicalJSONData(item)
            else { return .unknown(cursor: cursor) }
            return .delta(cursor: cursor, previousRevision: previousRevision, revision: revision, payload: payload)
        default:
            return .unknown(cursor: cursor)
        }
    }

    private nonisolated static func decimal(_ raw: Any?) -> UInt64? {
        TuiWireNumber.unsigned(raw)
    }

    private nonisolated static func canonicalJSONData(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

}

private enum RemoteLinkCommandOutcome: Sendable, Equatable {
    case exited(Int32)
    case timedOut
    case cancelled
}

/// GCD-driven reading of the link's child-process pipes. `FileHandle.bytes.lines` and
/// `readDataToEndOfFile()` park a cooperative thread in read(2) for as long as the pipe
/// stays open; every linked machine held three that way (link stdout, link stderr, the
/// events stream) and each `run` three more, so a few machines exhausted the pool —
/// `Task.sleep` deadlines stopped firing, links sat in "connecting" for minutes past
/// their timeout, and every socket command crawled. `readabilityHandler` runs on a GCD
/// queue and costs the pool nothing.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum RemoteLinkPipe: Sendable {
    /// Raw chunks as they arrive; ends at EOF. One consumer.
    public static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Lines (without their newline; a trailing CR is dropped) as they arrive; a final
    /// unterminated line is delivered at EOF. One consumer.
    public static func lines(from handle: FileHandle, bufferingPolicy: AsyncStream<String>.Continuation.BufferingPolicy = .unbounded) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let buffer = LineBuffer()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Everything up to EOF.
    public static func readToEnd(_ handle: FileHandle) async -> Data {
        var data = Data()
        for await chunk in chunks(from: handle) {
            data.append(chunk)
        }
        return data
    }

    /// Splits a byte stream into lines; only ever touched from the handle's GCD queue.
    public static func splitLines(_ data: Data) -> (lines: [String], rest: Data) {
        var lines: [String] = []
        var pending = data
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
            pending = pending[pending.index(after: newline)...]
        }
        return (lines, Data(pending))
    }

    // SAFETY: FileHandle serializes its readability callbacks for this handle.
    // Each buffer is confined to that callback; termination never accesses it.
    private final class LineBuffer: @unchecked Sendable {
        private static let maxLineBytes = 4 * 1_024 * 1_024
        private var pending = Data()
        private var dropping = false

        func append(_ data: Data) -> [String] {
            var lines: [String] = []
            var start = data.startIndex
            while start < data.endIndex {
                let newline = data[start...].firstIndex(of: 0x0A)
                let end = newline ?? data.endIndex
                if !dropping {
                    if pending.count + data.distance(from: start, to: end) > Self.maxLineBytes {
                        pending.removeAll(keepingCapacity: false)
                        dropping = true
                    } else {
                        pending.append(contentsOf: data[start..<end])
                    }
                }
                guard let newline else { break }
                if !dropping {
                    var line = String(decoding: pending, as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    lines.append(line)
                }
                pending.removeAll(keepingCapacity: true)
                dropping = false
                start = data.index(after: newline)
            }
            return lines
        }

        func flush() -> String? {
            defer { pending = Data(); dropping = false }
            guard !dropping, !pending.isEmpty else { return nil }
            var line = String(decoding: pending, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }
}

/// A value resolved at most once from a GCD callback and awaited from Swift concurrency;
/// `resolve(nil)` finishes it without a value (EOF before the line, no exit status).
public final class RemoteLinkFirstValue<Value: Sendable>: @unchecked Sendable {
    public init() {}

    private enum State {
        case pending
        case done(Value?)
    }

    // A GCD or Process callback and task cancellation can race to resume one
    // continuation. This short lock protects only that synchronous handoff.
    private let lock = NSLock()
    private var state: State = .pending
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    public func resolve(_ value: Value?) {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return
        }
        state = .done(value)
        let waiting = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in waiting {
            waiter.resume(returning: value)
        }
    }

    public var result: Value? {
        get async {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if case .done(let value) = state {
                        lock.unlock()
                        continuation.resume(returning: value)
                    } else if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else {
                        waiters[waiterID] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                cancel(waiterID: waiterID)
            }
        }
    }

    private func cancel(waiterID: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        waiter?.resume(returning: nil)
    }
}
