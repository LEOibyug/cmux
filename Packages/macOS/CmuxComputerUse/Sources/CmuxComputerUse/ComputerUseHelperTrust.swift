import Foundation
import Security

/// Accepts only the bundled helper signed by the running application's certificate.
public struct ComputerUseHelperTrust: Sendable {
    public static let bundleIdentifier = "com.cmuxterm.cua"

    private let isSigned: @Sendable (URL) -> Bool

    public init() {
        var code: SecCode?
        var staticCode: SecStaticCode?
        let certificate: Data?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           let information = Self.signingInformation(staticCode) {
            certificate = Self.certificate(in: information)
        } else {
            certificate = nil
        }
        self.init(isSigned: { url in
            guard let certificate else { return false }
            return Self.satisfiesRequirement(url, certificate: certificate)
        })
    }

    init(isSigned: @escaping @Sendable (URL) -> Bool) {
        self.isSigned = isSigned
    }

    func installSource(nested: URL?) -> URL? {
        guard let nested, isTrusted(nested) else { return nil }
        return nested
    }

    func isTrusted(_ url: URL) -> Bool {
        isSigned(url)
    }

    private static func satisfiesRequirement(_ url: URL, certificate: Data) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess,
              let information = signingInformation(code),
              information[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier else { return false }
        return Self.certificate(in: information) == certificate
    }

    private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess else { return nil }
        return information as? [String: Any]
    }

    private static func certificate(in information: [String: Any]) -> Data? {
        guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}
