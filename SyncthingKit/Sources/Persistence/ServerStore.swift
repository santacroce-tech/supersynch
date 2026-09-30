import Foundation
import Observation

/// A saved Syncthing instance. Non-secret; the API key lives in the Keychain
/// under `id.uuidString`.
public struct ServerConfig: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var baseURL: URL
    /// SHA-256 of the user-trusted certificate, if the server is self-signed.
    public var pinnedFingerprint: String?

    public init(id: UUID = UUID(), name: String, baseURL: URL, pinnedFingerprint: String? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.pinnedFingerprint = pinnedFingerprint
    }

    public var displayName: String { name.isEmpty ? (baseURL.host ?? baseURL.absoluteString) : name }
}

public enum ServerURL {
    /// Normalises user input: trims whitespace, defaults to `https://` when no
    /// scheme is given, drops query/fragment. Returns nil if unusable.
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.url
    }
}

/// The list of saved servers. Configs persist in `UserDefaults`; API keys in
/// the injected `SecretStore`.
@MainActor
@Observable
public final class ServerStore {
    public private(set) var servers: [ServerConfig] = []

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let storageKey = "servers.v1"

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        load()
    }

    public func server(id: UUID) -> ServerConfig? { servers.first { $0.id == id } }

    public func apiKey(for id: UUID) -> String? { try? secrets.secret(for: id.uuidString) }

    public func endpoint(for id: UUID) -> ServerEndpoint? {
        guard let server = server(id: id), let key = apiKey(for: id) else { return nil }
        return ServerEndpoint(baseURL: server.baseURL, apiKey: key, pinnedFingerprint: server.pinnedFingerprint)
    }

    /// Adds or replaces a server and its API key.
    public func save(_ server: ServerConfig, apiKey: String) throws {
        try secrets.setSecret(apiKey, for: server.id.uuidString)
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    public func remove(id: UUID) {
        try? secrets.removeSecret(for: id.uuidString)
        servers.removeAll { $0.id == id }
        persist()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { servers[$0] }
        var remaining = servers.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(0, insertAt), remaining.count))
        servers = remaining
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
