import SwiftUI
import SyncthingKit

@main
struct SuperSynchApp: App {
    @State private var app: AppModel = AppEnvironment.makeAppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundSync.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
        .onChange(of: scenePhase, initial: true) {
            let model = app
            switch scenePhase {
            case .active:
                BackgroundSync.cancelFinishing()
                Task { await model.setActive(true) }
            case .background:
                Task { await model.setActive(false) }
                // Keep syncing briefly, then stop cleanly and schedule
                // periodic background syncs.
                BackgroundSync.finishInBackground(model)
                BackgroundSync.schedule()
            default:
                break
            }
        }
        .commands { ServerCommands() }
    }
}

enum AppEnvironment {
    /// `-DemoMode` launches against in-memory sample data (no engine), for
    /// screenshots and UI checks in the simulator.
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-DemoMode") }

    @MainActor
    static func makeAppModel() -> AppModel {
        if isDemo {
            return AppModel(session: SyncSession(client: MockSyncthingAPIClient(preloaded: MockData.state)))
        }
        do {
            let model = AppModel(engine: try SyncEngine(deviceName: UIDevice.current.name))
            BackgroundSync.model = model
            return model
        } catch {
            return AppModel(session: SyncSession(client: MockSyncthingAPIClient()), setupError: error.localizedDescription)
        }
    }
}
