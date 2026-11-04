import Foundation

extension ContentView {
    func commandPaletteSurfaceKindLabel(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal:
            return String(localized: "commandPalette.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "commandPalette.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "commandPalette.kind.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "commandPalette.kind.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            return String(localized: "commandPalette.kind.rightSidebarTool", defaultValue: "Tool")
        case .customSidebar:
            return String(localized: "commandPalette.kind.customSidebar", defaultValue: "Custom Sidebar")
        case .simulator: return String(localized: "commandPalette.kind.simulator", defaultValue: "Simulator")
        case .agentSession:
            return String(localized: "commandPalette.kind.agentSession", defaultValue: "Agent")
        case .project:
            return String(localized: "commandPalette.kind.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        case .workspaceTodo:
            return String(localized: "commandPalette.kind.workspaceTodo", defaultValue: "Todos")
        case .notifications:
            return String(localized: "notifications.title", defaultValue: "Notifications")
        case .remoteLoading:
            return String(localized: "menu.help.ssh", defaultValue: "SSH")
        case .chief:
            return ChiefStrings.chiefName
        }
    }
    func commandPaletteSurfaceKeywords(for panelType: PanelType) -> [String] {
        switch panelType {
        case .terminal:
            return ["terminal", "shell", "console"]
        case .browser:
            return ["browser", "web", "page"]
        case .markdown:
            return ["markdown", "note", "preview"]
        case .filePreview:
            return ["file", "preview", "text", "pdf", "image", "audio", "video"]
        case .rightSidebarTool:
            return ["tool", "files", "find", "vault", "sidebar"]
        case .customSidebar:
            return ["custom", "sidebar", "pane"]
        case .simulator: return ["simulator", "iphone", "ipad", "ios"]
        case .agentSession:
            return ["agent", "codex", "claude", "opencode", "react", "solid"]
        case .project:
            return ["project", "xcode", "build", "settings", "schemes", "targets"]
        case .extensionBrowser:
            return ["sidebar", "extensions", "extensionkit", "browser"]
        case .workspaceTodo:
            return ["todo", "todos", "checklist", "task", "status"]
        case .notifications:
            return ["notifications", "alerts", "feed"]
        case .remoteLoading:
            return ["ssh", "remote", "loading"]
        case .chief:
            return ["chief", "home", "chat", "messages", "assistant", "agent"]
        }
    }
}
