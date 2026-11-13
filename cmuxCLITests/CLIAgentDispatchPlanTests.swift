import Foundation
import Testing

/// `cmux agent dispatch` parsing, quoting and screen reading. The plan is
/// compiled into this target from `CLI/AgentDispatchPlan.swift`.
@Suite("cmux agent dispatch: plan")
struct CLIAgentDispatchPlanTests {
    // MARK: Parsing

    @Test func wordsAfterTheSeparatorAreTheTaskVerbatim() throws {
        let options = try AgentDispatchOptions.parse([
            "--agent", "claude", "--name", "#12: docs", "--cwd", "/tmp/app", "--wait-working",
            "--", "--fix", "the", "--name", "flag",
        ])
        #expect(options.agent == .claude)
        #expect(options.name == "#12: docs")
        #expect(options.cwd == "/tmp/app")
        #expect(options.waitWorking)
        #expect(options.timeout == AgentDispatchOptions.defaultTimeout)
        #expect(options.prompt == .words("--fix the --name flag"))
        #expect(options.focus == nil)
    }

    @Test func defaultsToCodexWithNormalPermissions() throws {
        let options = try AgentDispatchOptions.parse(["--", "do it"])
        #expect(options.agent == .codex)
        #expect(options.agentCommand == ["codex"])
        #expect(!options.waitWorking)
    }

    @Test func inlineValuesAgentArgumentsFocusAndTimeout() throws {
        let options = try AgentDispatchOptions.parse([
            "--agent=codex", "--agent-arg", "-m", "--agent-arg=--search", "--no-focus", "--timeout=90", "task",
        ])
        #expect(options.agentCommand == ["codex", "-m", "--search"])
        #expect(options.focus == false)
        #expect(options.timeout == 90)
        #expect(options.waitWorking, "--timeout implies --wait-working")
        #expect(options.prompt == .words("task"))
    }

    @Test func promptFileAndStandardInput() throws {
        #expect(try AgentDispatchOptions.parse(["--prompt-file", "-"]).prompt == .standardInput)
        #expect(try AgentDispatchOptions.parse(["--prompt-file", "task.md"]).prompt == .file("task.md"))
    }

    @Test func worktreeAndBranch() throws {
        let options = try AgentDispatchOptions.parse(["--worktree", "/src/app", "--branch", "fix-it", "--", "x"])
        #expect(options.worktreeRepo == "/src/app")
        #expect(options.branch == "fix-it")
    }

    @Test(arguments: [
        ["--agent", "gemini", "--", "x"],          // unknown agent
        ["--"],                                     // no task
        ["--", "   "],                              // blank task
        [],                                         // no task
        ["--prompt-file", "-", "--", "x"],         // two task sources
        ["--branch", "b", "--", "x"],              // --branch without --worktree
        ["--cwd", "/a", "--worktree", "/b", "x"],  // both directories
        ["--timeout", "0", "x"],
        ["--timeout", "601", "x"],
        ["--timeout", "soon", "x"],
        ["--name", "", "x"],
        ["--name", "two\nlines", "x"],
        ["--bogus", "x"],
        ["--name"],                                 // missing value
    ])
    func rejects(_ args: [String]) {
        #expect(throws: CLIError.self) { try AgentDispatchOptions.parse(args) }
    }

    @Test func helpOnlyBeforeTheSeparator() {
        #expect(AgentDispatchOptions.isHelpRequest(["--help"]))
        #expect(AgentDispatchOptions.isHelpRequest(["--agent", "codex", "-h"]))
        #expect(!AgentDispatchOptions.isHelpRequest(["--", "document", "--help", "and", "-h"]))
    }

