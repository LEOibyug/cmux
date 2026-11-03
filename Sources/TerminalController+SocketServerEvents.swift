import CmuxControlSocket
import CmuxSettings
import Foundation
import os

private let socketServerEventsLogger = Logger(subsystem: "com.cmuxterm.app", category: "ControlSocket")

/// The composition-root wiring of ``SocketControlServerEvents`` for the app:
/// listener diagnostics stay local, marker files go to the
/// discovery store, and lifecycle hooks back to the controller.
extension TerminalController {
    /// Builds the package server's host-callback seam. `target` is filled in
    /// at the end of `init`; no listener event can fire before `start`.
    nonisolated static func makeSocketServerEvents(
        target: ServerEventTarget,
        markerStore: SocketPathMarkerStore
    ) -> SocketControlServerEvents {
        SocketControlServerEvents(
            breadcrumb: { message, _ in
                socketServerEventsLogger.debug("Socket listener: \(message, privacy: .public)")
            },
            failure: { message, stage, errnoCode, _ in
                socketServerEventsLogger.error(
                    "Socket listener failed: \(message, privacy: .public) stage=\(stage, privacy: .public) errno=\(errnoCode ?? 0)"
                )
            },
            listenerDidStart: { path, _ in
                // @MainActor closure, invoked synchronously inside start().
                
                target.controller?.socketListenerDidStart(path: path)
            },
            recordLastSocketPath: { path in
                markerStore.record(path)
            },
            cleanupDiscoveryState: { path in
                target.controller?.cleanupStoppedSocketState(path)
            },
            pathMissingDetected: { path, generation in
                Task { @MainActor in
                    target.controller?.restartSocketListenerIfPathMissing(path: path, generation: generation)
                }
            },
            rearmRequested: { generation, errnoCode, consecutiveFailures, delayMs in
                target.controller?.scheduleListenerRearm(
                    generation: generation,
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures,
                    delayMs: delayMs
                )
            },
            connectionDropped: { socket, _ in
                // Listener-queue callback: the accept buffer was full. Answer
                // the client with `overloaded` instead of a bare close.
                guard let controller = target.controller else {
                    close(socket)
                    return
                }
                controller.rejectSocketClient(socket, reason: .acceptBufferFull)
            }
        )
    }
}
