import Foundation
import CoreBluetooth
import AVFoundation
import Combine
import UserNotifications
import ActivityKit
import WidgetKit
import UIKit

enum ConnectionState: String {
    case disconnected = "Disconnected"
    case scanning     = "Scanning..."
    case connecting   = "Connecting..."
    case connected    = "Connected"
    case syncing      = "Syncing history..."
    case streaming    = "Streaming"
}

class BLEManager: NSObject, ObservableObject {

    // MARK: - Published State
    @Published var connectionState: ConnectionState = .disconnected
    @Published var heartRate: Int = 0

    // Tonight's smart-alarm plan (Module 7 sync). Drives the alcohol UI + card.
    @Published var tonightPlanMode: String = "normal"
    @Published var tonightPlanNote: String = ""
    @Published var tonightWindowStart: Int = 0
    @Published var tonightWindowEnd: Int = 0

    // v154 Smart Wake — server-driven adaptive wake. When armed, the SERVER is
    // the primary wake trigger (it owns the hard sleep-need floor + never-in-deep
    // rule); the local light-sleep detector defers to it. Persisted so the flag
    // + logic survive an app relaunch during the night.
    static let smartWakeArmedKey = "lucid_smart_wake_armed"
    @Published var smartWakeArmed: Bool = UserDefaults.standard.bool(forKey: BLEManager.smartWakeArmedKey)
    @Published var smartWakePlan: SmartWakePlan?
    @Published var smartWakeStatus: SmartWakeStatus?

    @Published var battery: Double = 0
    @Published var deviceClock: Date?
    @Published var isWorn: Bool = false
    @Published var isCharging: Bool = false
    @Published var readingsToday: Int = 0
    @Published var lastSync: Date?
    @Published var historySyncProgress: String = ""
    @Published var historySyncCount: Int = 0
    @Published var skinTemperature: Double = 0
    private var skinTempHistory: [(temp: Double, time: Date)] = []

    /// Diagnostic surface for the skin-temp pipeline. Exposed via SettingsView's
    /// SkinTempDiagnosticsCard so Fabi can see what's arriving without log
    /// access. If `lastTempEventAt` is nil 5+ min after BLE connect → strap
    /// firmware doesn't send temp events. If `lastTempRawHex` is non-nil but
    /// `skinTemperature` is 0 → decoder failed → log raw and add fallback parse.
    @Published var lastTempEventAt: Date?
    @Published var lastTempRawHex: String?
    @Published var lastTempEventSource: String?  // "TEMPERATURE event" | "type-49 metadata"
    @Published var totalTempEventsReceived: Int = 0
    /// All type-49 packets observed, unconditional. Lets the diagnostics card
    /// distinguish "packets arrive but get gated by isDownloadingHistory" from
    /// "no packets at all". Counter increments BEFORE any state checks.
    @Published var totalType49PacketsSeen: Int = 0
    /// Mirror of isDownloadingHistory for the diagnostics card. If this stays
    /// true forever, the gate is stuck and skin-temp decoding is blocked.
    @Published var isHistorySyncing: Bool = false

    // MARK: - Manual 72h Backfill State
    //
    // User-triggered from Settings → "Backfill last 72h". Different from the
    // automatic post-reconnect sync because:
    //   - Window is fixed at 72h, not "since lastSync"
    //   - Uses the strap-embedded timestamps (not distributed across the gap)
    //   - Pre-fetches existing minute-buckets from Supabase to dedup
    //   - Writes with source = 'whoop_ble_backfill' so we can distinguish later
    @Published var manualBackfillState: String = "idle"        // idle | querying | requesting | parsing | uploading | done | failed
    @Published var manualBackfillProgress: String = ""
    @Published var manualBackfillResult: String = ""           // human-readable result line for UI
    @Published var historyFlushState: String = "idle"          // idle | erasing | done | failed
    @Published var historyFlushResult: String = ""             // human-readable result line for the flush escape-hatch
    private var isManualBackfillMode: Bool = false
    private var manualBackfillExistingMinutes: Set<Int> = []
    /// v137 — timestamp of the last AUTOMATIC history erase (stuck-cursor self-heal).
    /// Cooldown-guards autoEraseStuckHistory() so a wedged strap can't trigger an
    /// erase loop. Persisted so the cooldown survives app relaunch / overnight kills.
    private var lastAutoHistoryErase: Date = {
        let t = UserDefaults.standard.double(forKey: "lucid_last_auto_history_erase")
        return t > 0 ? Date(timeIntervalSince1970: t) : .distantPast
    }()
    private var manualBackfillWindowStart: Date = Date()
    private var manualBackfillWindowEnd: Date = Date()

    // MARK: - All-Streams Diagnostics (v70 — power-user always-on visibility)
    //
    // Counts every packet by `type` so the SettingsView "All Streams" card can
    // show what's actually arriving. After CMD 106 + 107 + 81 fire on connect,
    // we expect type-51 (IMU @ 52Hz), type-43 (raw PPG), and type-2 (HR) to
    // all increment continuously. If any stays at 0, that capability isn't
    // streaming on this firmware.
    @Published var packetTypeCounts: [Int: Int] = [:]
    @Published var packetTypeLastSeen: [Int: Date] = [:]
    @Published var sessionStartedAt: Date = Date()

    // MARK: - Debug Log (visible on screen)
    @Published var debugLog: [String] = []
    private let maxLogLines = 200
    private let appLaunchTime = Date()
    var sessionUptimeText: String {
        let s = Int(Date().timeIntervalSince(appLaunchTime))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        return "\(s/3600)h \((s%3600)/60)m"
    }

    // Health engine publishes its own state
    let healthEngine = HealthEngine()

    // Activity auto-detection engine
    let activityDetector = ActivityDetector()

    // MARK: - IMU State (stored here because extensions can't have stored properties)
    @Published var imuActive = false
    var imuSampleCount = 0
    var lastIMULog: Date?

    // MARK: - Packet Debug Capture (v68) — reverse-engineering toggle
    //
    // When `debugPacketCapture` is on, every parsed BLE packet is pushed to
    // `whoop_packet_debug` (grouped by `reSessionId`). Used to hunt unknown packet
    // types that might carry PPG / SpO2 / skin temp / etc.
    //
    // When `cmdSweepEnabled` is on, a curated probe sweep of untested opcodes
    // runs 15-60s after connect — responses land in whoop_events.
    //
    // Both default ON for now; can be toggled via UserDefaults in Settings UI later.
    //
    // NOTE: `reSessionId` is distinct from the class-level `sessionId` which is a
    // per-app-launch id used for continuous remote log flushing. `reSessionId`
    // regenerates on every BLE reconnect so packet_debug rows group cleanly per
    // connection session.
    var debugPacketCapture: Bool {
        UserDefaults.standard.object(forKey: "debug_packet_capture") as? Bool ?? true
    }
    var cmdSweepEnabled: Bool {
        UserDefaults.standard.object(forKey: "cmd_sweep_enabled") as? Bool ?? true
    }
    var reSessionId: String = UUID().uuidString
    var debugPacketsThisSession: Int = 0
    let maxDebugPacketsPerSession: Int = 15000  // hard cap — prevents runaway volume

    // v69 — realtime raw payload decimation. Push every Nth type-40 packet to
    // whoop_realtime_raw for offline correlation of undecoded data0/data1 fields.
    // HR arrives ~every 10s → every-6 decimation = roughly 1 row / minute.
    var realtimeRawSampleCounter: Int = 0
    let realtimeRawSampleEvery: Int = 6

    // MARK: - Manual Activity State (must be in main class body, not extension)
    @Published var manualActivityType: String? = nil
    @Published var manualActivityStart: Date? = nil

    // MARK: - Fallback Alarm ID (must be in main class body, not extension)
    let fallbackAlarmId = "lucid_fallback_alarm"

    // MARK: - Smart-wake actuator idempotency (double-fire prevention)
    // Set on EVERY wake-actuator fire (server nudge OR local light detection).
    // Any second entry within the window is skipped so he's never buzzed twice.
    private var lastActuatorFireAt: Date?
    private var lastActuatedSessionId: String?
    private let actuatorDedupWindow: TimeInterval = 8 * 60   // ~8 min
    private let smartWakeBackupId = "lucid_smartwake_backup"

    // MARK: - Sleep onset tracking (for sleep timing/consistency)
    private var lastSleepOnsetTime: Date?

    // MARK: - Live Activity + Widget sync
    private var currentLiveActivity: Activity<LucidActivityAttributes>?
    private var liveActivityStartTime: Date?
    private var lastLiveActivityState: LucidActivityAttributes.ContentState?
    private var lastLiveActivityUpdate: Date?
    private var sharedDataSyncCounter: Int = 0  // sync every N readings

    // MARK: - Supabase
    let supabase = SupabaseClient()


    // MARK: - CoreBluetooth (dedicated queue for background reliability)
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdToStrap: CBCharacteristic?
    private var connectionInitiated = false
    internal let bleQueue = DispatchQueue(label: "com.lucid.ble", qos: .userInitiated)

    // MARK: - Service/Characteristic UUIDs
    private let serviceUUID = CBUUID(string: WhoopUUID.service)
    private let cmdToStrapUUID = CBUUID(string: WhoopUUID.cmdToStrap)
    private let cmdFromStrapUUID = CBUUID(string: WhoopUUID.cmdFromStrap)
    private let eventsUUID = CBUUID(string: WhoopUUID.events)
    private let dataUUID = CBUUID(string: WhoopUUID.data)
    private let memfaultUUID = CBUUID(string: WhoopUUID.memfault)

    // IMU decimation buffer — iOS pulls 52Hz frames but pushes ~1Hz averaged to Supabase.
    // Flush every N frames or every N seconds, whichever comes first.
    private var imuBuffer: [WhoopProtocol.IMUFrame] = []
    private var lastImuFlush: Date = .distantPast
    private let imuFlushInterval: TimeInterval = 1.0   // 1 row per second
    private let imuFlushMaxFrames: Int = 60            // safety cap — never buffer more than ~1 sec at 52 Hz

    // Standard BLE Device Information Service (0x180A)
    private let deviceInfoServiceUUID = CBUUID(string: "180A")
    private let manufacturerUUID = CBUUID(string: "2A29")
    private let modelNumberUUID = CBUUID(string: "2A24")
    private let serialNumberUUID = CBUUID(string: "2A25")
    private let hardwareRevUUID = CBUUID(string: "2A27")
    private let firmwareRevUUID = CBUUID(string: "2A26")
    private let softwareRevUUID = CBUUID(string: "2A28")
    private let systemIdUUID = CBUUID(string: "2A23")

    // MARK: - Device Info (read from BLE 0x180A)
    @Published var deviceInfo: [String: String] = [:]

    // MARK: - Reconnect & Timeout
    private var reconnectTimer: Timer?
    private var connectTimeout: Timer?
    private let connectionTimeout: TimeInterval = 10

    // MARK: - Supabase push timer
    // v66 — pushInterval was 10s. Downstream consumers felt lagged because
    // realtime_health rows arrived once every 10s. Dropping to 1s keeps live
    // consumers in near-real-time (BLE strap samples at 1Hz so 1s push
    // interval matches the source rate). Cellular network adds 50-500ms;
    // total perceived latency now <2s.
    private var pushTimer: Timer?
    /// Push cadence is conditional on the high-frequency broadcast toggle:
    ///   • Broadcaster ON  → 1s (BLE-rate, near-real-time)
    ///   • Broadcaster OFF → 10s (battery + bandwidth conservation)
    /// UserDefaults mirror is kept in sync by BroadcastCard.saveHFB()
    /// and .load() — BLEManager re-reads on every timer rebuild, triggered by
    /// .lucidHFBToggleChanged notification.
    static let hfbBroadcastEnabledKey = "lucid_hfb_broadcast_enabled"
    private var pushInterval: TimeInterval {
        UserDefaults.standard.bool(forKey: Self.hfbBroadcastEnabledKey) ? 1.0 : 10.0
    }
    private var pendingReadings: [HRReading] = []
    // v141 — gates the opportunistic drain on the BLE wake path. Only ever
    // touched on bleQueue (append site + flush site), so no lock needed.
    private var lastFlush: Date = .distantPast
    // v98 — latest IMU values cached for realtime_health pushes. Without this,
    // realtime_health.accel_mag_mg / movement_score were always NULL even with
    // IMU streaming enabled, breaking the wake-up detector's movement signal.
    private var lastAccelMagMg: Int = 0
    private var lastMovementScore: Double = 0
    private var lastImuUpdate: Date = .distantPast

    // MARK: - History Download State
    private var isDownloadingHistory = false
    private var historyBuffer: [HRReading] = []
    private var historyBatchCount = 0
    private var historyRawCaptureCount = 0  // v113 — bounds raw-hex logging of history packets per sync
    private var historySyncTimer: DispatchSourceTimer?  // background-safe (was Timer on main runloop — frozen while suspended)
    private let lastSyncKey = "lucid_last_sync_timestamp"

    // MARK: - Strap Clock Offset (used for getClock response display)
    private var strapClockOffset: Int64 = 0

    // MARK: - Scan mode
    private var useServiceFilter = false

    // MARK: - Silent Audio Keep-Alive
    private var audioPlayer: AVAudioPlayer?
    private var silentAudioActive = false

    // MARK: - Double-Tap State (General Event Marker)
    @Published var lastDoubleTap: Date?
    @Published var doubleTapMessage: String = ""
    @Published var showDoubleTapSheet: Bool = false  // Triggers quick-action picker in UI
    private var doubleTapDebounce: Date = .distantPast
    private var pendingTapTimestamp: Date?       // Tap time for logging context
    private var lastFavoriteAutoLog: Date = .distantPast  // zero-tap favorite escalation window
    private var lastAutoDetectedActivity: Date = .distantPast  // When auto-detect last fired
    private var autoDetectStartTime: Date?  // When current auto-detected activity began

    // MARK: - Background Keepalive Watchdog
    private var lastDataReceived: Date = Date()
    private var watchdogTimer: DispatchSourceTimer?  // background-safe (was Timer on main runloop — frozen while suspended)
    private let watchdogInterval: TimeInterval = 30  // Check every 30s
    private let dataStaleThreshold: TimeInterval = 60  // If no data for 60s, poke connection

    // MARK: - Audio Keep-Alive Self-Healing
    // The silent-audio keep-alive dies when another app holds the audio session
    // (music while socializing, a call, Siri) and iOS never delivers a matching
    // .ended interruption. On .began we re-arm a backoff probe that retries
    // setActive(true) — fails while the other app holds audio, succeeds the
    // instant it frees, no reliance on the unreliable .ended callback.
    private var audioRecoveryTimer: DispatchSourceTimer?
    private let audioRecoveryQueue = DispatchQueue(label: "com.lucid.audioRecovery", qos: .utility)
    private let audioRecoveryInterval: TimeInterval = 5  // retry setActive every 5s while interrupted

    // MARK: - Battery Prediction
    @Published var batteryPrediction: String = ""
    private var batteryHistory: [(date: Date, level: Double)] = []
    private let batteryHistoryKey = "lucid_battery_history"

    /// Public read-only snapshot of battery history for diagnostics UI.
    var batteryHistorySnapshot: [(date: Date, level: Double)] { batteryHistory }
    /// Estimated drain per hour (% / hr), based on the last 4-12h of history.
    /// Negative = draining (normal). Positive = charging. nil if not enough samples.
    var batteryDrainPerHour: Double? {
        let now = Date()
        let recent = batteryHistory.filter { now.timeIntervalSince($0.date) < 12 * 3600 }
        guard recent.count >= 3 else { return nil }
        guard let oldest = recent.first, let newest = recent.last else { return nil }
        let dt = newest.date.timeIntervalSince(oldest.date) / 3600
        guard dt > 0.5 else { return nil }
        return (newest.level - oldest.level) / dt
    }

    // MARK: - Strain Limit
    private var strainAlertSent = false
    private let strainThreshold: Double = 14.0

    // MARK: - Battery Alert (once per depletion cycle, resets above 50%)
    private var batteryAlertSent = false
    // Strap buzz guard — same lifecycle as batteryAlertSent. Without this the
    // strap was vibrating non-stop because the buzz block (line 2506) was
    // firing every battery reading (every few seconds).
    private var lowBatteryBuzzSent = false

    // MARK: - Stored peripheral identifier for reconnection
    private let peripheralIdKey = "lucid_whoop_peripheral_id"

    // MARK: - Continuous Remote Logging
    private var logPushTimer: DispatchSourceTimer?
    private var logPushBuffer: [String] = []
    private let logPushInterval: TimeInterval = 120 // Push every 2 min
    private let logQueue = DispatchQueue(label: "com.lucid.logBuffer", qos: .utility)
    let sessionId = UUID().uuidString.prefix(8).lowercased()

    // MARK: - Combine cancellables (used for connectionState → widget sync)
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        supabase.onLog = { [weak self] msg in
            self?.log(msg)
        }

        // Wire activity detector
        activityDetector.bleManager = self

        // Cold-start baseline fetch — pull last-known scores from Supabase BEFORE
        // the strap connects so the dashboard + lock screen widgets aren't empty
        // on app launch. Previously fetchBaseline was only called on BLE connect,
        // which left all stats at 0 whenever the app was reopened without the
        // strap nearby.
        healthEngine.fetchBaseline(supabase: supabase)
        healthEngine.debugSupabase = supabase

        // When HealthEngine finishes restoring, push the fresh data into the
        // App Group so lock screen widgets can render immediately.
        NotificationCenter.default.addObserver(
            forName: .healthBaselineRestored,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncSharedHealthData()
            self?.log("Cold-start widget sync: shared health data written to App Group")
        }

        // High-frequency broadcast toggle observer — when Fabi flips the toggle
        // in Settings, restart pushTimer with the new interval (1s when on for
        // near-real-time, 10s when off to save battery+data).
        NotificationCenter.default.addObserver(
            forName: .lucidHFBToggleChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let enabled = UserDefaults.standard.bool(forKey: Self.hfbBroadcastEnabledKey)
            self.log("HFB toggle changed: broadcaster \(enabled ? "ON" : "OFF") → pushInterval \(self.pushInterval)s")
            // Restart timer only if currently streaming (otherwise it's already
            // invalidated and will pick up the new interval on next connect).
            if self.pushTimer != nil {
                self.startPushTimer()
            }
        }

        // Connection-state observer — every BLE transition flips
        // SharedHealthData.isConnected and reloads widgets so the lock-screen
        // "Bridge live/offline" pill updates within ~1s of a state change,
        // not 60s later when the next periodic sync fires. Only react to
        // distinct transitions (.removeDuplicates) to skip redundant writes.
        $connectionState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .dropFirst() // skip the initial .disconnected emission at init time
            .sink { [weak self] newState in
                guard let self = self else { return }
                self.log("Connection transition → \(newState.rawValue) — pushing widget sync")
                self.syncSharedHealthData()
                // 2026-04-27 — auto-start of bridge Live Activity removed
                // per user feedback ("we want the widget, not a fucking
                // activity thingy"). Lock-screen widgets are the canonical
                // surface; Live Activity stays for manual workout/sauna/etc.
                // The startBridgeActivityIfNeeded helper still exists in
                // case we want to bring back the bar behind a setting.
            }
            .store(in: &cancellables)

        // Smart alarm callback — progressive haptic ramp per wake-science research.
        // Start gentle (pattern 0 at -60s from "done"), escalate (pattern 1), peak
        // (pattern 2 twice tightly). Total arc ~90s. Matches dawn-simulation mechanism.
        healthEngine.onSmartAlarmTrigger { [weak self] stage in
            guard let self = self else { return }
            self.log("SMART ALARM! Stage: \(stage.rawValue) — progressive ramp")
            // v154 reconciliation: when a server smart-wake session owns tonight,
            // the SERVER is the primary trigger (it enforces the hard sleep-need
            // floor + never-in-deep rule the local detector doesn't know). Defer;
            // the scheduleFallbackAlarm net stays as the ultimate safety.
            if self.smartWakeArmed {
                self.evt("smart_alarm_defer", "reason=v154_armed stage=\(stage.rawValue)")
                return
            }
            // Idempotency: skip if any wake actuator already fired in the window
            // (guards the overlap right after a v154 fire, even once armed clears).
            if self.recentlyActuated() {
                self.evt("alarm_skip", "reason=recent-actuation stage=\(stage.rawValue)")
                return
            }
            self.markActuatorFired(sessionId: nil)
            // Strap-buzz + progressive haptic ramp (the tuned wake mechanism).
            self.fireWakeHapticRamp(reasonLabel: "stage=\(stage.rawValue)")
            // Cancel the fallback alarm — smart alarm fired, no need for safety net notification
            self.cancelFallbackAlarm()
            // Also send iOS notification so it shows on lock screen
            self.sendAlarmNotification(stage: stage)
        }

        // v154 server smart-wake: NotificationListener posts .lucidSmartWakeFire
        // when the server writes the alarm nudge. Run the SAME strap-buzz
        // actuator here (decoupled via NotificationCenter — no BLEManager ref in
        // the listener). Idempotent, so a 30s re-poll never re-buzzes.
        NotificationCenter.default.addObserver(
            forName: .lucidSmartWakeFire, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let sid = note.userInfo?["session_id"] as? String
            let reason = (note.userInfo?["reason"] as? String) ?? "unknown"
            self.log("Received .lucidSmartWakeFire — session=\(sid?.prefix(8) ?? "?") reason=\(reason)")
            self.runSmartWakeActuator(sessionId: sid, reason: reason)
        }

        // Round-alarm: SleepEngine calls this when it detects he's already awake,
        // so the pending noon fallback notification gets cancelled instead of
        // firing "good morning" at someone who's been up for hours.
        healthEngine.cancelFallbackCallback = { [weak self] in
            self?.cancelFallbackAlarm()
        }

        // Pre-alarm micro-ping callback — single gentle pulse 20-25 min before window.
        // Briefly arouses user → re-enter N1/N2 → guarantees clean light-sleep detection
        // window at the real wake time. Sundelin 2024 snooze mechanism.
        healthEngine.onPreAlarmMicroPing { [weak self] in
            guard let self = self else { return }
            self.log("PRE-ALARM MICRO-PING — single gentle pulse to seed N1 transition")
            self.sendHapticRaw(0)
            self.bleQueue.asyncAfter(deadline: .now() + 0.5) { self.forceStopHaptics() }
        }

        // Wake-up detection callback — notify Lucid for morning briefing
        healthEngine.onWakeUpDetected { [weak self] in
            guard let self = self else { return }
            self.log("WAKE-UP DETECTED — notifying Lucid for morning briefing")
            // Gentle buzz to confirm wake-up detected
            self.runHapticPattern(0)
            // Notify Supabase so the health engine can compute morning briefing
            self.supabase.notifyWakeUp { success in
                self.log("Wake-up notification to Lucid: \(success ? "OK" : "FAILED")")
            }
            // v111 (2026-05-27) — Alcohol detection moved server-side.
            // Postgres `detect_overnight_alcohol()` RPC runs in v106 sleep
            // detection and stamps `health_metrics.alcohol_impact`. The chip
            // already reads `scores["alcohol_impact"]` from the recompute
            // result above. iOS = stupid transmitter. No more `source='auto'`
            // activity writes from this path. Overnight buffer in
            // ActivityDetector.processReading still accumulates (harmless,
            // dormant — can be re-armed later if server detection regresses).
            // self.activityDetector.processWakeUp()

            // v100 architecture migration — sleep score + recovery are now
            // computed server-side. Local stamp the wake time for UI, then fire
            // the RPC. Other intelligence metrics (illness, training, etc.)
            // remain iOS-side and continue to feed the experimental columns
            // via upsertDailyMetrics below.
            self.healthEngine.sleepEndTime = Date()
            Task { [weak self] in
                guard let self = self else { return }
                if let result = await self.supabase.recomputeHealthMetrics() {
                    await MainActor.run {
                        self.healthEngine.applyServerRecompute(result)
                    }
                    self.log("[AutoWake] Server recompute → recovery=\(Int(result.recovery)) sleepScore=\(Int(result.sleepScore)) sleepHours=\(String(format: "%.1f", result.sleepHours))")
                } else {
                    self.log("[AutoWake] Server recompute failed — keeping local in-memory values")
                }
            }
            self.healthEngine.checkIllnessDeviation()
            self.healthEngine.updateTrainingLoad()
            self.healthEngine.computeNocturnalDip()
            self.healthEngine.checkOvertrainingRisk()
            self.healthEngine.computeSleepDebt()
            self.healthEngine.computeVO2max()

            // Check for alcohol impact if detected last night
            if self.activityDetector.detectionHistory.contains(where: { $0.type == "alcohol" }) {
                self.healthEngine.computeAlcoholImpact()
            }

            // Save sleep timing for consistency tracking
            if let sleepStart = self.lastSleepOnsetTime {
                self.healthEngine.saveSleepTiming(bedtime: sleepStart, waketime: Date())
            }

            // Push full daily health summary to Supabase (all intelligence metrics)
            let he = self.healthEngine
            // Use sleepingMinHR (tracked during non-awake stages) as the authoritative
            // resting HR — avoids the pre-sleep elevated HR corrupting the daily metric.
            let avgHR: Int
            if he.sleepingMinHR > 0 {
                avgHR = Int(he.sleepingMinHR)
            } else if !he.recentHR.isEmpty {
                avgHR = Int(he.recentHR.suffix(30).reduce(0, +) / Double(min(he.recentHR.count, 30)))
            } else {
                avgHR = Int(he.baselineRHR)
            }
            self.supabase.upsertDailyMetrics(
                restingHR: avgHR,
                hrvAvg: he.currentRMSSD,
                sleepHours: he.sleepDurationHours,
                deepMin: Int(he.stageMinutes[.deep] ?? 0),
                remMin: Int(he.stageMinutes[.rem] ?? 0),
                lightMin: Int(he.stageMinutes[.light] ?? 0),
                sleepStart: he.sleepStartTime,
                sleepEnd: he.sleepEndTime,
                recoveryScore: he.recoveryScore,
                strainScore: he.strainScore,
                respiratoryRate: he.respiratoryRate,
                bodyBattery: he.bodyBattery,
                sdnnAvg: he.sdnn,
                pnn50Avg: he.pnn50,
                dfaAlpha1Avg: he.dfaAlpha1,
                cognitiveCapacity: he.cognitiveCapacity,
                cognitiveLabel: he.cognitiveLabel,
                illnessRisk: he.illnessRisk,
                illnessAlert: he.illnessAlert,
                trainingMonotony: he.trainingMonotony,
                trainingStrain: he.trainingStrain,
                acwr: he.trainingLoadRatio,
                // New quick-win metrics
                poincaréSD1: he.poincaréSD1,
                poincaréSD2: he.poincaréSD2,
                poincaréRatio: he.poincaréRatio,
                nocturnalHRDip: he.nocturnalHRDip,
                sleepFragmentation: he.sleepFragmentationIndex,
                sleepDebt: he.sleepDebtHours,
                vo2max: he.vo2maxEstimate,
                overtrainingRisk: he.overtrainingRisk,
                alcoholImpact: he.lastAlcoholImpact,
                skinTemp: self.skinTemperature,
                awakeMin: Int(he.stageMinutes[.awake] ?? 0),
                readinessLevel: he.readiness.rawValue,
                readinessScore: he.cognitiveCapacity,
                strainPhysical: {
                    let total = max(1.0, he.zoneMinutes.map(Double.init).reduce(0, +))
                    let high = Double(he.zoneMinutes[2]) + Double(he.zoneMinutes[3]) + Double(he.zoneMinutes[4])
                    return round(he.strainScore * (high / total) * 10) / 10
                }(),
                strainStress: {
                    let total = max(1.0, he.zoneMinutes.map(Double.init).reduce(0, +))
                    let high = Double(he.zoneMinutes[2]) + Double(he.zoneMinutes[3]) + Double(he.zoneMinutes[4])
                    let physFrac = high / total
                    let dfaFrac = he.dfaAlpha1 > 0 ? max(0.0, min(0.5, (1.5 - he.dfaAlpha1) / 1.5)) : 0.2
                    let sPhysical = he.strainScore * physFrac
                    let sAutonomic = he.strainScore * dfaFrac * (1.0 - physFrac)
                    return round(max(0.0, he.strainScore - sPhysical - sAutonomic) * 10) / 10
                }(),
                strainAutonomic: {
                    let total = max(1.0, he.zoneMinutes.map(Double.init).reduce(0, +))
                    let high = Double(he.zoneMinutes[2]) + Double(he.zoneMinutes[3]) + Double(he.zoneMinutes[4])
                    let physFrac = high / total
                    let dfaFrac = he.dfaAlpha1 > 0 ? max(0.0, min(0.5, (1.5 - he.dfaAlpha1) / 1.5)) : 0.2
                    return round(he.strainScore * dfaFrac * (1.0 - physFrac) * 10) / 10
                }(),
                hrr1: Double(he.lastHRR1),
                hrr2: Double(he.lastHRR2)
            )
            self.log("Full daily health intelligence pushed to Supabase")

            // Reset sleep onset for next night
            self.lastSleepOnsetTime = nil

            // Push weekly report on Sundays
            let weekday = Calendar.current.component(.weekday, from: Date())
            if weekday == 1 {
                let report = self.healthEngine.generateWeeklyReport()
                self.supabase.pushBrainDump(content: report, tags: ["weekly-report", "health", "auto"])
                self.log("Weekly health report pushed")
            }
        }

