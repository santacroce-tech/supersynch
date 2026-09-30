import SwiftUI
import SyncthingKit

/// Colour and iconography for sync states. Colours are semantic system
/// colours, so they adapt to Dark Mode and Increased Contrast.
struct StateStyle {
    let color: Color
    let systemImage: String
    let isActive: Bool

    init(_ state: FolderSyncState) {
        switch state {
        case .upToDate: self.init(.green, "checkmark.circle.fill")
        case .syncing: self.init(.blue, "arrow.triangle.2.circlepath.circle.fill", active: true)
        case .scanning: self.init(.teal, "magnifyingglass.circle.fill", active: true)
        case .waiting: self.init(.gray, "clock.fill")
        case .paused: self.init(.gray, "pause.circle.fill")
        case .error: self.init(.red, "exclamationmark.triangle.fill")
        case .outOfSync: self.init(.orange, "exclamationmark.circle.fill")
        case .unknown: self.init(.secondary, "questionmark.circle")
        }
    }

    init(_ state: DeviceSyncState) {
        switch state {
        case .upToDate: self.init(.green, "checkmark.circle.fill")
        case .syncing: self.init(.blue, "arrow.triangle.2.circlepath.circle.fill", active: true)
        case .disconnected: self.init(.secondary, "bolt.horizontal.circle")
        case .paused: self.init(.gray, "pause.circle.fill")
        case .unused: self.init(.secondary, "link.circle")
        }
    }

    private init(_ color: Color, _ systemImage: String, active: Bool = false) {
        self.color = color
        self.systemImage = systemImage
        self.isActive = active
    }
}

/// Icon + label for a state, animated (unless Reduce Motion is on) while active.
struct StateBadge: View {
    let label: String
    let style: StateStyle
    var showsLabel = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `.increased` on selected list rows, where tinted text would vanish.
    @Environment(\.backgroundProminence) private var prominence

    private var tint: Color { prominence == .increased ? .primary : style.color }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: style.systemImage)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: style.isActive && !reduceMotion)
                .accessibilityHidden(true)
            if showsLabel {
                Text(label)
                    .foregroundStyle(style.color == .secondary ? .secondary : tint)
            }
        }
        .font(.subheadline.weight(.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

extension StateBadge {
    init(_ state: FolderSyncState, showsLabel: Bool = true) {
        self.init(label: state.label, style: StateStyle(state), showsLabel: showsLabel)
    }

    init(_ state: DeviceSyncState, showsLabel: Bool = true) {
        self.init(label: state.label, style: StateStyle(state), showsLabel: showsLabel)
    }
}

/// Thin tinted progress bar with an accessible percentage.
struct CompletionBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        ProgressView(value: min(max(percent, 0), 100), total: 100)
            .tint(color)
            .accessibilityLabel(Text("Completion"))
            .accessibilityValue(Text(Format.percent(percent)))
    }
}

/// A label/value row used in detail screens.
struct InfoRow: View {
    let title: LocalizedStringKey
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
