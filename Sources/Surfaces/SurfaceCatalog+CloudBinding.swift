import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Persists the machine and remote workspace identity behind a local workspace.
    @MainActor
    func bindRemoteWorkspace(
        localWorkspaceID: UUID,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String?,
        generatedTitle: String? = nil,
        remoteWorkspaceName: String? = nil
    ) {
        let workspaceBeforeBind = tuiWorkspaceRenameService.environment.workspace(localWorkspaceID)
        let wasUnbound = workspaceBeforeBind?.remoteWorkspaceBinding?.remoteWorkspaceID?.isEmpty != false
        let titleBeforeBind = workspaceBeforeBind?.customTitle
        let sourceBeforeBind = workspaceBeforeBind?.effectiveCustomTitleSource
        let isLegacyGeneratedTitle = generatedTitle.map {
            titleBeforeBind?.trimmingCharacters(in: .whitespacesAndNewlines) ==
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                && workspaceBeforeBind?.customTitleSource == nil
        } ?? false
        tuiWorkspaceRenameService.bind(
            localWorkspaceID: localWorkspaceID,
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            generatedTitle: generatedTitle,
            remoteWorkspaceName: remoteWorkspaceName
        )
        // A remote id can arrive after a user edit. Submit that edit once, at
        // the first identity binding, before graph reconciliation can apply an
        // older snapshot. Repeated receipts never replay the old title.
        if wasUnbound,
           remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           sourceBeforeBind == .user,
           !isLegacyGeneratedTitle,
           let titleBeforeBind,
           let workspace = workspaceBeforeBind {
            propagateRemoteWorkspaceRename(
                workspace: workspace,
                localTitle: titleBeforeBind,
                previousCustomTitle: titleBeforeBind,
                previousCustomTitleSource: sourceBeforeBind
            )
        }
        if let workspace = tuiWorkspaceRenameService.environment.workspace(localWorkspaceID),
           let state = tuiStates[machine],
           (tuiStateObservations[machine] ?? .current).freshness == .current {
            tuiWorkspaceRenameService.reconcileRemoteWorkspaceName(
                workspace: workspace,
                machine: machine,
                state: state,
                catalog: self,
                observation: tuiStateObservations[machine] ?? .current
            )
        }
        requestTuiWorkspaceProjection(localWorkspaceID)
        tuiWorkspaceRenameService.updateTuiDirectories(localWorkspaceID: localWorkspaceID, catalog: self)
}

}
