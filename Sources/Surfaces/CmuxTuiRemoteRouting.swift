import Foundation
import CMUXAgentLaunch

/// Pure remote catalog selector and placement resolution shared by the app and CLI.
enum CmuxTuiRemoteRouting {

    /// The value of a `--focus <value>` / `--focus=<value>` flag: exactly true/false,
    /// 1/0 or yes/no (any case), nil for anything else. One spelling set for every
    /// command that opens UI, so `--focus` followed by an ordinary word stays bare.
    static func focusFlagValue(_ token: String) -> Bool? {
        switch token.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    /// Keeps the app-host test and legacy app-facing alias on the shared package contract.
    static func codexForkMonitorArguments(environment: [String: String]) -> [String] {
        CodexForkMonitorArguments().make(environment: environment)
    }


}
