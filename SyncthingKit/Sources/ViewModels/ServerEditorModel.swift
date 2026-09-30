import Foundation
import Observation

/// Checks that an endpoint is a reachable, correctly-authenticated Syncthing
/// instance: `GET /rest/noauth/health`, then `/rest/system/status` and
/// `/rest/system/version`.
public struct ConnectionValidator: Sendable {
    public struct Result: Sendable, Equatable {
        public var status: SystemStatus
        public var version: SystemVersion
    }

    private let clientFactory: AppModel.ClientFactory

    public init(clientFactory: @escaping AppModel.ClientFactory = { SyncthingHTTPClient(endpoint: $0) }) {
        self.clientFactory = clientFactory
    }

    public func validate(_ endpoint: ServerEndpoint) async throws -> Result {
        let client = clientFactory(endpoint)
        let health = try await client.health()
        guard health.isOK else {
            throw SyncthingError.other(String(localized: "The server reports it is unhealthy (\(health.status)).",
                                              bundle: SyncthingKit.bundle))
        }
        async let status = client.systemStatus()
        async let version = client.systemVersion()
        return try await Result(status: status, version: version)
    }
}

/// Add/edit-server form state, including the self-signed certificate
/// trust-on-first-use flow.
@MainActor
@Observable
public final class ServerEditorModel {
    public var name: String
    public var urlText: String
    public var apiKey: String

    public private(set) var isValidating = false
    public private(set) var error: SyncthingError?
    /// Set when the server presents an unknown certificate; the view shows a
    /// confirmation sheet with its fingerprint.
    public var certificateToReview: CertificateInfo?
    public private(set) var certificateChanged = false
    public private(set) var validated: ConnectionValidator.Result?

    public let existingID: UUID?
    private var pinnedFingerprint: String?
    private let validator: ConnectionValidator

    public init(editing server: ServerConfig? = nil, apiKey: String = "", validator: ConnectionValidator = .init()) {
        existingID = server?.id
        name = server?.name ?? ""
        urlText = server?.baseURL.absoluteString ?? ""
        self.apiKey = apiKey
        pinnedFingerprint = server?.pinnedFingerprint
        self.validator = validator
    }

    public var isEditing: Bool { existingID != nil }

    public var canSubmit: Bool {
        !isValidating && ServerURL.normalize(urlText) != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var trustedFingerprint: String? { pinnedFingerprint }

    /// Validates the connection and, on success, saves to `store`. Returns the
    /// saved config, or nil if validation failed or a certificate needs review.
    public func validateAndSave(to store: ServerStore) async -> ServerConfig? {
        guard let url = ServerURL.normalize(urlText) else {
            error = .invalidURL
            return nil
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidating = true
        error = nil
        defer { isValidating = false }

        do {
            let result = try await validator.validate(ServerEndpoint(baseURL: url, apiKey: key, pinnedFingerprint: pinnedFingerprint))
            validated = result
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = ServerConfig(
                id: existingID ?? UUID(),
                name: trimmedName.isEmpty ? (url.host ?? url.absoluteString) : trimmedName,
                baseURL: url,
                pinnedFingerprint: url.scheme == "https" ? pinnedFingerprint : nil
            )
            do {
                try store.save(config, apiKey: key)
            } catch {
                self.error = .other(error.localizedDescription)
                return nil
            }
            return config
        } catch let e as SyncthingError {
            switch e {
            case .untrustedCertificate(let info):
                certificateChanged = false
                certificateToReview = info
            case .certificateChanged(let info):
                certificateChanged = true
                certificateToReview = info
            default:
                error = e
            }
            return nil
        } catch {
            self.error = SyncthingError(error)
            return nil
        }
    }

    /// The user confirmed the certificate: pin it and retry.
    public func trustReviewedCertificate(andSaveTo store: ServerStore) async -> ServerConfig? {
        guard let info = certificateToReview else { return nil }
        return await trust(info, andSaveTo: store)
    }

    /// Pins `info` and retries. Takes the certificate explicitly because the
    /// review sheet may already have cleared `certificateToReview`.
    public func trust(_ info: CertificateInfo, andSaveTo store: ServerStore) async -> ServerConfig? {
        pinnedFingerprint = info.sha256
        certificateToReview = nil
        return await validateAndSave(to: store)
    }

    public func rejectReviewedCertificate() {
        certificateToReview = nil
        error = .other(String(localized: "The certificate was not trusted, so the connection was not made.",
                              bundle: SyncthingKit.bundle))
    }

    /// Applies a scanned or pasted `{name,url,apiKey}` JSON payload.
    public func apply(importPayload text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ServerImportPayload.self, from: data) else { return false }
        if let n = payload.name { name = n }
        urlText = payload.url
        apiKey = payload.apiKey
        return true
    }
}

/// QR / clipboard import format: `{"name": "...", "url": "...", "apiKey": "..."}`.
public struct ServerImportPayload: Codable, Sendable, Equatable {
    public var name: String?
    public var url: String
    public var apiKey: String
}
