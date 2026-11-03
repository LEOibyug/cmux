import Foundation

extension CMUXCLI {
    /// Guides are handled before socket discovery, authentication, and window focus.
    /// Only these command positions belong to cmux; an agent or exec payload can
    /// contain `--skill` without being intercepted.
    func runGuideCommand(command: String, commandArgs: [String], jsonOutput: Bool) throws -> Bool {
        guard command == "guide" || command == "--skill" else { return false }
        let remaining = commandArgs
        let invocation = "cmux guide | cmux --skill"
        let usageLabel = CMUXDiffViewerLocalization.string("cli.guide.usage", defaultValue: "Usage:")
        let usage = "\(usageLabel) \(invocation) [--json]\n\n" + Self.guideDescription
        if remaining == ["--help"] || remaining == ["-h"] {
            print(usage)
            return true
        }
        guard remaining.isEmpty else {
            throw CLIError(message: usage, exitCode: 2)
        }

        let content = Self.overviewGuide
        if jsonOutput {
            print(jsonString(["topic": "cmux", "format": "markdown", "content": content]))
        } else {
            print(content)
        }
        return true
    }

    static var guideDescription: String {
        CMUXDiffViewerLocalization.string(
            "cli.guide.description",
            defaultValue: "Read a short guide and find specific methods. No running app, network access, or sign-in is needed to read it."
        )
    }

    static var overviewGuide: String {
        """
        # cmux guide

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.intro", defaultValue: "cmux puts terminals, browsers, and agents in one workspace. Use this guide to choose a method, then read its help before acting. `cmux --skill` prints this same guide."))

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.targets", defaultValue: "## Find your target\n\nA window contains workspaces. A workspace contains split panes. Each pane contains surfaces, such as a terminal or browser tab. Inspect the caller and use the returned IDs. Keep the caller's workspace and surface context; use explicit targets and `--focus false` where supported."))

        ```sh
        cmux identify --json
        cmux tree --all --json
        cmux capabilities --json
        ```

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.terminals", defaultValue: "## Work with terminals\n\nCreate a workspace for a task, add panes for parallel work, and read terminal output before sending input. `send` enters text; `send-key` sends keys. Read the screen again to check the result."))

        `cmux new-workspace --help` · `cmux new-pane --help`
        `cmux read-screen --help` · `cmux send --help` · `cmux send-key --help`

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.browser", defaultValue: "## Use a browser\n\nUse `cmux browser` for a browser surface inside cmux. Use `agent-browser` for a separate browser session. Prefer an existing headful Chrome session when it exposes DevTools through remote debugging: `agent-browser --auto-connect snapshot`, or `agent-browser --cdp 9222 snapshot` for an explicit port. A normal Chrome window without remote debugging cannot be attached; `agent-browser --headed` starts a new visible browser. Read a snapshot, act on an observed element, then take a fresh snapshot. Check appearance with a screenshot. Keep each tool's target IDs within that tool."))

        ```sh
        cmux browser open https://example.com --focus false
        cmux browser --surface <surface> snapshot --interactive
        cmux browser --help
        agent-browser --auto-connect snapshot
        agent-browser --cdp 9222 snapshot
        agent-browser --headed open https://example.com
        agent-browser --help
        ```

        [agent-browser docs](https://agent-browser.dev/) · [agent-browser commands](https://agent-browser.dev/commands)

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.computer", defaultValue: "## Use app windows\n\nUse computer-use tools for native apps or visual controls. cmux provides these tools to Claude Code and Codex sessions launched in cmux. Complete setup in Settings > Computer Use. Read the `cmux-cua` skill for your agent's methods: inspect app or window state, click or type, then inspect again."))

        ## Show work and find more methods

        Use Markdown and diff views to show results. Use notifications and progress to report task state. Read command help for settings and integration methods.

        `cmux markdown --help` · `cmux diff --help` · `cmux notify --help` · `cmux set-progress --help`
        `cmux settings --help` · `cmux hooks --help`
        """
    }

}
