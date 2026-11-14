import Foundation

extension CMUXCLI {
    static let controlCenterUsage = """
    Usage: cmux control-center <show|status|ask|open-collection|cancel> [--json]

      show                          Open the native Control Center without activating cmux.
      status                        Read favorites, collections, memories and operation results.
      ask [--follow-up] -- <text>    Run one request; use '-' to read the request from stdin.
      open-collection <id|name>      Open a saved collection by ID or exact, unique name.
      cancel                        Cancel the current operation, without undoing completed actions.

    Independent requests start with fresh context. --follow-up explicitly continues the last
    operation. Model connection settings live in Control Center > Settings. A timeout does not
    imply that no actions ran; inspect status before trying again. No automatic replay occurs.
    """

    func runControlCenterCommand(_ arguments: [String], client: SocketClient, jsonOutput: Bool) throws {
        var args = arguments
        var emitJSON = jsonOutput
        if let index = args.firstIndex(of: "--json"), index < (args.firstIndex(of: "--") ?? args.endIndex) {
            args.remove(at: index)
            emitJSON = true
        }
        let verb = args.first ?? "show"
        var values = Array(args.dropFirst())
        let method: String
        var params: [String: Any] = [:]
        switch verb {
        case "show", "status", "cancel":
            guard values.isEmpty else { throw CLIError(message: Self.controlCenterUsage, exitCode: 2) }
            method = "control_center.\(verb)"
        case "ask":
            let followUp = values.first == "--follow-up"
            if followUp { values.removeFirst() }
            if values.first == "--" { values.removeFirst() }
            let prompt = values == ["-"]
                ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : values.joined(separator: " ")
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: Self.controlCenterUsage, exitCode: 2)
            }
            method = "control_center.ask"
            params = ["prompt": prompt, "follow_up": followUp]
        case "open-collection":
            guard values.count == 1, let collection = values.first, !collection.isEmpty else {
                throw CLIError(message: Self.controlCenterUsage, exitCode: 2)
            }
            method = "control_center.open_collection"
            params["collection"] = collection
        default:
            throw CLIError(message: Self.controlCenterUsage, exitCode: 2)
        }
        let response = try client.sendV2(method: method, params: params, responseTimeout: 190)
        if !emitJSON, verb == "ask", let output = response["output"] as? String, !output.isEmpty {
            print(output)
        } else {
            print(jsonString(response))
        }
    }
}
