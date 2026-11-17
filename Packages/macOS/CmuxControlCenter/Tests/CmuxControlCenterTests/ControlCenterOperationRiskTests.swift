import Foundation
import Testing
import CmuxControlCenter

@Suite("Control Center operation confirmation risk")
struct ControlCenterOperationRiskTests {
    private let directory = "/Users/example/project"

    @Test(arguments: [
        "rm -rf output", "printf ready; /bin/rm -- output", "true && rm output", "false || rmdir output",
        "env command rm output", "sudo -u root -- rm output", "r\\m output", "'rm' output",
        "r\\\nm output", "sh -c 'rm output'", "bash -lc 'rm output'", "find output -delete",
        "git -C repo reset --hard", "git clean -fd", "git branch -D old", "git restore tracked"
    ])
    func deletionSurvivesCompoundsQuotingAndWrappers(_ command: String) {
        #expect(ControlCenterOperationRisk.shell(command, directory: directory).contains("deletion"))
    }

    @Test(arguments: [
        "pwd", "ls -la src", "cat README.md", "head -n 5 README.md", "grep 'rm -rf' README.md",
        "rg '.env' src", "sort -u names.txt", "git status --short", "git --no-pager log -3",
        "git diff -- src/file.swift", "git config --get user.name", "command -v rm", "env -- /bin/pwd",
        "echo 'rm -rf /; sudo chmod 777 .env'", "printf '%s' '$(rm x)' '`rm x`' '$HOME/.ssh'",
        "printf '%s' \"rm\"", "echo --token=not-an-option-here", "echo safe # rm output",
        "cat README.md | head -n 3", "cat < README.md", "curl -sS https://example.invalid/readme",
        "curl -i https://example.invalid/readme"
    ])
    func ordinaryReadsAndQuotedDataDoNotRequireExtraConfirmation(_ command: String) {
        #expect(ControlCenterOperationRisk.shell(command, directory: directory).isEmpty)
    }

    @Test(arguments: [
        "mystery-tool input", "./ls README.md", "python3 -c 'print(1)'", "node script.js", "eval 'rm x'",
        "xargs rm", "find . -exec sh -c 'rm x' ';'", "echo $(pwd)", "echo `pwd`", "cat $TARGET",
        "cat *.txt", "cat <(printf hello)", "for f in *; do cat $f; done", "echo 'unterminated",
        "cat <<EOF\nhello\nEOF", "PATH=/custom/bin ls", "env PATH=/custom/bin ls", "sh -c 'pwd'",
        "command cd /etc && cat passwd", "rg --pre ./filter pattern src", "sort --compress-program=./filter file",
        "curl --config settings", "git -c alias.inspect='!rm x' inspect", "echo $'\\x72m'", "cat >",
        "printf -v PATH /custom/bin; ls", "less '+!rm file' README.md", "rg --hostname-bin ./script pattern src"
    ])
    func unknownOrUnsupportedExecutionRequiresConfirmation(_ command: String) {
        #expect(ControlCenterOperationRisk.shell(command, directory: directory).contains("opaqueExecution"))
    }

    @Test func literalArgumentsAreNotShellSource() {
        #expect(ControlCenterOperationRisk.arguments(["printf", "%s", "$(rm x); sudo chmod 777 .env"], directory: directory).isEmpty)
        #expect(ControlCenterOperationRisk.arguments(["echo", "--token=example", "rm", ">", ".env"], directory: directory).isEmpty)
        #expect(ControlCenterOperationRisk.arguments(["rm", "literal;name"], directory: directory) == ["deletion"])
        #expect(ControlCenterOperationRisk.arguments(["sh", "-c", "rm output"], directory: directory) == ["deletion", "opaqueExecution"])
        #expect(ControlCenterOperationRisk.arguments(["python3", "script.py"], directory: directory) == ["opaqueExecution"])
    }

