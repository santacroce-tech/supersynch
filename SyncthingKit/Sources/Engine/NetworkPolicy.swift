import Foundation
import Network
import Observation

/// Decides whether syncing may use the current network: optionally only on
/// Wi-Fi/Ethernet (not cellular or personal hotspot), and optionally not
/// when iOS Low Data Mode is on.
@MainActor
@Observable
public final class NetworkPolicy {
    public var wifiOnly: Bool {
        didSet { defaults.set(wifiOnly, forKey: Keys.wifiOnly); changed() }
    }
    public var respectLowDataMode: Bool {
        didSet { defaults.set(respectLowDataMode, forKey: Keys.lowData); changed() }
    }

    public private(set) var isExpensive = false
    public private(set) var isConstrained = false

    /// Called on the main actor whenever `allowsSync` may have changed.
    public var onChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let monitor: NWPathMonitor?

    private enum Keys {
        static let wifiOnly = "network.wifiOnly"
        static let lowData = "network.respectLowDataMode"
    }

    /// - Parameter monitorPath: false in tests (no live network monitoring).
    public init(defaults: UserDefaults = .standard, monitorPath: Bool = true) {
        self.defaults = defaults
        wifiOnly = defaults.bool(forKey: Keys.wifiOnly)
        respectLowDataMode = defaults.object(forKey: Keys.lowData) as? Bool ?? true
        monitor = monitorPath ? NWPathMonitor() : nil
        monitor?.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in self?.update(expensive: expensive, constrained: constrained) }
        }
        monitor?.start(queue: DispatchQueue(label: "SuperSynch.network"))
    }

    deinit { monitor?.cancel() }

    /// For tests and previews.
    public func update(expensive: Bool, constrained: Bool) {
        guard expensive != isExpensive || constrained != isConstrained else { return }
        isExpensive = expensive
        isConstrained = constrained
        changed()
    }

    public var allowsSync: Bool {
        Self.allows(wifiOnly: wifiOnly, respectLowDataMode: respectLowDataMode, expensive: isExpensive, constrained: isConstrained)
    }

    /// Why syncing is paused, for display; nil when allowed.
    public var blockReason: String? {
        if allowsSync { return nil }
        if wifiOnly && isExpensive {
            return String(localized: "Paused on cellular. Syncing resumes on Wi-Fi (Settings › Network).", bundle: SyncthingKit.bundle)
        }
        return String(localized: "Paused while Low Data Mode is on.", bundle: SyncthingKit.bundle)
    }

    public nonisolated static func allows(wifiOnly: Bool, respectLowDataMode: Bool, expensive: Bool, constrained: Bool) -> Bool {
        if wifiOnly && expensive { return false }
        if respectLowDataMode && constrained { return false }
        return true
    }

    private func changed() { onChange?() }
}
