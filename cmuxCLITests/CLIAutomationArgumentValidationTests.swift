import Foundation
import Testing

@Suite("Automation CLI argument validation", .serialized)
struct CLIAutomationArgumentValidationTests {
    @Test func rejectsMalformedArgumentsBeforeAutomationRequest() throws {
        let cases: [(arguments: [String], error: String)] = [
            (["automation", "list", "--typo"], "automation list: unknown option --typo"),
            (["automation", "list", "extra"], "automation list: unexpected argument extra"),
            (["automation", "show", "rule-id", "unexpected"], "automation show: unexpected argument unexpected"),
            (["automation", "enable", "rule-id", "--typo"], "automation enable: unknown option --typo"),
            (["automation", "enable", "rule-id", "extra"], "automation enable: unexpected argument extra"),
            (["automation", "disable", "rule-id", "unexpected"], "automation disable: unexpected argument unexpected"),
            (["automation", "disable", "rule-id", "--typo=s3cr3t"], "automation disable: unknown option --typo"),
            (["automation", "enable", "--", "rule-id", "extra"], "automation enable: unexpected argument extra"),
            (["automation", "logs", "extra"], "automation logs: unexpected argument extra"),
            (["automation", "logs", "--typo"], "automation logs: unknown option --typo"),
            (["automation", "logs", "--limit"], "automation logs: --limit requires a value"),
            (["automation", "logs", "--limit", "--typo"], "automation logs: --limit requires a value"),
            (["automation", "reload", "--typo"], "automation reload: unknown option --typo"),
        ]

        for testCase in cases {
            let fixture = try CodexTeamsSocketFixture()
            defer { fixture.stop() }

            let result = try runCLI(testCase.arguments, socketPath: fixture.path)

            #expect(!result.timedOut)
            #expect(result.status == 1, Comment(rawValue: result.stderr))
            #expect(result.stderr.contains(testCase.error), Comment(rawValue: result.stderr))
            #expect(!result.stderr.contains("s3cr3t"), "Option values must not be echoed")
            #expect(
                automationRequests(fixture).isEmpty,
                "Invalid automation arguments must be rejected before contacting the app"
            )
        }
    }

    @Test func acceptedArgumentsStillReachTheApp() throws {
        let cases: [(arguments: [String], method: String, id: String?, limit: Int?)] = [
            (["automation"], "automation.list", nil, nil),
            (["automation", "list", "--json"], "automation.list", nil, nil),
            (["automation", "show", "rule-id"], "automation.show", "rule-id", nil),
            (["automation", "enable", "rule-id"], "automation.enable", "rule-id", nil),
            (["automation", "disable", "rule-id", "--json"], "automation.disable", "rule-id", nil),
            (["automation", "logs"], "automation.logs", nil, nil),
            (["automation", "logs", "--limit", "5"], "automation.logs", nil, 5),
            (["automation", "logs", "--limit=5"], "automation.logs", nil, 5),
            (["automation", "reload"], "automation.reload", nil, nil),
        ]

        for testCase in cases {
            try expectAutomationRequest(
                testCase.arguments,
                method: testCase.method,
                id: testCase.id,
                limit: testCase.limit
            )
        }
    }

    @Test func typoIsReportedEvenWhenCmuxIsNotRunning() throws {
        let result = try runCLI(["automation", "enable", "rule-id", "--typo"])

        #expect(!result.timedOut)
        #expect(result.status == 1, Comment(rawValue: result.stderr))
        #expect(
            result.stderr.contains("automation enable: unknown option --typo"),
            Comment(rawValue: result.stderr)
        )
        #expect(!result.stderr.contains("No live cmux socket found"), Comment(rawValue: result.stderr))
    }

    @Test func doubleDashLetsARuleIDStartWithADash() throws {
        try expectAutomationRequest(
            ["automation", "enable", "--", "-rule-id"],
            method: "automation.enable",
            id: "-rule-id",
            limit: nil
        )
    }

    @Test func offlineTestRejectsWordsOutsideTheEvent() throws {
        let cases: [(arguments: [String], error: String)] = [
            (["automation", "test", Self.missingRuleID, "extra", "--event", "{}"], "automation test: unexpected argument extra"),
            (["automation", "test", Self.missingRuleID, "--typo", "--event", "{}"], "automation test: unknown option --typo"),
            (["automation", "test", Self.missingRuleID, "--event={}", "extra"], "automation test: unexpected argument extra"),
        ]

        for testCase in cases {
            let result = try runCLI(testCase.arguments)

            #expect(!result.timedOut)
            #expect(result.status == 1, Comment(rawValue: result.stderr))
            #expect(result.stderr.contains(testCase.error), Comment(rawValue: result.stderr))
        }
    }

    @Test func offlineTestStillAcceptsEachEventForm() throws {
        let cases: [[String]] = [
            ["automation", "test", Self.missingRuleID, "--event", "{}"],
            ["automation", "test", Self.missingRuleID, "--event={}"],
            // Unquoted JSON reaches the CLI as several words, which `--event` joins back together.
            ["automation", "test", Self.missingRuleID, "--event", "{\"name\":", "\"agent.needs_input\"}"],
        ]

        for arguments in cases {
            let result = try runCLI(arguments)

            // The empty rules file has no such rule, so reaching the lookup proves the event parsed.
            #expect(!result.timedOut)
            #expect(
                result.stderr.contains("Automation rule not found: \(Self.missingRuleID)"),
                Comment(rawValue: result.stderr)
            )
        }
    }

    private static let missingRuleID = "cli-argument-validation-missing-rule"

    private func expectAutomationRequest(
        _ arguments: [String],
        method: String,
        id: String?,
        limit: Int?
    ) throws {
        let fixture = try CodexTeamsSocketFixture()
        defer { fixture.stop() }

        let result = try runCLI(arguments, socketPath: fixture.path)

        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = automationRequests(fixture)
        #expect(
            requests.compactMap { $0["method"] as? String } == [method],
            Comment(rawValue: arguments.joined(separator: " "))
        )
        let params = requests.first?["params"] as? [String: Any] ?? [:]
        #expect(params["id"] as? String == id)
        #expect(params["limit"] as? Int == limit)
    }

    private func automationRequests(_ fixture: CodexTeamsSocketFixture) -> [[String: Any]] {
        fixture.requestsSnapshot().filter { request in
            (request["method"] as? String)?.hasPrefix("automation.") == true
        }
    }

    /// Runs the CLI under an empty home, so the user's rules, saved socket password
    /// and running cmux stay out of it. Without `socketPath` no app is reachable.
    private func runCLI(_ arguments: [String], socketPath: String? = nil) throws -> CLIHookProcessRunner.Result {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-automation-args-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "CMUX_TEST_ISOLATED_SOCKET_DISCOVERY": "1",
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        if let socketPath {
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_SOCKET_PASSWORD"] = ""
        }
        return CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(),
            arguments: arguments,
            environment: environment,
            timeout: 10
        )
    }
}
