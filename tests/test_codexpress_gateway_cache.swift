import Darwin
import Foundation

// Standalone consumer regression. All files live under this checkout; no credentials or server needed.
@main
struct CodexpressGatewayCacheTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp/cmux-gateway-\(UUID())", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let marker = state.appendingPathComponent("cmux-gateway.json")
        let config = state.appendingPathComponent("control-access.json")
        let client = CodexpressManagementClient(configurationURL: config) {
            preconditionFailure("a read-only target consulted the local credential selector")
        }
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        @Sendable func publish(_ contents: String) throws {
            let temp = state.appendingPathComponent(UUID().uuidString)
            let created = FileManager.default.createFile(atPath: temp.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600])
            precondition(created && rename(temp.path, marker.path) == 0)
        }
        let legacy = await client.gateway()
        expect(legacy == .local(nil), "a genuinely absent marker permits legacy local discovery")
        let local = #"{"version":1,"mode":"local"}"#
        try publish(local)
        let firstLocal = await client.gateway()
        expect(firstLocal.isLocal && firstLocal != legacy, "local publication pins a generation")

        let remote = #"{"version":1,"mode":"remote","instance_id":"A","endpoint":"https://a.invalid","fetched_at":100,"snapshot":{"running":true,"mode":"fixed","fixed_source_id":"provider","sources":[{"id":"provider","name":"Fixture","kind":"provider","enabled":true,"priority":2,"quota":{"fetched_at":100}}]}}"#
        try publish(remote)
        guard case let .remote(a) = await client.gateway(), let snapshot = a.snapshot else { fatalError("missing cached snapshot") }
        expect(a.endpoint == "https://a.invalid" && a.instanceID == "A", "target accompanies its snapshot")
        expect(snapshot.inflight == nil && snapshot.sources.first?.activeRequests == nil && snapshot.sources.first?.health == nil, "unreported metrics remain unknown")
        expect(snapshot.sources.first?.quota?.windows.isEmpty == true, "a timestamp-only quota keeps its source without inventing a quota window")
        expect(snapshot.fixedSourceID == "provider" && a.isStale(at: Date(timeIntervalSince1970: 161)), "cached routing and stale fetch time")

        // Click from the old local row, including a card action. Must reject before credential selection.
        let staleActions: [CodexpressManagementAction] = [.takeover(sourceID: "provider"), .requestReset(sourceID: "provider", requestID: UUID())]
        for action in staleActions {
            do { _ = try await client.perform(action, for: firstLocal); fatalError("stale write allowed") }
            catch CodexpressManagementError.connectionChanged {}
        }
        try fm.removeItem(at: marker)
        expect(await client.gateway() == .unavailable, "a vanished known marker is not a legacy installation")
        try publish(#"{"version":1,"mode":"remote","instance_id":"B","endpoint":"https://b.invalid"}"#)
        guard case let .remote(b) = await client.gateway() else { fatalError("empty cache fell back to local") }
        expect(b.instanceID == "B" && b.snapshot == nil && b.fetchedAt == nil, "new target cannot inherit the old snapshot or its timestamp")
        for invalid in ["{", #"{"version":2,"mode":"local"}"#, #"{"version":1,"mode":"unavailable"}"#,
                        #"{"version":1,"mode":"local","endpoint":"https://a.invalid"}"#,
                        #"{"version":1,"mode":"remote","instance_id":"X","endpoint":"https://key@a.invalid"}"#] {
            try publish(invalid)
            expect(await client.gateway() == .unavailable, "invalid or transitional marker cannot authorize local access")
            do { _ = try await client.status(for: firstLocal); fatalError("old status request allowed") }
            catch CodexpressManagementError.connectionChanged {}
        }
        try publish(local)
        expect(await client.gateway() != firstLocal, "local → remote → local may not revive an old row")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        expect(await client.gateway() == .unavailable, "nonprivate marker")
        try publish(local)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: state.path)
        expect(await client.gateway() == .unavailable, "nonprivate state directory")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: state)
        let linkedState = CodexpressManagementClient(configurationURL: alias.appendingPathComponent("control-access.json"))
        expect(await linkedState.gateway() == .unavailable, "linked state directory")
        try fm.removeItem(at: marker)
        try fm.createSymbolicLink(atPath: marker.path, withDestinationPath: "absent")
        expect(await client.gateway() == .unavailable, "dangling symlink is not a missing marker")
        try fm.removeItem(at: marker)
        precondition(mkfifo(marker.path, 0o600) == 0)
        expect(await client.gateway() == .unavailable, "FIFO rejected without blocking")

        // Change targets during manual credential selection. An invalid test key/port guarantees no network even on regression.
        try publish(local)
        let switching = CodexpressManagementClient(configurationURL: config) {
            try publish(remote)
            return .manual(port: 0, key: "")
        }
        let beforeSwitch = await switching.gateway()
        do { _ = try await switching.status(for: beforeSwitch); fatalError("selection changed during status") }
        catch CodexpressManagementError.connectionChanged {}
        print("Codexpress gateway cache regressions passed")
    }
}
