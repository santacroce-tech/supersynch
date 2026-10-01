import BackgroundTasks
import SyncthingKit
import UIKit

/// iOS doesn't let apps run continuously in the background, so syncing
/// happens in three windows:
/// 1. While the app is open.
/// 2. Right after it's backgrounded: a background task keeps syncing until
///    everything is idle or iOS's grace period (~30 s) runs out.
/// 3. Periodically, when iOS grants background time: an app-refresh task
///    (short) and a processing task (longer; usually while charging).
@MainActor
enum BackgroundSync {
    static let refreshID = "xyz.santacroce.SuperSynch.refresh"
    static let processingID = "xyz.santacroce.SuperSynch.sync"

    /// Set at launch; background tasks need the model.
    static var model: AppModel?

    private static var finishTask: Task<Void, Never>?
    private static var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            MainActor.assumeIsolated { run(task, budget: .seconds(25)) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            MainActor.assumeIsolated { run(task, budget: .seconds(10 * 60)) }
        }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(processing)
    }

    /// Called when the app moves to the background.
    static func finishInBackground(_ model: AppModel) {
        guard model.engine != nil else { return }
        finishTask?.cancel()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish sync") {
            // Expiration: stop right away.
            Task { @MainActor in await stopAndEnd(model) }
        }
        finishTask = Task { @MainActor in
            let remaining = UIApplication.shared.backgroundTimeRemaining
            let budget = min(remaining.isFinite ? remaining - 5 : 25, 25)
            _ = await model.syncInBackground(until: Date(timeIntervalSinceNow: max(budget, 1)), settle: .seconds(1))
            guard !Task.isCancelled else { return }
            await stopAndEnd(model)
        }
    }

    /// Called when the app becomes active again before the window ended.
    static func cancelFinishing() {
        finishTask?.cancel()
        finishTask = nil
        endBackgroundTask()
    }

    private static func stopAndEnd(_ model: AppModel) async {
        if UIApplication.shared.applicationState != .active {
            await model.suspend()
        }
        endBackgroundTask()
    }

    private static func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private static func run(_ task: BGTask, budget: Duration) {
        schedule()
        guard let model else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            let seconds = Double(budget.components.seconds)
            let idle = await model.syncInBackground(until: Date(timeIntervalSinceNow: seconds))
            if UIApplication.shared.applicationState != .active { await model.suspend() }
            task.setTaskCompleted(success: idle)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                if UIApplication.shared.applicationState != .active { await model.suspend() }
                task.setTaskCompleted(success: false)
            }
        }
    }
}
