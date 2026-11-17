internal import Foundation
internal import Darwin

/// Advisory reasons for explicit confirmation, never an execution prohibition or an OS permission check.
/// Stable identifiers: deletion, overwrite, privilege, permissions, system, credentials,
/// external, opaqueExecution. Results are unique and follow that order; empty is not a sandbox guarantee.
public enum ControlCenterOperationRisk {
    private static let reasonOrder = [
        "deletion", "overwrite", "privilege", "permissions", "system", "credentials", "external", "opaqueExecution"
    ]

    public static func shell(_ command: String, directory: String) -> [String] {
        ordered(inspectShell(command, directory: directory, depth: 0))
    }

    /// Entries are literal argv: shell metacharacters in an operand are not interpreted here.
    public static func arguments(_ arguments: [String], directory: String) -> [String] {
        ordered(inspect(arguments, directory: directory, depth: 0))
    }

    /// Only path metadata is inspected; no file contents or credentials are read.
    public static func file(_ path: String, writing: Bool) -> [String] {
        ordered(fileReasons((path as NSString).expandingTildeInPath, directory: FileManager.default.currentDirectoryPath, writing: writing))
    }

    private static func ordered(_ reasons: Set<String>) -> [String] {
        reasonOrder.filter { reasons.contains($0) }
    }

    private enum Token {
        case word(String)
        case separator
        case redirect(String)
    }

