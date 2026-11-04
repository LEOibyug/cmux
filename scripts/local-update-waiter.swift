import AppKit
import Darwin
import Dispatch
import Foundation

struct LocalUpdatePlan: Decodable {
    let target: String
    let staged: String
    let bundleIdentifier: String
    let certificate: String
    let previousCDHash: String
    let sourceCommit: String
    let receipt: String
    let lock: String
}

@MainActor
final class LocalUpdateInstaller {
    private let plan: LocalUpdatePlan
    private let target: URL
    private let staged: URL
    private let requirement: String
    private var exitSources: [pid_t: any DispatchSourceProcess] = [:]
    private var installing = false

    init(planURL: URL) throws {
        let metadata = try FileManager.default.attributesOfItem(atPath: planURL.path)
        guard metadata[.ownerAccountID] as? UInt32 == getuid(),
              (metadata[.posixPermissions] as? UInt16 ?? 0) & 0o077 == 0,
              metadata[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "LocalUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Update plan is not an owner-only file"])
        }
        plan = try JSONDecoder().decode(LocalUpdatePlan.self, from: Data(contentsOf: planURL))
        target = URL(fileURLWithPath: plan.target).standardizedFileURL
        staged = URL(fileURLWithPath: plan.staged).standardizedFileURL
        guard plan.certificate.count == 40, plan.certificate.allSatisfy(\.isHexDigit),
              plan.bundleIdentifier.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
              target != staged, target.pathExtension == "app", staged.pathExtension == "app",
              staged.deletingLastPathComponent().lastPathComponent.hasPrefix(".cmux-local-update-"),
              staged.deletingLastPathComponent().deletingLastPathComponent() == target.deletingLastPathComponent() else {
            throw NSError(domain: "LocalUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid update identity or destination"])
        }
        requirement = "=certificate leaf = H\"\(plan.certificate)\" and identifier \"\(plan.bundleIdentifier)\""
    }

    private func command(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LocalUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Candidate signature verification failed"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeState(_ state: String, error: String? = nil) {
        var value: [String: Any] = ["state": state, "sourceCommit": plan.sourceCommit]
        if let error { value["error"] = error }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: plan.receipt), options: [.atomic])
        } catch {
            fputs("Could not write local update status\n", stderr)
        }
    }

    private var applicationIsRunning: Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: plan.bundleIdentifier).filter {
            // Signal zero only probes liveness; it never sends a signal to the app.
            Darwin.kill($0.processIdentifier, 0) == 0 || errno == EPERM
        }
        for application in running {
            let pid = application.processIdentifier
            guard exitSources[pid] == nil else { continue }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.exitSources.removeValue(forKey: pid)?.cancel()
                    self.attemptInstallation()
                }
            }
            exitSources[pid] = source
            source.resume()
        }
        // Cover an exit between the first liveness probe and source registration.
        return running.contains { Darwin.kill($0.processIdentifier, 0) == 0 || errno == EPERM }
    }

    private func finish(_ status: Int32) -> Never {
        for source in exitSources.values { source.cancel() }
        exit(status)
    }

    private func attemptInstallation() {
        guard !installing, !applicationIsRunning else { return }
        installing = true
        let descriptor = open(plan.lock, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            writeState("failed", error: "Another local update owns the installation lock")
            finish(1)
        }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard !applicationIsRunning else { installing = false; return }
        do {
            let manager = FileManager.default
            for url in [target, staged] {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      Bundle(url: url)?.bundleIdentifier == plan.bundleIdentifier else {
                    throw NSError(domain: "LocalUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Installation bundle identity changed"])
                }
            }
            let current = try command(["--display", "--verbose=4", target.path])
            guard current.split(separator: "\n").contains(Substring("CDHash=" + plan.previousCDHash)) else {
                throw NSError(domain: "LocalUpdate", code: 5, userInfo: [NSLocalizedDescriptionKey: "Installed application changed after update preparation"])
            }
            _ = try command(["--verify", "--deep", "--strict", "-R", requirement, staged.path])
            guard !applicationIsRunning else { installing = false; writeState("waiting_for_exit"); return }
            writeState("installing")
            guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = try command(["--verify", "--deep", "--strict", "-R", requirement, target.path])
            try manager.removeItem(at: staged)
            try manager.removeItem(at: staged.deletingLastPathComponent())
            writeState("installed")
            print("Local update installed; reopen cmux when ready.")
            finish(0)
        } catch {
            writeState("failed", error: error.localizedDescription)
            fputs("Local update stopped; previous bundle retained if the swap had not completed.\n", stderr)
            finish(1)
        }
    }

    func run(readyDescriptor: Int32) {
        writeState("waiting_for_exit")
        // The controller's readiness pipe is not our lifetime owner.
        _ = "READY\n".withCString { Darwin.write(readyDescriptor, $0, 6) }
        close(readyDescriptor)
        attemptInstallation()
        withExtendedLifetime(self) { dispatchMain() }
    }
}

@main
struct LocalUpdateMain {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 3, let readyDescriptor = Int32(CommandLine.arguments[2]) else {
            fputs("Usage: local-update-waiter <private-plan.json> <ready-fd>\n", stderr)
            exit(2)
        }
        signal(SIGPIPE, SIG_IGN)
        do {
            try LocalUpdateInstaller(planURL: URL(fileURLWithPath: CommandLine.arguments[1])).run(readyDescriptor: readyDescriptor)
        } catch {
            fputs("Local update could not start: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
