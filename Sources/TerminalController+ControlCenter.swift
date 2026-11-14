import CmuxControlCenter
import Foundation

private struct ControlCenterControlStatus: Encodable, Sendable {
    let snapshot: ControlCenterSnapshot
    let operation: ControlCenterOperation?
    let output: String
    let error: String?
    let running: Bool
    let model: String
    let baseURL: String
    let configured: Bool
}

extension TerminalController {
    nonisolated func v2ControlCenter(method: String, params: [String: Any]) async -> V2CallResult {
        let coordinator = await ControlCenterCoordinator.shared
        await coordinator.load()
        switch method {
        case "control_center.show":
            await MainActor.run { ControlCenterWindowController.shared.show(activate: false) }
        case "control_center.cancel":
            await coordinator.cancel()
        case "control_center.ask":
            guard let prompt = params["prompt"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: "prompt is required", data: nil)
            }
            guard await !coordinator.isRunning else {
                return .err(code: "busy", message: "A Control Center operation is already running", data: nil)
            }
            await coordinator.submit(prompt, followUp: params["follow_up"] as? Bool ?? false)
            if let error = await coordinator.error {
                return .err(code: "operation_failed", message: error, data: nil)
            }
        case "control_center.open_collection":
            guard let selector = params["collection"] as? String, !selector.isEmpty else {
                return .err(code: "invalid_params", message: "collection is required", data: nil)
            }
            guard await !coordinator.isRunning else {
                return .err(code: "busy", message: "A Control Center operation is already running", data: nil)
            }
            let collections = await coordinator.snapshot.collections
            let matches = collections.filter {
                $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame || $0.name == selector
            }
            guard matches.count == 1, let collection = matches.first else {
                return .err(
                    code: matches.isEmpty ? "not_found" : "ambiguous",
                    message: matches.isEmpty ? "No saved collection matched" : "More than one collection matched; use an ID",
                    data: nil
                )
            }
            await coordinator.openCollection(collection)
            if let error = await coordinator.error {
                return .err(code: "operation_failed", message: error, data: nil)
            }
        case "control_center.status":
            break
        default:
            return .err(code: "method_not_found", message: "Unknown Control Center method", data: nil)
        }
        do {
            let encoded = try await MainActor.run {
                try JSONEncoder().encode(ControlCenterControlStatus(
                    snapshot: coordinator.snapshot,
                    operation: coordinator.operation,
                    output: coordinator.output,
                    error: coordinator.error,
                    running: coordinator.isRunning,
                    model: coordinator.connection.model,
                    baseURL: coordinator.connection.baseURL,
                    configured: !coordinator.connection.model.isEmpty && !coordinator.connection.apiKey.isEmpty
                ))
            }
            guard let result = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                return .err(code: "internal_error", message: "Invalid Control Center state", data: nil)
            }
            return .ok(result)
        } catch {
            return .err(code: "read_failed", message: error.localizedDescription, data: nil)
        }
    }
}