        // Reset alarm daily
        healthEngine.resetAlarmForNewDay()

        // Start continuous remote logging
        startRemoteLogging()

        // Use dedicated BLE queue (not main) for background reliability
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.lucid.whoop-bridge",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )

        // Listen for background task reconnect triggers (posted by BGAppRefreshTask / BGProcessingTask)
        NotificationCenter.default.addObserver(forName: .lucidReconnectBLE, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.connectionState == .disconnected else { return }
            self.log("Background task triggered reconnect — scanning...")
            self.startScanning()
        }
    }

    // MARK: - Debug Logging

    func log(_ msg: String) {
        let ts = DateFormatter()
        ts.dateFormat = "HH:mm:ss"
        let line = "[\(ts.string(from: Date()))] \(msg)"
        print(line)
        logQueue.async { self.logPushBuffer.append(line) }
        DispatchQueue.main.async {
            self.debugLog.append(line)
            if self.debugLog.count > self.maxLogLines {
                self.debugLog.removeFirst()
            }
        }
    }

    func clearLog() {
        DispatchQueue.main.async {
            self.debugLog.removeAll()
        }
    }

    /// High-signal lifecycle event → bridge_logs, so any night is fully
    /// backtrackable (connect, disconnect, alarm execution, sync, app state).
    /// Prefixed "evt_" to filter cleanly from the history-sync debug noise.
    /// NOT for per-reading data — these are infrequent timeline markers.
    func evt(_ category: String, _ value: String = "") {
        log("\u{1F4CD} \(category) \(value)")
        supabase.pushDebugLog(key: "evt_\(category)", value: value)
    }

    /// Start periodic push of debug logs to Supabase.
    ///
    /// Uses DispatchSourceTimer on bleQueue instead of Timer.scheduledTimer.
    /// Timer requires an active RunLoop — when iOS backgrounds the app, the
    /// RunLoop pauses and logs never get flushed. DispatchSourceTimer fires
    /// on the BLE queue which stays alive during background CoreBluetooth
    /// sessions, so overnight logs actually reach Supabase.
    func startRemoteLogging() {
        logPushTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + logPushInterval, repeating: logPushInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Heartbeat: every flush, inject a status line so we can see
            // when the app was alive even if nothing else logs
            let hr = self.heartRate
            let conn = self.connectionState.rawValue
            let bat = Int(self.battery)
            let sleep = self.healthEngine.sleepDetected
            let uptime = self.sessionUptimeText
            self.log("💓 Heartbeat: \(conn) HR=\(hr) bat=\(bat)% sleep=\(sleep) up=\(uptime)")
            self.flushRemoteLogs()
        }
        timer.resume()
        logPushTimer = timer
    }

    /// Flush buffered logs to Supabase — thread-safe via logQueue
    func flushRemoteLogs() {
        logQueue.sync {
            guard !logPushBuffer.isEmpty else { return }
            let batch = logPushBuffer
            logPushBuffer.removeAll()
            supabase.pushAppLog(lines: batch, sessionId: String(sessionId))
        }
    }

    // MARK: - Silent Audio Keep-Alive

    // Battery: when disabled, rely on CoreBluetooth State Restoration alone — already wired
    // (CBCentralManagerOptionRestoreIdentifierKey at init + willRestoreState + aggressive
    // reconnect-on-disconnect). Default ON (no behavior change). Set UserDefaults
    // "lucid_audio_keepalive_disabled" = true to validate burst-sync battery savings over one
    // night before fully removing the keep-alive. Restoration is the backstop either way.
    static var audioKeepAliveEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "lucid_audio_keepalive_disabled")
    }

    func startSilentAudio() {
        guard Self.audioKeepAliveEnabled else {
            log("Silent audio keep-alive disabled by setting — relying on CoreBluetooth state restoration")
            return
        }
        guard !silentAudioActive else { return }

        // Listen for audio interruptions (phone calls, Spotify, etc.)
        // Without this, the silent audio stops and iOS suspends BLE
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )

        // Media services can reset (rare, fatal): every audio object becomes
        // invalid and the silent player is dead PERMANENTLY unless we rebuild the
        // whole session. Without this observer that's a silent BLE-death path.
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil
        )

        // Audio ROUTE changes (a Bluetooth speaker the player was routed to gets grabbed
        // by another device, headphones unplugged): on .oldDeviceUnavailable iOS auto-PAUSES
        // our silent player with NO interruption notification — a silent keep-alive death.
        // This is the BT-speaker-handoff gap. Scoped to .oldDeviceUnavailable ONLY: our own
        // setCategory/setActive emit .categoryChange/.routeConfigurationChange, and rebuilding
        // on those would infinite-loop.
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Generate a tiny silent audio buffer instead of loading a file
            let sampleRate: Double = 44100
            let duration: Double = 1.0
            let numSamples = Int(sampleRate * duration)
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))!
            buffer.frameLength = AVAudioFrameCount(numSamples)
            // Buffer is already zeroed (silent)

            // Write to temp file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)

            audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
            audioPlayer?.numberOfLoops = -1  // Loop forever
            audioPlayer?.volume = 0.0
            audioPlayer?.play()

            silentAudioActive = true
            log("Silent audio keep-alive STARTED")
        } catch {
            log("Silent audio ERROR: \(error.localizedDescription)")
        }
    }

    func stopSilentAudio() {
        stopAudioRecoveryProbe()
        audioPlayer?.stop()
        audioPlayer = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        silentAudioActive = false
        log("Silent audio keep-alive STOPPED")
    }

    /// Re-activate silent audio after interruption ends (phone call, Spotify, etc.)
    /// Without this, BLE connection drops after hours because iOS suspends the app.
    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            log("Audio interrupted (another app took over) — starting self-healing reactivation probe")
            // Don't wait for .ended (Apple does NOT guarantee it fires). Retry
            // setActive on a background-safe timer until the session is ours again.
            startAudioRecoveryProbe()
        case .ended:
            log("Audio interruption ended — full restart of silent keep-alive")
            stopAudioRecoveryProbe()
            // Always do a clean stop + restart. Reusing the existing player is unreliable:
            // silentAudioActive can be true while the player is dead (race condition),
            // causing the keep-alive to silently fail and BLE to drop during overnight sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.stopSilentAudio()
                self.startSilentAudio()
            }
        @unknown default:
            break
        }
    }

    // MARK: - Audio Recovery Probe (background-safe)

    /// Retry AVAudioSession.setActive(true) on a background timer. While another
    /// app holds the audio session this throws every tick; the moment it frees,
    /// it succeeds and we rebuild the silent keep-alive — no reliance on .ended.
    private func startAudioRecoveryProbe() {
        guard Self.audioKeepAliveEnabled else { return }
        // ALL audioRecoveryTimer access is funneled onto audioRecoveryQueue. Without
        // this, the notification thread (.began/.ended), main (stopSilentAudio), and
        // the timer's own handler race on the non-atomic optional → ARC double-release
        // (use-after-free) in always-on overnight code. Serial queue = one writer.
        audioRecoveryQueue.async { [weak self] in
            guard let self = self else { return }
            self.audioRecoveryTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.audioRecoveryQueue)
            timer.schedule(deadline: .now() + self.audioRecoveryInterval, repeating: self.audioRecoveryInterval)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    // Session reclaimed — cancel inline (already on-queue), then rebuild
                    // on main. startSilentAudio re-creates and .play()s the player, so
                    // liveness is restored there (not merely trusting setActive success).
                    self.log("Audio session reclaimed — rebuilding silent keep-alive")
                    self.audioRecoveryTimer?.cancel()
                    self.audioRecoveryTimer = nil
                    DispatchQueue.main.async {
                        self.stopSilentAudio()
                        self.startSilentAudio()
                    }
                } catch {
                    // Still held by an exclusive app (call/Siri) — keep probing until it frees.
                }
            }
            timer.resume()
            self.audioRecoveryTimer = timer
        }
    }

    private func stopAudioRecoveryProbe() {
        audioRecoveryQueue.async { [weak self] in
            guard let self = self else { return }
            self.audioRecoveryTimer?.cancel()
            self.audioRecoveryTimer = nil
        }
    }

    /// Media services reset — every audio object is now invalid. Rebuild the
    /// entire silent keep-alive from scratch or BLE dies permanently.
    @objc private func handleMediaServicesReset(_ notification: Notification) {
        log("⚠️ Media services were reset — rebuilding audio keep-alive from scratch")
        stopAudioRecoveryProbe()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioPlayer = nil          // old player object is invalid after reset
            self.silentAudioActive = false
            self.startSilentAudio()
        }
    }

    /// Audio output route changed. On .oldDeviceUnavailable (the Bluetooth speaker /
    /// headphones the silent player was routed to went away — e.g. another device grabbed
    /// the speaker) iOS auto-pauses playback with NO interruption notification, silently
    /// killing the keep-alive. Rebuild. Scoped to .oldDeviceUnavailable ONLY — our own
    /// setCategory/setActive emit .categoryChange/.routeConfigurationChange and rebuilding
    /// on those would loop.
    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable else { return }
        log("Audio route lost its output device (BT speaker handoff?) — rebuilding silent keep-alive")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.silentAudioActive else { return }
            self.stopSilentAudio()
            self.startSilentAudio()
        }
    }

    // MARK: - Background Watchdog (detects iOS throttling)

    private func startWatchdog() {
        // DispatchSourceTimer on bleQueue — NOT Timer.scheduledTimer. A main-runloop
        // Timer is frozen while the app is suspended, so the old watchdog could never
        // fire exactly when it was needed (overnight, app backgrounded). The BLE queue
        // stays alive during background CoreBluetooth sessions (same fix as the log timer).
        watchdogTimer?.cancel()
        lastDataReceived = Date()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            self?.checkDataFreshness()
        }
        timer.resume()
        watchdogTimer = timer
        log("Watchdog started (background-safe DispatchSourceTimer) — will detect data throttling")
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func checkDataFreshness() {
        let staleness = Date().timeIntervalSince(lastDataReceived)

        if staleness > dataStaleThreshold {
            log("WATCHDOG: No data for \(Int(staleness))s — iOS may be throttling BLE")

            // Strategy 0: the silent keep-alive may have silently died (player dead while
            // silentAudioActive=true, or output priority lost from a NON-mixable interruption
            // that never posted .began). The .began probe structurally can't see that case —
            // but if we're awake enough to run the watchdog, we can verify the player is
            // actually playing and rebuild if not.
            DispatchQueue.main.async {
                if self.silentAudioActive, self.audioPlayer?.isPlaying != true {
                    self.log("WATCHDOG: silent keep-alive player is dead — rebuilding")
                    self.stopSilentAudio()
                    self.startSilentAudio()
                }
            }

            // Strategy 1: Re-send the startHR command to wake up the data stream
            if let p = peripheral, let c = cmdToStrap, p.state == .connected {
                log("WATCHDOG: Re-sending startHR to wake data stream")
                p.writeValue(WhoopProtocol.startHRPacket(), for: c, type: .withResponse)

                // Strategy 2: Read RSSI to force iOS to maintain the connection priority
                p.readRSSI()
            } else if let p = peripheral, p.state != .connected {
                // Peripheral got disconnected silently
                log("WATCHDOG: Peripheral disconnected! Reconnecting...")
                immediateReconnect(to: p)
            }
        }
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            log("BT not ready (state: \(centralManager.state.rawValue))")
            return
        }
        DispatchQueue.main.async { self.connectionState = .scanning }

        // Start silent audio to keep app alive in background
        DispatchQueue.main.async { self.startSilentAudio() }

        if useServiceFilter {
            log("Scanning WITH service filter...")
            centralManager.scanForPeripherals(
                withServices: [serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        } else {
            log("Scanning ALL BLE devices (no filter)...")
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func startScanWithFilter() {
        useServiceFilter = true
        centralManager.stopScan()
        startScanning()
    }

    func startScanWithoutFilter() {
        useServiceFilter = false
        centralManager.stopScan()
        startScanning()
    }

    /// Manually trigger a history download from the strap buffer
    func syncHistory() {
        guard connectionState == .streaming || connectionState == .connected else {
            log("Can't sync — not connected (state: \(connectionState.rawValue))")
            return
        }
        // Stop live HR first
        if let p = peripheral, let c = cmdToStrap {
            p.writeValue(WhoopProtocol.stopHRPacket(), for: c, type: .withResponse)
        }
        pushTimer?.invalidate()
        flushReadings()

        log("Manual history sync triggered")
        bleQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startHistoryDownload()
        }
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        pushTimer?.invalidate()
        connectTimeout?.invalidate()
        if let p = peripheral {
            if let char = cmdToStrap {
                p.writeValue(WhoopProtocol.stopHRPacket(), for: char, type: .withResponse)
            }
            centralManager.cancelPeripheralConnection(p)
        }
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.stopSilentAudio()
        }
        log("Disconnected manually")
    }

    // MARK: - Connection Sequence

    private func runConnectionSequence() {
        guard let char = cmdToStrap, let p = peripheral else { return }

        // v138: anchor "when did this connection start?" at the top of the
        // sequence. The gap-check scopes the server cursor to rows older than
        // this, so handshake-window packets (stamped now() by the DB) can't
        // poison the staleness read. Captured by value into the +2.5s closure.
        let connectStart = Date()

        log("Step 1: Requesting battery...")
        p.writeValue(WhoopProtocol.batteryPacket(), for: char, type: .withResponse)

        bleQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("Step 2: Requesting clock...")
            p.writeValue(WhoopProtocol.clockPacket(), for: c, type: .withResponse)
        }

        bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("Step 3: Syncing strap clock to real time...")
            p.writeValue(WhoopProtocol.setClockPacket(), for: c, type: .withResponse)
        }

        bleQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("Step 4: Requesting device status...")
            p.writeValue(WhoopProtocol.helloHarvardPacket(), for: c, type: .withResponse)
        }

        bleQueue.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("Step 4b: Listing available haptic patterns...")
            p.writeValue(WhoopProtocol.listHapticsPacket(), for: c, type: .withResponse)
        }

        bleQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, let _ = self.peripheral, let _ = self.cmdToStrap else { return }

            // v138: SERVER-AUTHORITATIVE + FAIL-SAFE gap detection.
            //
            // Invariant: "every gap is permanent UNTIL the server PROVES recent
            // data." We skip backfill ONLY when the server can show a live
            // whoop_ble sample, captured BEFORE this connection, that is <=1 min
            // old. Every other path — no proof, first sync, cursor fetch failed —
            // downloads the strap buffer. The download is minute-deduped against
            // realtime_health (fetchMinutesWithData) and pushes real strap
            // timestamps, so an unnecessary re-download is cheap and idempotent,
            // while a silent SKIP is the exact regression that bit us on May 7 /
            // May 21 / Jun 13. Over-fetch beats under-fetch, always.
            //
            // The cursor is scoped to recorded_at < connectStart (handshake
            // packets get stamped now() and would otherwise look like fresh data).
            // The local UserDefaults timestamp is NO LONGER in the decision — it
            // is kept only in the shadow log as an audit of the old logic.
            let deviceId = self.peripheral?.identifier.uuidString ?? "unknown"
            let localLastSync = self.getLastSyncTimestamp()
            let localGapMin = Int(Date().timeIntervalSince(localLastSync) / 60)
            // Strap holds ~72h; on any "we can't prove freshness" path we pull the
            // whole buffer and let minute-dedup discard what's already covered.
            let fullBufferStart = Date().addingTimeInterval(-72 * 3600)

            Task { [weak self] in
                guard let self else { return }
                let cursor = await self.supabase.fetchSyncCursor(before: connectStart)
                let serverMins = cursor?.minutesSinceLast

                // Resolve the authoritative decision + the backfill start boundary.
                let usedSource: String
                let willDownload: Bool
                let gapMinutes: Int
                let gapStart: Date
                if let cursor, let mins = serverMins, let lastAt = cursor.lastRecordedAt {
                    // Server PROVED a pre-connect live sample. Skip only if fresh.
                    usedSource = "server"
                    gapMinutes = Int(mins)
                    willDownload = mins > 1
                    gapStart = lastAt
                } else if cursor != nil {
                    // Fetched OK but no live rows before connect = genuine first
                    // sync (or strap offline past retention). Pull the full buffer.
                    usedSource = "server_first_sync"
                    gapMinutes = Int(Date().timeIntervalSince(fullBufferStart) / 60)
                    willDownload = true
                    gapStart = fullBufferStart
                } else {
                    // FAIL-SAFE: cursor fetch failed (offline / captive wifi / 5xx —
                    // the exact 6am-reconnect scenario). NEVER silently skip.
                    usedSource = "cursor_unavailable_failsafe"
                    gapMinutes = Int(Date().timeIntervalSince(fullBufferStart) / 60)
                    willDownload = true
                    gapStart = fullBufferStart
                }

                // Shadow audit: would the legacy local-timestamp logic have skipped
                // here? A `disagree` with client=skip is precisely the silent miss
                // the old code shipped — surfaced now instead of swallowed.
                let clientDecision = localGapMin > 1 ? "download" : "skip"
                let serverDecision = willDownload ? "download" : "skip"
                let agree = clientDecision == serverDecision
                self.supabase.pushDebugLog(
                    key: "history_sync_shadow",
                    value: "agree=\(agree) used=\(usedSource) client=\(clientDecision) server=\(serverDecision) "
                         + "client_gap_min=\(localGapMin) server_mins=\(serverMins.map{ String(format: "%.1f", $0) } ?? "nil") "
                         + "device_id=\(deviceId.prefix(8))"
                )
                self.supabase.pushDebugLog(
                    key: "history_sync_gap_check",
                    value: "decision=\(willDownload ? "download" : "skip") gap_min=\(gapMinutes) source=\(usedSource) gap_start=\(Int(gapStart.timeIntervalSince1970))"
                )

                self.bleQueue.async { [weak self] in
                    guard let self, self.peripheral != nil, self.cmdToStrap != nil else { return }
                    if willDownload {
                        self.log("GAP/BACKFILL (\(usedSource)): \(gapMinutes) min — downloading history")
                        self.startHistoryDownload(overrideGapStart: gapStart)
                    } else {
                        self.log("No gap (\(usedSource), \(gapMinutes) min) — starting realtime HR...")
                        self.startRealtimeStreaming()
                    }
                }
            }
        }
    }

    private func startRealtimeStreaming() {
        guard let p = peripheral, let c = cmdToStrap else { return }
        p.writeValue(WhoopProtocol.startHRPacket(), for: c, type: .withResponse)
        DispatchQueue.main.async {
            self.connectionState = .streaming
            // Reset per-session packet counters so the diagnostics card shows
            // current streaming activity, not all-time totals.
            self.packetTypeCounts.removeAll()
            self.packetTypeLastSeen.removeAll()
            self.sessionStartedAt = Date()
        }
        startPushTimer()
        startWatchdog()
        // v97: Removed premature saveLastSyncTimestamp() here. Entering streaming
        // state ≠ data has flowed. If the strap reconnected but disconnected
        // before any HR row arrived, this used to save "now" as last-sync,
        // which then made the next reconnect's gap-check see no gap and skip
        // backfill entirely. Real save points: line 3626 (every data tick) and
        // line 1826 (on actual disconnect). May 7 silent backfill miss → fixed.
        log("STREAMING - HR data active!")

        // v66 — enable full signal capture. Stagger commands so the strap
        // has time to respond to each one without drops.
        bleQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66: Requesting firmware version (CMD 7)")
            p.writeValue(WhoopProtocol.firmwareVersionPacket(), for: c, type: .withResponse)
        }
        bleQueue.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66: Requesting extended battery (CMD 98)")
            p.writeValue(WhoopProtocol.extendedBatteryPacket(), for: c, type: .withResponse)
        }
        bleQueue.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66: Requesting body location (CMD 84)")
            p.writeValue(WhoopProtocol.bodyLocationPacket(), for: c, type: .withResponse)
        }
        bleQueue.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66: Enabling IMU stream (CMD 106)")
            p.writeValue(WhoopProtocol.toggleIMUPacket(enable: true), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(type: "probe_sent_cmd_106", data: ["purpose": "enable_imu_stream"])
        }

        // Empirical probes — send once on connect, log raw responses into whoop_events.
        bleQueue.asyncAfter(deadline: .now() + 3.4) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66 probe: GET_RESEARCH_PACKET (CMD 132)")
            p.writeValue(WhoopProtocol.getResearchPacket(), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(type: "probe_sent_cmd_132", data: ["purpose": "research_packet"])
        }
        bleQueue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66 probe: Labrador data gen (CMD 124 on)")
            p.writeValue(WhoopProtocol.labradorDataGenPacket(enable: true), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(type: "probe_sent_cmd_124", data: ["purpose": "labrador_data_gen_on"])
        }
        bleQueue.asyncAfter(deadline: .now() + 4.6) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66 probe: Labrador filtered (CMD 139 on)")
            p.writeValue(WhoopProtocol.labradorFilteredPacket(enable: true), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(type: "probe_sent_cmd_139", data: ["purpose": "labrador_filtered_on"])
        }
        // v68 — community RE (bWanShiTong, 2026) hypothesises CMD 107/108 are
        // required precursors to CMD 81. Send enable-optical-data → toggle-optical-mode → start-raw,
        // spaced enough that the AFE has time to warm up between state changes.
        bleQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v68 probe: ENABLE_OPTICAL_DATA (CMD 107)")
            p.writeValue(WhoopProtocol.enableOpticalDataPacket(enable: true), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(type: "probe_sent_cmd_107", data: ["purpose": "enable_optical_data"])
        }
        bleQueue.asyncAfter(deadline: .now() + 5.6) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v68 probe: TOGGLE_OPTICAL_MODE (CMD 108)")
            p.writeValue(WhoopProtocol.toggleOpticalModePacket(enable: true), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(type: "probe_sent_cmd_108", data: ["purpose": "toggle_optical_mode"])
        }
        // Raw optical stream — highest BLE bandwidth. Must come AFTER 107 + 108.
        bleQueue.asyncAfter(deadline: .now() + 6.2) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v66 probe: START_RAW_DATA optical stream (CMD 81)")
            p.writeValue(WhoopProtocol.startRawOpticalPacket(), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(type: "probe_sent_cmd_81", data: ["purpose": "start_raw_optical"])
        }

        // v70 — Firmware 1.1.41 silently rejects cmd 106 (no response captured),
        // and cmds 81/107 ACK but never start streams. Hypothesis: firmware
        // added an auth gate or the payload format changed. Sweep cmd 106 with
        // alternate payload bytes to find the variant that elicits a response.
        // Spaced so each one's response can be observed independently.
        let cmd106Variants: [UInt8] = [0x02, 0x03, 0x05, 0x10, 0x80, 0xFF]
        for (i, val) in cmd106Variants.enumerated() {
            let delay = 8.0 + Double(i) * 1.2
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
                self.log("v70 fuzz: CMD 106 with payload 0x\(String(format: "%02x", val))")
                let payload = WhoopProtocol.buildRawCommandPacket(cmd: 106, data: Data([val]))
                p.writeValue(payload, for: c, type: .withResponse)
                self.supabase.pushWhoopEvent(
                    type: "fuzz_cmd_106",
                    data: ["payload_byte": Int(val), "iteration": i]
                )
            }
        }

        // v70 — Reorder probe: try START_RAW_DATA (81) BEFORE the optical
        // enable + toggle, see if order matters. Some firmware revisions
        // require raw-mode flag to be set first, then optical channel selected.
        bleQueue.asyncAfter(deadline: .now() + 16.0) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.log("v70 reorder probe: CMD 81 BEFORE 107/108 (alt sequence)")
            p.writeValue(WhoopProtocol.startRawOpticalPacket(), for: c, type: .withResponse)
        }
        bleQueue.asyncAfter(deadline: .now() + 16.6) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            p.writeValue(WhoopProtocol.enableOpticalDataPacket(enable: true), for: c, type: .withResponse)
        }
        bleQueue.asyncAfter(deadline: .now() + 17.2) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            p.writeValue(WhoopProtocol.toggleOpticalModePacket(enable: true), for: c, type: .withResponse)
            self.supabase.pushWhoopEvent(
                type: "probe_alt_sequence_81_107_108",
                data: ["purpose": "test_inverted_order"]
            )
        }

        // Silence detector — if no type-51 or type-43 arrives in the next 30s, log it.
        // Helps diagnose whether commands enabled the stream or not.
        bleQueue.asyncAfter(deadline: .now() + 35.0) { [weak self] in
            guard let self else { return }
            self.supabase.pushWhoopEvent(
                type: "stream_enable_checkpoint",
                data: [
                    "imu_samples_this_session": self.imuSampleCount,
                    "debug_packets_captured": self.debugPacketsThisSession,
                    "note": "if zero, CMD 106 did not enable IMU live streaming on this firmware"
                ]
            )
        }

        // v68 — kick off the CMD sweep 15s after streaming starts.
        // Every response lands in whoop_events; every resulting packet (if any)
        // lands in whoop_packet_debug. Mining ground for untested signals.
        runCommandSweep()

        // v69 — payload-variant scan 60s after connect. CMD 131/107/41 returned
        // status 0 on their initial probe — try different payloads to see which
        // (if any) unlock additional data flow.
        runPayloadVariantScan()
    }

    // MARK: - History Download (Gap Sync)

    // Store gap boundaries for timestamp distribution
    private var gapStartTime: Date = Date()
    private var gapEndTime: Date = Date()

    // MARK: - Manual 72h Backfill

    /// User-triggered from Settings. Pre-fetches the set of minutes already
    /// covered in realtime_health for the last 72h, then re-requests history
    /// from the strap. Records arriving in handleHistoryData are appended to
    /// historyBuffer as usual; the branch in finishHistoryDownload uses
    /// real strap timestamps + dedups against the existing minute set, then
    /// uploads via SupabaseClient.pushBackfillBatch.
    ///
    /// Safe to call when already streaming — strap will pause to dump history
    /// then resume. Caller should not invoke a second time while one is in
    /// flight (UI button disables itself via manualBackfillState).
    /// Send the strap's ERASE_HISTORY command (0x19) to wipe its internal flash
    /// buffer, then auto-kick a fresh 72h backfill once the strap has had a few
    /// seconds to process the erase.
    ///
    /// WHY THIS EXISTS: the strap can get stuck re-serving a dead ancient buffer
    /// region (off-wrist HR 1-7 from weeks ago). Every history request then returns
    /// out-of-range garbage and the drain never reaches "now" → 0 backfills for
    /// days. ERASE is the only documented escape (bWanShiTong RE). Destructive +
    /// irreversible, but that backlog is worthless off-wrist data so nothing real
    /// is lost. Live streaming is unaffected (live data never comes from the
    /// buffer). Manual-trigger only — never automatic.
    func flushHistoryBuffer() {
        guard let p = peripheral, let c = cmdToStrap, p.state == .connected else {
            DispatchQueue.main.async {
                self.historyFlushState = "failed"
                self.historyFlushResult = "Strap not connected — connect first."
            }
            return
        }

        DispatchQueue.main.async {
            self.historyFlushState = "erasing"
            self.historyFlushResult = ""
        }

        bleQueue.async { [weak self] in
            guard let self else { return }
            p.writeValue(WhoopProtocol.eraseHistoryPacket(), for: c, type: .withResponse)
            self.evt("history_erase_sent", "cmd=0x19 trigger=manual-flush")
            self.log("\u{26A0}\u{FE0F} ERASE_HISTORY (0x19) sent — wiping strap flash buffer")

            DispatchQueue.main.async {
                self.historyFlushState = "done"
                self.historyFlushResult = "Buffer wiped. Pulling fresh history in 5s…"
            }

            // Give the strap time to process the erase before re-dumping, then
            // auto-run the standard 72h backfill from a now-clean buffer.
            self.bleQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { self.manualBackfill72h() }
            }
        }
    }

    /// v137 — automatic sibling of flushHistoryBuffer(). Fired by the stuck-cursor
    /// detector in finishHistoryWithDedup (NOT the manual button). Sends ERASE 0x19
    /// to wipe the wedged buffer, then kicks a clean 72h pull once the strap settles
    /// so the read-cursor resets and the NEXT real gap drains correctly. No manual
    /// flush UI state — this is silent self-healing. Cooldown enforced by the caller.
    private func autoEraseStuckHistory() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard let p = self.peripheral, let c = self.cmdToStrap, p.state == .connected else {
                self.log("autoEraseStuckHistory: strap not connected — skipping erase")
                return
            }
            p.writeValue(WhoopProtocol.eraseHistoryPacket(), for: c, type: .withResponse)
            self.evt("history_erase_sent", "cmd=0x19 trigger=auto-stuck-cursor")
            self.log("\u{26A0}\u{FE0F} ERASE_HISTORY (0x19) sent automatically — wiping wedged buffer")
            self.bleQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { self.manualBackfill72h() }
            }
        }
    }

    func manualBackfill72h() {
        guard !isManualBackfillMode else {
            log("manualBackfill72h: already in progress — ignoring")
            return
        }
        guard let p = peripheral, let c = cmdToStrap else {
            DispatchQueue.main.async {
                self.manualBackfillState = "failed"
                self.manualBackfillResult = "Strap not connected — connect first."
            }
            return
        }

        isManualBackfillMode = true
        manualBackfillWindowEnd = Date()
        manualBackfillWindowStart = Date().addingTimeInterval(-72 * 3600)

        DispatchQueue.main.async {
            self.manualBackfillState = "querying"
            self.manualBackfillProgress = "Checking existing data…"
            self.manualBackfillResult = ""
        }

        self.supabase.pushDebugLog(key: "history_sync_request_sent", value: "trigger=manual-72h start=\(manualBackfillWindowStart.timeIntervalSince1970) end=\(manualBackfillWindowEnd.timeIntervalSince1970)")

        Task { [weak self] in
            guard let self else { return }
            // 1. Fetch the set of minutes already covered
            let existing = await self.supabase.fetchMinutesWithData(
                since: self.manualBackfillWindowStart,
                until: self.manualBackfillWindowEnd
            )
            self.manualBackfillExistingMinutes = existing
            let gapsMinutes = (72 * 60) - existing.count
            self.log("manualBackfill: \(existing.count) minutes have data, \(gapsMinutes) minutes are gaps to fill")
            self.supabase.pushDebugLog(key: "history_sync_dedup_set", value: "trigger=manual-72h minutes_with_data=\(existing.count) gaps_to_fill=\(gapsMinutes)")

            DispatchQueue.main.async {
                self.manualBackfillState = "requesting"
                self.manualBackfillProgress = "Asking strap for buffered history (\(gapsMinutes) min of gaps)…"
            }

            // 2. Trigger a fresh history request. finishHistoryDownload routes
            //    into finishHistoryWithDedup which handles both auto + manual
            //    via the isManualBackfillMode flag.
            self.bleQueue.async {
                self.isDownloadingHistory = true
                DispatchQueue.main.async { self.isHistorySyncing = true }
                self.historyBuffer.removeAll()
                self.historyBatchCount = 0
                self.gapStartTime = self.manualBackfillWindowStart
                self.gapEndTime = self.manualBackfillWindowEnd

                // 120s timeout — if strap is silent, finish gracefully
                self.armHistorySyncTimeout(trigger: "manual-72h")

                // v113 — preamble-ordered request (CMD 7→35→10→22) replaces the bare
                // CMD 22 that raced the hello handshake on firmware 41.x.
                self.sendHistoryRequestWithPreamble(p, c, trigger: "manual-72h")
            }
        }
    }

    /// v114 — REVERTED the v113 preamble. Live logs proved it was a REGRESSION:
    /// the re-sent helloHarvard (CMD 35) mid-session caused the strap to accept the
    /// request (sent batch START) then go SILENT — zero data packets, no END marker
    /// — until the 120s timeout. The pre-v113 bare CMD 22 at least cycled 68
    /// START/END batches. Theory: re-sending hello resets the strap's GATT notify
    /// state, so every notification after START is lost. runConnectionSequence
    /// already sends the 7→35→10 handshake ONCE at connect — that is the correct
    /// place; we must NOT re-send it per history request. So this now sends the bare
    /// history request (the known-cycling baseline) and just resets the raw-capture
    /// counter. Name kept to avoid churning the two call sites.
    private func sendHistoryRequestWithPreamble(_ p: CBPeripheral, _ c: CBCharacteristic, trigger: String) {
        historyRawCaptureCount = 0
        p.writeValue(WhoopProtocol.requestHistoryPacket(), for: c, type: .withResponse)
        supabase.pushDebugLog(key: "history_request_sent_bare", value: "trigger=\(trigger) v114 bare-cmd22 (preamble reverted)")
        log("History request (bare CMD 22) sent [\(trigger)] — waiting for strap…")
    }

    private func startHistoryDownload(overrideGapStart: Date? = nil) {
        guard peripheral != nil, cmdToStrap != nil else {
            log("History download skipped — no peripheral/char")
            startRealtimeStreaming()
            return
        }

        // Record gap boundaries — used for both timestamp validation
        // and as the dedup window when fetching existing minutes.
        // v137: prefer the server-derived gap start (last MAX(recorded_at)) when the
        // caller resolved one; the local timestamp is the offline fallback only.
        gapStartTime = overrideGapStart ?? getLastSyncTimestamp()
        gapEndTime = Date()
        let gapMinutes = Int(gapEndTime.timeIntervalSince(gapStartTime) / 60)
        log("Gap: \(gapMinutes) min (\(gapStartTime) → \(gapEndTime))")

        isDownloadingHistory = true
        DispatchQueue.main.async { self.isHistorySyncing = true }
        historyBuffer.removeAll()
        historyBatchCount = 0

        DispatchQueue.main.async {
            self.connectionState = .syncing
            self.historySyncCount = 0
            self.historySyncProgress = "Requesting history..."
        }

        // Pre-fetch the dedup set BEFORE asking the strap for history. Avoids
        // a race where the strap responds before our async fetch completes.
        // (manualBackfillExistingMinutes is shared with the manual flow but
        // isManualBackfillMode is false here so the finalizer treats it as auto.)
        Task { [weak self] in
            guard let self else { return }
            // Must cover the same depth the finalizer now accepts (96h), not just
            // the gap window. A dedup set narrower than the accept window would let
            // already-stored minutes re-upload as duplicates.
            let existing = await self.supabase.fetchMinutesWithData(
                since: Date().addingTimeInterval(-96 * 3600),
                until: self.gapEndTime
            )
            self.manualBackfillExistingMinutes = existing
            self.supabase.pushDebugLog(key: "history_sync_dedup_set", value: "trigger=auto-reconnect minutes_with_data=\(existing.count) gap_min=\(gapMinutes)")
            self.log("Auto-sync: \(existing.count) of \(gapMinutes) minutes already covered, will dedup against this")

            // Now safe to send the request — finalizer has a populated dedup set
            self.supabase.pushDebugLog(key: "history_sync_request_sent", value: "trigger=auto-reconnect gap_min=\(gapMinutes) start=\(self.gapStartTime.timeIntervalSince1970) end=\(self.gapEndTime.timeIntervalSince1970)")

            // Timeout watchdog — set up here so it doesn't fire before we even sent
            self.armHistorySyncTimeout(trigger: "auto-reconnect")

            self.bleQueue.async {
                guard let p = self.peripheral, let c = self.cmdToStrap else {
                    self.log("Auto-sync: peripheral disappeared before send — bailing")
                    self.isDownloadingHistory = false
                    DispatchQueue.main.async { self.isHistorySyncing = false }
                    self.bleQueue.async { self.startRealtimeStreaming() }
                    return
                }
                // v113 — preamble-ordered request (CMD 7→35→10→22) replaces the bare
                // CMD 22 that raced the hello handshake on firmware 41.x.
                self.sendHistoryRequestWithPreamble(p, c, trigger: "auto-reconnect")
            }
        }
    }

    /// One-shot 120s history watchdog, on bleQueue rather than the main runloop.
    /// A main-runloop Timer is frozen while the app is suspended, so a background
    /// sync that stalled never finalized — and since startRealtimeStreaming() is
    /// only reached from the finalizer, live HR was lost for the whole connection.
    private func armHistorySyncTimeout(trigger: String) {
        historySyncTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + 120)
        timer.setEventHandler { [weak self] in
            guard let self, self.isDownloadingHistory else { return }
            self.log("History download TIMEOUT after 120s [\(trigger)] — \(self.historyBuffer.count) records received")
            self.supabase.pushDebugLog(
                key: "history_sync_timeout",
                value: "trigger=\(trigger) records_buffered=\(self.historyBuffer.count) batches=\(self.historyBatchCount)"
            )
            self.finishHistoryDownload()
        }
        historySyncTimer = timer
        timer.resume()
    }

    /// Finish history download: dedup against existing minute-buckets, upload
    /// records with their REAL strap-embedded timestamps. Same finalizer for
    /// both auto-reconnect and manual-72h paths — branches on isManualBackfillMode
    /// only for UI state updates.
    private func finishHistoryDownload() {
        isDownloadingHistory = false
        DispatchQueue.main.async { self.isHistorySyncing = false }

        let trigger = isManualBackfillMode ? "manual-72h" : "auto-reconnect"
        supabase.pushDebugLog(key: "history_sync_complete", value: "trigger=\(trigger) records=\(historyBuffer.count) batches=\(historyBatchCount)")

        // Manual UI: jump to "parsing" state immediately
        if isManualBackfillMode {
            DispatchQueue.main.async {
                self.manualBackfillState = "parsing"
                self.manualBackfillProgress = "Strap returned \(self.historyBuffer.count) records, deduping…"
            }
        }

        // Resume live streaming immediately so we don't leave the strap idle
        // while the upload async-runs in the background.
        bleQueue.async { self.startRealtimeStreaming() }
        finishHistoryWithDedup(trigger: trigger)
    }

    /// Shared finalizer for both auto-reconnect and manual-72h paths.
    /// Uses real strap timestamps + dedups against pre-fetched minute set.
    private func finishHistoryWithDedup(trigger: String) {
        let recordsFromStrap = historyBuffer
        historyBuffer.removeAll()
        let windowStart = isManualBackfillMode ? manualBackfillWindowStart : gapStartTime
        let windowEnd = isManualBackfillMode ? manualBackfillWindowEnd : gapEndTime
        let existingMinutes = manualBackfillExistingMinutes

        Task { [weak self] in
            guard let self else { return }

            let nowUnix = Int(Date().timeIntervalSince1970)
            // The accept window is the strap's whole ring depth, NOT the gap window.
            // The strap serves from its oldest unacked record (~72h back) while the
            // gap window is usually only minutes wide, so matching the two rejected
            // 100% of records by construction — 756 syncs since 2026-05-07 produced
            // 5 uploads. gapStartTime still decides WHETHER to sync; it must never
            // filter records. Novelty is the dedup set's job, and that is idempotent.
            let acceptDepth: TimeInterval = 96 * 3600
            let minUnix = Int(Date().addingTimeInterval(-acceptDepth).timeIntervalSince1970)
            let maxUnix = nowUnix + 60
            let gapDesc = "gap=[\(Int(windowStart.timeIntervalSince1970))..\(Int(windowEnd.timeIntervalSince1970))]"

            var dedupedRecords: [(timestamp: Date, hr: UInt8, rrIntervals: [UInt16], hrv: Double)] = []
            var sleepReplayPairs: [(hr: Int, time: Date)] = []
            var skippedAlreadyCovered = 0
            var skippedOutOfRange = 0
            var skippedZeroHR = 0
            var oorNewestTs = 0   // v137: newest out-of-range ts — if even this is ancient, the cursor is stuck
            var oorMaxHR = 0      // highest HR among rejected records — a real pulse here means the buffer is NOT dead
            // v104 diagnostic: capture the first N out-of-range timestamps so
            // we can see what the strap is actually returning. The May 21
            // manual-72h push returned 9 records, all out-of-range, with no
            // visibility into why. This logs samples (not all — bounded) so
            // the next reproduce surfaces strap-clock drift / wrong epoch /
            // empty buffer noise unambiguously.
            var oorSamples: [String] = []
            let oorSampleCap = 8

            for r in recordsFromStrap {
                let ts = Int(r.timestamp)
                guard ts >= minUnix && ts <= maxUnix else {
                    if ts > 0 && ts < 4_102_444_800 && ts > oorNewestTs { oorNewestTs = ts }
                    if Int(r.heartRate) > oorMaxHR { oorMaxHR = Int(r.heartRate) }
                    if oorSamples.count < oorSampleCap {
                        // hr=NN ts=UNIX (ISO) — compact, parseable in bridge_logs
                        let isoStr: String = {
                            if ts > 0 && ts < 4_102_444_800 { // < year 2100
                                let f = ISO8601DateFormatter()
                                return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
                            }
                            return "invalid"
                        }()
                        oorSamples.append("hr=\(r.heartRate) ts=\(ts) iso=\(isoStr)")
                    }
                    skippedOutOfRange += 1
                    continue
                }
                // Type-47 arrives in two layouts. The 93-byte cmd=5 variant carries a
                // real HR at byte 14; the 73-byte cmd=0 variant does not, and byte 14
                // there reads 1-7. `heartRate > 0` admitted both, which is why 690 of
                // 785 backfilled rows landed with HR under 20. Only a physiological
                // pulse gets through now.
                guard r.heartRate >= 25 && r.heartRate <= 220 else {
                    skippedZeroHR += 1
                    continue
                }
                let minute = (ts / 60) * 60
                if existingMinutes.contains(minute) {
                    skippedAlreadyCovered += 1
                    continue
                }
                let recordedAt = Date(timeIntervalSince1970: TimeInterval(ts))
                let rmssd: Double = {
                    let rrs = r.rrIntervals.map { Double($0) }
                    guard rrs.count >= 2 else { return 0 }
                    let diffs = zip(rrs, rrs.dropFirst()).map { abs($0 - $1) }
                    let meanSqDiff = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
                    return meanSqDiff > 0 ? meanSqDiff.squareRoot() : 0
                }()
                dedupedRecords.append((recordedAt, r.heartRate, r.rrIntervals, rmssd))
                if r.heartRate > 30 {
                    sleepReplayPairs.append((Int(r.heartRate), recordedAt))
                }
            }

            self.supabase.pushDebugLog(key: "history_sync_dedup_result", value: "trigger=\(trigger) to_upload=\(dedupedRecords.count) already_covered=\(skippedAlreadyCovered) out_of_range=\(skippedOutOfRange) zero_hr=\(skippedZeroHR) total_from_strap=\(recordsFromStrap.count)")
            self.log("Dedup [\(trigger)]: \(dedupedRecords.count) to upload, \(skippedAlreadyCovered) already covered, \(skippedOutOfRange) out of window, \(skippedZeroHR) zero-HR (of \(recordsFromStrap.count))")
            // v104 diagnostic: dump out-of-range samples + window so we can
            // diagnose the empty/garbage buffer mystery (May 21 manual backfill).
            if !oorSamples.isEmpty {
                let windowDesc = "accept=[\(minUnix)..\(maxUnix)] \(gapDesc) now=\(nowUnix)"
                self.supabase.pushDebugLog(
                    key: "history_sync_oor_samples",
                    value: "trigger=\(trigger) \(windowDesc) count=\(skippedOutOfRange) oor_max_hr=\(oorMaxHR) samples=[\(oorSamples.joined(separator: " | "))]"
                )
            }

            // v137 — AUTO CURSOR-RESET (the permanent fix for the 4×-recurring
            // phone-death gap). The strap can wedge its history read-cursor on a dead
            // ancient buffer region (off-wrist HR ~6 from weeks ago) and replay it on
            // every request → 100% out-of-range, 0 backfilled, forever. Manual ERASE
            // was the only escape. Detect the unambiguous signature — a big storm of
            // out-of-range records whose NEWEST sample is still >24h before the
            // requested window (i.e. the strap is serving ancient data, not "no data")
            // — and fire ERASE 0x19 automatically so the next sync drains clean.
            // Auto-reconnect only + 6h cooldown so a wedged strap can never loop-erase.
            // v171 — hard safety condition added: oorMaxHR < 25. This erase fired on
            // 2026-07-31 13:04 against a buffer holding real HR 92-96 from Jul 28 and
            // destroyed it, because the old narrow accept window made
            // skippedOutOfRange >= 100 permanently true. A real pulse among the
            // rejected records means the buffer is live, not wedged — never erase it.
            if trigger == "auto-reconnect",
               recordsFromStrap.count >= 100,
               dedupedRecords.isEmpty,
               skippedAlreadyCovered == 0,
               skippedOutOfRange >= 100,
               oorMaxHR < 25,
               oorNewestTs > 0,
               oorNewestTs < minUnix - 86_400 {
                let sinceLastErase = Date().timeIntervalSince(self.lastAutoHistoryErase)
                let staleDays = (minUnix - oorNewestTs) / 86_400
                if sinceLastErase > 6 * 3600 {
                    self.lastAutoHistoryErase = Date()
                    UserDefaults.standard.set(self.lastAutoHistoryErase.timeIntervalSince1970, forKey: "lucid_last_auto_history_erase")
                    let newestIso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(oorNewestTs)))
                    self.supabase.pushDebugLog(
                        key: "history_auto_erase_triggered",
                        value: "trigger=auto-stuck-cursor total=\(recordsFromStrap.count) out_of_range=\(skippedOutOfRange) newest_served=\(oorNewestTs) newest_iso=\(newestIso) window_start=\(minUnix) stale_days=\(staleDays)"
                    )
                    self.log("\u{1F500} Stuck history cursor detected (newest served \(newestIso), \(staleDays)d stale) — auto-firing ERASE 0x19")
                    self.autoEraseStuckHistory()
                } else {
                    self.supabase.pushDebugLog(
                        key: "history_auto_erase_skipped_cooldown",
                        value: "trigger=auto-stuck-cursor stale_days=\(staleDays) mins_since_last_erase=\(Int(sinceLastErase / 60))"
                    )
                }
            }

            if self.isManualBackfillMode {
                DispatchQueue.main.async {
                    self.manualBackfillState = "uploading"
                    self.manualBackfillProgress = "Uploading \(dedupedRecords.count) new records…"
                }
            }

            guard !dedupedRecords.isEmpty else {
                if self.isManualBackfillMode {
                    DispatchQueue.main.async {
                        self.manualBackfillState = "done"
                        self.manualBackfillResult = recordsFromStrap.isEmpty
                            ? "Strap buffer was empty — nothing to backfill."
                            : "All \(recordsFromStrap.count) strap records were already covered or outside the window."
                        self.manualBackfillProgress = ""
                    }
                    self.isManualBackfillMode = false
                }
                self.manualBackfillExistingMinutes = []
                // Do NOT advance the cursor here — nothing was uploaded. Saving it on
                // a zero-upload sync walked the offline fail-safe forward past data
                // that had never landed, so the gap became invisible.
                return
            }

            let result = await self.supabase.pushBackfillBatch(records: dedupedRecords)
            self.supabase.pushDebugLog(key: "history_sync_upload_result", value: "trigger=\(trigger) uploaded=\(result.uploaded) failed=\(result.failed)")

            // Replay successfully-uploaded readings through sleep detection so
            // sleep_start/stages get retroactively corrected for any sleep window
            // that was in the gap (works for both auto-reconnect and manual paths).
            if !sleepReplayPairs.isEmpty {
                self.log("Replaying \(sleepReplayPairs.count) gap readings for sleep analysis")
                self.healthEngine.replayGapForSleep(readings: sleepReplayPairs)
            }

            if self.isManualBackfillMode {
                DispatchQueue.main.async {
                    if result.failed > 0 && result.uploaded == 0 {
                        self.manualBackfillState = "failed"
                        self.manualBackfillResult = "Upload failed (\(result.failed) records). Retry?"
                    } else {
                        self.manualBackfillState = "done"
                        let coveredMin = result.uploaded / 60
                        self.manualBackfillResult = "Backfilled \(result.uploaded) records (~\(coveredMin) min) into your gaps." +
                            (result.failed > 0 ? " \(result.failed) chunks failed." : "")
                    }
                    self.manualBackfillProgress = ""
                }
                self.isManualBackfillMode = false
            }
            self.manualBackfillExistingMinutes = []
            // Only advance the cursor once rows have actually landed.
            if result.uploaded > 0 { self.saveLastSyncTimestamp() }
        }
    }

    private func handleHistoryData(_ packet: WhoopPacket) {
        guard isDownloadingHistory else { return }

        // v113 — capture ground-truth bytes for the first 40 history packets per
        // sync (shared budget with the unknown-type branch). Firmware 41.x appears
        // to dump 93-byte decode_5c sensor packets (15 IEEE floats, HR NOT cooked
        // in-packet) instead of the old ~24-byte <LHLB> HR records our parser
        // assumes — so parseHistoricalRecord reads byte[14] (float data on a 93B
        // packet) → ~0 → filtered at the hr>0 check below → 0 records buffered.
        // Log size + seq (version discriminator) + the byte the parser treats as
        // HR + the parse outcome so the next build fixes the layout with zero
        // guessing. Pure diagnostic — behaviour below is unchanged.
        if historyRawCaptureCount < 40 {
            historyRawCaptureCount += 1
            let d = packet.data
            let s = d.startIndex
            let hex = d.prefix(96).map { String(format: "%02x", $0) }.joined()
            let hrByte14 = d.count >= 15 ? Int(d[s + 14]) : -1
            let parsed = WhoopProtocol.parseHistoricalRecord(data: d)
            let outcome = parsed == nil ? "nil" : "hr=\(parsed!.heartRate) rr=\(parsed!.rrIntervals.count)"
            supabase.pushDebugLog(
                key: "history_raw_packet",
                value: "n=\(historyRawCaptureCount) type=\(packet.type) seq=\(packet.seq) cmd=\(packet.cmd) len=\(d.count) hrByte14=\(hrByte14) parse=\(outcome) hex=\(hex)"
            )
        }

        // Parse the record — we only need HR and RR values
        // Timestamps will be distributed evenly across the gap later
        if let reading = WhoopProtocol.parseHistoricalRecord(data: packet.data) {
            if reading.heartRate > 0 {
                historyBuffer.append(reading)
                let count = historyBuffer.count
                if count % 500 == 0 {
                    DispatchQueue.main.async {
                        self.historySyncCount = count
                        self.historySyncProgress = "Downloaded \(count) readings..."
                    }
                    log("History: \(count) records buffered")
                }
            }
        }
    }

    private func handleHistoryMetadata(_ packet: WhoopPacket) {
        guard isDownloadingHistory else { return }
        let trigger = isManualBackfillMode ? "manual-72h" : "auto-reconnect"

        switch packet.cmd {
        case 1: // META_HISTORY_START
            historyBatchCount += 1
            log("History batch \(historyBatchCount) started")
            supabase.pushDebugLog(key: "history_sync_batch_start", value: "trigger=\(trigger) batch=\(historyBatchCount) running_total=\(historyBuffer.count)")

        case 2: // META_HISTORY_END — ack and request next batch
            // v113 — trim-offset fix + diagnostic. parseHistoryMetadata reads trim
            // at data[8:12] (<LHHL, unk=2B). But the record parser — whose HR@14 the
            // firmware-41 research confirms correct — implies the shared header is
            // unix4+subsec2+unk4 (10 bytes), so trim belongs at [10:14]. A wrong
            // trim froze at 655360 across 68 batches → strap re-sent batch 1 forever
            // → 0 records. We now ACK with [10:14] and log BOTH candidates so one
            // real sync proves which offset the firmware actually uses.
            let d = packet.data
            let s = d.startIndex
            let metaHex = d.prefix(32).map { String(format: "%02x", $0) }.joined()
            let trim8: UInt32? = d.count >= 12
                ? (UInt32(d[s+8]) | (UInt32(d[s+9]) << 8) | (UInt32(d[s+10]) << 16) | (UInt32(d[s+11]) << 24))
                : nil
            let trim10: UInt32? = d.count >= 14
                ? (UInt32(d[s+10]) | (UInt32(d[s+11]) << 8) | (UInt32(d[s+12]) << 16) | (UInt32(d[s+13]) << 24))
                : nil
            let t8str = trim8.map { "\($0)" } ?? "nil"
            let t10str = trim10.map { "\($0)" } ?? "nil"
            supabase.pushDebugLog(key: "history_meta_raw", value: "trigger=\(trigger) batch=\(historyBatchCount) len=\(d.count) hex=\(metaHex) trim_at8=\(t8str) trim_at10=\(t10str)")
            if let trim = trim10 ?? trim8 {
                log("History batch \(historyBatchCount) ended (trim10=\(t10str) trim8=\(t8str)), ACKing with \(trim)...")
                supabase.pushDebugLog(key: "history_sync_batch_end", value: "trigger=\(trigger) batch=\(historyBatchCount) ack_trim=\(trim) running_total=\(historyBuffer.count)")
                if let p = peripheral, let c = cmdToStrap {
                    p.writeValue(WhoopProtocol.historyAckPacket(trim: trim), for: c, type: .withResponse)
                }
            } else {
                log("History batch end — couldn't parse metadata (len=\(d.count))")
                supabase.pushDebugLog(key: "history_sync_batch_end_unparsed", value: "trigger=\(trigger) batch=\(historyBatchCount) hex=\(metaHex)")
            }

        case 3: // META_HISTORY_COMPLETE — all done!
            log("HISTORY COMPLETE! \(historyBuffer.count) total records across \(historyBatchCount) batches")
            historySyncTimer?.cancel(); historySyncTimer = nil

            DispatchQueue.main.async {
                self.historySyncProgress = "Processing \(self.historyBuffer.count) records..."
            }

            finishHistoryDownload()

        default:
            log("History metadata: unknown cmd \(packet.cmd)")
            supabase.pushDebugLog(key: "history_sync_metadata_unknown", value: "trigger=\(trigger) cmd=\(packet.cmd)")
        }
    }

    // MARK: - Last Sync Timestamp

    private func saveLastSyncTimestamp() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncKey)
    }

    private func getLastSyncTimestamp() -> Date {
        let ts = UserDefaults.standard.double(forKey: lastSyncKey)
        if ts > 0 {
            return Date(timeIntervalSince1970: ts)
        }
        // No previous sync — return 24h ago to trigger a full download
        return Date().addingTimeInterval(-86400)
    }

    // MARK: - Haptics

    @Published var availablePatterns: [UInt8] = []
    @Published var lastHapticResult: String = ""

    func listHapticPatterns() {
        guard let p = peripheral, let c = cmdToStrap else {
            log("Cannot list patterns — not connected")
            return
        }
        log("Requesting haptic patterns (CMD 80)...")
        p.writeValue(WhoopProtocol.listHapticsPacket(), for: c, type: .withResponse)
    }

    private var hapticStopTimer: DispatchWorkItem?

    func runHapticPattern(_ patternId: UInt8) {
        guard let p = peripheral, let c = cmdToStrap else {
            log("Cannot run haptics — not connected")
            return
        }
        log("Running haptic pattern \(patternId) (CMD 79)...")
        p.writeValue(WhoopProtocol.runHapticsPacket(patternId: patternId), for: c, type: .withResponse)

        // Safety timeout: force-stop after 2 seconds via BLE queue (works even when backgrounded)
        hapticStopTimer?.cancel()
        let stopWork = DispatchWorkItem { [weak self] in
            self?.log("Haptic safety timeout — force-stopping")
            self?.forceStopHaptics()
        }
        hapticStopTimer = stopWork
        bleQueue.asyncAfter(deadline: .now() + 2.0, execute: stopWork)
    }

    func stopHaptics() {
        forceStopHaptics()
    }

    /// Send a haptic command WITHOUT the auto-stop timer (for multi-buzz sequences)
    func sendHapticRaw(_ patternId: UInt8) {
        guard let p = peripheral, let c = cmdToStrap else { return }
        p.writeValue(WhoopProtocol.runHapticsPacket(patternId: patternId), for: c, type: .withResponse)
    }

    /// Aggressive stop: sends CMD 122 three times + tries pattern 0 as "silence" fallback
    internal func forceStopHaptics() {
        guard let p = peripheral, let c = cmdToStrap else {
            log("Cannot stop haptics — not connected")
            return
        }
        log("Force-stopping haptics (CMD 122 x3)...")
        // Send stop command 3 times with short delays
        p.writeValue(WhoopProtocol.stopHapticsPacket(), for: c, type: .withResponse)
        bleQueue.asyncAfter(deadline: .now() + 0.1) {
            p.writeValue(WhoopProtocol.stopHapticsPacket(), for: c, type: .withResponse)
        }
        bleQueue.asyncAfter(deadline: .now() + 0.2) {
            p.writeValue(WhoopProtocol.stopHapticsPacket(), for: c, type: .withResponse)
        }
        // Also try sending pattern 0 with 0x00 data as "off" signal
        bleQueue.asyncAfter(deadline: .now() + 0.3) {
            p.writeValue(WhoopProtocol.runHapticsPacket(patternId: 0), for: c, type: .withResponse)
        }
        // One more stop after the pattern-0 attempt
        bleQueue.asyncAfter(deadline: .now() + 0.5) {
            p.writeValue(WhoopProtocol.stopHapticsPacket(), for: c, type: .withResponse)
        }
    }

    // MARK: - LED / Optical Experiments (SpO2 research)
    // CMD 107 = ENABLE_OPTICAL_DATA, CMD 108 = TOGGLE_OPTICAL_MODE
    // SpO2 response format is undocumented — activate and capture raw packets to decode.
    // All unknown packet types are logged to Supabase when optical mode is active.

    @Published var ledTestResult: String = ""
    @Published var opticalModeActive: Bool = false
    @Published var capturedOpticalPackets: [[String]] = []  // [type_hex, cmd_hex, data_hex]

    /// Enable optical LEDs for SpO2 measurement.
    /// Sends CMD 107 (enable) then CMD 108 (toggle on).
    /// Unknown response packets are automatically captured and logged to Supabase for decoding.
    func enableOpticalCapture() {
        guard let p = peripheral, let c = cmdToStrap else {
            log("Cannot enable optical — not connected")
            return
        }
        log("OPTICAL: enabling data capture (CMD 107 + 108)...")
        // CMD 107 = ENABLE_OPTICAL_DATA
        let enable107 = WhoopProtocol.buildPacket(
            type: PacketType.command,
            cmd: WhoopCommand.enableOpticalData,
            data: Data([0x01])
        )
        p.writeValue(enable107, for: c, type: .withResponse)
        // CMD 108 = TOGGLE_OPTICAL_MODE (on)
        bleQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            p.writeValue(WhoopProtocol.toggleOpticalPacket(mode: 1), for: c, type: .withResponse)
            DispatchQueue.main.async { self.opticalModeActive = true }
            self.log("OPTICAL: mode toggled ON — watching for SpO2 packets on data characteristic...")
            // Auto-disable after 60s (single on-demand measurement)
            self.bleQueue.asyncAfter(deadline: .now() + 60) { self.disableOpticalCapture() }
        }
    }

    func disableOpticalCapture() {
        guard let p = peripheral, let c = cmdToStrap else { return }
        p.writeValue(WhoopProtocol.toggleOpticalPacket(mode: 0), for: c, type: .withResponse)
        DispatchQueue.main.async { self.opticalModeActive = false }
        log("OPTICAL: mode toggled OFF")
        // Push captured packets to Supabase for analysis if any were collected
        if !capturedOpticalPackets.isEmpty {
            let summary = capturedOpticalPackets.prefix(10).map { "\($0[0]):\($0[1]) \($0[2])" }.joined(separator: "\n")
            supabase.pushDebugLog(key: "OPTICAL_CAPTURE", value: "Captured \(capturedOpticalPackets.count) unknown packets:\n\(summary)")
            log("OPTICAL: pushed \(capturedOpticalPackets.count) captured packets to Supabase")
            DispatchQueue.main.async { self.capturedOpticalPackets.removeAll() }
        }
    }

    /// Called from packet handler for any unknown packet type when optical mode is active
    func captureOpticalPacket(type: UInt8, cmd: UInt8, data: Data) {
        guard opticalModeActive else { return }
        let entry = [
            String(format: "0x%02X", type),
            String(format: "0x%02X", cmd),
            data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        ]
        DispatchQueue.main.async { self.capturedOpticalPackets.append(entry) }
        log("OPTICAL packet: type=\(entry[0]) cmd=\(entry[1]) data=[\(entry[2])]")
    }

    func testOpticalMode(_ mode: UInt8) {
        guard let p = peripheral, let c = cmdToStrap else {
            log("Cannot test LED — not connected")
            return
        }
        log("Testing optical mode \(mode) (CMD 108)...")
        p.writeValue(WhoopProtocol.toggleOpticalPacket(mode: mode), for: c, type: .withResponse)
    }

    func testIMU(_ enable: Bool) {
        guard let p = peripheral, let c = cmdToStrap else {
            log("Cannot toggle IMU — not connected")
            return
        }
        log("IMU \(enable ? "ON" : "OFF") (CMD 106)...")
        p.writeValue(WhoopProtocol.toggleIMUPacket(enable: enable), for: c, type: .withResponse)
    }

    // MARK: - Supabase Push

    private func startPushTimer() {
        DispatchQueue.main.async {
            self.pushTimer?.invalidate()
            self.pushTimer = Timer.scheduledTimer(withTimeInterval: self.pushInterval, repeats: true) { [weak self] _ in
                self?.flushReadings()
            }
        }
    }

    private var deviceInfoUploaded = false

    private func uploadDeviceInfo() {
        guard !deviceInfoUploaded, !deviceInfo.isEmpty else { return }
        deviceInfoUploaded = true
        let info = deviceInfo
        let summary = info.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        log("Uploading device info to Supabase...")
        supabase.pushDebugLog(key: "device_info", value: summary)
    }

    /// Thin entry point. Funnels the snapshot-and-clear onto the serial bleQueue.
    /// v141 — flush is now triggered from TWO places: the main-runloop pushTimer
    /// AND opportunistically from the BLE wake path (didUpdateValueFor). Routing
    /// both through bleQueue means they can't race on pendingReadings (lost
    /// readings / double-send). This also fixes a pre-existing race: the old timer
    /// flushed on the main thread while appends ran on bleQueue.
    private func flushReadings() {
        bleQueue.async { [weak self] in self?.flushReadingsOnQueue() }
    }

    /// MUST be called on bleQueue. Snapshot pendingReadings, clear, and push.
    private func flushReadingsOnQueue() {
        guard !pendingReadings.isEmpty else { return }
        lastFlush = Date()
        let batch = pendingReadings
        pendingReadings.removeAll()

        let latestHR = batch.last.map { Int($0.heartRate) } ?? heartRate
        let allRR = batch.flatMap { $0.rrIntervals.map { Double($0) } }
        let rmssd = healthEngine.currentRMSSD

        // v98 — only attach IMU if we have a recent reading (within last 60s).
        // Stale IMU = strap was off-wrist or BLE bouncing — sending stale values
        // would mislead the wake-up detector.
        let imuFresh = Date().timeIntervalSince(lastImuUpdate) < 60
        let accelToSend = imuFresh ? lastAccelMagMg : 0
        let moveToSend = imuFresh ? lastMovementScore : 0

        supabase.pushReading(
            hr: latestHR,
            rr: allRR.map { Int($0) },
            hrv: rmssd,
            battery: battery,
            respiratoryRate: healthEngine.respiratoryRate,
            sleepStage: healthEngine.currentSleepStage.rawValue,
            readiness: healthEngine.readiness.rawValue,
            skinTemp: skinTemperature,
            sdnn: healthEngine.sdnn,
            pnn50: healthEngine.pnn50,
            dfaAlpha1: healthEngine.dfaAlpha1,
            cognitiveCapacity: healthEngine.cognitiveCapacity,
            cognitiveLabel: healthEngine.cognitiveLabel,
            illnessRisk: healthEngine.illnessRisk,
            accelMagMg: accelToSend,
            movementScore: moveToSend
        )
        DispatchQueue.main.async { self.lastSync = Date() }

        // Periodic daily metrics upsert (every 30 min of readings)
        // Ensures Supabase has latest scores even if wake-up detection doesn't fire
        if readingsToday > 0 && readingsToday % 180 == 0 {  // 180 readings × 10s = 30 min
            let he = healthEngine
            // Only write a real resting HR after sleep has ended for the day.
            // If sleep hasn't ended yet (e.g. periodic upsert fires at midnight while
            // user is still awake), fall back to the stored baseline to avoid writing
            // an elevated active HR as today's resting HR.
            let avgHR: Int
            if he.sleepEndTime != nil {
                avgHR = he.sleepingMinHR > 0 ? Int(he.sleepingMinHR) :
                    he.recentHR.isEmpty ? Int(he.baselineRHR) :
                    Int(he.recentHR.suffix(30).reduce(0, +) / Double(min(he.recentHR.count, 30)))
            } else {
                avgHR = Int(he.baselineRHR)  // no sleep yet today — use historical baseline
            }
            supabase.upsertDailyMetrics(
                restingHR: avgHR,
                hrvAvg: he.currentRMSSD,
                sleepHours: he.runningSleepHours,
                deepMin: Int(he.stageMinutes[.deep] ?? 0),
                remMin: Int(he.stageMinutes[.rem] ?? 0),
                lightMin: Int(he.stageMinutes[.light] ?? 0),
                sleepStart: he.sleepStartTime,
                sleepEnd: he.sleepEndTime,
                recoveryScore: he.recoveryScore,
                strainScore: he.strainScore,
                respiratoryRate: he.respiratoryRate,
                bodyBattery: he.bodyBattery,
                sdnnAvg: he.sdnn,
                pnn50Avg: he.pnn50,
                dfaAlpha1Avg: he.dfaAlpha1,
                cognitiveCapacity: he.cognitiveCapacity,
                cognitiveLabel: he.cognitiveLabel,
                illnessRisk: he.illnessRisk,
                illnessAlert: he.illnessAlert,
                trainingMonotony: he.trainingMonotony,
                trainingStrain: he.trainingStrain,
                acwr: he.trainingLoadRatio,
                skinTemp: skinTemperature,
                awakeMin: Int(he.stageMinutes[.awake] ?? 0),
                readinessLevel: he.readiness.rawValue,
                readinessScore: he.cognitiveCapacity,
                strainPhysical: {
                    let total = max(1.0, he.zoneMinutes.map(Double.init).reduce(0, +))
                    let high = Double(he.zoneMinutes[2]) + Double(he.zoneMinutes[3]) + Double(he.zoneMinutes[4])
                    return round(he.strainScore * (high / total) * 10) / 10
                }(),
                strainStress: {
                    let total = max(1.0, he.zoneMinutes.map(Double.init).reduce(0, +))
                    let high = Double(he.zoneMinutes[2]) + Double(he.zoneMinutes[3]) + Double(he.zoneMinutes[4])
                    let physFrac = high / total
                    let dfaFrac = he.dfaAlpha1 > 0 ? max(0.0, min(0.5, (1.5 - he.dfaAlpha1) / 1.5)) : 0.2
                    let sPhysical = he.strainScore * physFrac
                    let sAutonomic = he.strainScore * dfaFrac * (1.0 - physFrac)
                    return round(max(0.0, he.strainScore - sPhysical - sAutonomic) * 10) / 10
                }(),
                strainAutonomic: {
                    let total = max(1.0, he.zoneMinutes.map(Double.init).reduce(0, +))
                    let high = Double(he.zoneMinutes[2]) + Double(he.zoneMinutes[3]) + Double(he.zoneMinutes[4])
                    let physFrac = high / total
                    let dfaFrac = he.dfaAlpha1 > 0 ? max(0.0, min(0.5, (1.5 - he.dfaAlpha1) / 1.5)) : 0.2
                    return round(he.strainScore * dfaFrac * (1.0 - physFrac) * 10) / 10
                }(),
                hrr1: Double(he.lastHRR1),
                hrr2: Double(he.lastHRR2)
            )
        }
    }

    // MARK: - Auto-Reconnect (AGGRESSIVE — never gives up)

    private func immediateReconnect(to peripheral: CBPeripheral) {
        log("IMMEDIATE RECONNECT — requesting persistent connection...")
        connectionInitiated = false
        cmdToStrap = nil

        // CBConnectPeripheralOptionEnableAutoReconnect (iOS 17+)
        // This tells iOS to auto-reconnect even across app restarts
        var options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]

        // iOS 17+ auto-reconnect option
        if #available(iOS 17.0, *) {
            options["kCBConnectOptionEnableAutoReconnect"] = true
        }

        centralManager.connect(peripheral, options: options)
        DispatchQueue.main.async { self.connectionState = .connecting }
    }

    private func scheduleReconnect() {
        guard connectionState != .connected && connectionState != .streaming && connectionState != .syncing else { return }
        DispatchQueue.main.async { self.connectionState = .disconnected }
        log("Will scan again in 5s...")
        DispatchQueue.main.async {
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.startScanning()
            }
        }
    }

    // MARK: - Save/Load peripheral identifier for reconnection across app launches

    private func savePeripheralId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: peripheralIdKey)
    }

    private func loadPeripheralId() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: peripheralIdKey) else { return nil }
        return UUID(uuidString: str)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth ON")

            // Try to reconnect to known peripheral first
            if let savedId = loadPeripheralId() {
                let known = central.retrievePeripherals(withIdentifiers: [savedId])
                if let knownPeripheral = known.first {
                    log("Found saved peripheral, reconnecting...")
                    self.peripheral = knownPeripheral
                    knownPeripheral.delegate = self
                    immediateReconnect(to: knownPeripheral)
                    return
                }
            }

            // Otherwise scan
            startScanning()

        case .poweredOff:
            log("Bluetooth OFF")
            DispatchQueue.main.async { self.connectionState = .disconnected }
        case .unauthorized:
            log("Bluetooth UNAUTHORIZED - check Settings > Lucid Bridge > Bluetooth")
        case .unsupported:
            log("Bluetooth not supported on this device")
        case .resetting:
            log("Bluetooth resetting...")
        case .unknown:
            log("Bluetooth state unknown")
        @unknown default:
            log("Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "no-name"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceStr = services.map { $0.uuidString }.joined(separator: ", ")

        log("Found: \(name) RSSI:\(RSSI) svcs:[\(serviceStr)]")

        let isWhoop = name.lowercased().contains("whoop")
            || name.lowercased().contains("4-")
            || services.contains(serviceUUID)

        if isWhoop {
            log(">>> WHOOP DETECTED! \(name) id:\(peripheral.identifier.uuidString.prefix(8))")
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self

            // Save identifier for future reconnection
            savePeripheralId(peripheral.identifier)

            // Cancel any stale connection first, then connect
            central.cancelPeripheralConnection(peripheral)

            bleQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.immediateReconnect(to: peripheral)

                // Timeout — but only for initial connection
                DispatchQueue.main.async {
                    self.connectTimeout?.invalidate()
                    self.connectTimeout = Timer.scheduledTimer(withTimeInterval: self.connectionTimeout, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        if self.connectionState == .connecting {
                            self.log("CONNECTION TIMEOUT after \(Int(self.connectionTimeout))s")
                            self.scheduleReconnect()
                        }
                    }
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async { self.connectTimeout?.invalidate() }
        log("CONNECTED to \(peripheral.name ?? "Whoop")")
        evt("ble_connected", "name=\(peripheral.name ?? "Whoop") batt=\(Int(battery))%")
        DispatchQueue.main.async { self.connectionState = .connected }

        // v68 — new RE session. Regenerate session id and reset the packet counter
        // so packet_debug rows from this connection group together cleanly.
        reSessionId = UUID().uuidString
        debugPacketsThisSession = 0
        if debugPacketCapture {
            log("v68: debug packet capture ON — reSessionId=\(reSessionId.prefix(8))")
        }

        // Broadcast build info via simple constants only — no Info.plist access,
        // no complex formatting. Keeping this lean after a launch-crash scare.
        supabase.pushWhoopEvent(
            type: "build_info",
            data: [
                "code_version": "v70",
                "re_session_id": reSessionId
            ]
        )

        // Start silent audio to keep app alive
        DispatchQueue.main.async { self.startSilentAudio() }

        // Fetch personal health baseline from Supabase (for sleep staging)
        healthEngine.fetchBaseline(supabase: supabase)
        healthEngine.debugSupabase = supabase
        healthEngine.fetchTodaySteps() // HealthKit step count for illness detection

        // Retroactive sleep replay: if today's sleep was missed (phone died),
        // pull gap readings from Supabase and recalculate
        healthEngine.retroactiveReplayIfNeeded(supabase: supabase)

        // Restore any manual activity session that survived a force-quit
        restoreOrphanedManualActivity()

        log("Discovering ALL services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "clean disconnect"
        let errorCode = (error as? NSError)?.code ?? -1
        let errorDomain = (error as? NSError)?.domain ?? "none"
        log("⚠️ DISCONNECTED: \(reason) [domain=\(errorDomain) code=\(errorCode)]")
        log("   State at disconnect: HR=\(heartRate) battery=\(Int(battery))% sleep=\(healthEngine.sleepDetected) readings=\(readingsToday)")
        log("   Session uptime: \(sessionUptimeText)")
        evt("ble_disconnected", "reason=\(reason) code=\(errorCode) hr=\(heartRate) batt=\(Int(battery))% sleep=\(healthEngine.sleepDetected) uptime=\(sessionUptimeText)")

        // CRITICAL: reset history-sync flag on disconnect. If the strap drops
        // mid-history-download, finishHistoryDownload() never fires, and the
        // flag stays stuck = true forever. That would silently block all
        // skin-temp decoding (type-49 falls into the metadata branch).
        // Reset here so the next reconnect starts clean.
        let wasDownloading = isDownloadingHistory
        let bufferedAtDisconnect = historyBuffer.count
        isDownloadingHistory = false
        DispatchQueue.main.async { self.isHistorySyncing = false }

        // The auto path used to drop historyBuffer here with no log at all. At
        // 60-80 disconnects a day that silently discarded most interrupted syncs.
        // Salvage whatever arrived and always leave a trace. (Manual keeps its own
        // "failed" UI path below — running the finalizer would race it.)
        if wasDownloading && !isManualBackfillMode {
            supabase.pushDebugLog(
                key: "history_sync_aborted_disconnect",
                value: "trigger=auto-reconnect records_buffered=\(bufferedAtDisconnect)"
            )
            historySyncTimer?.cancel(); historySyncTimer = nil
            if bufferedAtDisconnect > 0 {
                finishHistoryWithDedup(trigger: "auto-reconnect")
            }
        }

        // Manual backfill cleanup: if user disconnected mid-flight, the UI
        // would be stuck on "running" forever. Surface as failed so the
        // button re-enables itself.
        if isManualBackfillMode {
            DispatchQueue.main.async {
                self.manualBackfillState = "failed"
                self.manualBackfillResult = "Strap disconnected during backfill — try again when reconnected."
                self.manualBackfillProgress = ""
            }
            isManualBackfillMode = false
            manualBackfillExistingMinutes = []
            supabase.pushDebugLog(key: "history_sync_aborted_disconnect", value: "trigger=manual-72h records_buffered=\(historyBuffer.count)")
        }

        // CRITICAL: flush logs NOW so the disconnect reason reaches Supabase
        // even if iOS kills the app right after
        flushRemoteLogs()

        DispatchQueue.main.async {
            self.pushTimer?.invalidate()
        }
        stopWatchdog()
        flushReadingsOnQueue()  // v141 — on bleQueue here; flush synchronously so the
                                // final batch is pushed before iOS can kill the app
        // Save the exact disconnect time so gap sync is precise — but only when
        // data actually landed. Advancing the cursor after a session that produced
        // nothing walked the offline fail-safe past a gap that was never filled.
        if readingsToday > 0 { saveLastSyncTimestamp() }

        // Persist today's daily summary on disconnect — if the strap never reconnects
        // before midnight, this write preserves the day's data. Uses the offline queue
        // so it survives a network outage at disconnect time.
        let he = healthEngine
        if he.recoveryScore > 0 || he.strainScore > 0 || he.sleepScore > 0 {
            let avgHR: Int
            if he.sleepEndTime != nil {
                avgHR = he.sleepingMinHR > 0 ? Int(he.sleepingMinHR) :
                    he.recentHR.isEmpty ? Int(he.baselineRHR) :
                    Int(he.recentHR.suffix(30).reduce(0, +) / Double(min(he.recentHR.count, 30)))
            } else {
                avgHR = Int(he.baselineRHR)
            }
            supabase.upsertDailyMetrics(
                restingHR: avgHR, hrvAvg: he.currentRMSSD,
                sleepHours: he.sleepDurationHours,
                deepMin: Int(he.stageMinutes[.deep] ?? 0),
                remMin: Int(he.stageMinutes[.rem] ?? 0),
                lightMin: Int(he.stageMinutes[.light] ?? 0),
                sleepStart: he.sleepStartTime, sleepEnd: he.sleepEndTime,
                recoveryScore: he.recoveryScore, strainScore: he.strainScore,
                respiratoryRate: he.respiratoryRate, bodyBattery: he.bodyBattery,
                sdnnAvg: he.sdnn, pnn50Avg: he.pnn50, dfaAlpha1Avg: he.dfaAlpha1,
                cognitiveCapacity: he.cognitiveCapacity, cognitiveLabel: he.cognitiveLabel,
                illnessRisk: he.illnessRisk, illnessAlert: he.illnessAlert,
                trainingMonotony: he.trainingMonotony, trainingStrain: he.trainingStrain,
                acwr: he.trainingLoadRatio,
                nocturnalHRDip: he.nocturnalHRDip, sleepFragmentation: he.sleepFragmentationIndex,
                sleepDebt: he.sleepDebtHours, vo2max: he.vo2maxEstimate,
                overtrainingRisk: he.overtrainingRisk, alcoholImpact: he.lastAlcoholImpact,
                skinTemp: skinTemperature, awakeMin: Int(he.stageMinutes[.awake] ?? 0),
                readinessLevel: he.readiness.rawValue, readinessScore: he.cognitiveCapacity,
                hrr1: Double(he.lastHRR1), hrr2: Double(he.lastHRR2)
            )
        }

        connectionInitiated = false
        cmdToStrap = nil

        // AGGRESSIVE RECONNECT — immediately request reconnection
        // CoreBluetooth connect() requests NEVER time out
        // iOS will reconnect whenever the peripheral is found, even hours later
        // This works even when the app is backgrounded or terminated (state restoration)
        log("AGGRESSIVE RECONNECT — will reconnect automatically when strap is in range")
        immediateReconnect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "no error given"
        log("CONNECT FAILED: \(reason)")

        // Still try to reconnect aggressively
        immediateReconnect(to: peripheral)
    }

    // Background state restoration — iOS relaunches app after termination
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("RESTORING from background termination...")

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            log("Restored peripheral: \(restored.name ?? "Whoop") state:\(restored.state.rawValue)")
            self.peripheral = restored
            restored.delegate = self

            if restored.state == .connected {
                DispatchQueue.main.async { self.connectionState = .connected }
                // Re-discover services to re-subscribe to characteristics
                restored.discoverServices(nil)
                DispatchQueue.main.async { self.startSilentAudio() }
            } else {
                // Immediately request reconnection
                immediateReconnect(to: restored)
            }
        } else {
            log("No peripherals to restore, will scan...")
            // centralManagerDidUpdateState will fire next and trigger scanning
        }

        // Recover scan state if we were scanning
        if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            log("Restored scan for \(scanServices.count) services")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let err = error {
            log("Service discovery ERROR: \(err.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("No services found!")
            return
        }

        log("Found \(services.count) services:")
        for service in services {
            log("  - \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let err = error {
            log("Char discovery ERROR for \(service.uuid): \(err.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            log("No characteristics for \(service.uuid)")
            return
        }

        // v70 — Push the full BLE surface (service + characteristics + properties)
        // to Supabase on every connect. Lets us verify whether firmware 1.1.41
        // added new chars/services we don't recognize, without needing on-phone
        // log access. If a new notify char appears, that's likely the auth gate
        // or the new IMU/PPG stream.
        var charSurface: [[String: Any]] = []
        for char in chars {
            charSurface.append([
                "uuid": char.uuid.uuidString,
                "props": describeProperties(char.properties),
                "is_known": [cmdToStrapUUID, cmdFromStrapUUID, eventsUUID, dataUUID, memfaultUUID].contains(char.uuid)
            ])
        }
        supabase.pushWhoopEvent(
            type: "ble_service_surface",
            data: [
                "service_uuid": service.uuid.uuidString,
                "char_count": chars.count,
                "characteristics": charSurface
            ]
        )

        log("Service \(service.uuid.uuidString.prefix(8))... has \(chars.count) chars:")
        for char in chars {
            let props = describeProperties(char.properties)
            log("  - \(char.uuid.uuidString.prefix(8))... [\(props)]")

            switch char.uuid {
            case cmdToStrapUUID:
                cmdToStrap = char
                log("  >>> CMD_TO_STRAP found!")

            case cmdFromStrapUUID:
                peripheral.setNotifyValue(true, for: char)
                log("  >>> Subscribed CMD_FROM_STRAP")

            case eventsUUID:
                peripheral.setNotifyValue(true, for: char)
                log("  >>> Subscribed EVENTS")

            case dataUUID:
                peripheral.setNotifyValue(true, for: char)
                log("  >>> Subscribed DATA")

            case memfaultUUID:
                peripheral.setNotifyValue(true, for: char)
                log("  >>> Subscribed MEMFAULT (firmware crash logs)")

            default:
                // Read standard Device Information chars
                let diChars: Set<CBUUID> = [manufacturerUUID, modelNumberUUID, serialNumberUUID,
                                             hardwareRevUUID, firmwareRevUUID, softwareRevUUID, systemIdUUID]
                if diChars.contains(char.uuid) && char.properties.contains(.read) {
                    peripheral.readValue(for: char)
                    log("  >>> Reading Device Info: \(char.uuid.uuidString)")
                }
                // Subscribe to any notify characteristic for keep-alive
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }

        if cmdToStrap != nil && !connectionInitiated {
            connectionInitiated = true
            log("All Whoop chars found! Starting protocol...")
            bleQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runConnectionSequence()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error {
            log("Notify ERROR for \(characteristic.uuid.uuidString.prefix(8)): \(err.localizedDescription)")
        } else {
            log("Notify ON for \(characteristic.uuid.uuidString.prefix(8))")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error {
            log("Read ERROR on \(characteristic.uuid.uuidString.prefix(8)): \(err.localizedDescription)")
            return
        }
        guard let raw = characteristic.value else { return }

        // Handle Device Information Service reads (standard BLE 0x180A)
        let diChars: [CBUUID: String] = [
            manufacturerUUID: "manufacturer", modelNumberUUID: "model",
            serialNumberUUID: "serial", hardwareRevUUID: "hardware_rev",
            firmwareRevUUID: "firmware_rev", softwareRevUUID: "software_rev"
        ]
        if let key = diChars[characteristic.uuid] {
            if let value = String(data: raw, encoding: .utf8) {
                DispatchQueue.main.async { self.deviceInfo[key] = value }
                log("DEVICE INFO: \(key) = \(value)")
            } else {
                let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
                DispatchQueue.main.async { self.deviceInfo[key] = hex }
                log("DEVICE INFO: \(key) = [hex] \(hex)")
            }
            // Upload device info once we have serial
            if key == "serial" {
                uploadDeviceInfo()
            }
            return
        }
        if characteristic.uuid == systemIdUUID {
            let hex = raw.map { String(format: "%02X", $0) }.joined(separator: ":")
            DispatchQueue.main.async { self.deviceInfo["system_id"] = hex }
            log("DEVICE INFO: system_id = \(hex)")
            return
        }

        guard let packet = WhoopProtocol.parsePacket(raw) else {
            // Unparseable packet — if debug capture is on, log the raw frame so we
            // can diagnose format changes (e.g., new header / new SOF / etc.)
            if debugPacketCapture && debugPacketsThisSession < maxDebugPacketsPerSession {
                debugPacketsThisSession += 1
                let hex = raw.prefix(1024).map { String(format: "%02x", $0) }.joined()
                let charName = characteristicName(characteristic.uuid)
                supabase.pushPacketDebug(
                    sessionId: reSessionId,
                    characteristic: charName,
                    packetType: -1,
                    packetCmd: -1,
                    packetLength: raw.count,
                    dataHex: String(hex),
                    note: "unparseable"
                )
            }
            return
        }

        // v68 — log every parsed packet during debug sessions. Lets us hunt unknown
        // packet types that might carry PPG / SpO2 / skin temp / respiration.
        if debugPacketCapture && debugPacketsThisSession < maxDebugPacketsPerSession {
            debugPacketsThisSession += 1
            let charName = characteristicName(characteristic.uuid)
            let hex = packet.data.prefix(1024).map { String(format: "%02x", $0) }.joined()
            supabase.pushPacketDebug(
                sessionId: reSessionId,
                characteristic: charName,
                packetType: Int(packet.type),
                packetCmd: Int(packet.cmd),
                packetLength: packet.data.count,
                dataHex: String(hex)
            )
        }

        switch characteristic.uuid {
        case cmdFromStrapUUID:
            handleCommandResponse(packet)
        case eventsUUID:
            handleEvent(packet)
        case dataUUID:
            handleData(packet)
        case memfaultUUID:
            // Firmware fault/crash log stream — push raw bytes. Rare event, always log + push.
            let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
            log("MEMFAULT: \(hex.prefix(200))")
            supabase.pushWhoopEvent(
                type: "memfault_crash",
                data: ["length": raw.count, "hex_preview": String(hex.prefix(200))],
                rawBytes: raw
            )
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error {
            log("Write ERROR on \(characteristic.uuid.uuidString.prefix(8)): \(err.localizedDescription)")
        }
    }

    // MARK: - Helper

    private func describeProperties(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("R") }
        if props.contains(.write) { parts.append("W") }
        if props.contains(.writeWithoutResponse) { parts.append("WnR") }
        if props.contains(.notify) { parts.append("N") }
        if props.contains(.indicate) { parts.append("I") }
        return parts.joined(separator: ",")
    }

    /// Map a BLE characteristic UUID to a short human name for debug logging.
    internal func characteristicName(_ uuid: CBUUID) -> String {
        switch uuid {
        case cmdFromStrapUUID: return "cmd_from_strap"
        case cmdToStrapUUID:   return "cmd_to_strap"
        case eventsUUID:       return "events"
        case dataUUID:         return "data"
        case memfaultUUID:     return "memfault"
        default:               return uuid.uuidString.lowercased()
        }
    }

    // MARK: - CMD Sweep (v68 — reverse-engineering)
    //
    // Probes a curated list of untested CMD opcodes to see which ones the strap
    // responds to. Response status codes come back on cmd_from_strap and land in
    // whoop_events via handleCommandResponse's default branch (unknown_cmd_response_<n>).
    //
    // Targets picked from:
    //   - Gaps in the known WhoopCommand enum (1-255)
    //   - Neighbors of known working CMDs (suggests feature groupings)
    //   - Opcodes other wearables use for SpO2 / skin-temp / respiration
    //
    // Pacing: 0.8s between probes, 50 probes per session max → ~40s of sweep activity.
    // Sweep kicks off 15s after HR streaming starts so the normal handshake doesn't
    // collide with our probe commands.
    internal func runCommandSweep() {
        guard cmdSweepEnabled else { return }

        // Curated probe list — prioritised by likelihood of unlocking something useful.
        // Updated from 2026-04-21 deep RE research (whoomp packet.js + bWanShiTong NOTES.md).
        let cmdsToTry: [UInt8] = [
            // 🔥 Highest-priority untested CMDs from community RE:
            63,   // SEND_R10_R11_REALTIME — possible raw optical R10/R11 channels
            105,  // TOGGLE_IMU_MODE_HISTORICAL — alternative path to IMU data
            131,  // SET_RESEARCH_PACKET — may unlock research mode
            145,  // GET_HELLO (newer variant) — may expose additional status
            39,   // SET_LED_DRIVE — PPG LED current control
            40,   // GET_LED_DRIVE
            41,   // SET_TIA_GAIN — AFE transimpedance amp
            42,   // GET_TIA_GAIN
            115,  // START_DEVICE_CONFIG_KEY_EXCHANGE — may unlock privileged mode
            14,   // TOGGLE_GENERIC_HR_PROFILE — BLE HR profile toggle
            16,   // TOGGLE_R7_DATA_COLLECTION — unknown data toggle
            66,   // SET_ALARM_TIME — exercise strap clock
            96,   // ENTER_HIGH_FREQ_SYNC — may unlock faster data
            97,   // EXIT_HIGH_FREQ_SYNC
            140,  // SET_ADVERTISING_NAME — confirmed working
            141,  // GET_ADVERTISING_NAME
            // SpO2 / pulse-ox territory
            100, 101, 102, 103, 104,
            // Optical mode neighbours (beyond what we already probe)
            109, 110, 111, 112,
            // Raw-optical neighbours (CMD 81 works, test adjacent opcodes)
            83, 85, 86, 87, 88,
            // Battery / power-mgmt neighbours
            // ⚠️ SKIPPED: 25 = FORCE_TRIM (deletes all data), 29 = REBOOT_STRAP
            24, 27, 28,
            // Research-packet neighbours (133-138 still untested)
            133, 134, 135, 136, 137, 138,
            // Labrador neighbours (124/139 return status 3, but range is unmapped)
            // ⚠️ SKIPPED: 142 = START_FIRMWARE_LOAD_NEW (enters DFU — bricks device)
            143,
            // Historical data neighbours
            // ⚠️ SKIPPED: 45 = ENTER_BLE_DFU (enters Nordic DFU mode)
            44, 46,
            // Large unexplored swath
            50, 60, 70, 90, 150, 160, 170, 180, 200, 220
        ]

        log("v68: CMD sweep starting — \(cmdsToTry.count) opcodes, 1 per 0.8s")

        for (i, cmd) in cmdsToTry.enumerated() {
            let delay = 15.0 + Double(i) * 0.8
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      let p = self.peripheral,
                      let c = self.cmdToStrap else { return }

                let packet = WhoopProtocol.buildRawCommandPacket(cmd: cmd)
                p.writeValue(packet, for: c, type: .withResponse)
                self.supabase.pushWhoopEvent(
                    type: "sweep_sent_cmd_\(cmd)",
                    data: ["idx": i, "total": cmdsToTry.count]
                )
            }
        }

        // Final checkpoint — reports how many new packet types + unknown CMD responses
        // landed during the sweep window. Makes it easy to spot the wins.
        let finalDelay = 15.0 + Double(cmdsToTry.count) * 0.8 + 10.0
        bleQueue.asyncAfter(deadline: .now() + finalDelay) { [weak self] in
            guard let self else { return }
            self.supabase.pushWhoopEvent(
                type: "cmd_sweep_complete",
                data: [
                    "re_session_id": self.reSessionId,
                    "opcodes_tried": cmdsToTry.count,
                    "debug_packets_captured": self.debugPacketsThisSession,
                    "imu_samples": self.imuSampleCount
                ]
            )
        }
    }

    // MARK: - Payload Variant Scan (v69)
    //
    // Three CMDs that returned STATUS 0 (success) on prior session are re-probed
    // with a range of payload values to see which (if any) unlock new behaviour:
    //   - CMD 131 (SET_RESEARCH_PACKET) — may enable research-mode data channels
    //   - CMD 107 (ENABLE_OPTICAL_DATA) — wrong value on first try might have blocked PPG
    //   - CMD 41  (SET_TIA_GAIN) — AFE gain sweep to surface LED-dependent data
    //   - CMD 39  (SET_LED_DRIVE) — LED current sweep to force a visible AFE change
    //
    // Staggered 1.0s apart starting at 60s after connect. Each write logs a
    // `variant_sent_cmd_<n>_val_<v>` event; responses land in whoop_events via
    // the default `unknown_cmd_response_<n>` path.
    internal func runPayloadVariantScan() {
        guard cmdSweepEnabled else { return }

        // (cmd, value, label) tuples.
        let variants: [(UInt8, UInt8, String)] = [
            // Research-packet mode scan
            (131, 0x01, "research_mode_1"),
            (131, 0x02, "research_mode_2"),
            (131, 0x03, "research_mode_3"),
            (131, 0xff, "research_mode_ff"),
            // Enable-optical payload sweep
            (107, 0x02, "optical_enable_2"),
            (107, 0x03, "optical_enable_3"),
            (107, 0xff, "optical_enable_ff"),
            // TIA gain sweep (PPG amplifier sensitivity)
            (41, 0x00, "tia_gain_min"),
            (41, 0x02, "tia_gain_low"),
            (41, 0x04, "tia_gain_mid"),
            (41, 0x07, "tia_gain_high"),
            (41, 0x0f, "tia_gain_max"),
            // LED drive sweep
            (39, 0x20, "led_drive_low"),
            (39, 0x80, "led_drive_mid"),
            (39, 0xff, "led_drive_max")
        ]

        log("v69: payload-variant scan — \(variants.count) combos starting at 60s")

        for (i, variant) in variants.enumerated() {
            let (cmd, value, label) = variant
            let delay = 60.0 + Double(i) * 1.0
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      let p = self.peripheral,
                      let c = self.cmdToStrap else { return }

                let packet: Data
                switch cmd {
                case 131: packet = WhoopProtocol.setResearchPacket(value)
                case 107: packet = WhoopProtocol.enableOpticalDataRaw(value)
                case 41:  packet = WhoopProtocol.setTiaGain(value)
                case 39:  packet = WhoopProtocol.setLedDrive(value)
                default:  packet = WhoopProtocol.buildRawCommandPacket(cmd: cmd, data: Data([value]))
                }
                p.writeValue(packet, for: c, type: .withResponse)
                self.supabase.pushWhoopEvent(
                    type: "variant_sent_cmd_\(cmd)_val_\(value)",
                    data: ["cmd": Int(cmd), "value": Int(value), "label": label, "idx": i]
                )
            }
        }

        // Post-scan checkpoint — surfaces how many new packet types were seen.
        let endDelay = 60.0 + Double(variants.count) * 1.0 + 15.0
        bleQueue.asyncAfter(deadline: .now() + endDelay) { [weak self] in
            guard let self else { return }
            self.supabase.pushWhoopEvent(
                type: "variant_scan_complete",
                data: [
                    "re_session_id": self.reSessionId,
                    "combos_tried": variants.count,
                    "debug_packets_total": self.debugPacketsThisSession,
                    "imu_samples": self.imuSampleCount
                ]
            )
        }
    }

    // MARK: - Packet Handlers

    private func handleCommandResponse(_ packet: WhoopPacket) {
        let cmd = packet.cmd

        // v66 — capture firmware version, extended battery, body location responses.
        if cmd == WhoopCommand.reportVersionInfo.rawValue {
            // v68 — response format confirmed by jogolden/whoomp parseVersionData:
            //   [3 status bytes] + [16 × uint32 LE]
            //   fields[0..3] = Harvard (MAX32652 MCU) version — the "user" firmware
            //   fields[4..7] = Boylston (nRF52840 BLE chip) version
            //   fields[8..15] = build metadata (unknown)
            let d = packet.data
            let hex = d.map { String(format: "%02x", $0) }.joined()
            log("Firmware version raw: \(hex)")

            var payload: [String: Any] = ["hex": hex]
            if let decoded = WhoopProtocol.decodeFirmwareVersion(from: d) {
                payload["harvard_version"] = decoded.harvard
                payload["boylston_version"] = decoded.boylston
                payload["build_meta"] = decoded.meta.map { Int($0) }
                log("Firmware — Harvard (MCU): \(decoded.harvard) · Boylston (BLE): \(decoded.boylston)")
            }

            // Keep the raw u32 field dump as a fallback (older-firmware compat).
            var fields: [UInt32] = []
            var i = d.startIndex
            while i + 4 <= d.endIndex {
                let v = UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)
                fields.append(v)
                i += 4
            }
            payload["u32_fields"] = fields.map { Int($0) }

            supabase.pushWhoopEvent(
                type: "firmware_version",
                data: payload,
                rawBytes: packet.data
            )
            return
        }
        if cmd == WhoopCommand.getExtendedBatteryInfo.rawValue {
            let parsed = WhoopProtocol.parseExtendedBattery(packet.data)
            var ed: [String: Any] = [:]
            if let v = parsed.voltageMv { ed["voltage_mv"] = v }
            if let s = parsed.socPct { ed["soc_pct"] = s }
            if let c = parsed.cycleCount { ed["cycle_count"] = c }
            if let h = parsed.stateOfHealthPct { ed["state_of_health_pct"] = h }
            if !ed.isEmpty {
                log("Extended battery (MAX77818): \(ed)")
            }
            // Always push — even unparseable rows carry raw_bytes for later decode.
            supabase.pushWhoopEvent(
                type: "extended_battery",
                data: ed.isEmpty ? nil : ed,
                rawBytes: packet.data
            )
            return
        }
        if cmd == WhoopCommand.getBodyLocationAndStatus.rawValue {
            let hex = packet.data.map { String(format: "%02X", $0) }.joined(separator: " ")
            log("Body location response: \(hex)")
            supabase.pushWhoopEvent(
                type: "body_location",
                data: ["bytes_hex": hex, "length": packet.data.count],
                rawBytes: packet.data
            )
            return
        }

        if cmd == WhoopCommand.getBatteryLevel.rawValue {
            if let level = WhoopProtocol.parseBattery(packet.data) {
                DispatchQueue.main.async {
                    self.battery = level
                    self.healthEngine.addBatteryReading(level)
                    self.batteryPrediction = self.healthEngine.estimatedChargeTime
                }
                log("Battery: \(String(format: "%.1f", level))%")
                updateBatteryPrediction()

                // 20% battery push notification — once per depletion cycle
                // Gives Fabi time to charge before bed, preventing overnight data gaps
                // Don't ping while he's asleep — a battery warning he can't act
                // on (can't charge while sleeping) but that wakes him is worse
                // than the data gap. Flag stays unset so it fires once he's up.
                if level <= 20 && level > 0 && !self.batteryAlertSent && !self.healthEngine.sleepDetected {
                    self.batteryAlertSent = true
                    self.sendLowBatteryNotification(level)
                } else if level > 50 {
                    self.batteryAlertSent = false  // Reset flag when charged back up
                    self.lowBatteryBuzzSent = false  // Reset strap buzz flag too
                }

                // Low-battery STRAP buzz removed (Fabi 2026-06-06): a wrist
                // vibration that can run long during BLE reconnect churn is more
                // annoying than helpful. The single phone notification above is
                // the alert — "two beeps, I look at my phone." The strap now only
                // ever buzzes for the actual wake alarm.
            }
        } else if cmd == WhoopCommand.getClock.rawValue {
            if let date = WhoopProtocol.parseClock(packet.data) {
                DispatchQueue.main.async { self.deviceClock = date }
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

                // Compute clock offset: how far behind is the strap?
                let realNow = Date()
                let offset = Int64(realNow.timeIntervalSince(date))
                strapClockOffset = offset
                let offsetDays = offset / 86400
                log("Clock: \(fmt.string(from: date)) (offset: \(offsetDays) days behind)")
            }
        } else if cmd == WhoopCommand.getHelloHarvard.rawValue && packet.data.count > 116 {
            let d = packet.data
            let s = d.startIndex
            let charging = d[s + 7] != 0
            let worn = d[s + 116] != 0
            DispatchQueue.main.async {
                self.isCharging = charging
                self.isWorn = worn
            }
            // Extract serial number (offset 16, null-terminated ASCII)
            var serial = ""
            if d.count > 26 {
                let serialBytes = d[d.startIndex + 16..<d.startIndex + 26]
                serial = String(data: serialBytes, encoding: .utf8)?.replacingOccurrences(of: "\0", with: "") ?? ""
            }

            // Extract device hash (offset 26, 54 hex chars)
            var deviceHash = ""
            if d.count > 80 {
                let hashBytes = d[d.startIndex + 26..<d.startIndex + 80]
                deviceHash = String(data: hashBytes, encoding: .utf8) ?? ""
            }

            // Battery raw (bytes 12-13 uint16 LE)
            var batteryRaw: UInt16 = 0
            if d.count > 14 {
                batteryRaw = UInt16(d[d.startIndex + 12]) | (UInt16(d[d.startIndex + 13]) << 8)
            }

            // Hardware/firmware from header bytes
            let hwRev = d[d.startIndex]
            let fwMajor = d[d.startIndex + 1]
            let fwMinor = d[d.startIndex + 2]
            let protocolVer = d[d.startIndex + 3]

            DispatchQueue.main.async {
                self.deviceInfo["serial"] = serial
                self.deviceInfo["hardware_rev"] = "0x\(String(format: "%02X", hwRev))"
                self.deviceInfo["firmware"] = "\(fwMajor).\(fwMinor)"
                self.deviceInfo["protocol"] = "0x\(String(format: "%02X", protocolVer))"
                self.deviceInfo["battery_raw"] = String(batteryRaw)
            }

            log("Worn: \(worn), Charging: \(charging), Serial: \(serial), FW: \(fwMajor).\(fwMinor), HW: 0x\(String(format: "%02X", hwRev))")
        } else if cmd == WhoopCommand.getAllHapticsPattern.rawValue {
            // Parse list of available haptic pattern IDs
            var patterns: [UInt8] = []
            for i in 0..<packet.data.count {
                patterns.append(packet.data[packet.data.startIndex + i])
            }
            DispatchQueue.main.async {
                self.availablePatterns = patterns
                self.lastHapticResult = "Found \(patterns.count) patterns: \(patterns.map { String($0) }.joined(separator: ", "))"
            }
            log("Haptic patterns: \(patterns.map { String($0) }.joined(separator: ", "))")
            supabase.pushDebugLog(key: "haptic_patterns", value: "count=\(patterns.count) ids=[\(patterns.map { String($0) }.joined(separator: ","))]")
        } else if cmd == WhoopCommand.runHapticsPattern.rawValue {
            DispatchQueue.main.async {
                self.lastHapticResult = "Pattern running!"
            }
            log("Haptic pattern started!")
        } else if cmd == WhoopCommand.stopHaptics.rawValue {
            DispatchQueue.main.async {
                self.lastHapticResult = "Haptics stopped"
            }
            log("Haptics stopped")
        } else if cmd == WhoopCommand.toggleOpticalMode.rawValue {
            let hex = packet.data.map { String(format: "%02x", $0) }.joined(separator: " ")
            DispatchQueue.main.async {
                self.ledTestResult = "Optical CMD 108 resp: \(hex)"
            }
            log("Optical mode response: \(hex)")
            // Also capture as optical packet — response bytes may encode SpO2 format
            captureOpticalPacket(type: packet.type, cmd: packet.cmd, data: packet.data)
        } else if cmd == WhoopCommand.toggleIMU.rawValue {
            let hex = packet.data.map { String(format: "%02x", $0) }.joined(separator: " ")
            log("IMU response: \(hex)")
        } else if cmd == WhoopCommand.historyAck.rawValue {
            log("History ACK confirmed by strap (cmd=23)")
        } else if cmd == WhoopCommand.sendHistoricalData.rawValue {
            log("History request ACK by strap (cmd=22) — data incoming...")
        } else {
            // Unknown command response — push to whoop_events so we catch probes (CMD 132/124/139 etc)
            let hex = packet.data.map { String(format: "%02x", $0) }.joined()
            log("CMD resp (unknown): cmd=\(cmd) len=\(packet.data.count) hex=\(hex.prefix(80))")
            supabase.pushWhoopEvent(
                type: "unknown_cmd_response_\(cmd)",
                data: ["cmd": Int(cmd), "length": packet.data.count, "hex": hex],
                rawBytes: packet.data
            )
            captureOpticalPacket(type: packet.type, cmd: packet.cmd, data: packet.data)
        }
    }

    private func handleEvent(_ packet: WhoopPacket) {
        let eventName: String
        switch packet.cmd {
        case WhoopEvent.battery.rawValue:
            // Event 3 — autonomous battery status report (separate from CMD 26 request).
            eventName = "BATTERY_EVENT"
            supabase.pushWhoopEvent(type: "battery_event", rawBytes: packet.data)
        case WhoopEvent.wristOn.rawValue:
            eventName = "WRIST_ON"
            DispatchQueue.main.async { self.isWorn = true }
            healthEngine.onWristOn()
        case WhoopEvent.wristOff.rawValue:
            eventName = "WRIST_OFF"
            DispatchQueue.main.async { self.isWorn = false }
            healthEngine.onWristOff()
        case WhoopEvent.chargingOn.rawValue:
            eventName = "CHARGING_ON"
            DispatchQueue.main.async { self.isCharging = true }
        case WhoopEvent.chargingOff.rawValue:
            eventName = "CHARGING_OFF"
            DispatchQueue.main.async { self.isCharging = false }
        case WhoopEvent.temperatureLevel.rawValue:
            eventName = "TEMPERATURE"
            handleTemperatureEvent(packet)
        case WhoopEvent.realtimeHROn.rawValue:
            eventName = "HR_STREAM_ON"
        case WhoopEvent.realtimeHROff.rawValue:
            eventName = "HR_STREAM_OFF"
        case WhoopEvent.doubleTap.rawValue:
            eventName = "DOUBLE_TAP"
            handleDoubleTap()

        // v66 — newly captured events, all pushed to whoop_events
        case WhoopEvent.strapCondition.rawValue:
            eventName = "STRAP_CONDITION"
            supabase.pushWhoopEvent(type: "strap_condition", rawBytes: packet.data)
        case WhoopEvent.afeReset.rawValue:
            eventName = "AFE_RESET"
            supabase.pushWhoopEvent(type: "afe_reset", rawBytes: packet.data)
        case WhoopEvent.ch1Saturation.rawValue:
            eventName = "CH1_SATURATION"
            supabase.pushWhoopEvent(type: "ch1_saturation", rawBytes: packet.data)
        case WhoopEvent.ch2Saturation.rawValue:
            eventName = "CH2_SATURATION"
            supabase.pushWhoopEvent(type: "ch2_saturation", rawBytes: packet.data)
        case WhoopEvent.accelSaturation.rawValue:
            eventName = "ACCEL_SATURATION"
            supabase.pushWhoopEvent(type: "accel_saturation", rawBytes: packet.data)
        case WhoopEvent.rawDataOn.rawValue:
            eventName = "RAW_DATA_ON"
            supabase.pushWhoopEvent(type: "raw_data_on", rawBytes: packet.data)
        case WhoopEvent.rawDataOff.rawValue:
            eventName = "RAW_DATA_OFF"
            supabase.pushWhoopEvent(type: "raw_data_off", rawBytes: packet.data)
        case WhoopEvent.hapticsFired.rawValue:
            eventName = "HAPTICS_FIRED"
            supabase.pushWhoopEvent(type: "haptic_fired", rawBytes: packet.data)
        case WhoopEvent.extendedBattery.rawValue:
            eventName = "EXTENDED_BATTERY"
            let parsed = WhoopProtocol.parseExtendedBattery(packet.data)
            var ed: [String: Any] = [:]
            if let v = parsed.voltageMv { ed["voltage_mv"] = v }
            if let c = parsed.cycleCount { ed["cycle_count"] = c }
            if let s = parsed.stateOfHealthPct { ed["state_of_health_pct"] = s }
            supabase.pushWhoopEvent(type: "extended_battery", data: ed.isEmpty ? nil : ed, rawBytes: packet.data)

        default:
            eventName = "EVENT_\(packet.cmd)"
            // Log unknown event data for future decoding — AND push it so we can
            // mine unknown events for patterns later.
            let hex = packet.data.map { String(format: "%02X", $0) }.joined(separator: " ")
            if packet.data.count > 0 {
                log("  Unknown event data: \(hex)")
            }
            supabase.pushWhoopEvent(
                type: "unknown_event_\(packet.cmd)",
                data: ["event_code": Int(packet.cmd), "data_hex": hex],
                rawBytes: packet.data
            )
        }
        log("Event: \(eventName)")
    }

    private func handleTemperatureEvent(_ packet: WhoopPacket) {
        // Log raw bytes for debugging (format not fully documented)
        let hex = packet.data.map { String(format: "%02X", $0) }.joined(separator: " ")
        LucidLog.log("BLE", "TEMP event raw: \(hex) (\(packet.data.count) bytes)")

        // Update diagnostic surface — visible in Settings → Skin Temp diagnostics
        DispatchQueue.main.async {
            self.lastTempEventAt = Date()
            self.lastTempRawHex = hex
            self.lastTempEventSource = "TEMPERATURE event"
            self.totalTempEventsReceived += 1
        }

        if let temp = WhoopProtocol.parseTemperature(packet.data) {
            // v152 — reject physiologically-impossible / stuck-glitch readings before
            // they cache. Only accepted values enter skinTemperature + history + push,
            // so a bad decode never becomes the baseline and the last good value holds.
            guard acceptSkinTemp(temp) else { return }
            DispatchQueue.main.async {
                self.skinTemperature = temp
            }
            skinTempHistory.append((temp: temp, time: Date()))
            // Keep last 24h
            let cutoff = Date().addingTimeInterval(-86400)
            skinTempHistory.removeAll { $0.time < cutoff }

            LucidLog.log("BLE", "Skin temp parsed: \(String(format: "%.1f", temp))°C")
        } else {
            LucidLog.log("BLE", "TEMP: could not decode \(packet.data.count) bytes")
        }
    }

    /// v152 — Skin-temp sanity guard (mirrors server migration v152). Two layers:
    /// (1) physiological gate: worn-wrist skin temp lives in [28, 39]°C; anything
    ///     outside is a bad decode (e.g. the 41.5°C garbage seen Jul 3).
    /// (2) slew-rate: skin temp cannot jump ≥2°C within an hour of the last accepted
    ///     reading — that is a sensor glitch, not physiology. Because only accepted
    ///     values are recorded in skinTempHistory, a stuck bad value keeps failing
    ///     against the held-good baseline instead of poisoning it.
    private func acceptSkinTemp(_ temp: Double) -> Bool {
        guard temp >= 28.0 && temp <= 39.0 else {
            LucidLog.log("BLE", "Skin temp \(String(format: "%.1f", temp))°C rejected: out of physiological range")
            return false
        }
        let hourAgo = Date().addingTimeInterval(-3600)
        if let last = skinTempHistory.last(where: { $0.time >= hourAgo }),
           abs(temp - last.temp) > 2.0 {
            LucidLog.log("BLE", "Skin temp \(String(format: "%.1f", temp))°C rejected: slew \(String(format: "%.1f", abs(temp - last.temp)))°C from \(String(format: "%.1f", last.temp))°C in <1h")
            return false
        }
        return true
    }

    // MARK: - Double Tap Handler

    private func handleDoubleTap() {
        // v115 — ignore double-tap events that arrive during a history backfill.
        // The strap replays its buffered event log (including OLD double-taps) while
        // dumping history; those replayed taps must not pop the live "What happened?"
        // sheet or fire a notification. Only genuine live taps count.
        guard !isDownloadingHistory else {
            log("Double tap ignored — history sync in progress (replayed event)")
            return
        }
        let now = Date()
        // Debounce: 8 seconds between valid taps (reduces false positives from jumps/clapping)
        guard now.timeIntervalSince(doubleTapDebounce) > 8.0 else {
            log("Double tap ignored — debounce (< 8s since last)")
            return
        }
        // Ignore during active exercise (HR > 110bpm = high false-positive zone from impact)
        if heartRate > 110 {
            log("Double tap ignored — HR \(heartRate)bpm (exercise mode, likely false positive)")
            return
        }
        doubleTapDebounce = now

        // ACK buzz — short confirmation vibration (use runHapticPattern for auto-stop safety)
        runHapticPattern(0)

        log("DOUBLE TAP detected")
        pendingTapTimestamp = now

        // Double-tap NEVER auto-logs. It captures the moment, arms the quick-select
        // sheet, and fires a notification — tap the notification (or open Lucid) to
        // pick what happened. Removed the old "zero-tap auto-log your #1 item"
        // behavior: it logged an espresso on every single tap. (Fabi, Jun 2026)
        DispatchQueue.main.async {
            self.lastDoubleTap = now
            self.doubleTapMessage = "What happened?"
            self.showDoubleTapSheet = true
            self.sendQuickTagNotification(
                title: "Double tap captured",
                body: "Open Lucid to tag what just happened."
            )
        }
    }

    /// Called from the UI when user picks a quick-action from the double-tap sheet
    func logDoubleTapEvent(type: String, category: String = "marker", displayName: String? = nil) {
        let tapTime = pendingTapTimestamp ?? Date()
        pendingTapTimestamp = nil

        log("DOUBLE TAP → \(type)")
        DispatchQueue.main.async {
            self.doubleTapMessage = "\(type) logged"
            self.showDoubleTapSheet = false
        }

        sendQuickTagNotification(
            title: "Tagged",
            body: "\(activityName(type)) saved to your timeline."
        )

        let currentHR = heartRate
        let avgHR = healthEngine.recentHR.isEmpty ? 70.0 :
            healthEngine.recentHR.suffix(10).reduce(0, +) / Double(min(healthEngine.recentHR.count, 10))
        let hrVariability = healthEngine.currentRMSSD

        supabase.pushActivity(
            type: type,
            source: "tap",
            startedAt: tapTime,
            hrAvg: Int(avgHR),
            hrPeak: currentHR,
            hrvAvg: hrVariability,
            notes: "Double-tap event: \(type)",
            category: category
        )

        // Mirror intake events into food_entries so they appear in the Food tab.
        // Per Fabi: 'I logged my espresso and it didn't appear in the meals thingy'
        // — that's because intake was only going to activities. Now both.
        if category == "intake" {
            // Use the friendly chip label ("Espresso") not the type ("Caffeine")
            // so the Food tab shows what was actually logged.
            let foodName = (displayName?.isEmpty == false) ? displayName! : activityName(type)
            Task { await self.mirrorIntakeToFoodEntries(name: foodName, at: tapTime, type: type) }
        }

        // EXPERIMENTAL biostate: a mood tag IS a ground-truth arousal label, so feed
        // it to the arousal detector as a correction. The server learn-guard ignores
        // noisy/artifact windows, so awake-motion taps log but won't poison baselines.
        if category == "mood", let label = Self.arousalLabel(for: type) {
            let note = "mood tag: \(displayName ?? type)"
            Task {
                await ExperimentalFeaturesService.shared.logStateCorrection(
                    detector: "arousal", correctedState: label.state, correctedValue: label.value, note: note)
            }
        }
    }

    /// Maps a Mood quick-tag type → an arousal ground-truth label (0-10, 5=baseline).
    /// Used to train the EXPERIMENTAL arousal detector from double-tap mood logs.
    static func arousalLabel(for type: String) -> (state: String, value: Double)? {
        switch type {
        case "stress_spike", "anxiety": return ("high_arousal", 8)
        case "hyperfocus":              return ("elevated", 7)
        case "good_mood":               return ("neutral", 5)
        case "low_mood":                return ("relaxed", 3)
        default:                        return nil
        }
    }

    /// Log a free-text custom event — Lucid auto-categorizes with emoji + type
    func logCustomEvent(note: String) {
        let tapTime = pendingTapTimestamp ?? Date()
        pendingTapTimestamp = nil

        let lower = note.lowercased()

        // Smart local categorization from keywords
        let (type, category, emoji) = inferEventType(from: lower)

        log("CUSTOM EVENT → \(emoji) \(type): \(note)")
        DispatchQueue.main.async {
            self.doubleTapMessage = "\(emoji) \(note.prefix(30))"
            self.showDoubleTapSheet = false
        }

        sendQuickTagNotification(
            title: "Custom event saved",
            body: "\(emoji) \(note)"
        )

        let currentHR = heartRate
        let avgHR = healthEngine.recentHR.isEmpty ? 70.0 :
            healthEngine.recentHR.suffix(10).reduce(0, +) / Double(min(healthEngine.recentHR.count, 10))

        supabase.pushActivity(
            type: type,
            source: "custom",
            startedAt: tapTime,
            hrAvg: Int(avgHR),
            hrPeak: currentHR,
            hrvAvg: healthEngine.currentRMSSD,
            notes: note,
            category: category,
            metadata: [
                "raw_note": note,
                "inferred_emoji": emoji,
                "inferred_type": type,
                "hr_at_moment": currentHR,
                "body_battery": healthEngine.bodyBattery,
                "strain": healthEngine.strainScore,
                "user_text": note
            ]
        )

        // Mirror intake freeform events into food_entries (espresso, water, etc.)
        if category == "intake" {
            Task { await self.mirrorIntakeToFoodEntries(name: note, at: tapTime, type: type) }
        }
    }

    /// Mirror intake events into food_entries so they show up in the Food tab.
    /// Type drives default kcal/NOVA/flags. Freeform name is preserved verbatim
    /// — the server canonicalizes.
    private func mirrorIntakeToFoodEntries(name: String, at: Date, type: String) async {
        let isAlcohol = (type == "alcohol")
        let isSupplement = (type == "supplement")
        let isDrink = (type == "water" || type == "caffeine" || type == "alcohol")

        // Default kcal estimates — user can edit later
        let baseKcal: Int = {
            switch type {
            case "water": return 0
            case "supplement": return 0
            case "caffeine": return 5     // espresso ballpark; user edits if cappuccino etc
            case "alcohol": return 100    // beer/wine ballpark
            case "meal": return 0         // unknown, marker only
            default: return 0
            }
        }()
        // "double"/"doppel"/"2x" doubles the estimate (mirrors server estimate_meal_from_text).
        let lname = name.lowercased()
        let kcal = (baseKcal > 0 && (lname.contains("double") || lname.contains("doppel") || lname.hasPrefix("2 ") || lname.contains("x2"))) ? baseKcal * 2 : baseKcal

        let novaClass: Int = {
            switch type {
            case "supplement": return 4   // ultra-processed
            case "alcohol": return 4
            case "caffeine": return 1     // black coffee/espresso = NOVA 1
            default: return 1
            }
        }()

        let mindTags: [String] = {
            var tags: [String] = []
            if isAlcohol { tags.append("alcohol") }
            return tags
        }()

        let item = DetectedItem(
            name: name,
            grams: 0,
            kcal: kcal,
            novaClass: novaClass,
            mindTags: mindTags,
            isDrink: isDrink,
            isAlcohol: isAlcohol,
            isSupplement: isSupplement
        )

        let entry = FoodEntry(
            id: nil,
            userId: supabase.userId,
            capturedAt: at,
            photoUrl: nil,
            geminiRawJson: nil,
            items: [item],
            caption: name,
            totalKcal: kcal,
            novaAvg: Double(novaClass),
            mindScore: nil,
            confidence: "quick_tag",
            source: "quick_tag",
            createdAt: nil,
            logQuality: FoodEntry.computeLogQuality(source: "quick_tag", confidence: "quick_tag", items: [item])
        )
        do {
            _ = try await supabase.saveFoodEntry(entry)
            log("Mirrored intake → food_entries: \(name)")
        } catch {
            log("Mirror food_entries failed: \(error.localizedDescription)")
        }
    }

    /// Infer event type, category, and emoji from free text
    private func inferEventType(from text: String) -> (type: String, category: String, emoji: String) {
        // Intake / substances
        if text.contains("coffee") || text.contains("caffeine") || text.contains("espresso") || text.contains("latte") {
            return ("caffeine", "intake", "☕")
        }
        if text.contains("creatine") || text.contains("supplement") || text.contains("vitamin") || text.contains("omega") || text.contains("magnesium") || text.contains("zinc") || text.contains("protein shake") || text.contains("pre-workout") {
            return ("supplement", "intake", "💊")
        }
        if text.contains("ate") || text.contains("meal") || text.contains("lunch") || text.contains("dinner") || text.contains("breakfast") || text.contains("food") || text.contains("snack") || text.contains("eaten") {
            return ("meal", "intake", "🍽️")
        }
        if text.contains("water") || text.contains("hydrat") || text.contains("drank") {
            return ("water", "intake", "💧")
        }
        if text.contains("alcohol") || text.contains("beer") || text.contains("wine") || text.contains("drink") || text.contains("shot") || text.contains("cocktail") {
            return ("alcohol", "intake", "🍺")
        }

        // Physical
        if text.contains("workout") || text.contains("gym") || text.contains("exercise") || text.contains("training") || text.contains("lift") || text.contains("run ") || text.contains("running") {
            return ("exercise", "physical", "🏋️")
        }
        if text.contains("walk") || text.contains("outside") || text.contains("fresh air") || text.contains("hike") {
            return ("walk", "physical", "🚶")
        }
        if text.contains("sauna") || text.contains("steam") {
            return ("sauna", "physical", "🧖")
        }
        if text.contains("cold") || text.contains("ice bath") || text.contains("plunge") {
            return ("cold_plunge", "physical", "🥶")
        }
        if text.contains("stretch") || text.contains("yoga") {
            return ("stretching", "physical", "🧘")
        }
        if text.contains("ski") || text.contains("slope") || text.contains("piste") {
            return ("skiing", "physical", "⛷️")
        }
        if text.contains("ride") || text.contains("motorcycle") || text.contains("bike") || text.contains("motorbike") {
            return ("riding", "physical", "🏍️")
        }

        // Mood / emotional
        if text.contains("stress") || text.contains("anxious") || text.contains("anxiety") || text.contains("panic") || text.contains("overwhelm") {
            return ("stress_spike", "mood", "😤")
        }
        if text.contains("argument") || text.contains("fight") || text.contains("angry") || text.contains("frustrat") || text.contains("pissed") {
            return ("conflict", "mood", "😡")
        }
        if text.contains("happy") || text.contains("great") || text.contains("amazing") || text.contains("good mood") || text.contains("excited") {
            return ("positive_mood", "mood", "😊")
        }
        if text.contains("sad") || text.contains("down") || text.contains("depressed") || text.contains("lonely") || text.contains("crying") {
            return ("low_mood", "mood", "😢")
        }
        if text.contains("tired") || text.contains("exhausted") || text.contains("fatigue") || text.contains("sleepy") || text.contains("drained") {
            return ("fatigue", "mood", "😴")
        }

        // Cognitive
        if text.contains("meditat") || text.contains("mindful") || text.contains("breathing") {
            return ("meditation", "cognitive", "🧘")
        }
        if text.contains("focus") || text.contains("deep work") || text.contains("coding") || text.contains("working") || text.contains("productive") {
            return ("deep_work", "cognitive", "🧠")
        }
        if text.contains("idea") || text.contains("thought") || text.contains("insight") || text.contains("realized") {
            return ("brain_dump", "marker", "💡")
        }
        if text.contains("read") || text.contains("book") || text.contains("article") {
            return ("reading", "cognitive", "📖")
        }

        // Social
        if text.contains("meeting") || text.contains("call") || text.contains("chat") || text.contains("talked") {
            return ("social", "social", "👥")
        }
        if text.contains("family") || text.contains("parents") || text.contains("mom") || text.contains("dad") || text.contains("brother") || text.contains("sister") {
            return ("family", "social", "👨‍👩‍👦")
        }

        // Health
        if text.contains("headache") || text.contains("migraine") || text.contains("pain") || text.contains("sick") || text.contains("nausea") {
            return ("symptom", "health", "🤒")
        }
        if text.contains("medicine") || text.contains("ibuprofen") || text.contains("tylenol") || text.contains("pill") || text.contains("medication") {
            return ("medication", "health", "💉")
        }

        // Sleep
        if text.contains("nap") || text.contains("slept") || text.contains("woke up") || text.contains("sleep") {
            return ("nap", "sleep", "😴")
        }

        // Default — generic marker with the note preserved
        return ("note", "marker", "📝")
    }

    // MARK: - Widget + Live Activity Sync

    /// Push current health data to App Groups for widget display.
    /// IMPORTANT: load existing struct so we preserve mode/state fields owned
    /// by ContentView (appMode, recoveryOverlay, dayState). Otherwise the widget
    /// face would flicker back to defaults every 60s while BLE is streaming.
    func syncSharedHealthData() {
        var data = SharedHealthData.load()
        data.recoveryScore = healthEngine.recoveryScore
        data.sleepScore = healthEngine.sleepScore
        data.strainScore = healthEngine.strainScore
        data.bodyBattery = healthEngine.bodyBattery
        data.trainingLoadRatio = healthEngine.trainingLoadRatio
        data.trainingLoadStatus = healthEngine.trainingLoadStatus
        data.sleepConsistencyScore = healthEngine.sleepConsistencyScore
        data.heartRate = heartRate
        data.currentRMSSD = healthEngine.currentRMSSD
        data.currentHRZone = healthEngine.currentHRZone
        data.respiratoryRate = healthEngine.respiratoryRate
        data.isConnected = connectionState == .streaming || connectionState == .connected
        data.strapBattery = battery
        data.sleepDetected = healthEngine.sleepDetected
        data.sleepStage = healthEngine.currentSleepStage.rawValue
        data.sleepDurationHours = healthEngine.sleepDurationHours
        data.readiness = healthEngine.readiness.rawValue.lowercased()
        data.cognitiveCapacity = healthEngine.cognitiveCapacity
        data.cognitiveLabel = healthEngine.cognitiveLabel
        data.sdnn = healthEngine.sdnn
        data.pnn50 = healthEngine.pnn50
        data.dfaAlpha1 = healthEngine.dfaAlpha1
        data.illnessAlert = healthEngine.illnessAlert
        data.illnessRisk = healthEngine.illnessRisk
        data.trainingMonotony = healthEngine.trainingMonotony
        data.trainingStrain = healthEngine.trainingStrain
        data.activeActivityType = manualActivityType ?? activityDetector.activeDetections.first?.type
        data.activeActivityStart = manualActivityStart ?? activityDetector.activeDetections.first?.startTime
        data.lastUpdated = Date()
        SharedHealthData.save(data)

        // Tell widgets to refresh
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Bridge Live Activity (always-on while BLE streams)
    //
    // Distinct from manual workout activities (sauna, cold_plunge, exercise).
    // Activity type "bridge" → continuous lock-screen face showing live HR.
    // Auto-managed by the connectionState sink in init():
    //   .streaming    → startBridgeActivityIfNeeded() (only if no manual one)
    //   .disconnected → stopBridgeActivityIfActive()  (only if it's the bridge)
    // updateLiveActivity() ticks per BLE reading (~5-10s), giving true live HR.
    static let bridgeActivityType = "bridge"

    /// Start the always-on bridge Live Activity, but only if no other activity
    /// is running (we never replace a user's manual workout/sauna).
    private func startBridgeActivityIfNeeded() {
        if let current = currentLiveActivity,
           current.attributes.activityType != Self.bridgeActivityType {
            log("Skipping bridge activity start — manual activity (\(current.attributes.activityType)) is running")
            return
        }
        if currentLiveActivity?.attributes.activityType == Self.bridgeActivityType {
            // Already running — connectionState may oscillate connected ↔ streaming
            // briefly during reconnects. Keep the activity alive across that.
            return
        }
        startLiveActivity(type: Self.bridgeActivityType)
    }

    /// Stop the bridge activity ONLY — never touches a manual workout activity.
    private func stopBridgeActivityIfActive() {
        guard let current = currentLiveActivity,
              current.attributes.activityType == Self.bridgeActivityType else {
            return
        }
        stopLiveActivity()
    }

    /// Start a Live Activity for an active health event (Spotify-style lock screen bar)
    func startLiveActivity(type: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log("Live Activities not enabled")
            return
        }

        // End any existing live activity first
        stopLiveActivity()

        let attributes = LucidActivityAttributes(
            activityType: type,
            startTime: Date()
        )

        let state = LucidActivityAttributes.ContentState(
            heartRate: heartRate,
            duration: 0,
            strainAccumulated: healthEngine.strainScore,
            currentHRZone: healthEngine.currentHRZone,
            bodyBattery: healthEngine.bodyBattery,
            emoji: activityEmoji(type),
            currentRMSSD: healthEngine.currentRMSSD
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(30)),
                pushType: nil
            )
            currentLiveActivity = activity
            liveActivityStartTime = Date()
            lastLiveActivityState = state
            lastLiveActivityUpdate = Date()
            log("Live Activity started: \(type)")
        } catch {
            log("Live Activity failed: \(error.localizedDescription)")
        }
    }

    /// Update the Live Activity with current vitals.
    /// Throttled to ≥0.9s between updates AND deduped against last state —
    /// iOS silently drops updates faster than ~1 Hz, and identical states
    /// just burn budget. (See smart-alarm-research.md → Live Activity rate-matching.)
    func updateLiveActivity() {
        guard let activity = currentLiveActivity,
              let startTime = liveActivityStartTime else { return }

        let now = Date()
        if let last = lastLiveActivityUpdate, now.timeIntervalSince(last) < 0.9 {
            return  // throttle: iOS caps at ~1 Hz
        }

        let state = LucidActivityAttributes.ContentState(
            heartRate: heartRate,
            duration: now.timeIntervalSince(startTime),
            strainAccumulated: healthEngine.strainScore,
            currentHRZone: healthEngine.currentHRZone,
            bodyBattery: healthEngine.bodyBattery,
            emoji: activityEmoji(activity.attributes.activityType),
            currentRMSSD: healthEngine.currentRMSSD
        )

        // Dedupe — only the duration drift matters if HR/HRV/zone/battery are unchanged,
        // and duration is a TimelineView responsibility on the lock face anyway.
        if let prev = lastLiveActivityState,
           prev.heartRate == state.heartRate,
           prev.currentHRZone == state.currentHRZone,
           Int(prev.bodyBattery) == Int(state.bodyBattery),
           Int(prev.currentRMSSD) == Int(state.currentRMSSD) {
            return
        }

        lastLiveActivityState = state
        lastLiveActivityUpdate = now

        // staleDate = now + 30s so DI greys out if BLE drops, instead of stale numbers.
        let stale = now.addingTimeInterval(30)
        Task {
            await activity.update(.init(state: state, staleDate: stale))
        }
    }

    /// End the current Live Activity
    func stopLiveActivity() {
        guard let activity = currentLiveActivity else { return }

        let finalState = LucidActivityAttributes.ContentState(
            heartRate: heartRate,
            duration: Date().timeIntervalSince(liveActivityStartTime ?? Date()),
            strainAccumulated: healthEngine.strainScore,
            currentHRZone: 0,
            bodyBattery: healthEngine.bodyBattery,
            emoji: activityEmoji(activity.attributes.activityType),
            currentRMSSD: healthEngine.currentRMSSD
        )

        // bridge mode dismisses immediately (ambient — no "lingering" state).
        // Workout sessions linger 60s so the user sees the final HR/strain frozen.
        let policy: ActivityUIDismissalPolicy = (activity.attributes.activityType == "bridge")
            ? .immediate
            : .after(.now + 60)

        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: policy)
        }

        currentLiveActivity = nil
        liveActivityStartTime = nil
        lastLiveActivityState = nil
        lastLiveActivityUpdate = nil
        log("Live Activity ended")
    }

    private func activityEmoji(_ type: String) -> String {
        switch type {
        case "sauna": return "🧖"
        case "cold_plunge": return "🥶"
        case "exercise", "workout": return "🏋️"
        case "skiing": return "⛷️"
        case "nap": return "😴"
        case "anxiety": return "😰"
        case "deep_work": return "🧠"
        case "meditation": return "🧘"
        default: return "🎯"
        }
    }

    /// Called by auto-detection engine when an activity is detected
    /// NO HAPTICS — auto-detection buzzing was too aggressive and wouldn't stop.
    /// Activities still get logged to Supabase silently.
    func markAutoDetectedActivity(type: String = "activity", isSleep: Bool = false) {
        lastAutoDetectedActivity = Date()
        autoDetectStartTime = Date()
        log("Auto-detect: \(type) started (silent)")

        // Start Live Activity for non-sleep activities
        if !isSleep {
            startLiveActivity(type: type)
        }

        DispatchQueue.main.async {
            self.doubleTapMessage = "\(type) detected"
        }
    }

    /// Called when an auto-detected activity ends — NO HAPTICS
    func markAutoDetectedActivityEnd(type: String = "activity", isSleep: Bool = false, metadata: [String: Any]? = nil) {
        log("Auto-detect: \(type) ended (silent)")

        let startTime = autoDetectStartTime ?? Date().addingTimeInterval(-300)
        let avgHR = healthEngine.recentHR.isEmpty ? 0 :
            Int(healthEngine.recentHR.suffix(30).reduce(0, +) / Double(min(healthEngine.recentHR.count, 30)))
        let peakHR = healthEngine.recentHR.isEmpty ? 0 : Int(healthEngine.recentHR.suffix(30).max() ?? 0)

        supabase.pushActivity(
            type: type,
            source: "auto",
            startedAt: startTime,
            endedAt: Date(),
            hrAvg: avgHR,
            hrPeak: peakHR,
            hrvAvg: healthEngine.currentRMSSD,
            category: "physical",
            metadata: metadata
        )
        autoDetectStartTime = nil

        // End Live Activity
        stopLiveActivity()

        // v112 (2026-05-30) — auto-detected-exercise → "🧠 Peak Focus Window"
        // alert disabled. Auto-detection itself is dead since v110 but this
        // call would still have fired on a manually-ended auto session.
        // Manual exercise path below (line ~3387) preserves the alert because
        // it's user-initiated (double-tap mark, not algorithm detection).
        // if type == "exercise" {
        //     let duration = Date().timeIntervalSince(startTime)
        //     if duration >= 10 * 60 {
        //         scheduleExerciseCognitiveAlert()
        //     }
        // }

        DispatchQueue.main.async {
            self.doubleTapMessage = "\(type) ended"
        }
    }

    /// Schedule push notification 2 min after exercise for ADHD cognitive window
    private func scheduleExerciseCognitiveAlert() {
        let content = UNMutableNotificationContent()
        content.title = "🧠 Peak Focus Window Open"
        content.body = "Your brain is sharpest right now — the next 10-15 min are prime for your hardest task."
        content.sound = .default
        content.categoryIdentifier = "COGNITIVE_WINDOW"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 120, repeats: false)
        let request = UNNotificationRequest(identifier: "cognitive-window-\(Date().timeIntervalSince1970)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let e = error { self.log("Cognitive window notif error: \(e)") }
            else { self.log("Cognitive window alert scheduled (2 min)") }
        }
    }

    // MARK: - Manual Activity Tagging

    private var manualActivityTypeKey: String { "lucid_manual_activity_type" }
    private var manualActivityStartKey: String { "lucid_manual_activity_start" }

    /// Restore any in-flight manual activity that survived a force-quit.
    /// Call this once after BLE connects so we can complete orphaned sessions.
    func restoreOrphanedManualActivity() {
        guard manualActivityType == nil,
              let savedType = UserDefaults.standard.string(forKey: manualActivityTypeKey),
              let savedEpoch = UserDefaults.standard.object(forKey: manualActivityStartKey) as? Double else { return }
        let savedStart = Date(timeIntervalSince1970: savedEpoch)
        let elapsed = Date().timeIntervalSince(savedStart)
        // Only restore if started <6h ago — older orphans are likely stale
        guard elapsed < 6 * 3600 else {
            UserDefaults.standard.removeObject(forKey: manualActivityTypeKey)
            UserDefaults.standard.removeObject(forKey: manualActivityStartKey)
            return
        }
        manualActivityType = savedType
        manualActivityStart = savedStart
        log("MANUAL ACTIVITY: Restored orphaned \(savedType) from \(Int(elapsed/60))min ago")
    }

    /// Start a manual activity (Deep Work, Exercise, Meditation, etc.)
    /// This teaches the algorithm what different activities look like in HR/HRV data.
    func startManualActivity(type: String) {
        if let current = manualActivityType {
            // End the previous one first
            endManualActivity()
        }
        manualActivityType = type
        manualActivityStart = Date()
        // Persist so the session survives a force-quit or app termination
        UserDefaults.standard.set(type, forKey: manualActivityTypeKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: manualActivityStartKey)
        startLiveActivity(type: type)
        log("MANUAL ACTIVITY: \(type) started")
    }

    /// End the current manual activity and push to Supabase
    func endManualActivity() {
        guard let type = manualActivityType, let start = manualActivityStart else { return }
        // Clear persistence first so a crash during pushActivity doesn't re-create on next launch
        UserDefaults.standard.removeObject(forKey: manualActivityTypeKey)
        UserDefaults.standard.removeObject(forKey: manualActivityStartKey)

        let avgHR = healthEngine.recentHR.isEmpty ? 0 :
            Int(healthEngine.recentHR.suffix(30).reduce(0, +) / Double(min(healthEngine.recentHR.count, 30)))
        let peakHR = healthEngine.recentHR.isEmpty ? 0 : Int(healthEngine.recentHR.suffix(30).max() ?? 0)
        let duration = Date().timeIntervalSince(start)

        supabase.pushActivity(
            type: type,
            source: "manual",
            startedAt: start,
            endedAt: Date(),
            hrAvg: avgHR,
            hrPeak: peakHR,
            hrvAvg: healthEngine.currentRMSSD,
            notes: "Manual: \(type) (\(Int(duration / 60))min)",
            category: type == "exercise" || type == "workout" ? "physical" : "cognitive"
        )

        log("MANUAL ACTIVITY: \(type) ended (\(Int(duration / 60))min, avg HR \(avgHR))")

        // Post-exercise cognitive window for manual exercise/workout
        if (type == "exercise" || type == "workout") && duration >= 10 * 60 {
            scheduleExerciseCognitiveAlert()
        }

        // Heart Rate Recovery tracking (HRR1 at 60s, HRR2 at 120s post-exercise)
        if peakHR > 100 && duration >= 5 * 60 {
            healthEngine.markExerciseEnd(peakHR: peakHR)
            healthEngine.updateMaxHR(sessionMaxHR: peakHR)
            // Schedule HRR1 check at 60s
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self = self else { return }
                self.healthEngine.computeHRR1(currentHR: self.heartRate)
            }
            // Schedule HRR2 check at 120s
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self = self else { return }
                self.healthEngine.computeHRR2(currentHR: self.heartRate)
                self.log("HRR: peak \(peakHR) → 1min \(self.healthEngine.lastHRR1)bpm drop, 2min \(self.healthEngine.lastHRR2)bpm drop (\(self.healthEngine.hrrStatus))")
            }
        }

        manualActivityType = nil
        manualActivityStart = nil
        stopLiveActivity()
    }

    // MARK: - Strain Limit Notification

    func checkStrainLimit(currentStrain: Double) {
        guard currentStrain >= strainThreshold && !strainAlertSent else { return }
        strainAlertSent = true
        log("STRAIN LIMIT HIT (\(String(format: "%.1f", currentStrain)) ≥ \(strainThreshold)) — logged (no haptic)")
        // NO HAPTIC — auto-buzzing was too aggressive. Just log it.
    }

    func resetDailyAlerts() {
        strainAlertSent = false
    }

    // MARK: - Fallback Alarm (iOS Notification — works even if phone dies or BLE disconnects)

    /// Schedule a fallback alarm notification at the END of the smart alarm window.
    /// If the smart alarm fires earlier (detected light sleep + strap buzz), this gets cancelled.
    /// If the phone dies or BLE disconnects, iOS still delivers the notification.
    func scheduleFallbackAlarm() {
        let d = UserDefaults.standard
        let alcohol = d.bool(forKey: "lucid_alcohol_active")
        let alarmEnabled = alcohol || d.bool(forKey: "lucid_alarm_enabled")
        guard alarmEnabled else {
            cancelFallbackAlarm()
            return
        }

        // Alcohol night: backstop at the humane noon time, never the user's
        // normal (earlier) end — that early force-wake is the bug we're fixing.
        let endMinutes = alcohol
            ? (d.integer(forKey: "lucid_alcohol_end") > 0 ? d.integer(forKey: "lucid_alcohol_end") : 12 * 60)
            : d.integer(forKey: "lucid_alarm_end")
        guard endMinutes > 0 else { return }

        let endHour = endMinutes / 60
        let endMin = endMinutes % 60

        // Cancel any existing fallback chain before re-scheduling.
        cancelFallbackAlarm()

        // v108: SINGLE fallback alarm (was 15 chained — Fabi feedback 2026-05-25:
        // "30 notifications is the dumbest thing"). One UNCalendarNotificationTrigger
        // with defaultCritical sound + .timeSensitive bypasses silent/DND. If the
        // first pulse doesn't wake him, the spam-chain wouldn't have helped anyway
        // (and only frustrates after he's already up).
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let now = Date()
        var baseComponents = calendar.dateComponents([.year, .month, .day], from: now)
        baseComponents.hour = endHour
        baseComponents.minute = endMin
        baseComponents.second = 0
        var baseDate = calendar.date(from: baseComponents) ?? now
        // If end-time is in the past for today, push to tomorrow.
        if baseDate < now {
            baseDate = calendar.date(byAdding: .day, value: 1, to: baseDate) ?? baseDate
        }

        // v108: single pulse (was for i in 0..<15)
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: baseDate
        )
        let content = UNMutableNotificationContent()
        content.title = alcohol ? "\u{1F305} Morning — no rush" : "\u{23F0} Wake Up"
        content.body = alcohol
            ? "Recovery backstop. You slept in to clear last night — get up when you're ready."
            : "Smart alarm fallback. Time to get up!"
        content.sound = UNNotificationSound.defaultCritical
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = fallbackAlarmId
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(fallbackAlarmId)_0",
            content: content,
            trigger: trigger
        )
        center.add(request) { [weak self] error in
            if let error = error {
                self?.log("Fallback alarm schedule FAILED: \(error.localizedDescription)")
            }
        }
        log("Fallback alarm scheduled at \(endHour):\(String(format: "%02d", endMin)) (single pulse)")
    }

    /// Cancel the fallback alarm (called when smart alarm fires successfully).
    /// Removes the pulse + any legacy chained ids from older installs (0..<15).
    func cancelFallbackAlarm() {
        let center = UNUserNotificationCenter.current()
        // Clear current single-pulse id + legacy 15-chain ids + bare-id form
        let ids = (0..<15).map { "\(fallbackAlarmId)_\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids + [fallbackAlarmId])
        log("Fallback alarm cancelled")
    }

    // MARK: - Go-Back-To-Sleep wake (in-window coach)

    /// Arm a one-off gentle wake at a specific time — used by the "go back to
    /// sleep?" coach when Fabi chooses to grab one more cycle. Uses its OWN id so
    /// it never clobbers the nightly fallback alarm. Re-arming replaces it.
    func armGoBackWake(at date: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["lucid_goback_wake"])
        let now = Date()
        guard date > now else { return }

        let calendar = Calendar.current
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let content = UNMutableNotificationContent()
        content.title = "\u{2600}\u{FE0F} Time to get up"
        content.body = "Your extra cycle's done — easy does it."
        content.sound = UNNotificationSound.defaultCritical
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = fallbackAlarmId
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "lucid_goback_wake", content: content, trigger: trigger
        )
        center.add(request) { [weak self] error in
            if let error = error {
                self?.log("Go-back wake schedule FAILED: \(error.localizedDescription)")
            }
        }
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        log("Go-back wake armed at \(h):\(String(format: "%02d", m))")
    }

    // MARK: - Tonight Plan Sync (Smart Alarm Module 7)

    /// Pull tonight's plan from the server and apply it. Safe to call on app
    /// foreground, on the wind-down transition, and after toggling drinking.
    func syncTonightPlan() async {
        guard let plan = await supabase.fetchTonightPlan() else { return }
        applyTonightPlan(plan)
    }

    /// Write the plan into local alarm state. Alcohol nights set the override
    /// keys read by HealthEngine.alarmWindow* + scheduleFallbackAlarm; otherwise
    /// the override is cleared and the user's own window is used.
    func applyTonightPlan(_ plan: TonightPlan) {
        let d = UserDefaults.standard
        if plan.isAlcohol {
            d.set(true, forKey: "lucid_alcohol_active")
            d.set(plan.windowStartMinutes > 0 ? plan.windowStartMinutes : 9 * 60, forKey: "lucid_alcohol_start")
            d.set(plan.windowEndMinutes > 0 ? plan.windowEndMinutes : 12 * 60, forKey: "lucid_alcohol_end")
        } else {
            d.set(false, forKey: "lucid_alcohol_active")
        }
        DispatchQueue.main.async {
            self.tonightPlanMode = plan.mode
            self.tonightPlanNote = plan.note
            self.tonightWindowStart = plan.windowStartMinutes
            self.tonightWindowEnd = plan.windowEndMinutes
        }
        scheduleFallbackAlarm()
        log("Applied tonight plan: mode=\(plan.mode) window=\(plan.windowStartMinutes)-\(plan.windowEndMinutes)")
        evt("plan_applied", "mode=\(plan.mode) window=\(plan.windowStartMinutes)-\(plan.windowEndMinutes)")
    }

    // MARK: - v154 Smart Wake (server-driven actuator + arm/cancel/status)

    /// True if a wake actuator fired within the dedup window — used to prevent
    /// the server nudge + local light-sleep detection from double-buzzing.
    private func recentlyActuated() -> Bool {
        guard let at = lastActuatorFireAt else { return false }
        return Date().timeIntervalSince(at) < actuatorDedupWindow
    }

    /// Record an actuator fire for idempotency. Single source of truth for both
    /// the server-nudge path and the local light-sleep path.
    private func markActuatorFired(sessionId: String?) {
        lastActuatorFireAt = Date()
        if let sessionId = sessionId { lastActuatedSessionId = sessionId }
    }

    /// The progressive strap-buzz + haptic wake ramp — extracted verbatim from
    /// the local smart-alarm callback so the v154 server path reuses the EXACT
    /// same tuned mechanism (gentle → escalate → peak over ~80s, each escalation
    /// gated on "already awake"). Runs on the BLE queue like the original.
    func fireWakeHapticRamp(reasonLabel: String) {
        // Log the wake EXECUTION — strap connectivity is the key unknown when an
        // alarm "fires but doesn't wake him" (haptic can't reach a dropped strap).
        let canBuzz = self.peripheral != nil && self.cmdToStrap != nil
        self.evt("alarm_fired", "\(reasonLabel) canBuzz=\(canBuzz) hr=\(self.heartRate) batt=\(Int(self.battery))%")
        // Each ESCALATION pulse first checks he hasn't already woken from an
        // earlier pulse — no point buzzing harder at someone who's up. Only the
        // gentle opener fires unconditionally (that's the wake itself).
        func escalateIfAsleep(_ pattern: UInt8) {
            if self.healthEngine.isLikelyAwakeNow {
                self.evt("alarm_pulse_skip", "pattern=\(pattern) reason=already-awake hr=\(self.heartRate)")
                self.forceStopHaptics(); return
            }
            self.evt("alarm_pulse", "pattern=\(pattern) canBuzz=\(self.peripheral != nil && self.cmdToStrap != nil)")
            self.sendHapticRaw(pattern)
        }
        // Gentle opening pulse (pattern 0)
        self.sendHapticRaw(0)
        self.bleQueue.asyncAfter(deadline: .now() + 0.5) { self.forceStopHaptics() }
        // Mid pulse (pattern 1) at +20s — stronger, still soft
        self.bleQueue.asyncAfter(deadline: .now() + 20.0) { escalateIfAsleep(1) }
        self.bleQueue.asyncAfter(deadline: .now() + 20.5) { self.forceStopHaptics() }
        // Stronger pulse (pattern 2) at +45s
        self.bleQueue.asyncAfter(deadline: .now() + 45.0) { escalateIfAsleep(2) }
        self.bleQueue.asyncAfter(deadline: .now() + 45.5) { self.forceStopHaptics() }
        // Final double-buzz at +75s if still asleep — escalation peak
        self.bleQueue.asyncAfter(deadline: .now() + 75.0) { escalateIfAsleep(2) }
        self.bleQueue.asyncAfter(deadline: .now() + 75.5) { self.forceStopHaptics() }
        self.bleQueue.asyncAfter(deadline: .now() + 77.0) { escalateIfAsleep(2) }
        self.bleQueue.asyncAfter(deadline: .now() + 77.5) { self.forceStopHaptics() }
        // Backup stop — fires even if connection drops and reconnects
        self.bleQueue.asyncAfter(deadline: .now() + 80.0) { self.forceStopHaptics() }
    }

    /// v154 server-driven wake actuator. Runs the SAME strap-buzz ramp as the
    /// local smart alarm plus a lock-screen critical ping. IDEMPOTENT: if any
    /// wake fired in the last ~8 min it skips — so the server nudge, a 30s
    /// re-poll, and the local detector can never stack into a double buzz.
    func runSmartWakeActuator(sessionId: String?, reason: String) {
        if recentlyActuated() {
            let ago = lastActuatorFireAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
            evt("smart_wake_skip", "reason=recent-fire ago=\(ago)s session=\(sessionId?.prefix(8) ?? "?")")
            return
        }
        markActuatorFired(sessionId: sessionId)
        evt("smart_wake_fire", "reason=\(reason) session=\(sessionId?.prefix(8) ?? "?")")

        // The real wake — buzz the strap on his wrist (a banner can't wake him).
        fireWakeHapticRamp(reasonLabel: "smart_wake reason=\(reason)")
        // Lock-screen critical ping — reuse the existing tuned buzz chain.
        scheduleAlarmBuzzChain(
            title: wakeTitle(),
            body: "Smart wake — the right moment to get up.",
            count: 1, spacingSec: 2, firstDelaySec: 0.1,
            idPrefix: "lucid_smart_alarm"
        )
        // The wake fired — cancel the safety-net fallback + deadline backup so he
        // isn't buzzed again later. (The fallback MECHANISM stays for future nights.)
        cancelFallbackAlarm()
        cancelSmartWakeBackup()
    }

    /// Persist + publish the armed flag. Thread-safe from any queue.
    private func setSmartWakeArmed(_ armed: Bool) {
        UserDefaults.standard.set(armed, forKey: Self.smartWakeArmedKey)
        DispatchQueue.main.async { self.smartWakeArmed = armed }
    }

    /// Arm the v154 engine for tonight. Sets the local ownership flag (so the UI +
    /// local detector defer to the server), keeps the fallback net active, and —
    /// when a hard "up by" deadline is given — schedules an independent critical
    /// backup at that time so he wakes even if BOTH the nudge and buzz fail.
    @discardableResult
    func armSmartWake(latestWake: Date? = nil, prepMin: Int = 30) async -> SmartWakePlan? {
        let plan = await supabase.armSmartWake(latestWake: latestWake, prepMin: prepMin)
        guard let plan = plan else {
            evt("smart_wake_arm_failed", "")
            return nil
        }
        setSmartWakeArmed(true)
        DispatchQueue.main.async { self.smartWakePlan = plan }
        evt("smart_wake_armed", "target=\(plan.targetH)h floor=\(plan.safetyFloorH)h deadline=\(plan.latestWakeLabel ?? "none") belowFloor=\(plan.deadlineBelowFloor)")
        // Keep the ultimate safety net active for tonight (uses the user's own
        // alarm settings; never removed — do NOT rely on it as the primary wake).
        scheduleFallbackAlarm()
        // Hard critical backup at the requested deadline (esp. below-floor case).
        if let dl = latestWake {
            scheduleSmartWakeBackup(at: dl)
        } else {
            // No deadline: scheduleFallbackAlarm() above no-ops unless the user's
            // own alarm toggle (or alcohol mode) is on. Guarantee an OS-level
            // backstop that fires even from a KILLED app — the nudge→strap path
            // needs the app alive, this doesn't. ~10.5h out is later than the
            // server's onset+9.5h humane cap (onset > arm-time), so it never
            // pre-empts the real wake — it only catches total-failure oversleep.
            let d = UserDefaults.standard
            let fallbackWillFire = d.bool(forKey: "lucid_alcohol_active") || d.bool(forKey: "lucid_alarm_enabled")
            if !fallbackWillFire {
                scheduleSmartWakeBackup(at: Date(timeIntervalSinceNow: 10.5 * 3600))
            }
        }
        await refreshSmartWakeStatus()
        return plan
    }

    /// Cancel tonight's smart-wake session and clear all local ownership state.
    func cancelSmartWake() async {
        _ = await supabase.cancelSmartWake()
        setSmartWakeArmed(false)
        DispatchQueue.main.async { self.smartWakePlan = nil }
        cancelSmartWakeBackup()
        evt("smart_wake_cancelled", "")
        await refreshSmartWakeStatus()
    }

    /// Pull the live status and reconcile the local armed flag with server truth.
    /// Once the server session completes (post-wake / next day) the status goes
    /// idle → we clear the local flag, re-enabling the local light-sleep detector.
    func refreshSmartWakeStatus() async {
        let st = await supabase.fetchSmartWakeStatus()
        DispatchQueue.main.async { self.smartWakeStatus = st }
        if let st = st, st.armed != self.smartWakeArmed {
            setSmartWakeArmed(st.armed)
        }
    }

    /// Independent hard-deadline backup for an armed night — one critical
    /// notification at the user's "up by" time. Own id so it never clobbers the
    /// nightly fallback. Guarantees a wake even if the whole nudge+buzz path
    /// fails (fail toward waking, never toward silence).
    private func scheduleSmartWakeBackup(at date: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [smartWakeBackupId])
        guard date > Date() else { return }
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let content = UNMutableNotificationContent()
        content.title = wakeTitle()
        content.body = "Backup alarm — your set time is here."
        content.sound = UNNotificationSound.defaultCritical
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = fallbackAlarmId
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: smartWakeBackupId, content: content, trigger: trigger))
        let h = Calendar.current.component(.hour, from: date)
        let m = Calendar.current.component(.minute, from: date)
        log("Smart-wake deadline backup armed at \(h):\(String(format: "%02d", m))")
    }

    private func cancelSmartWakeBackup() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [smartWakeBackupId])
    }

    /// Wind-down nudge with a rendered image attachment (first use of
    /// UNNotificationAttachment in the app). Fired when wind-down mode opens.
    func sendWindDownNotification(note: String) {
        let content = UNMutableNotificationContent()
        content.title = "\u{1F319} Time to wind down"
        content.body = note.isEmpty ? "Slow the body down. Lights low, screens away." : note
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = "lucid_winddown"
        if let imgURL = makeNotificationImage(
            title: "Wind down",
            subtitle: "Slow the body down",
            accent: UIColor(red: 0.545, green: 0.486, blue: 0.965, alpha: 1)  // violet
        ), let att = try? UNNotificationAttachment(identifier: "winddown_img", url: imgURL) {
            content.attachments = [att]
        }
        let req = UNNotificationRequest(
            identifier: "lucid_winddown_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
        log("Wind-down notification sent")
    }

    /// Render a simple gradient card PNG to a temp file for a rich notification.
    /// iOS copies the file into its attachment store, so temp is fine.
    private func makeNotificationImage(title: String, subtitle: String, accent: UIColor) -> URL? {
        let size = CGSize(width: 1000, height: 500)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1).cgColor,
                accent.withAlphaComponent(0.40).cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(grad, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let para = NSMutableParagraphStyle()
            para.alignment = .left
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 76, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            (title as NSString).draw(in: CGRect(x: 64, y: 150, width: 872, height: 110),
                                     withAttributes: titleAttr)
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.82),
                .paragraphStyle: para
            ]
            (subtitle as NSString).draw(in: CGRect(x: 64, y: 280, width: 872, height: 150),
                                        withAttributes: subAttr)
        }
        guard let data = img.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucid_notif_\(UUID().uuidString).png")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Push notification at 20% battery so Fabi can charge before bed (prevents overnight data gaps)
    private func sendLowBatteryNotification(_ level: Double) {
        log("WHOOP battery at \(String(format: "%.0f", level))% — sending low battery push")
        let content = UNMutableNotificationContent()
        content.title = "\u{1FAAB} Whoop Battery Low"
        content.body = String(format: "%.0f%% remaining — charge before bed to keep overnight data flowing.", level)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "lucid_battery_low",
            content: content,
            trigger: nil  // Fire immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Time-aware wake title — "Good morning" is plain wrong at 1pm.
    private func wakeTitle() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 0..<10:  return "\u{1F305} Good morning"
        case 10..<14: return "\u{23F0} Time to get up"
        default:      return "\u{23F0} Wake up"
        }
    }

    /// Send an immediate notification when smart alarm fires (shows on lock screen).
    /// v108: SINGLE notification (was 20 chained — Fabi feedback 2026-05-25). The
    /// strap haptic ramp at line 356 already provides progressive wrist vibration
    /// for waking; the phone notification just needs to ping once + show on lock
    /// screen. defaultCritical sound + .timeSensitive bypasses silent/DND.
    private func sendAlarmNotification(stage: HealthEngine.SleepStage) {
        evt("alarm_notification", "title=\(wakeTitle()) stage=\(stage.rawValue)")
        scheduleAlarmBuzzChain(
            title: wakeTitle(),
            body: "Smart alarm: waking you from \(stage.rawValue) sleep",
            count: 1,
            spacingSec: 2,
            firstDelaySec: 0.1,
            idPrefix: "lucid_smart_alarm"
        )
    }

    /// Builds a chained sequence of N notifications spaced at intervals so iOS
    /// fires its default critical-alert haptic repeatedly — produces a real
    /// "vibrating alarm" feel instead of a single ping. Cancellable by ID prefix.
    func scheduleAlarmBuzzChain(
        title: String,
        body: String,
        count: Int,
        spacingSec: TimeInterval,
        firstDelaySec: TimeInterval,
        idPrefix: String
    ) {
        let center = UNUserNotificationCenter.current()
        // Cancel any prior chain with this prefix to avoid stacking.
        cancelAlarmBuzzChain(idPrefix: idPrefix)

        for i in 0..<count {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound.defaultCritical
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = idPrefix
            // Each pulse needs a unique non-zero delay; UNTimeIntervalNotificationTrigger
            // requires interval > 0.
            let interval = max(0.1, firstDelaySec + Double(i) * spacingSec)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let req = UNNotificationRequest(
                identifier: "\(idPrefix)_\(i)",
                content: content,
                trigger: trigger
            )
            center.add(req)
        }
    }

    /// Cancel a chain — used when user dismisses or app foregrounds during alarm.
    func cancelAlarmBuzzChain(idPrefix: String) {
        let center = UNUserNotificationCenter.current()
        let ids = (0..<30).map { "\(idPrefix)_\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func sendQuickTagNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "LUCID_QUICK_TAG"
        content.threadIdentifier = "lucid.quicktag"
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }

        let request = UNNotificationRequest(
            identifier: "lucid-quicktag-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.log("Quick-tag notification failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Battery Prediction

    func updateBatteryPrediction() {
        guard battery > 0 else { return }

        let now = Date()
        batteryHistory.append((date: now, level: battery))

        // Keep last 48 hours of data
        batteryHistory = batteryHistory.filter { now.timeIntervalSince($0.date) < 48 * 3600 }

        guard batteryHistory.count >= 3 else {
            DispatchQueue.main.async {
                self.batteryPrediction = "Collecting data..."
            }
            return
        }

        // Calculate drain rate (% per hour)
        let oldest = batteryHistory.first!
        let newest = batteryHistory.last!
        let hoursDiff = newest.date.timeIntervalSince(oldest.date) / 3600
        guard hoursDiff > 0.5 else { return } // Need at least 30 min of data

        let levelDiff = oldest.level - newest.level
        let drainPerHour = levelDiff / hoursDiff

        if drainPerHour <= 0 {
            // Charging or stable
            DispatchQueue.main.async {
                self.batteryPrediction = self.isCharging ? "⚡ Charging" : "Stable"
            }
            return
        }

        let hoursLeft = battery / drainPerHour
        let chargeTime = now.addingTimeInterval(hoursLeft * 3600)

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        let prediction: String
        if hoursLeft < 1 {
            prediction = "⚠️ ~\(Int(hoursLeft * 60))min left"
        } else if hoursLeft < 24 {
            prediction = "🔋 ~\(Int(hoursLeft))h left (charge by \(fmt.string(from: chargeTime)))"
        } else {
            prediction = "🔋 \(Int(hoursLeft))h+ left"
        }

        DispatchQueue.main.async {
            self.batteryPrediction = prediction
        }
    }

    private func handleData(_ packet: WhoopPacket) {
        // v70 — All-streams diagnostics. Count every packet by type, regardless
        // of whether we have a decoder for it. Surfaces stream activity to
        // SettingsView's "All Streams" card so power-user mode can be verified.
        let pType = Int(packet.type)
        DispatchQueue.main.async {
            self.packetTypeCounts[pType, default: 0] += 1
            self.packetTypeLastSeen[pType] = Date()
        }

        // Log non-realtime packets for debugging history sync
        if isDownloadingHistory && packet.type != PacketType.realtimeData.rawValue {
            log("SYNC DATA: type=\(packet.type) cmd=\(packet.cmd) len=\(packet.data.count)")
        }

        if packet.type == PacketType.realtimeData.rawValue {
            guard let reading = WhoopProtocol.parseHRData(cmd: packet.cmd, data: packet.data) else { return }

            if reading.heartRate > 0 {
                DispatchQueue.main.async {
                    self.heartRate = Int(reading.heartRate)
                    self.readingsToday += 1
                }

                // Feed HR to health engine (sleep stage + smart alarm + strain + body battery)
                healthEngine.addHRReading(Int(reading.heartRate))
                healthEngine.updateStrain(hr: Int(reading.heartRate))
                healthEngine.updateBodyBattery(hr: Int(reading.heartRate))

                // EXPERIMENTAL biostate: throttled (5-min) change-check → lockscreen notif
                BiostateNotifier.shared.noteTick()

                // Track daytime HR for nocturnal dip calculation (awake + no exercise)
                if !healthEngine.sleepDetected && manualActivityType == nil {
                    healthEngine.addDaytimeHRReading(Double(reading.heartRate))
                }

                // Recovery is morning-locked (computeRecovery is no-op until next sleep-end).
                // We still call it occasionally so that if (a) wake-up handler missed and
                // (b) it's past 14:00 local, the fallback path kicks in.
                if readingsToday % 30 == 0 {
                    healthEngine.computeRecoveryFallbackIfNeeded()
                }

                for rr in reading.rrIntervals {
                    healthEngine.addRRInterval(Double(rr))
                }

                // Track sleep onset time
                if healthEngine.sleepDetected && lastSleepOnsetTime == nil {
                    lastSleepOnsetTime = Date()
                } else if !healthEngine.sleepDetected && lastSleepOnsetTime != nil {
                    // Will be consumed by wake-up handler, then reset
                }

                // v70 — power-user always-on mode. Previously: IMU auto-disabled
                // 8-22 to save Whoop battery. Per Fabi's spec (2026-05-06):
                // "I don't care if I have to charge every third day, as long as
                // the data is great". Keep IMU streaming continuously. The
                // enable-IMU command (cmd 106) is already sent on every connect
                // in startRealtimeStreaming, so we just stop disabling it here.
                if !imuActive {
                    enableIMUForSleep()  // misnomer now — also fires when awake
                }

                // Feed to activity detector
                activityDetector.processReading(
                    hr: Int(reading.heartRate),
                    rmssd: healthEngine.currentRMSSD,
                    timestamp: Date()
                )

                // Live Activity ticks on EVERY reading — that's the whole
                // point of moving live HR off widgets. Lock-screen Live
                // Activities can update at packet cadence (5-10s) without
                // hitting any rate limit. Widget sync stays on the 60s
                // interval since iOS rate-limits widget reloads regardless.
                updateLiveActivity()

                sharedDataSyncCounter += 1
                if sharedDataSyncCounter >= 6 {
                    sharedDataSyncCounter = 0
                    syncSharedHealthData()
                }

                pendingReadings.append(reading)
                // v138: do NOT save the last-sync timestamp on every packet. That
                // per-tick write was the clobber that drove gap_min=0 — on reconnect
                // it had already advanced to ~now, so the gap-check saw no gap and
                // skipped backfill. The timestamp is now saved only where it means
                // "we are caught up": history-download completion + clean disconnect.
                lastDataReceived = Date()  // Watchdog: mark data alive

                // v141 — DRAIN ON THE WAKE WINDOW (the real gap fix).
                // The main-runloop pushTimer is FROZEN while the app is suspended,
                // so on a backgrounded phone (evening, pocket, screen off, media
                // playing) it never fires — readings pile up in pendingReadings in
                // RAM and are lost when iOS reclaims the app. That was ~7.7h/day of
                // loss, peaking in active/evening hours. But CoreBluetooth still
                // wakes us per notification (bluetooth-central bg mode), and this
                // callback runs on bleQueue, which is alive during that wake. So we
                // drain here, at the source rate cadence, independent of the timer
                // AND independent of whether the audio keep-alive is still alive.
                // This is the "app as periodic drain" model the BLE architecture
                // research prescribed — stop depending on staying unsuspended.
                if Date().timeIntervalSince(lastFlush) >= pushInterval {
                    flushReadingsOnQueue()
                }

                // v70 — TYPE-40 RAW CAPTURE.
                // On v1.1.41 firmware, type-40 packets are only 17 bytes (abbreviated HR).
                // Data0/data1 fields live in type-47 packets instead (see handleData's
                // type-47 branch below). We still push type-40 packets here for timeline
                // reconstruction — just with empty data0/data1 since those offsets
                // don't exist in the 17-byte format.
                realtimeRawSampleCounter += 1
                if realtimeRawSampleCounter % realtimeRawSampleEvery == 0 {
                    let fullHex = packet.data.map { String(format: "%02x", $0) }.joined()
                    // Extract data0/data1 only when packet is large enough; empty otherwise.
                    let hasDecodeFormat = packet.data.count >= 78
                    let data0Hex = hasDecodeFormat
                        ? packet.data[26..<45].map { String(format: "%02x", $0) }.joined()
                        : ""
                    let data1Hex = hasDecodeFormat
                        ? packet.data[48..<78].map { String(format: "%02x", $0) }.joined()
                        : ""

                    let state: String? = {
                        if healthEngine.sleepDetected { return "sleeping" }
                        if manualActivityType != nil  { return "active" }
                        if heartRate > 0 && heartRate < 80 { return "resting" }
                        return nil
                    }()

                    supabase.pushRealtimeRaw(
                        hr: Int(reading.heartRate),
                        rrIntervals: reading.rrIntervals.map { Int($0) },
                        data0Hex: data0Hex,
                        data1Hex: data1Hex,
                        fullHex: fullHex,
                        activityState: state,
                        packetType: Int(packet.type)
                    )
                }
            }
        } else if packet.type == PacketType.historicalData.rawValue {
            // v70 — Type-47 @ 93 bytes is the "decode_5c" full sensor packet.
            // We observed 131 of these today in history-sync bursts. Bytes [26..85]
            // carry 15 × IEEE-754 floats (accel / gyro / PPG channels likely).
            // Capture decoded form to whoop_realtime_raw before the normal history
            // path runs — two writers, no contention.
            if packet.data.count == 93,
               let decoded = WhoopProtocol.parseType47Packet(packet.data) {
                let fullHex = packet.data.map { String(format: "%02x", $0) }.joined()
                let data0Hex = packet.data[26..<45].map { String(format: "%02x", $0) }.joined()
                let data1Hex = packet.data[48..<78].map { String(format: "%02x", $0) }.joined()
                let state: String? = {
                    if healthEngine.sleepDetected { return "sleeping" }
                    if manualActivityType != nil  { return "active" }
                    if heartRate > 0 && heartRate < 80 { return "resting" }
                    return nil
                }()
                supabase.pushRealtimeRaw(
                    hr: heartRate,                                  // last known HR, not from this packet
                    rrIntervals: [],                                // type-47 doesn't carry RR
                    data0Hex: data0Hex,
                    data1Hex: data1Hex,
                    fullHex: fullHex,
                    activityState: state,
                    packetType: Int(packet.type),
                    seq: Int(decoded.seq),
                    counter: Int(decoded.counter),
                    timestampUnix: Int64(decoded.timestamp),
                    timestampFrac: Int64(decoded.timestampFrac),
                    parsedFloats: decoded.floats
                )
            }
            handleHistoryData(packet)
        } else if packet.type == PacketType.metadata.rawValue {
            // v68 — Type 49 is overloaded: during history sync it's start/end markers,
            // during live streaming it's the "decode_1c subtype 0x31" skin-temperature
            // packet (bytes [4..9] = int48 LE / 100,000 = °C).
            // Source: bWanShiTong/reverse-engineering-whoop misc.py → decode_1c.
            //
            // Prefer temperature decode when not syncing history; if the value lands
            // outside the body-temp range, fall through to the history handler so we
            // don't silently swallow real metadata frames.

            // Diagnostic: count ALL type-49 packets, regardless of state. Lets
            // the Skin Temp diagnostics card distinguish "packets arrive but
            // gated" from "no packets ever".
            DispatchQueue.main.async { self.totalType49PacketsSeen += 1 }

            if !isDownloadingHistory, let tempC = WhoopProtocol.parseRealtimeTemperature(data: packet.data), acceptSkinTemp(tempC) {
                let hex = packet.data.map { String(format: "%02X", $0) }.joined(separator: " ")
                LucidLog.log("BLE", "Type-49 temp parsed: \(String(format: "%.2f", tempC))°C from \(packet.data.count) bytes")
                DispatchQueue.main.async {
                    self.skinTemperature = tempC
                    self.skinTempHistory.append((temp: tempC, time: Date()))
                    // Keep last 12 hours only.
                    let cutoff = Date().addingTimeInterval(-12 * 3600)
                    self.skinTempHistory = self.skinTempHistory.filter { $0.time > cutoff }
                    self.lastTempEventAt = Date()
                    self.lastTempRawHex = hex
                    self.lastTempEventSource = "type-49 metadata"
                    self.totalTempEventsReceived += 1
                }
                supabase.pushWhoopEvent(
                    type: "skin_temp_celsius",
                    data: ["temp_c": tempC]
                )
            } else {
                handleHistoryMetadata(packet)
            }
        } else if packet.type == PacketType.event.rawValue {
            handleEvent(packet)
        } else if packet.type == PacketType.imuRealtime.rawValue || packet.type == 51 {
            handleIMUData(packet)
        } else if packet.type == PacketType.consoleLogs.rawValue {
            // Firmware debug output — push raw text to whoop_events for later analysis.
            let printable = packet.data.filter { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
            let logText = String(data: printable, encoding: .ascii) ?? ""
            let hex = packet.data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
            if !logText.isEmpty || packet.data.count > 0 {
                supabase.pushWhoopEvent(
                    type: "console_log",
                    data: ["text": logText, "hex_prefix": hex, "length": packet.data.count],
                    rawBytes: packet.data
                )
            }
        } else if packet.type == PacketType.realtimeRawData.rawValue {
            // Raw optical (PPG) — MAX86171 FIFO format decoded per datasheet.
            let samples = WhoopProtocol.parsePPGPacket(cmd: packet.cmd, data: packet.data)
            if !samples.isEmpty {
                // Group by channel so one row carries one sample-tick's 5 channel values
                // when possible. For now push one row per sample (simpler, small volume).
                let now = Date()
                let rows: [[String: Any]] = samples.map { s in
                    var row: [String: Any] = [
                        "recorded_at": ISO8601DateFormatter().string(from: now)
                    ]
                    switch s.channel {
                    case .green1, .green2, .green3: row["ppg_green1"] = Int(s.adc)
                    case .red: row["ppg_red"] = Int(s.adc)
                    case .infrared: row["ppg_ir"] = Int(s.adc)
                    case .unknown: break
                    }
                    return row
                }
                supabase.pushWhoopOpticalBatch(rows)
            } else {
                // Fallback — decoder didn't produce samples, keep raw bytes for later.
                supabase.pushWhoopEvent(
                    type: "raw_optical_frame_unparsed",
                    data: ["length": packet.data.count],
                    rawBytes: packet.data
                )
            }
        } else if packet.type == PacketType.imuHistorical.rawValue {
            // Historical IMU — push raw for now, fold into whoop_imu once format confirmed.
            supabase.pushWhoopEvent(
                type: "imu_historical_frame",
                data: ["length": packet.data.count],
                rawBytes: packet.data
            )
        } else {
            // Log unknown packet types (may reveal IMU if type isn't 51)
            if !isDownloadingHistory {
                log("DATA: type=\(packet.type) cmd=\(packet.cmd) len=\(packet.data.count)")
                // Log first few bytes for unknown types to help decode
                if packet.data.count > 0 {
                    let hex = packet.data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
                    log("  HEX: \(hex)")
                }
            } else if historyRawCaptureCount < 40 {
                // v113 — during history sync we previously dropped non-47/49 packets
                // SILENTLY. If firmware 41.x routes HR history through a different
                // packet type, that's exactly the byte stream we need — capture it
                // (bounded, shared budget) instead of swallowing it.
                historyRawCaptureCount += 1
                let hex = packet.data.prefix(96).map { String(format: "%02x", $0) }.joined()
                supabase.pushDebugLog(
                    key: "history_misc_packet",
                    value: "n=\(historyRawCaptureCount) type=\(packet.type) seq=\(packet.seq) cmd=\(packet.cmd) len=\(packet.data.count) hex=\(hex)"
                )
            }
            // Capture unknown packets when optical mode is active — may contain SpO2 data
            captureOpticalPacket(type: packet.type, cmd: packet.cmd, data: packet.data)
        }
    }

    // MARK: - IMU Data Handling

    /// v70 — always-on IMU streaming. Was gated to 22:00-08:00 sleep window
    /// for Whoop battery; per Fabi's power-user spec, drop the gate so we
    /// stream continuously. Battery cost ~3-5%/hr per BatteryDiagnosticsCard.
    func enableIMUForSleep() {
        if !imuActive {
            testIMU(true)
            DispatchQueue.main.async { self.imuActive = true }
            log("[IMU] Enabled (power-user always-on mode)")
        }
    }

    /// Disable IMU when not needed (saves battery)
    func disableIMU() {
        if imuActive {
            testIMU(false)
            DispatchQueue.main.async { self.imuActive = false }
            log("[IMU] Disabled")
        }
    }

    private func handleIMUData(_ packet: WhoopPacket) {
        imuSampleCount += 1
        let d = packet.data

        // Try the v66 multi-frame parser first — handles batched 52 Hz frames with timestamp header.
        let frames = WhoopProtocol.parseIMUPacket(cmd: packet.cmd, data: d)

        if !frames.isEmpty {
            // Feed each frame to the health engine for movement-aware sleep staging.
            for f in frames {
                let accelMag = Double(f.accelMagnitudeMg) * 8.192   // back to int16 magnitude scale
                let gyroMag = sqrt(Double(f.gyroX)*Double(f.gyroX) + Double(f.gyroY)*Double(f.gyroY) + Double(f.gyroZ)*Double(f.gyroZ))
                healthEngine.addIMUReading(accelMagnitude: accelMag, gyroMagnitude: gyroMag)
            }
            // v98 — cache mean of this batch for the next realtime_health push.
            // Mean over the batch (not last frame) smooths out single-frame jitter
            // since the BLE packet bundles ~52 Hz frames per second.
            let count = Double(frames.count)
            let meanMg = Int(frames.map { Double($0.accelMagnitudeMg) }.reduce(0, +) / count)
            let meanMove = frames.map { $0.movementScore }.reduce(0, +) / count
            lastAccelMagMg = meanMg
            lastMovementScore = meanMove
            lastImuUpdate = Date()

            // Buffer frames for Supabase — decimated flush every 1s or 60 frames.
            imuBuffer.append(contentsOf: frames)
            let now = Date()
            if imuBuffer.count >= imuFlushMaxFrames || now.timeIntervalSince(lastImuFlush) >= imuFlushInterval {
                flushIMUBufferToSupabase()
                lastImuFlush = now
            }
        } else if d.count >= 12 {
            // Legacy fallback: first 12 bytes as a single frame (no timestamp header).
            let accelX = Int16(d[0]) | (Int16(d[1]) << 8)
            let accelY = Int16(d[2]) | (Int16(d[3]) << 8)
            let accelZ = Int16(d[4]) | (Int16(d[5]) << 8)
            let gyroX  = Int16(d[6]) | (Int16(d[7]) << 8)
            let gyroY  = Int16(d[8]) | (Int16(d[9]) << 8)
            let gyroZ  = Int16(d[10]) | (Int16(d[11]) << 8)

            let accelMag = sqrt(Double(accelX)*Double(accelX) + Double(accelY)*Double(accelY) + Double(accelZ)*Double(accelZ))
            let gyroMag = sqrt(Double(gyroX)*Double(gyroX) + Double(gyroY)*Double(gyroY) + Double(gyroZ)*Double(gyroZ))
            healthEngine.addIMUReading(accelMagnitude: accelMag, gyroMagnitude: gyroMag)
            // v98 — same legacy path: cache the single-frame value so realtime_health
            // gets at least something rather than NULL when only the legacy parser fires.
            // Convert raw int16 magnitude back to ~mg-equivalent for column consistency.
            lastAccelMagMg = Int(accelMag / 8.192)
            lastMovementScore = min(1.0, abs(accelMag / 8.192 - 1000.0) / 2000.0)
            lastImuUpdate = Date()
        }

        // Debug log: first 10 packets + every 60s after that
        let now = Date()
        let shouldLog = imuSampleCount <= 10 || lastIMULog == nil || now.timeIntervalSince(lastIMULog!) > 60
        if shouldLog {
            lastIMULog = now
            let hex = d.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            log("[IMU] #\(imuSampleCount) type=\(packet.type) cmd=\(packet.cmd) len=\(d.count) frames=\(frames.count) hex=\(hex)")
            if imuSampleCount <= 5 {
                supabase.pushDebugLog(key: "imu_raw_\(imuSampleCount)", value: "type=\(packet.type) cmd=\(packet.cmd) len=\(d.count) hex=\(hex)")
            }
        }
    }

    /// Average the IMU buffer down to a single row and push to whoop_imu.
    /// 52 Hz → ~1 Hz keeps Supabase usage sane while still giving us movement signal.
    private func flushIMUBufferToSupabase() {
        guard !imuBuffer.isEmpty else { return }
        let frames = imuBuffer
        imuBuffer.removeAll(keepingCapacity: true)

        let count = Double(frames.count)
        let meanAx = Int(frames.map { Double($0.accelX) }.reduce(0, +) / count)
        let meanAy = Int(frames.map { Double($0.accelY) }.reduce(0, +) / count)
        let meanAz = Int(frames.map { Double($0.accelZ) }.reduce(0, +) / count)
        let meanGx = Int(frames.map { Double($0.gyroX) }.reduce(0, +) / count)
        let meanGy = Int(frames.map { Double($0.gyroY) }.reduce(0, +) / count)
        let meanGz = Int(frames.map { Double($0.gyroZ) }.reduce(0, +) / count)
        let meanMag = Int(frames.map { Double($0.accelMagnitudeMg) }.reduce(0, +) / count)
        let meanMove = frames.map { $0.movementScore }.reduce(0, +) / count

        let row: [String: Any] = [
            "recorded_at": ISO8601DateFormatter().string(from: Date()),
            "accel_x": meanAx,
            "accel_y": meanAy,
            "accel_z": meanAz,
            "gyro_x": meanGx,
            "gyro_y": meanGy,
            "gyro_z": meanGz,
            "accel_mag_mg": meanMag,
            "movement_score": meanMove,
            "sample_rate_hz": 52
        ]
        supabase.pushWhoopIMUBatch([row])
    }

    // MARK: - Start of private-var storage for IMU buffer is above; nothing new here.
}

