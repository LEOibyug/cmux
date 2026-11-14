import CmuxControlCenter

extension ControlCenterCoordinator {
    func importCodexpressConnection() async {
        let previous = connection
        let title = ControlCenterStrings.text("importCodexpress")
        await runOperation(title: title) {
            let binding: ControlCenterCodexpressBinding
            do {
                binding = try await ControlCenterCodexpressBinding.current()
            } catch let error as ControlCenterCodexpressError {
                throw ControlCenterHostError.blocked(ControlCenterStrings.text(Self.codexpressErrorKey(error)))
            }
            try self.checkCancellation()
            var updated = previous
            updated.baseURL = binding.baseURL
            updated.apiKey = binding.apiKey
            do {
                try await self.localStore().saveConnection(updated)
            } catch {
                throw ControlCenterHostError.blocked(ControlCenterStrings.text("codexpressSaveFailed"))
            }
            self.connection = updated
            self.hasLoadedConnection = true
            self.models = []
            self.resetContext()
            let detail = ControlCenterStrings.text("codexpressImported")
            self.output = detail
            self.operation?.steps.append(ControlCenterStep(title: title, status: .success, detail: detail))
        }
    }

    private static func codexpressErrorKey(_ error: ControlCenterCodexpressError) -> String {
        switch error {
        case .invalidStateDirectory: return "codexpressInvalidStateDirectory"
        case .unavailable: return "codexpressUnavailable"
        case .timedOut: return "codexpressTimedOut"
        case .invalidResponse: return "codexpressInvalidResponse"
        case .rejected: return "codexpressRejected"
        case .ingressNotRunning: return "codexpressIngressNotRunning"
        case .invalidPort: return "codexpressInvalidPort"
        case .invalidKey: return "codexpressInvalidKey"
        }
    }
}
