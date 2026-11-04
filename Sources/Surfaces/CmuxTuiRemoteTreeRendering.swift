import CmuxCore
import Foundation

extension CmuxTuiRemoteRouting {
    private static func treeNumber(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? Int64 { return Double(v) }
        return nil
    }

    /// The human rendering of one catalog machine with its resources. Pure, so the shape is
    /// testable and the same lines can back other surfaces. `workspaceTitles` maps local
    /// workspace ids (uppercased) to their sidebar title for This Mac's grouping.
    static func treeLines(machine: [String: Any], resources: [[String: Any]], workspaceTitles: [String: String] = [:]) -> [String] {
        let id = (machine["id"] as? String) ?? "?"
        let isLocal = (machine["local"] as? Bool) == true || id == "local"
        let terminals = resources.filter { ($0["kind"] as? String) == "terminal" }
        let browsers = resources.filter { ($0["kind"] as? String) == "browser" }
        var lines: [String] = []

        if isLocal {
            let name = (machine["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var header = String(localized: "cli.vm.tree.thisMac", defaultValue: "This Mac")
            if let name { header += "  \(name)" }
            header += "  · " + String(
                format: String(localized: "cli.vm.tree.localSummary", defaultValue: "%1$d terminals · %2$d browsers"),
                terminals.count, browsers.count
            )
            lines.append(header)
            lines.append("  " + String(localized: "cli.vm.tree.terminals", defaultValue: "terminals/"))
            if terminals.isEmpty {
                lines.append("    " + String(localized: "cli.vm.tree.noLocal", defaultValue: "(no terminals open)"))
            }
            // Group by the local workspace that projects each terminal, keeping first-seen order.
            var groups: [(key: String, label: String, items: [[String: Any]])] = []
            for terminal in terminals {
                let workspaceId = ((terminal["open_workspace_ids"] as? [String])?.first ?? "").uppercased()
                let label = workspaceTitles[workspaceId]
                    ?? (workspaceId.isEmpty
                        ? String(localized: "cli.vm.tree.unknownWorkspace", defaultValue: "(not in a workspace)")
                        : String(workspaceId.prefix(8)))
                if let index = groups.firstIndex(where: { $0.key == workspaceId }) {
                    groups[index].items.append(terminal)
                } else {
                    groups.append((key: workspaceId, label: label, items: [terminal]))
                }
            }
            for group in groups {
                lines.append("    \(group.label)")
                for terminal in group.items {
                    lines.append("      " + treeResourceCell(terminal, openHint: "cmux surface open"))
                }
            }
            if !browsers.isEmpty {
                lines.append("  " + String(localized: "cli.vm.tree.browsers", defaultValue: "browsers/"))
                for browser in browsers {
                    let resourceId = (browser["id"] as? String) ?? "?"
                    let title = (browser["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let url = (browser["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    lines.append("    " + [title, url].compactMap { $0 }.joined(separator: "  ") + "  (cmux surface open \(resourceId))")
                }
            }
            return lines
        }

        let status = (machine["status"] as? String) ?? "unknown"
        var facts: [String] = []
        if let cpus = treeNumber(machine["cpus"]), cpus > 0 {
            facts.append(String(format: String(localized: "cli.vm.tree.vcpu", defaultValue: "%.0f vCPU"), cpus))
        }
        if let memoryMb = treeNumber(machine["memory_mb"]), memoryMb > 0 {
            facts.append(String(format: "%.0f GB", memoryMb / 1024))
        }
        if let diskMb = treeNumber(machine["disk_mb"]), diskMb > 0 {
            facts.append(String(format: String(localized: "cli.vm.tree.disk", defaultValue: "%.0f GB disk"), diskMb / 1024))
        }
        let linkState = (machine["link_state"] as? String) ?? ((machine["link"] as? [String: Any])?["state"] as? String) ?? ""
        let linkError = ((machine["link_error_message"] as? String) ?? ((machine["link"] as? [String: Any])?["error_message"] as? String))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let linkErrorDescription = linkError ?? String(
            localized: "tuiTree.placeholder.linkError",
            defaultValue: "Link failed"
        )
        if !linkState.isEmpty, linkState != "n/a" {
            facts.append(String(format: String(localized: "cli.vm.tree.link", defaultValue: "link %@"), linkState))
        }
        lines.append(facts.isEmpty ? "\(id)  \(status)" : "\(id)  \(status)  · " + facts.joined(separator: " · "))

        lines.append("  " + String(localized: "cli.vm.tree.workspaces", defaultValue: "workspaces/"))
        // Remote workspaces, in cmux-tui index order: the machine payload lists them all
        // (so an empty workspace still shows), and resource views fill their layout.
        var workspaces: [(
            id: String,
            name: String,
            index: Int,
            focused: Bool,
            placements: [TreePlacement]
        )] = []
        // Terminal views can be numerous; keep membership assignment O(1)
        // instead of scanning every workspace for every view.
        var workspaceIndexByID: [String: Int] = [:]
        for raw in (machine["remote_workspaces"] as? [[String: Any]]) ?? [] {
            guard let workspaceId = raw["id"] as? String, !workspaceId.isEmpty else { continue }
            if let index = workspaceIndexByID[workspaceId] {
                // A defensive merge keeps malformed/replayed machine lists from
                // rendering the same workspace twice.
                if workspaces[index].name.isEmpty {
                    workspaces[index].name = (raw["name"] as? String) ?? ""
                }
                workspaces[index].focused = workspaces[index].focused || (raw["focused"] as? Bool) == true
            } else {
                workspaceIndexByID[workspaceId] = workspaces.count
                workspaces.append((
                    id: workspaceId,
                    name: (raw["name"] as? String) ?? "",
                    index: treeNumber(raw["index"]).map { Int($0) } ?? Int.max,
                    focused: (raw["focused"] as? Bool) == true,
                    placements: []
                ))
            }
        }
        for resource in resources {
            // Every workspace view contributes a pointer row: one placement per daemon
            // tab, the same partition the sidebar draws (grouped by pane below).
            let kind = resource["kind"] as? String
            guard ["terminal", "browser"].contains(kind ?? "") else { continue }
            var placements: [(workspace: [String: Any], view: [String: Any]?)] = []
            if let views = resource["remote_views"] as? [[String: Any]] {
                for view in views {
                    guard let workspace = view["workspace"] as? [String: Any] else { continue }
                    placements.append((workspace, view))
                }
            } else if let workspace = resource["remote_workspace"] as? [String: Any] {
                // An explicit empty `remote_views` overrides this legacy field.
                placements.append((workspace, nil))
            }
            for placement in placements {
                guard let workspaceId = placement.workspace["id"] as? String, !workspaceId.isEmpty else { continue }
                let member = TreePlacement(resource: resource, view: placement.view)
                if let index = workspaceIndexByID[workspaceId] {
                    workspaces[index].placements.append(member)
                } else {
                    workspaceIndexByID[workspaceId] = workspaces.count
                    workspaces.append((
                        id: workspaceId,
                        name: (placement.workspace["name"] as? String) ?? "",
                        index: treeNumber(placement.workspace["index"]).map { Int($0) } ?? Int.max,
                        focused: (placement.workspace["focused"] as? Bool) == true,
                        placements: [member]
                    ))
                }
            }
        }
        workspaces.sort {
            $0.index != $1.index ? $0.index < $1.index : $0.id < $1.id
        }
        // The link state decides what an empty workspace list means: a machine that is
        // asleep, still connecting, or whose link failed has workspaces the tree simply
        // cannot see yet, and hiding that behind "none yet" hides the failure.
        switch linkState {
        case "connecting":
            lines.append("    " + String(localized: "cli.vm.tree.link.connecting", defaultValue: "connecting…"))
        case "error", "unavailable":
            lines.append("    " + String(
                format: String(localized: "cli.vm.tree.link.error", defaultValue: "⚠ %@"),
                linkErrorDescription
            ))
            lines.append("    " + String(
                format: String(localized: "cli.surface.tree.link.retry", defaultValue: "retry: cmux surface tree %@ --refresh"),
                id
            ))
        default:
            if workspaces.isEmpty {
                lines.append("    " + String(
                    format: String(localized: "cli.surface.tree.noWorkspaces", defaultValue: "(no workspaces reported by %@)"),
                    id
                ))
            }
        }
        for workspace in workspaces {
            let workspaceId = workspace.id
            let name = workspace.name.isEmpty ? workspaceId : workspace.name
            lines.append("    \(name)  \(workspaceId)\(workspace.focused ? "  *" : "")")
            // Rows follow the layout, as in the sidebar, with every tab as a
            // sibling leaf. Pane grouping is retained only for ordering.
            for placement in treeLayoutRows(workspace.placements) {
                lines.append("      " + treeWorkspaceCell(placement, machineID: id, workspaceID: workspaceId))
            }
        }
        let ports = browsers.compactMap { browser -> (Int, String, [String: Any])? in
            // Snapshot parsing folds localhost browser views into the provider's
            // canonical `port:<n>` resource. Non-port daemon browsers remain
            // workspace-only and therefore do not enter this section.
            guard let key = browser["key"] as? String,
                  key.hasPrefix("port:"),
                  let port = Int(key.dropFirst("port:".count)),
                  (1...65_535).contains(port),
                  key == "port:\(port)" else { return nil }
            return (port, key, browser)
        }.sorted { lhs, rhs in
            lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }
        if !ports.isEmpty {
            lines.append("  " + String(localized: "cli.vm.tree.ports", defaultValue: "ports/"))
            for (port, _, browser) in ports {
                let label = (browser["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let open = (browser["open"] as? Bool) == true
                var cell = "    \(port)\(label.map { "  \($0)" } ?? "")  (cmux surface open \(id)/browser/port:\(port))"
                if open { cell += "  " + String(localized: "cli.vm.tree.openMarker", defaultValue: "(open)") }
                lines.append(cell)
            }
        }


        // Every machine-owned terminal stays in the flat index even while its
        // link is connecting/asleep/failed. The link-status line above explains
        // why workspace membership may be stale; hiding the terminals would
        // make an otherwise addressable resource disappear from the catalog.
        let terminalsLabel = String(localized: "cli.vm.tree.terminals", defaultValue: "terminals/")
        let noTerminalsLabel = String(localized: "cli.vm.tree.noTerminals", defaultValue: "(no terminals)")
        lines.append("  " + terminalsLabel)
        if terminals.isEmpty {
            lines.append("    " + noTerminalsLabel)
        } else {
            var attached: [[String: Any]] = []
            var detached: [[String: Any]] = []
            for terminal in terminals {
                if treeTerminalIsDetached(terminal) {
                    detached.append(terminal)
                } else {
                    attached.append(terminal)
                }
            }
            for terminal in attached {
                lines.append("    " + treeResourceCell(terminal, openHint: "cmux surface open"))
            }
            if !detached.isEmpty {
                lines.append("    " + String(localized: "cli.vm.tree.detached", defaultValue: "(detached — no tab on the machine shows these)"))
                for terminal in detached {
                    lines.append("      " + treeResourceCell(terminal, openHint: "cmux surface open"))
                }
            }
        }
        return lines
    }

    /// Whether a catalog terminal is live and has no resolved daemon views.
    /// Exited records with stale tab ids are intentionally not detached.
    private static func treeTerminalIsDetached(_ terminal: [String: Any]) -> Bool {
        let lifecycle = (terminal["lifecycle"] as? String) ?? "running"
        guard lifecycle == "launching" || lifecycle == "running" else { return false }
        if let views = terminal["remote_views"] as? [[String: Any]] {
            return views.isEmpty
        }
        if let viewCount = treeNumber(terminal["view_count"]) {
            return viewCount == 0
        }
        return terminal["remote_workspace"] == nil
    }

    /// One workspace placement as the catalog payload describes it: the resource and the
    /// daemon tab (`remote_views` entry) showing it in this workspace; nil for payloads
    /// that predate views.
    struct TreePlacement {
        let resource: [String: Any]
        let view: [String: Any]?
    }

    /// Maps wire placements through the same ``RemoteWorkspaceLayout`` used by the sidebar.
    /// Formatting stays in the CLI; pane grouping, ordering, and active-tab selection do not.
    static func treeLayoutRows(_ placements: [TreePlacement]) -> [TreePlacement] {
        func position(_ view: [String: Any]?, _ key: String) -> Int? {
            treeNumber(view?[key]).flatMap { Int(exactly: $0) }
        }
        let kindRank: [String: Int] = ["terminal": 0, "browser": 1]
        let layout = RemoteWorkspaceLayout(placements: placements.map { placement in
            RemoteWorkspacePlacement(
                screenID: placement.view?["screen_id"] as? String,
                paneID: placement.view?["pane_id"] as? String,
                screenIndex: position(placement.view, "screen_index"),
                paneIndex: position(placement.view, "pane_index"),
                tabIndex: position(placement.view, "index"),
                focused: placement.view?["focused"] as? Bool == true,
                kindOrder: kindRank[placement.resource["kind"] as? String ?? ""] ?? 3
            )
        })
        return layout.flatPlacementIndices.map { placements[$0] }
    }

    /// Every workspace resource opens through the generic surface command.
    private static func treeWorkspaceCell(_ placement: TreePlacement, machineID: String, workspaceID: String) -> String {
        var resource = placement.resource
        if let name = (placement.view?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            resource["title"] = name
        }
        let resourceID = resource["id"] as? String ?? "?"
        let command = "cmux surface open \(resourceID)"
        return treeResourceCell(resource, openHint: command, showFullKey: true, command: command)
    }

    private static func treeResourceCell(
        _ terminal: [String: Any],
        openHint: String,
        addressKey: String = "id",
        showFullKey: Bool = false,
        command: String? = nil
    ) -> String {
        let resourceId = (terminal["id"] as? String) ?? "?"
        let key = (terminal["key"] as? String) ?? resourceId
        let lifecycle = (terminal["lifecycle"] as? String) ?? "running"
        let glyph: String
        switch lifecycle {
        case "launching": glyph = "…"
        case "exited": glyph = "○"
        case "unavailable": glyph = "◌"
        default: glyph = "●"
        }
        let displayKey = addressKey == "key" || showFullKey ? key : String(key.prefix(8))
        var cell = "\(glyph) \(displayKey)"
        let title = RemoteTerminalTitle(processTitle: terminal["title"] as? String ?? "", viewNames: (terminal["remote_views"] as? [[String: Any]])?.map { $0["name"] as? String } ?? []).poolTitle
        if !title.isEmpty { cell += "  \(title)" }
        if let cwd = terminal["detail"] as? String, !cwd.isEmpty { cell += "  \(cwd)" }
        if let agent = terminal["agent"] as? [String: Any], let state = agent["state"] as? String, !state.isEmpty {
            let source = (agent["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let label = source.map { "\($0) \(state)" } ?? state
            cell += "  " + String(format: String(localized: "cli.vm.tree.agent", defaultValue: "[agent %@]"), label)
        }
        if let open = (terminal["open_surface_ids"] as? [String])?.first, !open.isEmpty {
            cell += "  " + String(format: String(localized: "cli.vm.tree.open", defaultValue: "(open: %@)"), String(open.prefix(8)))
        }
        let address = command ?? (addressKey == "key" ? "\(openHint)/\(key)" : "\(openHint) \(resourceId)")
        cell += "  (\(address))"
        return cell
    }

}