    @Test func normalizedPrompt() throws {
        #expect(try AgentDispatchOptions.normalizedPrompt("  fix it \n") == "fix it")
        #expect(try AgentDispatchOptions.normalizedPrompt("--help me") == " --help me")
        #expect(throws: CLIError.self) { try AgentDispatchOptions.normalizedPrompt(" \n ") }
        #expect(throws: CLIError.self) {
            try AgentDispatchOptions.normalizedPrompt(String(repeating: "a", count: AgentDispatchOptions.maxPromptBytes + 1))
        }
    }

    @Test func titleDefaultsToTheTasksFirstLine() throws {
        let options = try AgentDispatchOptions.parse(["--", "x"])
        #expect(options.title(prompt: "Fix   login\nthen more") == "Fix login")
        let long = AgentDispatchOptions.defaultTitle(for: String(repeating: "word ", count: 20))
        #expect(long.count == 40)
        #expect(long.hasSuffix("…"))
    }

    // MARK: Layout

    @Test func slugAndWorktreePath() {
        #expect(AgentDispatchPlan.slug("#123: Fix login!") == "123-fix-login")
        #expect(AgentDispatchPlan.slug("日本語") == "agent")
        #expect(AgentDispatchPlan.worktreePath(repo: "/src/app/", slug: "fix") == "/src/app-fix")
        #expect(AgentDispatchPlan.worktreeAddArguments(repo: "/src/app", path: "/src/app-fix", branch: "fix")
            == ["-C", "/src/app", "worktree", "add", "-b", "fix", "--", "/src/app-fix"])
    }

    @Test func typedCommandOnlyNamesTheLauncher() {
        #expect(AgentDispatchPlan.typedCommand(launcherPath: "/tmp/cmux-dispatch.ab/launch.sh")
            == " /bin/sh '/tmp/cmux-dispatch.ab/launch.sh'")
        #expect(AgentDispatchPlan.shellWord("it's") == #"'it'"'"'s'"#)
    }

    /// The launcher hands the task to the agent as one argv word, byte for
    /// byte, and removes its directory. `printf %s` stands in for the agent.
    @Test func launcherPassesTheTaskAsOneArgumentAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dispatch-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = #"Fix "it's" $HOME `id` $(whoami) \n; rm -rf / && echo *"# + "\nsecond line"
        let promptPath = directory.appendingPathComponent("task.txt").path
        let scriptPath = directory.appendingPathComponent("launch.sh").path
        try Data(task.utf8).write(to: URL(fileURLWithPath: promptPath))
        let script = AgentDispatchPlan.launcherScript(
            agentCommand: ["/usr/bin/printf", "%s"], promptPath: promptPath, directory: directory.path
        )
        try Data(script.utf8).write(to: URL(fileURLWithPath: scriptPath))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == task)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Screen

    @Test func codexWorkingRow() {
        let screen = "› Fix the login bug\n\n• Working (3s • esc to interrupt)\n\n  ⏎ send"
        #expect(AgentDispatchScreenReading.read(screen, agent: .codex) == .working("• Working (3s • esc to interrupt)"))
        #expect(AgentDispatchScreenReading.read("Working on it", agent: .codex) == .pending)
    }

    @Test func claudeSpinnerRowButNotItsStatusBar() {
        let bar = "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt"
        #expect(AgentDispatchScreenReading.read(bar, agent: .claude) == .pending)
        let screen = "> Fix the README\n✻ Pondering… (5s · ↑ 1.2k tokens · esc to interrupt)\n\(bar)"
        #expect(AgentDispatchScreenReading.read(screen, agent: .claude)
            == .working("✻ Pondering… (5s · ↑ 1.2k tokens · esc to interrupt)"))
    }

    @Test func blockedScreensAreReportedNotAnswered() {
        let trust = "Quick safety check\nYes, I trust this folder\nNo, exit"
        #expect(AgentDispatchScreenReading.read(trust, agent: .claude) == .blocked(reason: "trust_prompt"))
        #expect(AgentDispatchScreenReading.read("zsh: command not found: codex", agent: .codex)
            == .blocked(reason: "agent_not_found"))
        #expect(AgentDispatchScreenReading.read("/tmp/x/launch.sh: line 5: exec: claude: not found", agent: .claude)
            == .blocked(reason: "agent_not_found"))
        #expect(AgentDispatchScreenReading.read("user@mac app % ", agent: .codex) == .pending)
    }

    // MARK: Waiting on surface.wait_text_change

    @Test func aChangedScreenWithoutTheAgentWorkingWaitsAfterItsRevision() {
        let step = AgentDispatchWaitStep.read(
            ["text": "user@mac app % ", "revision": "r1", "changed": true], agent: .codex
        )
        #expect(step == AgentDispatchWaitStep(reading: .pending, revision: "r1", isFinal: false))
    }

    @Test func theWorkingRowEndsTheWait() {
        let step = AgentDispatchWaitStep.read(
            ["text": "• Working (3s • esc to interrupt)", "revision": "r2", "changed": true], agent: .codex
        )
        #expect(step.reading == .working("• Working (3s • esc to interrupt)"))
        #expect(step.isFinal)
    }

    @Test func anUnchangedReplyIsTheAppsDeadlineAndKeepsTheLastReading() {
        let trust = "Do you trust the files in this folder?\n❯ 1. Yes, proceed"
        let step = AgentDispatchWaitStep.read(["text": trust, "revision": "r3", "changed": false], agent: .claude)
        #expect(step.reading == AgentDispatchScreenReading.read(trust, agent: .claude))
        #expect(step.isFinal)
    }

    @Test func aBlockingScreenThatChangedKeepsWaitingForSomeoneToAnswerIt() {
        let trust = "Do you trust the files in this folder?\n❯ 1. Yes, proceed"
        let step = AgentDispatchWaitStep.read(["text": trust, "revision": "r4", "changed": true], agent: .claude)
        #expect(!step.isFinal, "a trust prompt may still be answered before the deadline")
        #expect(step.revision == "r4")
    }

    @Test func aReplyWithoutARevisionCannotBeWaitedAfter() {
        #expect(AgentDispatchWaitStep.read(["text": ""], agent: .codex).isFinal)
        #expect(AgentDispatchWaitStep.read(["text": "", "revision": ""], agent: .codex).isFinal)
    }
}
