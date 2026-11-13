/// The kind of surface a Dock pane hosts. The Dock reuses the main-area panel
/// system, so it supports first-class terminal and browser panes.
enum DockSurfaceKind: String, Codable, Equatable, Sendable {
    case terminal
    case browser
}
