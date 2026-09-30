import CryptoKit
import Foundation
import Security

/// Per-session TLS policy. Certificates the system trusts are accepted
/// normally. Otherwise the leaf certificate's SHA-256 must match the pin the
/// user confirmed for this server; anything else is rejected and recorded so
/// the client can offer the trust flow. TLS validation is never disabled.
final class TrustEvaluator: NSObject, URLSessionDelegate, @unchecked Sendable {
    struct Rejection: Sendable {
        var info: CertificateInfo
        var pinMismatch: Bool
    }

    private let pinnedFingerprint: String?
    private let lock = NSLock()
    private var lastRejection: Rejection?

    init(pinnedFingerprint: String?) {
        self.pinnedFingerprint = pinnedFingerprint?.uppercased()
    }

    /// Returns and clears the most recent rejection.
    func takeRejection() -> Rejection? {
        lock.lock(); defer { lock.unlock() }
        let r = lastRejection
        lastRejection = nil
        return r
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let info = Self.certificateInfo(for: trust, host: space.host) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if let pinnedFingerprint, pinnedFingerprint == info.sha256 {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        lock.lock()
        lastRejection = Rejection(info: info, pinMismatch: pinnedFingerprint != nil)
        lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    static func certificateInfo(for trust: SecTrust, host: String) -> CertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return certificateInfo(for: leaf, host: host)
    }

    static func certificateInfo(for certificate: SecCertificate, host: String) -> CertificateInfo {
        let der = SecCertificateCopyData(certificate) as Data
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
        return CertificateInfo(sha256: fingerprint(of: der), subject: subject, host: host)
    }

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}
