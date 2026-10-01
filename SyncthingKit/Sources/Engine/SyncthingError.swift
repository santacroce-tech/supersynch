import Foundation

/// Failures surfaced by the embedded Syncthing engine, with human-readable text.
public enum SyncthingError: Error, Sendable, Equatable {
    /// The embedded node isn't running (starting up, stopped or backgrounded).
    case notRunning
    /// The engine rejected an operation; the message comes from Syncthing.
    case engine(String)
    /// Input the user entered isn't valid (e.g. a malformed device ID).
    case invalidInput(String)
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
        case .notRunning:
            Self.l("Syncthing isn't running right now.")
        case .engine(let message):
            message
        case .invalidInput(let message):
            message
        case .decoding(let detail):
            Self.l("Syncthing returned data that couldn't be read (\(detail)).")
        case .cancelled:
            Self.l("The operation was cancelled.")
        case .other(let message):
            message
        }
    }

    /// Whether retrying later might succeed (used by the live-update loop).
    public var isTransient: Bool {
        switch self {
        case .invalidInput, .cancelled: false
        default: true
        }
    }
}
