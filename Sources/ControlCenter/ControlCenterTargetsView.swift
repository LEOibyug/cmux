import SwiftUI
import CmuxControlCenter
import CmuxAgentSessionStore

struct ControlCenterSessionsView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var query = ""
    @State private var directoryEdit: SessionDirectoryEdit?
    @Environment(\.controlCenterTheme) private var theme

    private var resultCount: Int {
        coordinator.sessionResultsState == .active ? coordinator.sessions.count : coordinator.managedSessions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker(ControlCenterStrings.text("sessionSource"), selection: $coordinator.sessionSourceID) {
                    if !coordinator.sessionSources.contains(where: { $0.rawValue == "omp" }) {
                        Text("OMP").tag("omp").disabled(true)
                    }
                    ForEach(coordinator.sessionSources) { source in Text(source.displayName).tag(source.rawValue) }
                }
                .frame(maxWidth: 180)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryForegroundColor)
                    TextField(ControlCenterStrings.text("searchSessions"), text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await coordinator.searchSessions(query) } }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            Task { await coordinator.searchSessions("") }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondaryForegroundColor) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(theme.inputSurfaceColor, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.borderColor))
                Button(ControlCenterStrings.text("search")) { Task { await coordinator.searchSessions(query) } }
                    .buttonStyle(.borderedProminent)
                Button { Task { await coordinator.refreshManagedSessions() } } label: {
                    if coordinator.isRefreshingSessions { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .help(ControlCenterStrings.text("sessionRefresh"))
                .disabled(coordinator.isRefreshingSessions || coordinator.sessionSourceID != "omp")
            }
            .disabled(coordinator.isRunning)

            HStack(spacing: 10) {
                if coordinator.sessionSourceID == "omp" {
                    Picker(ControlCenterStrings.text("sessions"), selection: $coordinator.sessionListState) {
                        ForEach(ControlCenterSessionListState.allCases) { state in
                            Text(ControlCenterStrings.text("sessionState." + state.rawValue)).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 400)
                    .disabled(coordinator.isRunning)
                }
                Spacer(minLength: 4)
                if coordinator.isSearchingSessions { ProgressView().controlSize(.small) }
                Text("\(resultCount)").font(.caption.monospacedDigit()).foregroundStyle(theme.secondaryForegroundColor)
            }
            Text("\(ControlCenterStrings.text("sessionManagedScope")): \(coordinator.connection.defaultDirectory)")
                .font(.caption).foregroundStyle(theme.secondaryForegroundColor).textSelection(.enabled)
            if !coordinator.sessionInventoryWarnings.isEmpty {
                Label("\(ControlCenterStrings.text("sessionState.pending")): \(coordinator.sessionInventoryWarnings.count)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help(coordinator.sessionInventoryWarnings.joined(separator: "\n"))
            }

            if resultCount == 0 {
                ControlCenterEmptyCardView(symbol: "tray", title: ControlCenterStrings.text("sessions"),
                    subtitle: ControlCenterStrings.text("sessionManagedHint"))
                Spacer(minLength: 0)
            } else {
                List {
                    if coordinator.sessionResultsState == .active {
                        ForEach(coordinator.sessions) { target in activeRow(target) }
                    } else {
                        ForEach(coordinator.managedSessions) { record in managedRow(record) }
                    }
                    if coordinator.sessionHasMore {
                        Button(ControlCenterStrings.text("sessionLoadMore")) { Task { await coordinator.loadMoreSessions() } }
                            .frame(maxWidth: .infinity)
                            .disabled(coordinator.isSearchingSessions || coordinator.isRunning)
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.borderColor))
            }
        }
        .task(id: coordinator.sessionSourceID + coordinator.sessionListState.rawValue + coordinator.connection.defaultDirectory) {
            await coordinator.searchSessions(query)
        }
        .sheet(item: $directoryEdit) { edit in
            ControlCenterSessionDirectoryEditor(edit: edit) { cwd in
                directoryEdit = nil
                Task { await coordinator.manageSession(edit.action, targetID: edit.targetID, cwd: cwd) }
            }
            .controlCenterSheetTheme(theme)
        }
    }

    private func activeRow(_ target: ControlCenterTarget) -> some View {
        HStack(spacing: 12) {
            ControlCenterTargetLabelView(target: target)
            if coordinator.sessionParents[target.id] != nil {
                Text(ControlCenterStrings.text("sessionFork")).font(.caption2).foregroundStyle(theme.secondaryForegroundColor)
            }
            Spacer(minLength: 8)
            let saved = coordinator.savedFavorite(for: target) != nil
            Button { Task { await coordinator.toggleFavorite(target) } } label: {
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
            }
            .help(ControlCenterStrings.text(saved ? "removeSaved" : "favorite"))
            .disabled(coordinator.isSavingFavorites)
            if target.agentID == "omp" {
                Menu {
                    Button(ControlCenterStrings.text("sessionChangeDirectory")) {
                        directoryEdit = SessionDirectoryEdit(targetID: target.id, name: target.name, cwd: target.path, action: "update_session_directory")
                    }
                    Button(ControlCenterStrings.text("sessionArchive")) {
                        Task { await coordinator.manageSession("archive_session", targetID: target.id) }
                    }
                    Button(ControlCenterStrings.text("sessionTrash")) {
                        Task { await coordinator.manageSession("trash_session", targetID: target.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Button(ControlCenterStrings.text("open")) { Task { await coordinator.open(target) } }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small).disabled(coordinator.isRunning).padding(.vertical, 4)
    }

    private func managedRow(_ record: OMPManagedSessionRecord) -> some View {
        HStack(spacing: 12) {
            ControlCenterTargetLabelView(target: ControlCenterTarget(id: record.id, name: record.title, kind: .session,
                path: record.cwd, sessionID: record.sessionID, sessionFile: record.journalPath))
            Spacer(minLength: 8)
            Button(ControlCenterStrings.text("sessionRestore")) {
                directoryEdit = SessionDirectoryEdit(targetID: record.id, name: record.title, cwd: record.cwd, action: "restore_session")
            }
            .buttonStyle(.borderedProminent).controlSize(.small).disabled(coordinator.isRunning)
        }
        .padding(.vertical, 4)
    }
}

private struct SessionDirectoryEdit: Identifiable {
    let id = UUID()
    let targetID: UUID
    let name: String
    let cwd: String
    let action: String
}

private struct ControlCenterSessionDirectoryEditor: View {
    let edit: SessionDirectoryEdit
    let submit: (String) -> Void
    @State private var cwd = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ControlCenterStrings.text(edit.action == "restore_session" ? "sessionRestore" : "sessionChangeDirectory")).font(.headline)
            Text(edit.name).lineLimit(2)
            TextField(ControlCenterStrings.text("directory"), text: $cwd).textFieldStyle(.roundedBorder)
            Text(ControlCenterStrings.text("sessionDirectoryHint")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(ControlCenterStrings.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(ControlCenterStrings.text("save")) { submit(cwd) }
                    .keyboardShortcut(.defaultAction).disabled(cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { cwd = edit.cwd }
    }
}

struct ControlCenterTargetLabelView: View {
    let target: ControlCenterTarget
    @Environment(\.controlCenterTheme) private var theme

    private var symbol: String {
        switch target.kind {
        case .session: return "terminal"
        case .directory: return "folder"
        case .file: return "doc.text"
        case .url: return "globe"
        case .newSession: return "plus.rectangle"
        }
    }

    private var badgeText: String {
        if target.kind == .session {
            return SessionAgent(rawValue: target.agentID)?.displayName ?? target.agentID
        }
        return ControlCenterStrings.text(target.kind.rawValue)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? target.path : target.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(badgeText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(theme.foregroundColor.opacity(0.06), in: Capsule())
                }
                if !target.path.isEmpty {
                    Text(target.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let session = target.sessionID, !session.isEmpty {
                    Text("\(SessionAgent(rawValue: target.agentID)?.displayName ?? target.agentID) · \(session)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct ControlCenterFavoritesView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var editing: ControlCenterTarget?
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ControlCenterStrings.text("favorites"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.secondaryForegroundColor)
                if !coordinator.snapshot.favorites.isEmpty {
                    Text("\(coordinator.snapshot.favorites.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.foregroundColor.opacity(0.06), in: Capsule())
                }
                Spacer()
                Button {
                    editing = ControlCenterTarget(name: "", kind: .directory, path: "")
                } label: {
                    Label(ControlCenterStrings.text("addFavorite"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if coordinator.snapshot.favorites.isEmpty {
                ControlCenterEmptyCardView(
                    symbol: "bookmark",
                    title: ControlCenterStrings.text("favorites"),
                    subtitle: ControlCenterStrings.text("offlineHint")
                )
                Spacer(minLength: 0)
            } else {
                List(coordinator.snapshot.favorites) { target in
                    HStack(spacing: 12) {
                        ControlCenterTargetLabelView(target: target)
                        Spacer(minLength: 8)
                        Button(ControlCenterStrings.text("open")) {
                            Task { await coordinator.open(target) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(coordinator.isRunning)
                        Button(ControlCenterStrings.text("edit")) { editing = target }
                            .controlSize(.small)
                            .disabled(coordinator.isRunning || coordinator.isSavingFavorites)
                        Button(ControlCenterStrings.text("remove")) {
                            Task { await coordinator.deleteFavorite(target.id) }
                        }
                        .controlSize(.small)
                        .disabled(coordinator.isRunning || coordinator.isSavingFavorites)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.borderColor))
            }
        }
        .sheet(item: $editing) { target in
            ControlCenterTargetEditorView(target: target, sources: coordinator.sessionSources) { updated in
                Task { await coordinator.saveFavorite(updated) }
            }
            .controlCenterSheetTheme(theme)
        }
        .task { await coordinator.refreshSessionSources() }
    }
}

struct ControlCenterTargetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlCenterTheme) private var theme
    @State var target: ControlCenterTarget
    let sources: [SessionAgent]
    let save: (ControlCenterTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ControlCenterStrings.text("favorite")).font(.headline)
            Form {
                Section {
                    TextField(ControlCenterStrings.text("name"), text: $target.name)
                    Picker(ControlCenterStrings.text("kind"), selection: $target.kind) {
                        ForEach(ControlCenterTarget.Kind.allCases, id: \.self) { kind in
                            Text(ControlCenterStrings.text(kind.rawValue)).tag(kind)
                        }
                    }
                    TextField(ControlCenterStrings.text("path"), text: $target.path)
                }
                if target.kind == .session {
                    Section {
                        Picker(ControlCenterStrings.text("sessionSource"), selection: $target.agentID) {
                            if !sources.contains(where: { $0.rawValue == target.agentID }) {
                                Text(SessionAgent(rawValue: target.agentID)?.displayName ?? target.agentID).tag(target.agentID)
                            }
                            ForEach(sources) { source in Text(source.displayName).tag(source.rawValue) }
                        }
                        .onChange(of: target.agentID) { _, _ in
                            target.sessionID = nil
                            target.sessionFile = nil
                        }
                        TextField(ControlCenterStrings.text("sessionID"), text: Binding(get: { target.sessionID ?? "" }, set: { target.sessionID = $0 }))
                        Text(ControlCenterStrings.text("indexedSessionHint")).font(.caption).foregroundStyle(theme.secondaryForegroundColor)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button(ControlCenterStrings.text("cancel")) { dismiss() }
                Button(ControlCenterStrings.text("save")) { save(target); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (target.kind != .session && target.path.isEmpty) || (target.kind == .session && (target.sessionID ?? "").isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520, height: target.kind == .session ? 380 : 280)
    }
}

struct ControlCenterCollectionsView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var editing: ControlCenterCollection?
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ControlCenterStrings.text("collections"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.secondaryForegroundColor)
                if !coordinator.snapshot.collections.isEmpty {
                    Text("\(coordinator.snapshot.collections.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.foregroundColor.opacity(0.06), in: Capsule())
                }
                Spacer()
                Button {
                    editing = ControlCenterCollection(name: "", items: [])
                } label: {
                    Label(ControlCenterStrings.text("addCollection"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if coordinator.snapshot.collections.isEmpty {
                ControlCenterEmptyCardView(
                    symbol: "square.stack",
                    title: ControlCenterStrings.text("collections"),
                    subtitle: ControlCenterStrings.text("settingsHint")
                )
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(coordinator.snapshot.collections) { collection in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: "square.stack.3d.up")
                                        .foregroundStyle(theme.accentColor)
                                    Text(collection.name)
                                        .font(.headline)
                                    Text("\(collection.items.count)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(theme.secondaryForegroundColor)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(theme.foregroundColor.opacity(0.06), in: Capsule())
                                    Spacer(minLength: 8)
                                    Button(ControlCenterStrings.text("open")) {
                                        Task { await coordinator.openCollection(collection) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(coordinator.isRunning)
                                    Button(ControlCenterStrings.text("retryFailed")) {
                                        Task { await coordinator.openCollection(collection, retryFailedOnly: true) }
                                    }
                                    .controlSize(.small)
                                    .disabled(coordinator.isRunning)
                                    Button(ControlCenterStrings.text("edit")) { editing = collection }
                                        .controlSize(.small)
                                    Button(ControlCenterStrings.text("remove")) {
                                        Task { await coordinator.deleteCollection(collection.id) }
                                    }
                                    .controlSize(.small)
                                }
                                if !collection.items.isEmpty {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(collection.items.enumerated()), id: \.element.id) { index, item in
                                            HStack(alignment: .top, spacing: 10) {
                                                Text("\(index + 1)")
                                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                                    .foregroundStyle(theme.secondaryForegroundColor)
                                                    .frame(width: 20, height: 20)
                                                    .background(theme.foregroundColor.opacity(0.05), in: Circle())
                                                    .padding(.top, 5)
                                                ControlCenterTargetLabelView(target: item)
                                                Spacer(minLength: 0)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(theme.elevatedSurfaceColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.borderColor)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .sheet(item: $editing) { collection in
            ControlCenterCollectionEditorView(collection: collection, favorites: coordinator.snapshot.favorites) { updated in
                Task { await coordinator.saveCollection(updated) }
            }
            .controlCenterSheetTheme(theme)
        }
    }
}

struct ControlCenterCollectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlCenterTheme) private var theme
    @State var collection: ControlCenterCollection
    let favorites: [ControlCenterTarget]
    let save: (ControlCenterCollection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ControlCenterStrings.text("collections")).font(.headline)
            TextField(ControlCenterStrings.text("name"), text: $collection.name)
                .textFieldStyle(.roundedBorder)
            Text(ControlCenterStrings.text("orderedItems"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
            List {
                ForEach(Array(collection.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(theme.secondaryForegroundColor)
                            .frame(width: 20, height: 20)
                            .background(theme.foregroundColor.opacity(0.06), in: Circle())
                        ControlCenterTargetLabelView(target: item)
                        Spacer()
                        Button(ControlCenterStrings.text("up")) { collection.items.swapAt(index, index - 1) }
                            .controlSize(.small)
                            .disabled(index == 0)
                        Button(ControlCenterStrings.text("down")) { collection.items.swapAt(index, index + 1) }
                            .controlSize(.small)
                            .disabled(index + 1 == collection.items.count)
                        Button(ControlCenterStrings.text("remove")) { collection.items.remove(at: index) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.borderColor))
            .frame(minHeight: 150)

            Text(ControlCenterStrings.text("addFromFavorites"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
            List(favorites) { favorite in
                HStack(spacing: 10) {
                    ControlCenterTargetLabelView(target: favorite)
                    Spacer()
                    Button(ControlCenterStrings.text("add")) { collection.items.append(favorite) }
                        .controlSize(.small)
                        .disabled(collection.items.contains { $0.id == favorite.id })
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.borderColor))
            .frame(minHeight: 130)

            HStack {
                Spacer()
                Button(ControlCenterStrings.text("cancel")) { dismiss() }
                Button(ControlCenterStrings.text("save")) { save(collection); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || collection.items.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640, height: 580)
    }
}

struct ControlCenterWorkspaceView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @Environment(\.controlCenterTheme) private var theme
    @State private var path = ""
    @State private var name = ""
    @State private var createDirectory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Section {
                    Text(ControlCenterStrings.text("workspaceHint"))
                        .font(.callout)
                        .foregroundStyle(theme.secondaryForegroundColor)
                    TextField(ControlCenterStrings.text("path"), text: $path)
                    TextField(ControlCenterStrings.text("name"), text: $name)
                    Toggle(ControlCenterStrings.text("createDirectory"), isOn: $createDirectory)
                    HStack {
                        Spacer()
                        Button(ControlCenterStrings.text("createWorkspace")) {
                            Task { await coordinator.createWorkspace(path: path, name: name, createDirectory: createDirectory) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isRunning)
                    }
                }
                if let operation = coordinator.operation {
                    Section {
                        ControlCenterOperationCardView(operation: operation)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { if path.isEmpty { path = coordinator.connection.defaultDirectory } }
    }
}
