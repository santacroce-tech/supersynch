import Foundation

/// Every failure the API layer surfaces, with a human-readable description.
public enum SyncthingError: Error, Sendable, Equatable {
    case invalidURL
    case unauthorized
    case notFound
    case server(status: Int, message: String)
    case timeout
    case offline
    case unreachable(host: String)
    case tlsFailure
    /// App Transport Security blocked plain HTTP to a non-local host.
    case plainHTTPNotAllowed
    /// The server presented a certificate that isn't trusted by the system and
    /// hasn't been pinned. The user may choose to trust it.
    case untrustedCertificate(CertificateInfo)
    /// A certificate was pinned for this server, but a different one was presented.
    case certificateChanged(CertificateInfo)
    case decoding(String)
    case cancelled
    case other(String)
}

extension SyncthingError: LocalizedError {
    private static func l(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: SyncthingKit.bundle)
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            Self.l("The server address is not a valid URL. Use a form like https://192.168.1.10:8384.")
        case .unauthorized:
            Self.l("The API key was rejected. Copy it again from the Syncthing web GUI under Actions → Settings → API Key.")
        case .notFound:
            Self.l("The server doesn't recognise this request. It may be running an unsupported Syncthing version.")
        case .server(let status, let message):
            message.isEmpty
                ? Self.l("The server returned an error (HTTP \(status)).")
                : Self.l("The server returned an error (HTTP \(status)): \(message)")
        case .timeout:
            Self.l("The server took too long to respond.")
        case .offline:
            Self.l("This device appears to be offline.")
        case .unreachable(let host):
            Self.l("Can't reach \(host). Check the address and port, and that Syncthing's GUI listens on a reachable interface (not only 127.0.0.1).")
        case .tlsFailure:
            Self.l("A secure connection couldn't be established. If the server uses plain HTTP, change the address to start with http://.")
        case .plainHTTPNotAllowed:
            Self.l("Plain HTTP is only allowed for local network addresses. Use https:// for remote servers.")
        case .untrustedCertificate:
            Self.l("The server's certificate isn't trusted. Review its fingerprint to trust it.")
        case .certificateChanged:
            Self.l("The server's certificate has changed since you trusted it. This could indicate an attack, or that the certificate was regenerated.")
        case .decoding(let detail):
            Self.l("The server's response couldn't be read (\(detail)).")
        case .cancelled:
            Self.l("The request was cancelled.")
        case .other(let message):
            message
        }
    }

    /// Whether retrying later might succeed (used by the live-update loop).
    public var isTransient: Bool {
        switch self {
        case .timeout, .offline, .unreachable, .server, .other, .decoding: true
        default: false
        }
    }
}

/// Details of a server certificate shown to the user before pinning.
public struct CertificateInfo: Sendable, Equatable, Hashable {
    /// SHA-256 over the DER-encoded leaf certificate, uppercase hex.
    public var sha256: String
    public var subject: String
    public var host: String

    public init(sha256: String, subject: String, host: String) {
        self.sha256 = sha256; self.subject = subject; self.host = host
    }

    /// Fingerprint grouped as `AB:CD:EF:…` for display.
    public var formattedFingerprint: String {
        stride(from: 0, to: sha256.count, by: 2).map { i -> String in
            let start = sha256.index(sha256.startIndex, offsetBy: i)
            let end = sha256.index(start, offsetBy: 2, limitedBy: sha256.endIndex) ?? sha256.endIndex
            return String(sha256[start..<end])
        }.joined(separator: ":")
    }
}
