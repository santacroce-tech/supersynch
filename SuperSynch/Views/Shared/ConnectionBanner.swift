import SwiftUI
import SyncthingKit

/// Explicit, human-readable connection status shown above server content.
struct ConnectionBanner: View {
    let session: ServerSession
    var onEditServer: (() -> Void)?

    var body: some View {
        switch session.phase {
        case .live, .idle:
            EmptyView()
        case .connecting:
            banner(color: .secondary, systemImage: nil) {
                Text("Connecting to \(session.server.displayName)…")
            }
        case .polling(let error):
            banner(color: .orange, systemImage: "antenna.radiowaves.left.and.right.slash") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live updates interrupted. Retrying…").fontWeight(.semibold)
                    Text(error.localizedDescription).font(.footnote)
                }
            }
        case .failed(let error):
            banner(color: .red, systemImage: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Can't connect to \(session.server.displayName)").fontWeight(.semibold)
                    Text(error.localizedDescription).font(.footnote)
                    HStack {
                        Button("Retry") { session.stop(); session.start() }
                        if needsServerEdit(error), let onEditServer {
                            Button("Edit Server", action: onEditServer)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .shutDown:
            banner(color: .gray, systemImage: "power") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Syncthing was shut down. It must be started again on the host.")
                    Button("Reconnect") { session.start() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func needsServerEdit(_ error: SyncthingError) -> Bool {
        switch error {
        case .unauthorized, .untrustedCertificate, .certificateChanged, .invalidURL, .plainHTTPNotAllowed, .tlsFailure:
            true
        default:
            false
        }
    }

    private func banner<Content: View>(color: Color, systemImage: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Places the connection banner above any list content.
struct WithConnectionBanner: ViewModifier {
    let session: ServerSession
    var onEditServer: (() -> Void)?

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            ConnectionBanner(session: session, onEditServer: onEditServer)
                .padding(.horizontal)
                .padding(.bottom, 4)
                .background(.bar.opacity(session.phase == .live || session.phase == .idle ? 0 : 1))
        }
    }
}

extension View {
    func connectionBanner(_ session: ServerSession, onEditServer: (() -> Void)? = nil) -> some View {
        modifier(WithConnectionBanner(session: session, onEditServer: onEditServer))
    }
}
