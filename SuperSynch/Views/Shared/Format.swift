import Foundation
import SyncthingKit

/// Locale-aware formatting helpers.
enum Format {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(bytesPerSecond.rounded())
        return String(localized: "\(bytes.formatted(.byteCount(style: .file, spellsOutZero: false)))/s")
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func uptime(seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated,
                                                   maximumUnitCount: 2))
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never") }
        return date.formatted(.relative(presentation: .named))
    }
}
