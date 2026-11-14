import SwiftUI
import CmuxControlCenter

struct ControlCenterSessionsView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker(ControlCenterStrings.text("sessionSource"), selection: $coordinator.sessionSourceID) {
                    if !coordinator.sessionSources.contains(where: { $0.rawValue == "omp" }) {
                        Text("OMP").tag("omp").disabled(true)
                    }
                    ForEach(coordinator.sessionSources) { source in
                        Text(source.displayName).tag(source.rawValue)
                    }
                }
                .frame(maxWidth: 220)
                .disabled(coordinator.isRunning)
                TextField(ControlCenterStrings.text("searchSessions"), text: $query)
                    .onSubmit { Task { await coordinator.searchSessions(query) } }
                Button(ControlCenterStrings.text("search")) { Task { await coordinator.searchSessions(query) } }
            }
            .disabled(coordinator.isRunning)
            Text(ControlCenterStrings.text("sessionHint")).font(.caption).foregroundStyle(.secondary)
            if let source = coordinator.sessionResultsSourceID, source != coordinator.sessionSourceID {
                Text("\(ControlCenterStrings.text("sessionResultsSource")): \(coordinator.sessionSources.first(where: { $0.rawValue == source })?.displayName ?? source)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(coordinator.sessions) { target in
                HStack {
                    ControlCenterTargetLabelView(target: target)
                    Spacer()
                    let saved = coordinator.savedFavorite(for: target) != nil
                    Button {
                        Task { await coordinator.toggleFavorite(target) }
                    } label: {
                        Label(ControlCenterStrings.text(saved ? "saved" : "favorite"), systemImage: saved ? "checkmark" : "bookmark")
                    }
                    .help(ControlCenterStrings.text(saved ? "removeSaved" : "favorite"))
                    .disabled(coordinator.isRunning || coordinator.isSavingFavorites)
                    Button(ControlCenterStrings.text("open")) { Task { await coordinator.open(target) } }
                        .disabled(coordinator.isRunning)
                }
            }
        }
        .task(id: coordinator.sessionSourceID) { await coordinator.searchSessions(query) }
    }
}

struct ControlCenterTargetLabelView: View {
    let target: ControlCenterTarget
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(target.name).fontWeight(.medium)
            Text(target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let session = target.sessionID {
                Text("\(SessionAgent(rawValue: target.agentID)?.displayName ?? target.agentID) · \(session)")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

struct ControlCenterFavoritesView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var editing: ControlCenterTarget?

    var body: some View {
        VStack(alignment: .leading) {
            Button(ControlCenterStrings.text("addFavorite")) {
                editing = ControlCenterTarget(name: "", kind: .directory, path: "")
            }
            List(coordinator.snapshot.favorites) { target in
                HStack {
                    ControlCenterTargetLabelView(target: target)
                    Spacer()
                    Button(ControlCenterStrings.text("open")) { Task { await coordinator.open(target) } }.disabled(coordinator.isRunning)
                    Button(ControlCenterStrings.text("edit")) { editing = target }
                        .disabled(coordinator.isRunning || coordinator.isSavingFavorites)
                    Button(ControlCenterStrings.text("remove")) { Task { await coordinator.deleteFavorite(target.id) } }
                        .disabled(coordinator.isRunning || coordinator.isSavingFavorites)
                }
            }
        }
        .sheet(item: $editing) { target in
            ControlCenterTargetEditorView(target: target, sources: coordinator.sessionSources) { updated in
                Task { await coordinator.saveFavorite(updated) }
            }
        }
        .task { await coordinator.refreshSessionSources() }
    }
}

struct ControlCenterTargetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var target: ControlCenterTarget
    let sources: [SessionAgent]
    let save: (ControlCenterTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ControlCenterStrings.text("favorite")).font(.headline)
            Form {
                TextField(ControlCenterStrings.text("name"), text: $target.name)
                Picker(ControlCenterStrings.text("kind"), selection: $target.kind) {
                    ForEach(ControlCenterTarget.Kind.allCases, id: \.self) { kind in
                        Text(ControlCenterStrings.text(kind.rawValue)).tag(kind)
                    }
                }
                TextField(ControlCenterStrings.text("path"), text: $target.path)
                if target.kind == .session {
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
                    Text(ControlCenterStrings.text("indexedSessionHint")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(ControlCenterStrings.text("cancel")) { dismiss() }
                Button(ControlCenterStrings.text("save")) { save(target); dismiss() }
                    .disabled(target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (target.kind != .session && target.path.isEmpty) || (target.kind == .session && (target.sessionID ?? "").isEmpty))
            }
        }.padding(24).frame(width: 520)
    }
}

struct ControlCenterCollectionsView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var editing: ControlCenterCollection?

