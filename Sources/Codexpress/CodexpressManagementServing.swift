import Foundation

protocol CodexpressManagementServing: Sendable {
    func gateway() async -> CodexpressGateway
    func watchGateway(_ changed: @escaping @Sendable (Bool) -> Void) -> (any DispatchSourceFileSystemObject)?
    func status(for gateway: CodexpressGateway) async throws -> CodexpressSnapshot
    func perform(_ action: CodexpressManagementAction, for gateway: CodexpressGateway) async throws -> CodexpressOperation
    func operation(id: String, for gateway: CodexpressGateway) async throws -> CodexpressOperation
    func resetRequest(id: UUID, for gateway: CodexpressGateway) async throws -> CodexpressResetRequest
}
