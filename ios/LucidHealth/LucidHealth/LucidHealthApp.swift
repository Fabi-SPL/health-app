import SwiftUI
import BackgroundTasks
import UserNotifications

extension Notification.Name {
    static let lucidReconnectBLE = Notification.Name("lucidReconnectBLE")
    /// Fired whenever auth state changes (sign-in success, token refresh, sign-out).
    /// Views observing isAuthenticated subscribe via .onReceive to re-render
    /// without needing SupabaseClient itself to be ObservableObject.
    static let lucidAuthChanged = Notification.Name("lucidAuthChanged")
    /// Fired when the high-frequency broadcast toggle flips. BLEManager listens
    /// and re-creates pushTimer with the appropriate interval (1s while
    /// broadcasting, 10s otherwise to save phone battery + bandwidth).
    static let lucidHFBToggleChanged = Notification.Name("lucidHFBToggleChanged")
    /// v154 smart-wake fire. NotificationListener posts this (with session_id +
    /// reason in userInfo) when the server writes the alarm nudge; BLEManager
    /// observes it and runs the strap-buzz actuator to actually wake him.
    /// Decoupled via NotificationCenter so the listener needs no BLEManager ref.
    static let lucidSmartWakeFire = Notification.Name("lucidSmartWakeFire")
    /// Posted by AppDelegate's UNUserNotificationCenterDelegate when the user
    /// taps the lock-screen "Stop Alarm" action (or the alarm notification
    /// itself) on a LUCID_ALARM-category alert. BLEManager observes this and
    /// kills every wake actuator — the kill switch the smart alarm never had.
    static let lucidStopAlarm = Notification.Name("lucidStopAlarm")
}

@main
struct LucidHealthApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var bleManager = BLEManager()
    @Environment(\.scenePhase) private var scenePhase

    /// Periodic auth refresh. Token expires after ~1h; refresh every 10 min
    /// while app is active so the user is never caught with an expired
    /// session when they open the app.
    @State private var authRefreshTimer: Timer?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .task {
                    await SupabaseClient.shared.signInIfNeeded()
                    NotificationCenter.default.post(name: .lucidAuthChanged, object: nil)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhase(newPhase)
                }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Re-run sign-in on every foreground transition. Cheap when token
            // is still valid (early-return inside ensureAuth) and refreshes
            // when expired.
            Task {
                await SupabaseClient.shared.signInIfNeeded()
                NotificationCenter.default.post(name: .lucidAuthChanged, object: nil)
            }
            // v154: reconcile the local smart-wake armed flag with server truth
            // on every foreground — clears it once the server session completes
            // (post-wake / next day), re-enabling the local light-sleep detector.
            Task { await bleManager.refreshSmartWakeStatus() }
            startAuthRefreshTimer()
        case .background, .inactive:
            stopAuthRefreshTimer()
        @unknown default:
            break
        }
    }

    private func startAuthRefreshTimer() {
        stopAuthRefreshTimer()
        authRefreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task {
                await SupabaseClient.shared.signInIfNeeded()
                NotificationCenter.default.post(name: .lucidAuthChanged, object: nil)
            }
        }
    }

    private func stopAuthRefreshTimer() {
        authRefreshTimer?.invalidate()
        authRefreshTimer = nil
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let bleRefreshTaskId   = "com.lucid.health.ble-keepalive"
    static let bleOvernightTaskId = "com.lucid.health.ble-overnight"

    private lazy var notifySupabase = SupabaseClient()
    private lazy var notificationListener = NotificationListener(supabase: notifySupabase)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bleRefreshTaskId, using: nil) { task in
            self.handleBLERefresh(task: task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bleOvernightTaskId, using: nil) { task in
            self.handleOvernightProcessing(task: task as! BGProcessingTask)
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { granted, error in
            print("Notification permission: \(granted ? "granted" : "denied") \(error?.localizedDescription ?? "")")
        }

        // "Stop Alarm" kill switch — the P0 fix. Every lock-screen alarm alert
        // (local smart alarm, v154 server smart-wake, nightly fallback, go-back
        // wake, smart-wake deadline backup) sets categoryIdentifier =
        // "LUCID_ALARM" so this button always shows. Merge via
        // getNotificationCategories so this never clobbers BiostateNotifier's
        // categories (registered later, on first HR tick) and vice versa —
        // mirrors the existing merge pattern in Services/BiostateNotifier.swift.
        let stopAction = UNNotificationAction(
            identifier: "STOP_ALARM", title: "Stop Alarm", options: [.destructive]
        )
        let alarmCategory = UNNotificationCategory(
            identifier: "LUCID_ALARM", actions: [stopAction],
            intentIdentifiers: [], options: []
        )
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.union([alarmCategory]))
        }

        notificationListener.start()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        guard content.categoryIdentifier == "LUCID_ALARM",
              response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            completionHandler()
            return
        }
        // Any tap except a bare swipe-to-dismiss counts as "he's dealing with
        // it" — both the destructive Stop Alarm button AND opening the app by
        // tapping the banner kill the buzz.
        NotificationCenter.default.post(
            name: .lucidStopAlarm, object: nil,
            userInfo: ["source": response.actionIdentifier]
        )
        // Hold the background execution window open past forceStopHaptics'
        // own ~0.5s internal delay chain so the BLE stop packets actually get a
        // chance to transmit before iOS can suspend the process again. Calling
        // completionHandler() immediately risks the app being frozen mid-write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            completionHandler()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBLERefresh()
        scheduleOvernightProcessing()
    }

    private func scheduleBLERefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bleRefreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            print("BLE keepalive schedule failed: \(error)")
        }
    }

    private func handleBLERefresh(task: BGAppRefreshTask) {
        scheduleBLERefresh()
        task.expirationHandler = { }
        NotificationCenter.default.post(name: .lucidReconnectBLE, object: nil)
        task.setTaskCompleted(success: true)
    }

    private func scheduleOvernightProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.bleOvernightTaskId)
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 1
        components.minute = 0
        var earliest = calendar.date(from: components) ?? Date()
        if earliest < Date() { earliest = calendar.date(byAdding: .day, value: 1, to: earliest)! }
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(request) } catch {
            print("Overnight BLE processing schedule failed: \(error)")
        }
    }

    private func handleOvernightProcessing(task: BGProcessingTask) {
        scheduleOvernightProcessing()
        task.expirationHandler = { }
        NotificationCenter.default.post(name: .lucidReconnectBLE, object: nil)
        task.setTaskCompleted(success: true)
    }
}
