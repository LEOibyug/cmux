enum CodexpressManagementError: Error, Sendable {
    case notConfigured
    case missingManualKey
    case connectionChanged
    case disabled
    case insecureConfiguration
    case invalidConfiguration
    case unauthorized
    case unavailable
    case invalidResponse
    case httpStatus(Int)
    case refreshFailed(sourceID: String, code: String?, nextRetryAt: Double?)
    /// The POST may have been accepted. Reconcile with GET; never repeat it automatically.
    case outcomeUnknown

    var isDefiniteRejection: Bool {
        switch self {
        case .notConfigured, .missingManualKey, .connectionChanged, .disabled,
             .insecureConfiguration, .invalidConfiguration, .unauthorized, .refreshFailed:
            return true
        case .httpStatus(let status):
            return (400...499).contains(status)
        case .unavailable, .invalidResponse, .outcomeUnknown:
            return false
        }
    }
}
