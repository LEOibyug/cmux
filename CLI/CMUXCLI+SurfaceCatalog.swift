import Foundation

extension CMUXCLI {
    static var surfaceUsage: String {
        """
        Usage: cmux surface ls [local|ssh:<connection>] [--refresh] [--json]
               cmux surface open <resource> [--workspace <id|ref>] [--pane <id|ref>]
                    [--left|--right|--up|--down|--tab] [--new] [--focus|--no-focus]
               cmux surface new-terminal --machine <local|ssh:connection> [--cwd <dir>]
                    [--name <name>] [--remote-workspace <id>] [--workspace <id|ref>]
                    [--no-open] [--focus|--no-focus] [-- <command...>]
               cmux surface resume --help
               cmux surface size [--surface <id|ref>] [--json]
               cmux surface size-policy <latest|smallest|largest|priority|fixed> [--cols N --rows N]
               cmux surface participants [--surface <id|ref>] [--json]

        Lists existing local and user-controlled SSH resources. Open projects a resource
        into a pane; new-terminal creates a terminal on the selected machine.
        \(openFocusDefaultHelp)
        """
    }

    private func runSurfaceCatalogList(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        let refresh = hasFlag(rest, name: "--refresh")
        if let unknown = rest.first(where: { $0.hasPrefix("-") && !["--refresh", "--json"].contains($0) }) {
            throw CLIError(message: "surface ls: unknown flag '\(unknown)'")
        }
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard positional.count <= 1 else { throw CLIError(message: Self.surfaceUsage) }
        var params: [String: Any] = [:]
        if let machine = positional.first { params["machine"] = machine }
        if refresh { params["refresh"] = true }
        let response = try client.sendV2(method: "surface.catalog", params: params, responseTimeout: 180)
        if jsonOutput { print(jsonString(response)); return }
        let machines = response["machines"] as? [[String: Any]] ?? []
        let resources = response["resources"] as? [[String: Any]] ?? []
        guard !machines.isEmpty else { print("No local or SSH machines."); return }
        var workspaceTitles: [String: String] = [:]
        if let list = try? client.sendV2(method: "workspace.list"),
           let workspaces = list["workspaces"] as? [[String: Any]] {
            for workspace in workspaces {
                guard let id = workspace["id"] as? String else { continue }
                workspaceTitles[id.uppercased()] = workspace["title"] as? String ?? id
            }
        }
        for (index, machine) in machines.enumerated() {
            if index > 0 { print("") }
            let machineID = machine["id"] as? String ?? ""
            let own = resources.filter { ($0["machine"] as? String) == machineID }
            for line in CmuxTuiRemoteRouting.treeLines(machine: machine, resources: own, workspaceTitles: workspaceTitles) {
                print(line)
            }
        }
    }

