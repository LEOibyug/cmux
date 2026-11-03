import Foundation

extension SettingsSectionID {
    /// The section a navigation request for this id selects, and the anchor
    /// the detail pane scrolls to.
    ///
    /// Sidebar selection and the detail scroll both resolve through here so
    /// they cannot disagree about where a request lands. A request without
    /// an anchor lands on the section header.
    func navigationDestination(providedAnchor: String?) -> (section: SettingsSectionID, anchorID: String) {
        return (self, providedAnchor ?? "section:\(rawValue)")
    }

    /// Decodes a `cmux.settings.navigate` notification's `target` and
    /// optional `anchor`, or returns `nil` for an unknown target.
    static func navigationDestination(
        userInfo: [AnyHashable: Any]?
    ) -> (section: SettingsSectionID, anchorID: String)? {
        guard
            let rawValue = userInfo?["target"] as? String,
            let requested = SettingsSectionID(rawValue: rawValue)
        else { return nil }
        return requested.navigationDestination(providedAnchor: userInfo?["anchor"] as? String)
    }
}
