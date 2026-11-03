import Foundation

protocol CodexpressManagementServing: Sendable {
    func status() async throws -> CodexpressSnapshot
    func perform(_ action: CodexpressManagementAction) async throws -> CodexpressOperation
    func operation(id: String) async throws -> CodexpressOperation
    func resetRequest(id: UUID) async throws -> CodexpressResetRequest
}
