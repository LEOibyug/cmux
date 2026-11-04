import Foundation

extension AppDelegate {
    func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        SessionRestorePolicy.isRunningUnderAutomatedTests(environment: env)
    }


}
