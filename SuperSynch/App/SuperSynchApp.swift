import SwiftUI
import SyncthingKit

@main
struct SuperSynchApp: App {
    @State private var app: AppModel = AppEnvironment.makeAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
        .onChange(of: scenePhase, initial: true) {
            // Long-polling stops in the background and resumes on foreground.
            app.setActive(scenePhase == .active)
        }
        .commands { ServerCommands() }
    }
}

enum AppEnvironment {
    /// `-DemoMode` launches against in-memory sample data (no network), for
    /// screenshots and UI checks in the simulator.
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-DemoMode") }

    @MainActor
    static func makeAppModel() -> AppModel {
        guard isDemo else { return AppModel(store: ServerStore()) }
        let suite = "demo"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ServerStore(defaults: defaults, secrets: InMemorySecretStore())
        try? store.save(ServerConfig(name: "Home NAS", baseURL: URL(string: "https://nas.local:8384")!), apiKey: "demo")
        try? store.save(ServerConfig(name: "VPS", baseURL: URL(string: "https://vps.example.com:8384")!), apiKey: "demo")
        return AppModel(store: store, defaults: defaults, clientFactory: { _ in MockSyncthingAPIClient(preloaded: MockData.state) })
    }
}
