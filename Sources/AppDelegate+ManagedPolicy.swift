import AppKit
import CmuxSettings
import Foundation

/// Runtime enforcement for retained local browser, socket, computer-use and
/// user-created remote-connection policies.
extension AppDelegate {
    /// Installs the managed-policy transition observer once at startup.
    func installManagedPolicyEnforcement() {
        guard managedPolicyEnforcementObserver == nil else { return }
        managedPolicyEnforcementObserver = ManagedPolicyEnforcementObserver(
            socketControlPolicy: {
                CmuxSettingsFileStore.socketControlPolicyResolution()
            },
            enforceBrowserPolicy: { [weak self] in
                self?.closeBrowserPanelsForManagedPolicy()
            },
            enforceBrowserURLAllowlistPolicy: { [weak self] in
                self?.enforceBrowserURLAllowlistPolicy()
            },
            enforceRemoteConnectionsPolicy: { [weak self] in
                self?.endRemoteConnectionsForManagedPolicy()
            },
            enforceComputerUsePolicy: { [weak self] in
                self?.applyManagedComputerUsePolicy()
            },
            enforceSocketControlPolicy: { [weak self] in
                self?.reconcileSocketListenerConfiguration(source: "managed_policy")
            }
        )
    }


    /// `DisableComputerUse` transitions, both directions: activation stops the
    /// helper (the spawn policy already withholds the tools from new agent
    /// launches); a lift re-applies the user's own setting.
    func applyManagedComputerUsePolicy() {
        guard let service = computerUseRuntimeService else { return }
        let catalog = settingsRuntime?.catalog ?? SettingCatalog()
        let store = settingsRuntime?.jsonStore
            ?? JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let userEnabled = store.snapshotValue(for: catalog.computerUse.enabled)
        Task { @MainActor in
            // `setEnabled` applies the policy itself; passing the user's value
            // keeps a lift symmetrical with activation.
            await service.setEnabled(userEnabled)
        }
    }


    /// `DisableRemoteConnections` activation. Every live cmux-created remote
    /// connection ends: remote workspaces (SSH and Mosh attachments)
    /// disconnect and drop their configuration so no reconnect path can
    /// redial, remote tmux mirrors detach and close, and their SSH control
    /// masters exit. Remote tmux sessions stay alive on their hosts; only
    /// cmux's connections to them end. The per-call gates
    /// (`Workspace.configureRemoteConnection`, `reconnectRemoteConnection`,
    /// the remote-tmux socket verbs) refuse anything new while the policy is
    /// forced, and read the resolver live once it lifts.
    func endRemoteConnectionsForManagedPolicy() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs where workspace.isRemoteWorkspace {
                workspace.disconnectRemoteConnection(
                    clearConfiguration: true,
                    disconnectedDetail: ManagedRemoteConnectionsPolicy().disabledMessage
                )
            }
        }
        remoteTmuxController.detachAllForManagedPolicy()
    }


    /// Closes every live browser pane — main area and Docks, across all
    /// windows — when `DisableEmbeddedBrowser` activates while cmux runs.
    func closeBrowserPanelsForManagedPolicy() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs {
                let browserPanelIds = workspace.panels.compactMap { id, panel in
                    panel is BrowserPanel ? id : nil
                }
                for panelId in browserPanelIds {
                    _ = workspace.closePanel(panelId, force: true)
                }
                if let dock = workspace._dockSplit {
                    closeDockBrowserPanelsForManagedPolicy(dock)
                }
            }
            for dock in manager.liveWindowDockStores {
                closeDockBrowserPanelsForManagedPolicy(dock)
            }
        }
    }

    /// Re-evaluates every live browser document when the effective allowlist
    /// changes. The panel/delegate boundary renders the localized blocked page
    /// and also traverses popup windows.
    func enforceBrowserURLAllowlistPolicy() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    (panel as? BrowserPanel)?.enforceURLAllowlistPolicy()
                }
                if let dock = workspace._dockSplit {
                    dock.forEachPanel { _, panel in
                        (panel as? BrowserPanel)?.enforceURLAllowlistPolicy()
                    }
                }
            }
            for dock in manager.liveWindowDockStores {
                dock.forEachPanel { _, panel in
                    (panel as? BrowserPanel)?.enforceURLAllowlistPolicy()
                }
            }
        }
    }

    private func closeDockBrowserPanelsForManagedPolicy(_ store: DockSplitStore) {
        var browserPanelIds: [UUID] = []
        store.forEachPanel { panelId, panel in
            if panel is BrowserPanel { browserPanelIds.append(panelId) }
        }
        for panelId in browserPanelIds {
            _ = store.closePanel(panelId, force: true)
        }
    }

    private func allTabManagersForManagedPolicyEnforcement() -> [TabManager] {
        var managers: [TabManager] = []
        for context in mainWindowContexts.values {
            managers.append(context.tabManager)
        }
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        return managers
    }
}
