import Foundation
import Testing
@testable import CmuxComputerUse

@MainActor
struct ComputerUseHelperTrustTests {
    @Test func anUnsignedBundleInstallsNothingAndReportsUnavailable() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false }
        )
        defer { runtime.stopForTermination() }

        #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        #expect(runtime.helperAppURL == nil)
        #expect(runtime.helperUnavailableInThisBuild)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.installedHelperAppURL.path))
    }

    @Test func anUntrustedBundledHelperCannotReuseATrustedCachedCopy() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let destination = fixture.paths.installedHelperAppURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixture.files.bundle, to: destination)
        let destinationPath = destination.standardizedFileURL.path
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false },
            helperTrust: ComputerUseHelperTrust(isSigned: { $0.standardizedFileURL.path == destinationPath })
        )
        defer { runtime.stopForTermination() }

        #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        #expect(runtime.helperAppURL == nil)
        #expect(runtime.helperUnavailableInThisBuild)
    }
}
