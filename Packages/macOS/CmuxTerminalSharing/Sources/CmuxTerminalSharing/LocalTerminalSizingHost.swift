import CmuxTerminalSizing

/// The sizing host of one local Mac terminal.
///
/// Wraps ``TerminalSizingEngine`` for the Mac pane's viewport, policy and
/// detach/reattach lifecycle. The terminal process continues running when its
/// Mac view detaches, and the controller applies the decided grid.
public struct LocalTerminalSizingHost: Sendable {
    /// The engine; its `state` is what every viewer sees.
    public private(set) var engine: TerminalSizingEngine
    /// The participant id of the Mac pane itself.
    public let macParticipantID: String
    /// Set while someone else disconnected the Mac pane's own view.
    public private(set) var macDetachment: TerminalSharingDetachment?
    /// The Mac pane as it attaches: identity plus its latest grid, kept while
    /// its view is detached so a reattach restores the current pane grid.
    private var macParticipant: TerminalSizingParticipant

    /// Creates the host with the Mac pane attached.
    ///
    /// - Parameters:
    ///   - macParticipant: the Mac pane; its viewport is the pane's own grid.
    ///   - initialSize: the grid before anyone else reports, normally the PTY's size.
    ///   - policy: the effective policy.
    public init(
        macParticipant: TerminalSizingParticipant,
        initialSize: TerminalGridSize,
        policy: TerminalSizingPolicy = .fitEveryone
    ) {
        macParticipantID = macParticipant.id
        self.macParticipant = macParticipant
        engine = TerminalSizingEngine(initialSize: initialSize, policy: policy)
        engine.attach(macParticipant)
    }

    /// The published state.
    public var state: TerminalSizingState { engine.state }

    /// The Mac pane's own grid, as last reported (also while its view is detached).
    public var macViewport: TerminalGridSize? {
        macParticipant.viewport
    }


    /// What to apply to the Ghostty surface: nothing extra when the grid is the
    /// Mac pane's own grid, otherwise a pin to the decided grid. A detached
    /// Mac view never sets the grid, so its pane stays pinned to it.
    public var applyTarget: TerminalSizingApplyTarget {
        let size = state.size
        if macDetachment == nil, let macViewport, macViewport == size { return .uncapped }
        return .grid(size)
    }

    /// Whether the participant is disconnected and must not report or type.
    ///
    /// - Parameter id: a participant id.
    /// - Returns: `true` while a disconnect is in force.
    public func isDetached(_ id: String) -> Bool {
        id == macParticipantID && macDetachment != nil
    }

    // MARK: Mutations. Each returns true when the published state changed.

    /// Records the Mac pane's current grid. While the Mac view is detached
    /// the grid is only remembered for the reattach.
    @discardableResult
    public mutating func updateMacViewport(_ viewport: TerminalGridSize) -> Bool {
        macParticipant.viewport = viewport.clamped
        guard macDetachment == nil else { return false }
        return engine.report(macParticipantID, viewport: viewport)
    }


    /// Explicit input or focus from a participant.
    @discardableResult
    public mutating func noteActivity(_ id: String) -> Bool {
        guard !isDetached(id) else { return false }
        return engine.noteActivity(id)
    }

    /// Sets the effective policy.
    @discardableResult
    public mutating func setPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        engine.setPolicy(policy)
    }

    /// Sets or clears a participant's counts override.
    @discardableResult
    public mutating func setCountsOverride(_ id: String, _ value: Bool?) -> Bool {
        engine.setCountsOverride(id, value)
    }

    /// Disconnects the Mac view without stopping its terminal process.
    ///
    /// - Parameters:
    ///   - id: the Mac pane's participant id.
    ///   - detachment: the reason and time to report to the view.
    /// - Returns: whether the participant was attached and is now detached.
    @discardableResult
    public mutating func disconnect(_ id: String, detachment: TerminalSharingDetachment) -> Bool {
        guard id == macParticipantID, let row = state.participant(id) else { return false }
        macParticipant.countsOverride = row.participant.countsOverride
        macDetachment = detachment
        engine.detach(id)
        return true
    }

    /// Lifts a disconnect and restores the Mac pane with its latest grid.
    ///
    /// - Parameters:
    ///   - id: the participant id.
    ///   - asViewer: attach with `counts_override: false`.
    /// - Returns: whether a disconnect was in force.
    @discardableResult
    public mutating func reattach(_ id: String, asViewer: Bool) -> Bool {
        guard id == macParticipantID, macDetachment != nil else { return false }
        macDetachment = nil
        var mac = macParticipant
        mac.countsOverride = asViewer ? false : nil
        engine.attach(mac)
        return true
    }

}
