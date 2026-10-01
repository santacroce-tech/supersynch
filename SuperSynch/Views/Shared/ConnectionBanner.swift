import SwiftUI
import SyncthingKit

/// Explicit, human-readable engine status shown above content when
/// something isn't right.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let error = app.setupError {
            banner(color: .red, systemImage: "exclamationmark.triangle.fill") {
                Text("Syncthing couldn't be set up: \(error)")
            }
        } else if app.engine != nil, let reason = app.network.blockReason {
            banner(color: .orange, systemImage: "wifi.slash") { Text(reason) }
        } else if case .failed(let message)? = app.engine?.status {
            banner(color: .red, systemImage: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Syncthing failed to start").fontWeight(.semibold)
                    Text(message).font(.footnote)
                    Button("Try Again") { Task { await app.setActive(false); await app.setActive(true) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        } else if app.engine?.status == .starting || app.session.phase == .connecting {
            banner(color: .secondary, systemImage: nil) { Text("Starting Syncthing…") }
        } else if case .polling(let error) = app.session.phase {
            banner(color: .orange, systemImage: "antenna.radiowaves.left.and.right.slash") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live updates interrupted. Retrying…").fontWeight(.semibold)
                    Text(error.localizedDescription).font(.footnote)
                }
            }
        }
    }

    private func banner<Content: View>(color: Color, systemImage: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    func connectionBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
    }
}