    func runSurfaceCatalogCommand(subcommand: String, rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.surfaceUsage)
            return
        }
        switch subcommand {
        case "ls", "list", "tree", "catalog":
            try runSurfaceCatalogList(rest: rest, client: client, jsonOutput: jsonOutput)

        case "open", "project":
            let (workspaceOpt, rest1) = parseOption(rest, name: "--workspace")
            let (paneOpt, rest2) = parseOption(rest1, name: "--pane")
            let (focus, rest3) = try parseOpenFocusFlags(rest2, command: "surface open")
            let sides: [String: String] = ["--left": "left", "--right": "right", "--up": "up", "--down": "down"]
            let directions = rest3.compactMap { sides[$0] }
            guard directions.count <= 1 else { throw CLIError(message: Self.surfaceUsage) }
            let direction = directions.first
            let tab = hasFlag(rest3, name: "--tab")
            if tab && direction != nil {
                throw CLIError(message: String(
                    localized: "cli.surface.open.tabAndSide",
                    defaultValue: "surface open: --tab and a pane side (--left/--right/--up/--down) are two different placements; pass one"
                ))
            }
            let new = hasFlag(rest3, name: "--new")
            let known = Set(sides.keys).union(["--tab", "--new", "--json"])
            if let unknown = rest3.first(where: { $0.hasPrefix("-") && !known.contains($0) }) {
                throw CLIError(message: "surface open: unknown flag '\(unknown)'\n\n\(Self.surfaceUsage)")
            }
            let positional = rest3.filter { !$0.hasPrefix("-") }
            guard positional.count == 1, let resource = positional.first, resource.split(separator: "/", maxSplits: 2).count == 3 else {
                throw CLIError(message: Self.surfaceUsage)
            }
            if (direction != nil || tab) && paneOpt == nil {
                throw CLIError(message: "surface open: --left/--right/--up/--down/--tab need --pane <id|ref>\n\n\(Self.surfaceUsage)")
            }
            var params: [String: Any] = ["resource": resource, "focus": focus ?? Self.defaultFocusForUserOpen()]
            if let workspaceOpt { params["workspace_id"] = workspaceOpt }
            if let paneOpt { params["pane_id"] = paneOpt }
            if let direction { params["direction"] = direction }
            if tab { params["placement"] = "tab" }
            if new { params["reuse"] = false }
            let response: [String: Any]
            do {
                response = try client.sendV2(method: "surface.project", params: params, responseTimeout: 180)
            } catch let error as CLIError where error.message.contains("Unknown surface") {
                throw CLIError(message: String(
                    format: String(localized: "cli.surface.open.unknownResource", defaultValue: "Unknown surface '%@'. See: cmux surface ls --json"),
                    resource
                ))
            }
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let surfaceId = (response["surface_id"] as? String) ?? "?"
            let workspaceId = (response["workspace_id"] as? String) ?? "?"
            let reused = (response["reused"] as? Bool) == true
            print("OK surface=\(surfaceId) workspace=\(workspaceId) resource=\(resource)\(reused ? " reused=true" : "")")

        case "new-terminal", "new":
            let (machineOpt, rest1) = parseOption(rest, name: "--machine")
            let (cwdOpt, rest2) = parseOption(rest1, name: "--cwd")
            let (nameOpt, rest3) = parseOption(rest2, name: "--name")
            let (remoteWorkspaceOpt, rest4) = parseOption(rest3, name: "--remote-workspace")
            let (workspaceOpt, rest4a) = parseOption(rest4, name: "--workspace")
            let (focus, rest5) = try parseOpenFocusFlags(rest4a, command: "surface new-terminal")
            let noOpen = hasFlag(rest5, name: "--no-open")
            var command: [String] = []
            var flags = rest5
            if let separator = rest5.firstIndex(of: "--") {
                command = Array(rest5[(separator + 1)...])
                flags = Array(rest5[..<separator])
            }
            if let unknown = flags.first(where: { $0.hasPrefix("-") && !["--no-open", "--json"].contains($0) }) {
                throw CLIError(message: "surface new-terminal: unknown flag '\(unknown)'\n\n\(Self.surfaceUsage)")
            }
            guard let machine = machineOpt, !machine.isEmpty else {
                throw CLIError(message: "surface new-terminal: --machine <local|ssh:connection> is required\n\n\(Self.surfaceUsage)")
            }
            var params: [String: Any] = ["machine": machine, "open": !noOpen, "focus": focus ?? Self.defaultFocusForUserOpen()]
            if !command.isEmpty { params["command"] = command }
            if let cwdOpt { params["cwd"] = cwdOpt }
            if let nameOpt { params["name"] = nameOpt }
            if let remoteWorkspaceOpt { params["remote_workspace_id"] = remoteWorkspaceOpt }
            if let workspaceOpt { params["workspace_id"] = workspaceOpt }
            let response = try client.sendV2(method: "surface.new_terminal", params: params, responseTimeout: 240)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let resource = (response["resource"] as? String) ?? "?"
            let terminalId = (response["terminal_id"] as? String) ?? "?"
            var line = "OK resource=\(resource) terminal=\(terminalId)"
            if let surfaceId = response["surface_id"] as? String, !surfaceId.isEmpty { line += " surface=\(surfaceId)" }
            if let workspaceId = response["workspace_id"] as? String, !workspaceId.isEmpty { line += " workspace=\(workspaceId)" }
            print(line)

        default:
            throw CLIError(message: "Unsupported surface subcommand: \(subcommand)\n\n\(Self.surfaceUsage)")
        }
    }
}