    // This is deliberately a lexer, not a shell parser. Any expansion, unsupported grammar,
    // or incomplete tokenization raises opaqueExecution even when recognizable words are retained.
    private static func lex(_ source: String) -> (tokens: [Token], opaque: Bool) {
        let characters = Array(source)
        var tokens: [Token] = []
        var word = ""
        var started = false
        var quote: Character?
        var opaque = false
        var index = 0
        func flush() {
            if started { tokens.append(.word(word)) }
            word = ""
            started = false
        }
        while index < characters.count {
            let character = characters[index]
            if quote == "'" {
                if character == "'" { quote = nil } else { word.append(character) }
            } else if character == "\\", quote != "'" {
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if quote == "\"", !["$", "`", "\"", "\\", "\n"].contains(next) {
                        word.append(character)
                    } else {
                        index += 1
                        if next != "\n" { word.append(next); started = true }
                    }
                } else { opaque = true }
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                else {
                    if character == "$" || character == "`" { opaque = true }
                    word.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character == "#", !started {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            } else if character == ";" || character == "\n" || character == "|" || character == "&" {
                flush()
                tokens.append(.separator)
                if index + 1 < characters.count, characters[index + 1] == character,
                   character == "|" || character == "&" { index += 1 }
            } else if character == ">" || character == "<" {
                // Descriptor prefixes must not become command words (2>/tmp/log).
                if started, !word.isEmpty, word.allSatisfy({ $0.isNumber }) { word = ""; started = false }
                flush()
                var operation = String(character)
                if index + 1 < characters.count, [character, "&", "|"].contains(characters[index + 1]) {
                    index += 1
                    operation.append(characters[index])
                }
                if operation == "<<" { opaque = true }
                tokens.append(.redirect(operation))
            } else if character.isWhitespace {
                flush()
            } else {
                if ["$", "`", "*", "?", "[", "]", "{", "}", "(", ")", "!", "^", "#", "~", "\u{0}"].contains(character) {
                    opaque = true
                }
                word.append(character)
                started = true
            }
            index += 1
        }
        if quote != nil { opaque = true }
        flush()
        return (tokens, opaque)
    }

    private static func inspectShell(_ source: String, directory: String, depth: Int) -> Set<String> {
        guard depth < 12 else { return ["opaqueExecution"] }
        let result = lex(source)
        var reasons: Set<String> = result.opaque ? ["opaqueExecution"] : []
        var words: [String] = []
        var redirect: String?
        var currentDirectory = directory
        func finish() {
            reasons.formUnion(inspect(words, directory: currentDirectory, depth: depth + 1))
            // A literal cd affects relative paths in subsequent simple commands. Other shell
            // directory manipulations are opaque rather than assumed to leave paths unchanged.
            if words.first == "cd", words.count == 2, !words[1].hasPrefix("-") {
                currentDirectory = absolute(words[1], directory: currentDirectory)
            }
            words.removeAll(keepingCapacity: true)
        }
        for token in result.tokens {
            switch token {
            case .word(let word):
                if let operation = redirect {
                    if word != "&1" && word != "&2" && word != "-" {
                        reasons.formUnion(fileReasons(word, directory: currentDirectory, writing: operation.hasPrefix(">")))
                    }
                    redirect = nil
                } else { words.append(word) }
            case .separator:
                if redirect != nil { reasons.insert("opaqueExecution"); redirect = nil }
                finish()
            case .redirect(let operation):
                if redirect != nil { reasons.insert("opaqueExecution") }
                if operation.hasPrefix(">"), operation != ">&" { reasons.insert("overwrite") }
                if operation == ">&" || operation == "<&" { reasons.insert("opaqueExecution") }
                redirect = operation
            }
        }
        if redirect != nil { reasons.insert("opaqueExecution") }
        finish()
        return reasons
    }

    private static func inspect(_ arguments: [String], directory: String, depth: Int) -> Set<String> {
        guard !arguments.isEmpty else { return [] }
        guard depth < 12, !arguments.contains(where: { $0.utf8.contains(0) }), !arguments[0].isEmpty else {
            return ["opaqueExecution"]
        }
        let executable = arguments[0]
        let name = (executable as NSString).lastPathComponent
        let args = Array(arguments.dropFirst())
        var reasons: Set<String> = []
        // An explicit arbitrary executable path can shadow a familiar utility. Only standard
        // OS utility directories receive the named-command classification without an opaque flag.
        if executable.contains("/"), !["/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/"].contains(where: { executable == $0 + name }) {
            reasons.insert("opaqueExecution")
        }
        if executable.contains("=") {
            reasons.insert("opaqueExecution")
            reasons.formUnion(inspect(args, directory: directory, depth: depth + 1))
            return reasons
        }
        if ["env", "command", "builtin", "exec", "nohup", "nice", "sudo", "doas", "time"].contains(name) {
            if name == "sudo" || name == "doas" { reasons.insert("privilege") }
            if name == "command", args.first == "-v" || args.first == "-V" { return reasons }
            var index = 0
            while index < args.count {
                let argument = args[index]
                if argument == "--" { index += 1; break }
                if argument.contains("="), name == "env" {
                    reasons.insert("opaqueExecution")
                    index += 1
                } else if argument.hasPrefix("-") {
                    let takesValue = name == "env" ? ["-u", "--unset", "-C", "--chdir"] :
                        (name == "sudo" || name == "doas" ? ["-u", "-g", "-h", "-p", "-C", "-T", "-r", "-t"] : ["-n"])
                    if takesValue.contains(argument), index + 1 < args.count {
                        if name == "env" { reasons.insert("opaqueExecution") }
                        index += 2
                    } else {
                        let simple = ["--", "-i", "--ignore-environment", "-p", "-n"]
                        if !simple.contains(argument) { reasons.insert("opaqueExecution") }
                        index += 1
                    }
                } else { break }
            }
            if index < args.count {
                let nested = Array(args[index...])
                if nested.first == "cd" { reasons.insert("opaqueExecution") }
                reasons.formUnion(inspect(nested, directory: directory, depth: depth + 1))
            } else if name != "env" { reasons.insert("opaqueExecution") }
            return reasons
        }
        if ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(name) {
            reasons.insert("opaqueExecution")
            if let index = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
               index + 1 < args.count {
                reasons.formUnion(inspectShell(args[index + 1], directory: directory, depth: depth + 1))
            }
            return reasons
        }
        switch name {
        case "rm", "rmdir", "unlink", "srm": reasons.insert("deletion")
        case "mv": reasons.formUnion(["deletion", "overwrite"])
        case "cp", "install", "dd", "truncate", "tee", "ditto": reasons.insert("overwrite")
        case "chmod", "chown", "chgrp", "chflags", "umask": reasons.insert("permissions")
        case "xattr":
            if args.contains(where: { $0.hasPrefix("-") && ($0.contains("w") || $0.contains("d") || $0.contains("c")) }) { reasons.insert("permissions") }
        case "defaults":
            if !["read", "read-type", "domains", "find", "help"].contains(args.first ?? "") { reasons.insert("system") }
        case "su": reasons.formUnion(["privilege", "opaqueExecution"])
        case "security": reasons.formUnion(["credentials", "system"])
        case "launchctl", "diskutil", "hdiutil", "csrutil", "spctl", "systemsetup", "networksetup", "pmset", "nvram", "reboot", "shutdown", "halt", "osascript", "kill", "killall", "pkill", "dscl", "dscacheutil", "softwareupdate":
            reasons.insert("system")
        case "git": reasons.formUnion(gitReasons(args))
        case "curl":
            if args.contains(where: { ["-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "--json"].contains($0) || $0.hasPrefix("--data=") || $0.hasPrefix("--upload-file=") || $0.hasPrefix("--form=") || ($0.hasPrefix("-d") && $0.count > 2) || ($0.hasPrefix("-T") && $0.count > 2) || ($0.hasPrefix("-F") && $0.count > 2) }) { reasons.insert("external") }
            if let index = args.firstIndex(of: "-X") ?? args.firstIndex(of: "--request"), index + 1 < args.count,
               !["GET", "HEAD", "OPTIONS"].contains(args[index + 1].uppercased()) { reasons.insert("external") }
            if args.contains(where: { $0.hasPrefix("--request=") || ($0.hasPrefix("-X") && $0.count > 2) }) { reasons.insert("external") }
            if args.contains(where: { ["-o", "-O", "--output", "--remote-name"].contains($0) || $0.hasPrefix("--output=") }) { reasons.insert("overwrite") }
            // Curl configuration files and exotic options can supply uploads or credentials.
            if args.contains(where: { ["-K", "--config"].contains($0) || $0.hasPrefix("--config=") || ($0.hasPrefix("-K") && $0.count > 2) }) { reasons.insert("opaqueExecution") }
            let readOptions = ["-s", "-S", "-sS", "-L", "-I", "-i", "-f", "-v", "--silent", "--show-error", "--location", "--head", "--include", "--fail", "--verbose", "--compressed", "--http1.1", "--http2", "--url", "--max-time", "--connect-timeout", "-m", "-A", "--user-agent", "-H", "--header", "-q", "--disable"]
            if args.contains(where: { $0.hasPrefix("-") && !readOptions.contains($0) }) { reasons.insert("opaqueExecution") }
        case "scp", "sftp", "rsync":
            reasons.formUnion(["external", "overwrite", "opaqueExecution"])
            if args.contains(where: { $0.hasPrefix("--delete") }) { reasons.insert("deletion") }
        case "gh", "npm", "pnpm", "yarn", "cargo", "docker", "podman", "twine":
            reasons.insert("opaqueExecution")
            if args.contains(where: { ["publish", "push", "upload", "release", "deploy", "create", "send"].contains($0) }) { reasons.insert("external") }
        case "find":
            reasons.insert("opaqueExecution")
            if args.contains("-delete") { reasons.insert("deletion") }
        case "date":
            if args.contains(where: { $0 == "-s" || $0.hasPrefix("--set") || $0.first?.isNumber == true }) { reasons.insert("system") }
            return reasons
        case "hostname":
            if args.contains(where: { !$0.hasPrefix("-") }) { reasons.insert("system") }
            return reasons
        case "printf":
            if args.first == "-v" { reasons.insert("opaqueExecution") }
            return reasons
        case "echo", "true", "false", ":", "pwd", "whoami", "id", "uname", "which", "type":
            return reasons
        case "cd":
            if args.count != 1 || args[0].hasPrefix("-") { reasons.insert("opaqueExecution") }
        case "ls", "cat", "head", "tail", "less", "more", "wc", "sort", "uniq", "cut", "tr", "grep", "rg", "ag", "stat", "file", "du", "df", "tree", "readlink", "realpath", "diff", "cmp", "basename", "dirname": break
        default: reasons.insert("opaqueExecution")
        }
        if args.contains(where: { argument in
            ["--pre", "--compress-program", "--hostname-bin", "--pager"].contains(where: { argument == $0 || argument.hasPrefix($0 + "=") })
        }) {
            reasons.insert("opaqueExecution")
        }
        if ["less", "more"].contains(name), args.contains(where: { $0.hasPrefix("+") }) { reasons.insert("opaqueExecution") }
        if name == "sort", args.contains(where: { $0 == "-o" || $0 == "--output" || $0.hasPrefix("--output=") || ($0.hasPrefix("-o") && $0.count > 2) }) { reasons.insert("overwrite") }
        if name == "uniq", args.filter({ !$0.hasPrefix("-") }).count > 1 { reasons.insert("overwrite") }
        if name == "file", args.contains(where: { $0 == "-C" || $0 == "--compile" }) { reasons.insert("overwrite") }
        if !["echo", "printf"].contains(name), args.contains(where: credentialOption) { reasons.insert("credentials") }
        if ["curl", "wget"].contains(name), args.contains(where: { $0.hasPrefix("-u") }) { reasons.insert("credentials") }
        if ["ssh", "scp", "sftp"].contains(name), args.contains("-i") { reasons.insert("credentials") }
        // Scan literal path operands, including option=value and @file upload forms. This is
        // path metadata only; unknown commands already require confirmation independently.
        var skipPattern = ["grep", "rg", "ag"].contains(name) && !args.contains(where: { $0 == "-e" || $0 == "--regexp" || $0 == "-f" || $0 == "--file" })
        for argument in args {
            let candidate: String
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                candidate = String(argument[argument.index(after: equals)...])
            } else if argument.hasPrefix("@") { candidate = String(argument.dropFirst()) }
            else if argument.hasPrefix("-") { continue }
            else { candidate = argument }
            if skipPattern, !argument.hasPrefix("-") { skipPattern = false; continue }
            if candidate.isEmpty { continue }
            reasons.formUnion(fileReasons(candidate, directory: directory, writing: !reasons.isDisjoint(with: ["deletion", "overwrite", "permissions"])))
        }
        return reasons
    }

    private static func credentialOption(_ argument: String) -> Bool {
        let option = argument.lowercased().split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        return ["--password", "--passwd", "--token", "--access-token", "--api-key", "--apikey", "--secret", "--client-secret", "--credential", "--credentials", "--oauth2-bearer", "--user", "--proxy-user", "--netrc", "--netrc-file", "--cert", "--key", "--identity-file"].contains(option)
            || argument.lowercased().contains("authorization:")
    }

    private static func gitReasons(_ args: [String]) -> Set<String> {
        var reasons: Set<String> = []
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let option = args[index]
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(option) {
                if option == "-c" { reasons.insert("opaqueExecution") }
                index += 2
            } else {
                if !["--no-pager", "--paginate", "--no-optional-locks", "--literal-pathspecs"].contains(option) { reasons.insert("opaqueExecution") }
                index += 1
            }
        }
        guard index < args.count else { return reasons.union(["opaqueExecution"]) }
        let command = args[index]
        let operands = Array(args.dropFirst(index + 1))
        switch command {
        case "push", "send-email", "request-pull": reasons.insert("external")
        case "reset", "clean", "rm", "restore", "checkout", "rebase", "revert", "filter-branch", "prune", "gc": reasons.insert("deletion")
        case "branch", "tag":
            if operands.contains(where: { ["-d", "-D", "--delete", "-f", "--force"].contains($0) }) { reasons.insert("deletion") }
            else if !operands.isEmpty { reasons.insert("opaqueExecution") }
        case "config":
            if !operands.contains(where: { ["--get", "--get-all", "--get-regexp", "--list", "-l", "get", "list"].contains($0) }) { reasons.insert("overwrite") }
            if operands.contains(where: { $0.lowercased().contains("credential") }) { reasons.insert("credentials") }
        case "credential", "credential-store", "credential-cache": reasons.formUnion(["credentials", "opaqueExecution"])
        case "status", "diff", "log", "show", "rev-parse", "rev-list", "ls-files", "ls-tree", "blame", "describe", "shortlog": break
        default: reasons.insert("opaqueExecution")
        }
        if operands.contains(where: { $0.hasPrefix("--exec") || $0 == "--ext-diff" || $0 == "--textconv" || $0.hasPrefix("--output") }) { reasons.insert("opaqueExecution") }
        return reasons
    }

    private static func absolute(_ path: String, directory: String) -> String {
        if path.hasPrefix("/") { return path }
        return (directory as NSString).appendingPathComponent(path)
    }

    private static func resolved(_ path: String) -> String {
        // realpath preserves symlink/.. traversal order. Missing final components are appended
        // only after resolving the deepest existing ancestor; no content is ever opened.
        var ancestor = path
        var suffix: [String] = []
        while true {
            if let pointer = realpath(ancestor, nil) {
                let base = String(cString: pointer)
                free(pointer)
                return (suffix.reversed().reduce(base) { ($0 as NSString).appendingPathComponent($1) } as NSString).standardizingPath
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard parent != ancestor, !parent.isEmpty else { return (path as NSString).standardizingPath }
            suffix.append((ancestor as NSString).lastPathComponent)
            ancestor = parent
        }
    }

    private static func fileReasons(_ path: String, directory: String, writing: Bool) -> Set<String> {
        guard !path.isEmpty, path.utf8.count <= 16_384, !path.utf8.contains(0) else { return ["opaqueExecution"] }
        let requested = absolute(path, directory: directory)
        let candidates = [(requested as NSString).standardizingPath, resolved(requested)]
        var reasons: Set<String> = []
        for candidate in candidates {
            let lower = candidate.lowercased()
            let components = lower.split(separator: "/").map(String.init)
            let name = components.last ?? ""
            if components.contains(where: { [".ssh", ".aws", ".azure", ".gnupg", "keychains", ".kube", ".omp", ".codex", ".claude", ".gemini"].contains($0) })
                || ["/.config/gcloud", "/.config/gh", "/.config/omp", "/.local/share/keyrings"].contains(where: { lower.hasSuffix($0) || lower.contains($0 + "/") })
                || lower.contains("/.docker/config.json")
                || lower.contains("/.cmuxterm/omp-live-input/")
                || lower.hasSuffix("/controlcenter/connection.json")
                || [".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "credentials.json", "auth.json", "tokens.json", "secrets.json", "id_rsa", "id_ed25519", "id_ecdsa", "authorized_keys", "known_hosts"].contains(name)
                || name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".pem") || name.hasSuffix(".key")
                || lower.hasPrefix("/etc/sudoers.d/") || lower.hasPrefix("/private/etc/sudoers.d/")
                || ["/etc/shadow", "/etc/master.passwd", "/etc/passwd", "/etc/sudoers", "/private/etc/shadow", "/private/etc/master.passwd", "/private/etc/passwd", "/private/etc/sudoers"].contains(lower) {
                reasons.insert("credentials")
            }
            if writing, ["/system", "/library", "/applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var", "/var", "/dev"].contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }) {
                reasons.insert("system")
            }
            if writing, [".zshrc", ".zshenv", ".zprofile", ".bashrc", ".bash_profile", ".profile"].contains(name)
                || (writing && components.contains(where: { $0 == "launchagents" || $0 == "launchdaemons" })) { reasons.insert("system") }
        }
        if writing, FileManager.default.fileExists(atPath: requested) { reasons.insert("overwrite") }
        return reasons
    }
}
