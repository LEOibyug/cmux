import CmuxSurfaceCatalogModel
import Foundation

/// Retains a created SSH terminal across local projection retries, so Retry never creates a second process.
@MainActor
final class TuiTerminalCreationCoordinator {
    typealias Create = @MainActor () async throws -> SurfaceResource
    typealias Project = @MainActor (SurfaceResource) async throws -> (projection: SurfaceProjection, reused: Bool)
    typealias DiscardProjection = @MainActor (SurfaceProjection) -> Void
    private let create: Create
    private let project: Project
    private let discardProjection: DiscardProjection
    private let onStart: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void
    private let onCancel: @MainActor () -> Void
    private let onSuccess: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var createdResource: SurfaceResource?

    init(create: @escaping Create, project: @escaping Project,
         onStart: @escaping @MainActor () -> Void = {}, onFailure: @escaping @MainActor (Error) -> Void,
         onCancel: @escaping @MainActor () -> Void = {}, onSuccess: @escaping @MainActor () -> Void,
         discardProjection: @escaping DiscardProjection = { _ in }) {
        self.create = create
        self.project = project
        self.onStart = onStart
        self.onFailure = onFailure
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.discardProjection = discardProjection
    }
    func start() {
        guard task == nil else { return }
        generation &+= 1
        let operationGeneration = generation
        onStart()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == operationGeneration { self.task = nil } }
            do {
                let resource: SurfaceResource
                if let createdResource = self.createdResource {
                    resource = createdResource
                } else {
                    resource = try await self.create()
                    guard self.generation == operationGeneration else { throw CancellationError() }
                    self.createdResource = resource
                }
                try Task.checkCancellation()
                let result = try await self.project(resource)
                guard self.generation == operationGeneration, !Task.isCancelled else {
                    if !result.reused { self.discardProjection(result.projection) }
                    throw CancellationError()
                }
                self.onSuccess()
            } catch {
                guard self.generation == operationGeneration else { return }
                if error is CancellationError || Task.isCancelled { self.onCancel() }
                else { self.onFailure(error) }
            }
        }
    }
    func retry() { start() }
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        onCancel()
    }
    deinit { task?.cancel() }
}
