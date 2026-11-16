import Foundation

// Compile with Sources/Codexpress/CodexpressSnapshot.swift; no app host or gateway required.
@main
struct CodexpressSnapshotReferenceTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func window(_ fields: String) throws -> CodexpressSnapshot.QuotaWindow {
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
            )
            return try decoder.decode(CodexpressSnapshot.QuotaWindow.self, from: Data("{\"name\":\"secondary\",\(fields)}".utf8))
        }
        func expect(_ actual: Double?, _ expected: Double?, _ message: String) {
            if let actual, let expected {
                precondition(abs(actual - expected) < 0.000_001, message)
            } else {
                precondition(actual == nil && expected == nil, message)
            }
        }

        // The local clock wins over a stale snapshot's reference, without changing quota.
        let weekly = try window("\"window_seconds\":604800,\"used_percent\":60,\"reset_at\":2000302400,\"ref_cost\":1")
        expect(weekly.referenceProgress(at: now), 50, "halfway through the actual seven-day cycle")
        expect(weekly.referenceProgress(at: now.addingTimeInterval(60_480)), 40, "remaining time decreases without fetching")
        expect(weekly.referenceProgress(at: now.addingTimeInterval(-604_800)), 100, "future cycle clamps at 100")
        expect(weekly.referenceProgress(at: now.addingTimeInterval(604_800)), 0, "expired reset stays at zero")
        expect(weekly.referenceProgress(at: now.addingTimeInterval(1_209_600)), 0, "never infer another cycle")
        expect(weekly.usedPercent, 60, "reference does not consume quota")

        for fields in [
            "\"window_seconds\":604800", "\"window_seconds\":604800,\"ref_cost\":null",
            "\"window_seconds\":604800,\"ref_cost\":-1", "\"window_seconds\":604800,\"ref_cost\":101",
            "\"window_seconds\":604800,\"ref_cost\":\"NaN\"", "\"window_seconds\":604800,\"ref_cost\":\"broken\"",
            "\"window_seconds\":18000,\"reset_at\":2000302400,\"ref_cost\":50",
            "\"reset_at\":2000302400,\"ref_cost\":50",
            "\"window_seconds\":604800,\"reset_at\":0",
            "\"window_seconds\":604800,\"reset_at\":\"Infinity\""
        ] {
            expect(try window(fields).referenceProgress(at: now), nil, "missing or invalid reference: \(fields)")
        }
        for reset in ["null", "0", "-1", "\"Infinity\""] {
            expect(try window("\"window_seconds\":604800,\"reset_at\":\(reset),\"ref_cost\":42.3").referenceProgress(at: now), 42.3, "valid snapshot fallback")
        }
        for (used, level) in [(54.999, 0), (55.0, 1), (59.999, 1), (60.0, 2)] {
            let quota = try window("\"window_seconds\":604800,\"used_percent\":\(used),\"ref_cost\":50")
            switch (quota.referenceLevel(at: now), level) {
            case (.normal, 0), (.warning, 1), (.critical, 2): break
            default: preconditionFailure("reference warning threshold at used=\(used)")
            }
            expect(quota.usedPercent, used, "warning never alters the actual remaining quota")
        }
        let unknown = try window("\"window_seconds\":604800,\"ref_cost\":100")
        guard case .normal = unknown.referenceLevel(at: now) else { preconditionFailure("unknown remaining stays neutral") }

        // Decode the real consumer boundary: keep the same real windows and quota values.
        for windows in [
            "{\"name\":\"secondary\",\"window_seconds\":604800,\"used_percent\":60,\"ref_cost\":50}",
            "{\"name\":\"primary\",\"window_seconds\":18000,\"used_percent\":20},{\"name\":\"secondary\",\"window_seconds\":604800,\"used_percent\":60,\"ref_cost\":50}"
        ] {
            let payload = """
            {"running":true,"mode":"auto","inflight":0,"sources":[{"id":"fixture","name":"Official","kind":"official","enabled":true,"priority":1,"health":"ready","active_requests":0,"quota":{"windows":[\(windows)]}}]}
            """
            let snapshot = try JSONDecoder().decode(CodexpressSnapshot.self, from: Data(payload.utf8))
            let quota = snapshot.sources[0].quota!.windows
            precondition(quota.count == (windows.contains("primary") ? 2 : 1), "no synthetic quota window")
            expect(quota.last?.usedPercent, 60, "real weekly quota survives decoding")
            expect(quota.last?.referenceProgress(at: now), 50, "reference survives status decoding")
        }
        print("Codexpress snapshot reference regressions passed")
    }
}