    var body: some View {
        VStack(alignment: .leading) {
            Button(ControlCenterStrings.text("addCollection")) { editing = ControlCenterCollection(name: "", items: []) }
            List(coordinator.snapshot.collections) { collection in
                VStack(alignment: .leading, spacing: 8) {
                    Text(collection.name).font(.headline)
                    ForEach(collection.items) { ControlCenterTargetLabelView(target: $0) }
                    HStack {
                        Button(ControlCenterStrings.text("open")) { Task { await coordinator.openCollection(collection) } }.disabled(coordinator.isRunning)
                        Button(ControlCenterStrings.text("retryFailed")) { Task { await coordinator.openCollection(collection, retryFailedOnly: true) } }.disabled(coordinator.isRunning)
                        Button(ControlCenterStrings.text("edit")) { editing = collection }
                        Button(ControlCenterStrings.text("remove")) { Task { await coordinator.deleteCollection(collection.id) } }
                    }
                }.padding(.vertical, 6)
            }
        }
        .sheet(item: $editing) { collection in
            ControlCenterCollectionEditorView(collection: collection, favorites: coordinator.snapshot.favorites) { updated in
                Task { await coordinator.saveCollection(updated) }
            }
        }
    }
}

struct ControlCenterCollectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var collection: ControlCenterCollection
    let favorites: [ControlCenterTarget]
    let save: (ControlCenterCollection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ControlCenterStrings.text("collections")).font(.headline)
            TextField(ControlCenterStrings.text("name"), text: $collection.name)
            Text(ControlCenterStrings.text("orderedItems")).font(.subheadline)
            List {
                ForEach(Array(collection.items.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        ControlCenterTargetLabelView(target: item)
                        Spacer()
                        Button(ControlCenterStrings.text("up")) { collection.items.swapAt(index, index - 1) }.disabled(index == 0)
                        Button(ControlCenterStrings.text("down")) { collection.items.swapAt(index, index + 1) }.disabled(index + 1 == collection.items.count)
                        Button(ControlCenterStrings.text("remove")) { collection.items.remove(at: index) }
                    }
                }
            }.frame(minHeight: 140)
            Text(ControlCenterStrings.text("addFromFavorites")).font(.subheadline)
            List(favorites) { favorite in
                HStack {
                    ControlCenterTargetLabelView(target: favorite)
                    Spacer()
                    Button(ControlCenterStrings.text("add")) { collection.items.append(favorite) }
                        .disabled(collection.items.contains { $0.id == favorite.id })
                }
            }.frame(minHeight: 120)
            HStack {
                Spacer()
                Button(ControlCenterStrings.text("cancel")) { dismiss() }
                Button(ControlCenterStrings.text("save")) { save(collection); dismiss() }
                    .disabled(collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || collection.items.isEmpty)
            }
        }.padding(24).frame(width: 620, height: 560)
    }
}

struct ControlCenterWorkspaceView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var path = ""
    @State private var name = ""
    @State private var createDirectory = false

    var body: some View {
        Form {
            Text(ControlCenterStrings.text("workspaceHint")).foregroundStyle(.secondary)
            TextField(ControlCenterStrings.text("path"), text: $path)
            TextField(ControlCenterStrings.text("name"), text: $name)
            Toggle(ControlCenterStrings.text("createDirectory"), isOn: $createDirectory)
            Button(ControlCenterStrings.text("createWorkspace")) {
                Task { await coordinator.createWorkspace(path: path, name: name, createDirectory: createDirectory) }
            }.disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isRunning)
            if let operation = coordinator.operation { ControlCenterOperationCardView(operation: operation) }
        }
        .onAppear { if path.isEmpty { path = coordinator.connection.defaultDirectory } }
    }
}
