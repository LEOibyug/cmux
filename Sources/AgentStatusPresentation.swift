import CmuxSidebar
import Foundation

/// One hook-owned status presentation shared by workspace rows and surface tabs.
struct AgentStatusPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case waiting
        case needsInput
        case completed
        case error
    }

    let state: State
    let text: String
    let symbolName: String

    init?(entry: SidebarStatusEntry) {
        guard AgentHibernationLifecycleStatusKeys.isAllowed(entry.key) else { return nil }
        let icon = entry.icon.map { $0.hasPrefix("sf:") ? String($0.dropFirst(3)) : $0 }
        if icon == "exclamationmark.triangle.fill" || icon == "xmark.circle.fill" {
            state = .error
        } else if icon == "bell.fill" {
            state = .needsInput
        } else if let workState = entry.workState {
            switch workState {
            case .running, .subagents: state = .running
            case .waiting: state = .waiting
            }
        } else {
            switch icon {
            case "bolt.fill", "point.3.filled.connected.trianglepath.dotted":
                state = .running
            case "hourglass":
                state = .waiting
            case "pause.circle.fill", "checkmark.circle.fill", "checkmark.circle":
                state = .completed
            default:
                return nil
            }
        }
        text = entry.sidebarDisplayText
        switch state {
        case .running: symbolName = icon ?? "bolt.fill"
        case .waiting: symbolName = "hourglass"
        case .needsInput: symbolName = "bell.fill"
        case .completed: symbolName = "checkmark.circle.fill"
        case .error: symbolName = "exclamationmark.triangle.fill"
        }
    }

    var isAnimating: Bool { state == .running }

    // Opaque palettes retain contrast on both the sidebar's blue selection and
    // unselected light/dark chrome; selection never washes the status to gray.
    var foregroundHex: String {
        switch state {
        case .running: "#8BCBFF"
        case .waiting, .needsInput: "#FFD36B"
        case .completed: "#7EE2A8"
        case .error: "#FFADB3"
        }
    }

    var backgroundHex: String {
        switch state {
        case .running: "#142F4D"
        case .waiting, .needsInput: "#422F0B"
        case .completed: "#163A2C"
        case .error: "#481C23"
        }
    }
}