    @Test(arguments: [
        ("cp first second", "overwrite"), ("mv first second", "overwrite"), ("printf x > output", "overwrite"),
        ("printf x >> output", "overwrite"), ("tee output", "overwrite"), ("sort -o output input", "overwrite"),
        ("chmod 600 file", "permissions"), ("chown root file", "permissions"), ("sudo pwd", "privilege"),
        ("launchctl unload service", "system"), ("spctl --master-disable", "system"),
        ("git push origin main", "external"), ("npm publish", "external"), ("gh release create tag", "external"),
        ("curl --data payload https://example.invalid", "external"),
        ("curl --user user:synthetic https://example.invalid", "credentials"),
        ("curl -H 'Authorization: Bearer synthetic' https://example.invalid", "credentials"),
        ("curl --token=synthetic https://example.invalid", "credentials"),
        ("cat .env", "credentials"), ("cat nested/../.aws/credentials", "credentials"),
        ("cd /private/etc && cat passwd", "credentials"), ("cat < .env", "credentials"),
        ("cp input /etc/hosts", "system")
    ])
    func reportsSpecificConfirmationReasons(_ command: String, _ reason: String) {
        #expect(ControlCenterOperationRisk.shell(command, directory: directory).contains(reason))
    }

    @Test func combinesReasonsInStableUniqueOrder() {
        #expect(ControlCenterOperationRisk.shell("sudo rm .env; chmod 600 .env; git push; eval x", directory: directory)
            == ["deletion", "privilege", "permissions", "credentials", "external", "opaqueExecution"])
    }

    @Test func fileWritesAndSensitiveReadsUseMetadataWithoutReadingContents() throws {
        let root = controlCenterTestDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = root.appendingPathComponent("ordinary.txt")
        try Data("synthetic".utf8).write(to: ordinary)
        let originalPermissions = try FileManager.default.attributesOfItem(atPath: ordinary.path)[.posixPermissions] as? NSNumber
        #expect(ControlCenterOperationRisk.file(ordinary.path, writing: false).isEmpty)
        #expect(ControlCenterOperationRisk.file(ordinary.path, writing: true) == ["overwrite"])
        #expect(ControlCenterOperationRisk.file(root.appendingPathComponent("new.txt").path, writing: true).isEmpty)
        #expect(ControlCenterOperationRisk.file(root.appendingPathComponent(".ssh/new-key").path, writing: false) == ["credentials"])
        #expect(ControlCenterOperationRisk.file("/etc/hosts", writing: false).isEmpty)
        #expect(ControlCenterOperationRisk.file("/etc/hosts", writing: true).contains("system"))
        #expect(ControlCenterOperationRisk.file("/private/etc/sudoers", writing: false).contains("credentials"))
        #expect(try Data(contentsOf: ordinary) == Data("synthetic".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: ordinary.path)[.posixPermissions] as? NSNumber == originalPermissions)
    }

    @Test func resolvesAliasesAndSymlinkDotDotBeforeSensitiveTargetAssessment() throws {
        let root = controlCenterTestDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sensitive = root.appendingPathComponent(".ssh")
        let nested = sensitive.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let target = sensitive.appendingPathComponent("ordinary-name")
        try Data("synthetic".utf8).write(to: target)
        let alias = root.appendingPathComponent("public-name")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        #expect(ControlCenterOperationRisk.file(alias.path, writing: false) == ["credentials"])
        #expect(ControlCenterOperationRisk.file(alias.path, writing: true) == ["overwrite", "credentials"])
        let directoryAlias = root.appendingPathComponent("public-directory")
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: nested)
        #expect(ControlCenterOperationRisk.file(directoryAlias.path + "/../ordinary-name", writing: false) == ["credentials"])
        #expect(ControlCenterOperationRisk.file(directoryAlias.path + "/../missing-key", writing: true) == ["credentials"])
        #expect(ControlCenterOperationRisk.arguments(["cat", "public-name"], directory: root.path) == ["credentials"])
        let literalTilde = root.appendingPathComponent("~")
        try FileManager.default.createSymbolicLink(at: literalTilde, withDestinationURL: sensitive)
        #expect(ControlCenterOperationRisk.arguments(["cat", "~/ordinary-name"], directory: root.path) == ["credentials"])
        #expect(ControlCenterOperationRisk.shell("cat '~/ordinary-name'", directory: root.path) == ["credentials"])
    }
}
