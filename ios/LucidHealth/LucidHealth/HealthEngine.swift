import Foundation
import Combine
import Accelerate
import UserNotifications
import HealthKit

extension Notification.Name {
    /// Posted by HealthEngine.fetchBaseline() when Supabase restore completes.
    /// BLEManager listens to this to push fresh data into the widget App Group
    /// so lock screen widgets can render on cold start (before the strap connects).
    static let healthBaselineRestored = Notification.Name("lucid.healthBaselineRestored")
}

/// Lucid Health Engine — computes Cognitive Readiness, RMSSD, and respiratory rate
/// from live RR intervals streamed from the Whoop strap.
/// Auto-calibrated from 654 days of personal Whoop data (2024-06 → 2026-04).
///
/// Methods are organized into extensions:
///   - HRVEngine.swift: RMSSD, SDNN, pNN50, DFA α1, respiratory rate, cognitive readiness
///   - SleepEngine.swift: sleep stage detection, smart alarm, gap replay, IMU
///   - RecoveryEngine.swift: recovery score, strain, body battery, training load
///   - IllnessDetector.swift: multi-signal illness sentinel
class HealthEngine: ObservableObject {

    // MARK: - Published Metrics
    @Published var currentRMSSD: Double = 0
    @Published var lnRMSSD: Double = 0
    @Published var readiness: ReadinessLevel = .unknown
    @Published var respiratoryRate: Double = 0  // breaths per minute
    @Published var currentCoherence: Double = 0  // HeartMath 0.1 Hz coherence ratio (0...1)
    @Published var sleepDetected: Bool = false

    // Research-backed HRV metrics (Shaffer & Ginsberg 2017)
    @Published var sdnn: Double = 0              // overall autonomic function
    @Published var pnn50: Double = 0             // parasympathetic, correlates with processing speed
    @Published var dfaAlpha1: Double = 0          // fractal correlation (1.0 = healthy, <0.75 = stress)
    @Published var cognitiveCapacity: Double = 0  // 0-100 composite score (v2)
    @Published var cognitiveLabel: String = "—"   // "Full" / "Reduced" / "Low"

    // Sleep
    @Published var currentSleepStage: SleepStage = .awake
    @Published var smartAlarmTriggered: Bool = false
    @Published var sleepScore: Double = 0
    @Published var sleepDurationHours: Double = 0
    @Published var sleepEfficiency: Double = 0
    @Published var sleepConsistencyScore: Double = 50
    @Published var wakeUpNotified: Bool = false

    // Recovery
    @Published var recoveryScore: Double = 0
    @Published var recoveryLabel: String = "—"
    @Published var recoveryHRVContribution: Double = 0
    @Published var recoveryRHRContribution: Double = 0
    @Published var recoverySleepContribution: Double = 0
    @Published var recoveryRRContribution: Double = 0
    // v106: server-stamped alcohol-night flag. 1.0 = detected, 0/nil = sober.
    // Surfaces a 🍺 badge under the recovery ring so a low score has context.
    @Published var alcoholImpact: Double = 0

    // Strain
    @Published var strainScore: Double = 0
    @Published var currentHRZone: Int = 0
    @Published var zoneMinutes: [Int] = [0, 0, 0, 0, 0]

    // Body Battery & Training Load
    @Published var bodyBattery: Double = 100
    @Published var trainingLoadRatio: Double = 1.0
    @Published var trainingLoadStatus: String = "Optimal"
    @Published var trainingMonotony: Double = 0
    @Published var trainingStrain: Double = 0

    // Illness
    @Published var illnessAlert: String? = nil
    @Published var illnessRisk: Int = 0
    @Published var todaySteps: Int = 0

    // IMU
    @Published var movementScore: Double = 0

    // Baseline (fetched from Supabase)
    @Published var baselineRHR: Double = 60.0
    @Published var baselineHRV: Double = 60.0

    // Battery prediction
    @Published var estimatedChargeTime: String = ""

    // === NEW: Quick Win Metrics (Research Report Apr 10, 2026) ===

    // Poincaré SD1/SD2 — autonomic balance (Finding 1.1)
    @Published var poincaréSD1: Double = 0       // short-term parasympathetic
    @Published var poincaréSD2: Double = 0       // long-term sympathovagal
    @Published var poincaréRatio: Double = 0     // SD2/SD1 — high = sympathetic dominant

    // Nocturnal HR Dip — cardiovascular risk screen (Finding 2.1)
    @Published var nocturnalHRDip: Double = 0    // % drop from daytime to sleep HR
    @Published var nocturnalDipStatus: String = "—" // "Normal" (>10%) or "Non-Dipper" (<10%)

    // Sleep Fragmentation Index (Finding 2.2)
    @Published var sleepFragmentationIndex: Double = 0  // stage transitions per hour

    // Sleep Debt — rolling 14-day deficit (Finding 2.4)
    @Published var sleepDebtHours: Double = 0    // cumulative hours of debt

    // Heart Rate Recovery post-exercise (Finding 3.1)
    @Published var lastHRR1: Int = 0             // HR drop at 1 min post-exercise
    @Published var lastHRR2: Int = 0             // HR drop at 2 min post-exercise
    @Published var hrrStatus: String = "—"       // "Excellent" / "Good" / "Impaired"

    // VO2max estimate (Finding 3.2)
    @Published var vo2maxEstimate: Double = 0    // mL/kg/min from Uth-Sørensen
    var historicalMaxHR: Double = 190            // updated from activities

    // Overtraining Risk (Finding 5.5)
    @Published var overtrainingRisk: String = "None" // "None" / "Warning" / "High Risk"
    @Published var consecutiveLowHRVDays: Int = 0

    // Alcohol Impact Score (Finding 6.1)
    @Published var lastAlcoholImpact: Double = 0 // % RMSSD depression vs baseline

    // Stealable Whoop community patterns (May 2026) — mirrored from LucidBridge.
    @Published var baevskyStress: Double = 0          // 0-500, sympathetic activation
    @Published var baevskyStressLabel: String = "—"   // Calm / Normal / Stressed
    @Published var edwardsTRIMP: Double = 0           // weighted strain (zone × weight sum)

    // MARK: - Cognitive Readiness Levels
    enum ReadinessLevel: String {
        case green   = "Green"
        case yellow  = "Yellow"
        case red     = "Red"
        case unknown = "—"
    }

    // MARK: - Sleep Stages
    enum SleepStage: String, CaseIterable {
        case awake = "Awake"
        case light = "Light"
        case deep  = "Deep"
        case rem   = "REM"
    }

    // MARK: - HRV Buffers (used by HRVEngine)
    var rrBuffer: [Double] = []
    var rrTimestamps: [Date] = []
    var rmssdHistory: [Double] = []
    var baselineRMSSD: [Double] = []
    var sdnnHistory: [Double] = []
    var dfaAlpha1History: [Double] = []
    let rrBufferSize = 120
    let rmssdWindowSize = 30
    let dfaAlpha1HistoryKey = "lucid_dfa_alpha1_7d"

    // MARK: - Sleep State (used by SleepEngine)
    var hrHistory: [Int] = []
    var recentHR: [Double] = []
    var recentHRV: [Double] = []
    /// Minimum HR seen while in a non-awake sleep stage. Set by SleepEngine, reset at sleep start.
    /// Used as the authoritative resting HR in upsertDailyMetrics after wake-up.
    var sleepingMinHR: Double = 0
    private var wristOnTime: Date?
    private var wristOffTime: Date?
    var sustainedLowHRMinutes: Double = 0
    var sustainedHighHRMinutes: Double = 0
    // v98 — tracks consecutive minutes of detected body movement. Used by
    // the movement-confirmed wake path: if sustained for ≥5 min during morning
    // hours while sleepDetected, fire wake regardless of HR threshold. Fixes
    // the May 8 case where Fabi's chronic low baseline HR (54) overlapped his
    // awake-low-activity HR, leaving HR-only wake detection blind.
    var sustainedMovementMinutes: Double = 0
    var lastSleepCheckTime: Date?
    var wakeUpLockUntil: Date?
    /// Alcohol-recovery night (Smart Alarm Module 7). Set by the tonight-plan
    /// sync. When active, the wake window is overridden to a humane late window
    /// (server plan, default 09:00–12:00) and the gate is more conservative so
    /// the back-half deep-sleep rebound is never cut short.
    var alcoholActive: Bool {
        UserDefaults.standard.bool(forKey: "lucid_alcohol_active")
    }
    var alarmEnabled: Bool {
        // Alcohol mode keeps a humane noon backstop armed even if the user's
        // own alarm is off — it just never force-wakes early.
        if alcoholActive { return true }
        return UserDefaults.standard.bool(forKey: "lucid_alarm_enabled")
    }
    var alarmWindowStart: Int {
        if alcoholActive {
            let s = UserDefaults.standard.integer(forKey: "lucid_alcohol_start")
            return s > 0 ? s : 9 * 60       // 09:00 — no earlier
        }
        return UserDefaults.standard.integer(forKey: "lucid_alarm_start")
    }
    var alarmWindowEnd: Int {
        if alcoholActive {
            let e = UserDefaults.standard.integer(forKey: "lucid_alcohol_end")
            return e > 0 ? e : 12 * 60      // 12:00 backstop
        }
        return UserDefaults.standard.integer(forKey: "lucid_alarm_end")
    }
    var alarmFiredToday = false
    /// Date the alarm last fired. Used to auto-reset alarmFiredToday across days
    /// so the alarm actually fires on day 2+ without requiring an app restart.
    var alarmLastFireDate: Date?
    /// Pre-alarm micro-ping state. Fires a single gentle haptic 20-25 min before
    /// the wake window to briefly arouse the user → re-enter N1/N2 → virtually
    /// guarantees a clean light-sleep detection window. Sundelin 2024.
    var microPingFiredToday = false
    var microPingLastFireDate: Date?
    /// RMSSD history for slope-based wake gate. 5-min EMA, 3-window positive slope
    /// = N3→N2→N1 transition (AUC 0.85). Shaffer 2017, Beattie 2017.
    var rmssdSamples: [(time: Date, value: Double)] = []
    /// Last 3 EMA values (every 5 min) — used for slope detection.
    var rmssdEmaWindow: [Double] = []
    var lastRmssdEmaTime: Date?
    var sleepStageCallback: ((SleepStage) -> Void)?
    var preAlarmMicroPingCallback: (() -> Void)?
    var wakeUpCallback: (() -> Void)?
    var cancelFallbackCallback: (() -> Void)?

    // MARK: - Round-alarm guards (never wake someone already awake; survive relaunch)

    /// Robust "is he awake right now?" — independent of the sleep-stage classifier,
    /// which is unreliable on his chronic-low-HR mornings (sleeping HR ~58 rarely
    /// crosses the classifier's wake threshold even when he's up and about).
    var isLikelyAwakeNow: Bool {
        if currentSleepStage == .awake { return true }
        let recent = Array(recentHR.suffix(12))   // ~2 min at 10s cadence
        guard recent.count >= 6 else { return false }
        let avg = recent.reduce(0, +) / Double(recent.count)
        return avg > baselineRHR + 18
    }

    private var alarmDayStamp: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
    /// Alarm/micro-ping fire is persisted so BLE-reconnect relaunches can't reset
    /// the in-memory flag and re-fire hours later (the 1pm re-fire bug).
    var alarmFiredPersistedToday: Bool {
        UserDefaults.standard.string(forKey: "lucid_alarm_fired_date") == alarmDayStamp
    }
    func persistAlarmFired() {
        UserDefaults.standard.set(alarmDayStamp, forKey: "lucid_alarm_fired_date")
    }
    var microPingFiredPersistedToday: Bool {
        UserDefaults.standard.string(forKey: "lucid_microping_fired_date") == alarmDayStamp
    }
    func persistMicroPingFired() {
        UserDefaults.standard.set(alarmDayStamp, forKey: "lucid_microping_fired_date")
    }
    var lastWakeUpNotification: Date?
    let wakeUpCooldownHours: Double = 12.0
    var sleepStartTime: Date?
    var sleepEndTime: Date?
    var stageMinutes: [SleepStage: Double] = [.awake: 0, .light: 0, .deep: 0, .rem: 0]
    var lastStageChangeTime: Date?
    var previousStageForTracking: SleepStage = .awake
    var lastSleepNotification: Date?
    let bedtimeHistoryKey = "lucid_bedtime_history"
    let waketimeHistoryKey = "lucid_waketime_history"

    // Sleep debug logging
    weak var debugSupabase: SupabaseClient?
    var lastDebugLog: Date?
    var lastAlarmDebugLog: Date?

    // IMU buffers (used by SleepEngine)
    var recentAccel: [Double] = []
    var recentGyro: [Double] = []
    var isBodyStill: Bool { movementScore < calibration.imuStillThreshold }
    var isMoving: Bool { movementScore > calibration.imuMovingThreshold }

    // Running sleep duration
    var runningSleepHours: Double {
        if sleepDurationHours > 0 { return sleepDurationHours }
        guard let start = sleepStartTime else { return 0 }
        let end = sleepEndTime ?? Date()
        return max(0, end.timeIntervalSince(start) / 3600.0)
    }

    // Sleep stage transition counter (for fragmentation index)
    var stageTransitionCount: Int = 0

    // Sleep debt history key
    let sleepDebtKey = "lucid_daily_sleep_hours"
    let optimalSleepHours: Double = 7.8  // Fabi's P75 from 654 days (mean 7.4)

    // HRR tracking
    var exerciseEndHR: Int = 0
    var exerciseEndTime: Date?

    // Daytime HR tracking for nocturnal dip
    var daytimeHRReadings: [Double] = []

    // MARK: - Strain State (used by RecoveryEngine)
    var strainAccumulator: Double = 0
    var lastStrainReset: Date?
    var hrZoneReadingCount: Int = 0
    let dailyStrainKey = "lucid_daily_strain_history"
    var zoneThresholds: [Double] {
        let maxHR = 190.0
        return [maxHR * 0.50, maxHR * 0.60, maxHR * 0.70, maxHR * 0.80]
    }

    // MARK: - Illness State (used by IllnessDetector)
    let dailyRHRKey = "lucid_daily_rhr_history"
    let dailyHRVKey = "lucid_daily_hrv_history"
    let dailyRRKey = "lucid_daily_resp_history"
    let dailyStepsKey = "lucid_daily_steps_history"
    let healthStore = HKHealthStore()

    // MARK: - Battery Prediction
    private var batteryLog: [(date: Date, level: Double)] = []
    private let batteryHistoryKey = "lucid_battery_history"

    // MARK: - Persistence Keys
    private let baselineKey = "lucid_rmssd_baseline_7d"
    private let morningRMSSDKey = "lucid_morning_rmssd"
    private let baselineResetFlag = "lucid_baseline_reset_v2"
    let currentRMSSDKey = "lucid_current_rmssd"
    private var baselineLoaded = false

    // MARK: - Recovery Lock + Body Battery Persistence
    // Recovery is morning-locked (Whoop/Oura/Polar consensus). Once computed at
    // markSleepEnd(), it doesn't change until the next sleep-end. This avoids the
    // 90% → 9% intraday swing caused by treating live HRV (a task-state signal)
    // as a recovery signal. Buchheit 2014 / Plews 2013 / Whoop docs all agree.
    let recoveryLockedDateKey = "lucid_recovery_locked_date_v1"
    let recoveryScoreTodayKey = "lucid_recovery_score_today_v1"
    let bodyBatteryKey = "lucid_body_battery_v1"
    let bodyBatterySavedAtKey = "lucid_body_battery_saved_at_v1"
    /// Sleep-period RMSSD samples — captured during sleep, used for recovery
    /// computation at wake. Mirrors Whoop's "last SWS HRV" approach.
    var sleepPeriodRMSSDSamples: [Double] = []
    /// Date that the morning recovery score is locked for. nil = not yet
    /// computed today; if equal to today, computeRecovery() is a no-op.
    var recoveryLockedDate: Date?
    /// Last fallback compute (in case wake-up never fired by 14:00 local).
    var fallbackRecoveryFired: Bool = false

    // MARK: - Safety Recalculation
    private var safetyRecalcTimer: Timer?
    private var liveDataStartTime: Date?
    private let sleepReplayFlag = "lucid_sleep_replay_v1"

    // MARK: - Calibration
    private let calibrationKey = "lucid_personal_calibration_v2"
    var calibration = PersonalCalibration()

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Init
    // ═══════════════════════════════════════════════════════════════

    init() {
        migrateIfNeeded()
        loadBaseline()
        loadCalibration()
        loadBatteryHistory()
    }

    /// One-time migration: wipe polluted on-device baselines
    private func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: baselineResetFlag) else { return }

        print("[HealthEngine] Running baseline reset migration v2 — wiping polluted learned data")

        UserDefaults.standard.removeObject(forKey: baselineKey)
        baselineRMSSD.removeAll()
        UserDefaults.standard.removeObject(forKey: morningRMSSDKey)
        UserDefaults.standard.removeObject(forKey: bedtimeHistoryKey)
        UserDefaults.standard.removeObject(forKey: waketimeHistoryKey)
        UserDefaults.standard.removeObject(forKey: dailyStrainKey)
        UserDefaults.standard.removeObject(forKey: "lucid_detection_corrections")
        UserDefaults.standard.removeObject(forKey: "lucid_suppressed_types")

        currentSleepStage = .awake
        sleepDetected = false
        recoveryScore = 0
        sleepScore = 0
        strainScore = 0
        bodyBattery = 100

        UserDefaults.standard.set(true, forKey: baselineResetFlag)
        print("[HealthEngine] Migration complete — awaiting fresh baselines from Supabase")
    }

    // MARK: - Wrist Events

    func onWristOn() {
        wristOnTime = Date()
        if let offTime = wristOffTime {
            let duration = Date().timeIntervalSince(offTime)
            if duration > 30 * 60 {
                print("[Health] Wrist on after \(Int(duration / 60))min off — possible wake-up")
            }
        }
    }

    func onWristOff() {
        wristOffTime = Date()
    }

    // MARK: - Daily Metrics

    var morningRMSSD: Double? {
        UserDefaults.standard.object(forKey: morningRMSSDKey) as? Double
    }

    func saveDailyBaseline() {
        guard !rmssdHistory.isEmpty else { return }
        let avgRMSSD = rmssdHistory.reduce(0, +) / Double(rmssdHistory.count)

        baselineRMSSD.append(avgRMSSD)
        if baselineRMSSD.count > 7 {
            baselineRMSSD.removeFirst(baselineRMSSD.count - 7)
        }

        UserDefaults.standard.set(baselineRMSSD, forKey: baselineKey)
        print("[Health] Saved daily baseline: RMSSD=\(String(format: "%.1f", avgRMSSD)), 7d count=\(baselineRMSSD.count)")
        rmssdHistory.removeAll()
    }

    func saveMorningReading() {
        guard currentRMSSD > 0 else { return }
        let today = Calendar.current.startOfDay(for: Date())
        let savedDate = UserDefaults.standard.object(forKey: "lucid_morning_date") as? Date

        if savedDate == nil || !Calendar.current.isDate(savedDate!, inSameDayAs: today) {
            UserDefaults.standard.set(currentRMSSD, forKey: morningRMSSDKey)
            UserDefaults.standard.set(today, forKey: "lucid_morning_date")
            print("[Health] Morning RMSSD saved: \(String(format: "%.1f", currentRMSSD))")
        }
    }

    // MARK: - Persistence

    private func loadBaseline() {
        if let saved = UserDefaults.standard.array(forKey: baselineKey) as? [Double] {
            baselineRMSSD = saved
            print("[Health] Loaded 7-day baseline: \(baselineRMSSD.count) entries")
        }
        // Restore last known RMSSD synchronously — no network wait, instant UI
        let savedRMSSD = UserDefaults.standard.double(forKey: currentRMSSDKey)
        if savedRMSSD > 0 {
            currentRMSSD = savedRMSSD
            lnRMSSD = log(savedRMSSD)
            print("[Health] Restored currentRMSSD from cache: \(Int(savedRMSSD)) ms")
        }
        restoreLockedRecoveryIfFresh()
        restoreBodyBatteryIfFresh()
    }

    /// Restore the morning-locked recovery score if it was computed today.
    /// Without this, app re-launch would let computeRecovery() run again from
    /// stale live HRV and undo the lock.
    func restoreLockedRecoveryIfFresh() {
        guard let saved = UserDefaults.standard.object(forKey: recoveryLockedDateKey) as? Date else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if Calendar.current.isDate(saved, inSameDayAs: today) {
            recoveryLockedDate = saved
            let cached = UserDefaults.standard.double(forKey: recoveryScoreTodayKey)
            if cached > 0 {
                recoveryScore = round(cached)
                if cached >= 67 { recoveryLabel = "Green" }
                else if cached >= 34 { recoveryLabel = "Yellow" }
                else { recoveryLabel = "Red" }
                print("[Health] Restored locked recovery for today: \(Int(cached))")
            }
        }
    }

    /// Restore Body Battery if it was saved within the last 30 min.
    /// Older values are stale (HR/HRV moved on without us); start from
    /// last save anyway since the alternative is "100" which is wrong.
    func restoreBodyBatteryIfFresh() {
        let saved = UserDefaults.standard.double(forKey: bodyBatteryKey)
        guard saved > 0 else { return }
        if let savedAt = UserDefaults.standard.object(forKey: bodyBatterySavedAtKey) as? Date {
            let ageMin = Date().timeIntervalSince(savedAt) / 60
            print("[Health] Restored body battery: \(Int(saved))% (\(Int(ageMin)) min stale)")
        }
        bodyBattery = saved
    }

    /// Persist Body Battery — called from updateBodyBattery on every BLE sample.
    /// Throttled to one write per minute to avoid hammering UserDefaults
    /// (BLE pushes ~6 samples/min).
    func saveBodyBattery() {
        if let lastSavedAt = UserDefaults.standard.object(forKey: bodyBatterySavedAtKey) as? Date {
            if Date().timeIntervalSince(lastSavedAt) < 60 { return }
        }
        UserDefaults.standard.set(bodyBattery, forKey: bodyBatteryKey)
        UserDefaults.standard.set(Date(), forKey: bodyBatterySavedAtKey)
    }

    // MARK: - Personal Baseline (fetched from Supabase)

    func fetchBaseline(supabase: SupabaseClient) {
        Task {
            async let baselineResult = supabase.fetchHealthBaseline()
            async let scoresResult = supabase.fetchLastScores()

            let baseline = await baselineResult
            let scores = await scoresResult

            if let rhr = baseline["rhr"], let hrv = baseline["hrv"], rhr > 0 {
                DispatchQueue.main.async {
                    self.baselineRHR = rhr
                    self.baselineHRV = hrv
                    self.baselineLoaded = true
                    print("[Health] Baseline loaded: RHR=\(String(format: "%.0f", rhr)) HRV=\(String(format: "%.0f", hrv))")

                    if self.baselineRMSSD.isEmpty && hrv > 0 {
                        self.baselineRMSSD = Array(repeating: hrv, count: 7)
                        UserDefaults.standard.set(self.baselineRMSSD, forKey: self.baselineKey)
                        print("[Health] Seeded 7-day RMSSD baseline from Supabase HRV: \(String(format: "%.0f", hrv))")
                    }
                }
            } else {
                print("[Health] Baseline fetch failed — using defaults RHR=60 HRV=60")
            }

            // Restore ALL scores from Supabase.
            // v101 — server is authoritative for today's row. Was previously gated
            // on `self.X == 0` which meant a stale UserDefaults restore (e.g. 33
            // from yesterday's compute) blocked the fresh server value (e.g. 77
            // from a fixed upsert) on cold start. Fabi was stuck on yesterday's
            // recovery for hours after build 76 install because of this gate.
            // Server can never be more stale than local — local is computed from
            // the same data and pushed to server, so server >= local in freshness.
            DispatchQueue.main.async {
                // fetchLastScores falls back to the most recent day with data when
                // today's row does not exist yet. Those numbers belong to another
                // day — they may seed baselines, but painting them on as today's
                // scores is why Aug 2 and Aug 3 displayed Aug 1's recovery.
                let isFallback = (scores["is_fallback"] ?? 0) == 1

                // Restore any in-flight stage minutes BEFORE the server assignment
                // below, never after. Running it afterwards let the on-device
                // UserDefaults accumulator overwrite the server's stage split —
                // the Jul-14 1.1h clobber, which had regressed into this path.
                self.restoreStageMinutesIfNeeded()

                // v106 fix: was `r > 0` — but 0 is a valid recovery score (alcohol
                // night, total burnout etc.). NULL is the "no data" case, and `if let`
                // already rejects nil. Treating 0 as no-data made the app show
                // yesterday's 75 on the May 23 drunk night when server had 0.
                if let r = scores["recovery"], r >= 0, !isFallback {
                    self.recoveryScore = round(r)
                    if r >= 67 { self.recoveryLabel = "Green" }
                    else if r >= 34 { self.recoveryLabel = "Yellow" }
                    else { self.recoveryLabel = "Red" }
                    UserDefaults.standard.set(r, forKey: self.recoveryScoreTodayKey)
                    print("[Health] Restored recovery from server: \(Int(r))")
                }
                // v106: alcohol-night flag from server (gives context to a low score)
                self.alcoholImpact = scores["alcohol_impact"] ?? 0
                if let hours = scores["sleep_hours"], hours > 0, !isFallback {
                    // Prefer the server's own sleep_score. The local bucket ladder
                    // disagreed with it (server 65 showed as 50, 83 showed as 90),
                    // and that number feeds the lock-screen widget and DayState.
                    if let ss = scores["sleep_score"], ss > 0 {
                        self.sleepScore = round(ss)
                    } else {
                        self.sleepScore = round(hours >= 7 ? 90 : hours >= 6 ? 70 : hours >= 5 ? 50 : 30)
                    }
                    self.sleepDurationHours = round(hours * 10) / 10
                    if let eff = scores["sleep_efficiency"], eff > 0 { self.sleepEfficiency = eff }
                    if let deep = scores["deep_min"], deep > 0 { self.stageMinutes[.deep] = deep }
                    if let rem = scores["rem_min"], rem > 0 { self.stageMinutes[.rem] = rem }
                    if let light = scores["light_min"], light > 0 { self.stageMinutes[.light] = light }
                    // awake_min was fetched and parsed but never assigned, so the
                    // stage bar normalised over a total that excluded it and
                    // inflated every stage percentage.
                    if let awake = scores["awake_min"], awake > 0 { self.stageMinutes[.awake] = awake }
                    print("[Health] Restored sleep from server: \(String(format: "%.1f", hours))h (D:\(Int(scores["deep_min"] ?? 0))m R:\(Int(scores["rem_min"] ?? 0))m L:\(Int(scores["light_min"] ?? 0))m A:\(Int(scores["awake_min"] ?? 0))m)")
                }
                if let s = scores["strain"], s > 0, !isFallback {
                    self.strainScore = round(s * 10) / 10
                    print("[Health] Restored strain from server: \(String(format: "%.1f", s))")
                }
                if let b = scores["body_battery"], b > 0, !isFallback {
                    self.bodyBattery = b
                    print("[Health] Restored body battery from server: \(Int(b))%")
                }
                if let c = scores["cognitive"], c > 0 {
                    self.cognitiveCapacity = c
                    if c >= 75 { self.cognitiveLabel = "Full" }
                    else if c >= 50 { self.cognitiveLabel = "Good" }
                    else if c >= 25 { self.cognitiveLabel = "Reduced" }
                    else { self.cognitiveLabel = "Low" }
                    print("[Health] Restored cognitive from server: \(Int(c))")
                }
                if let acwr = scores["acwr"], acwr > 0 {
                    self.trainingLoadRatio = acwr
                    print("[Health] Restored training load: \(String(format: "%.2f", acwr))")
                }
                if let tm = scores["training_monotony"], tm > 0 { self.trainingMonotony = tm }
                if let ts = scores["training_strain"], ts > 0 { self.trainingStrain = ts }
                if let illness = scores["illness_risk"], illness > 0 {
                    self.illnessRisk = Int(illness)
                }
                // INTENTIONALLY DO NOT restore sleep_start_epoch / sleep_end_epoch
                // here. These are runtime tracking variables for the *current* sleep
                // cycle, not historical display data. Restoring them on cold start
                // led to stale values (sometimes a week old) becoming the engine's
                // ground truth, which:
                //   1. Made markSleepStart()'s `if sleepStartTime == nil` guard
                //      always-false → stageMinutes never reset between nights
                //   2. Got persisted into every subsequent upsertDailyMetrics call
                //      → DB rows showed sleep_start = N days ago
                //   3. Accumulated into 12h+ "deep sleep" totals
                // Display-side callers (SleepAdjustSheet, ActivityView Timeline)
                // already gate on a "is this gap reasonable?" check and fall back
                // to defaults / DB-direct queries when no engine state exists.
                // AppMode "Just Woke Up" uses a 20-min recency window so a missing
                // sleepEndTime just means it doesn't fire on cold start — acceptable.

                // Restore currentRMSSD and respiratoryRate from last day's scores so
                // the recovery-driver breakdowns can compute on cold start (otherwise
                // computeRecovery early-exits at `guard currentRMSSD > 0` and all four
                // contribution bars show +0 even though the score is non-zero).
                if self.currentRMSSD == 0, let hrv = scores["hrv_avg"], hrv > 0 {
                    self.currentRMSSD = hrv
                    self.lnRMSSD = log(hrv)
                    UserDefaults.standard.set(hrv, forKey: self.currentRMSSDKey)
                    print("[Health] Restored currentRMSSD from last scores: \(Int(hrv))")
                }
                if self.respiratoryRate == 0, let rr = scores["respiratory_rate"], rr > 0 {
                    self.respiratoryRate = rr
                    print("[Health] Restored respiratoryRate: \(String(format: "%.1f", rr))")
                }

                // Pre-seed baselineRMSSD if still empty — unblocks updateReadiness() guard
                // before the slower fetchHealthBaseline() (14-day query) completes.
                if self.baselineRMSSD.isEmpty, let hrv = scores["hrv_avg"], hrv > 0 {
                    self.baselineRMSSD = Array(repeating: hrv, count: 7)
                    UserDefaults.standard.set(self.baselineRMSSD, forKey: self.baselineKey)
                    print("[Health] Pre-seeded baselineRMSSD from last scores: \(Int(hrv))")
                }
                // Restore baseline RHR from last recorded resting_hr
                if self.baselineRHR == 60, let rhr = scores["resting_hr"], rhr > 30 {
                    self.baselineRHR = rhr
                    print("[Health] Restored baselineRHR from last scores: \(Int(rhr))")
                }

                // HRV research metrics
                if self.sdnn == 0, let s = scores["sdnn"], s > 0 { self.sdnn = s }
                if self.pnn50 == 0, let p = scores["pnn50"], p > 0 { self.pnn50 = p }
                if self.dfaAlpha1 == 0, let d = scores["dfa_alpha1"], d > 0 { self.dfaAlpha1 = d }

                // Quick-win health metrics (v32) — restore so dashboard shows correct values
                // immediately on cold start, before strap reconnects
                if self.nocturnalHRDip == 0, let dip = scores["nocturnal_hr_dip"], dip != 0 {
                    self.nocturnalHRDip = dip
                    self.nocturnalDipStatus = dip >= 10 ? "Normal" : "Non-Dipper"
                }
                if self.sleepFragmentationIndex == 0, let frag = scores["sleep_fragmentation"], frag > 0 {
                    self.sleepFragmentationIndex = frag
                }
                if self.sleepDebtHours == 0, let debt = scores["sleep_debt_hours"], debt > 0 {
                    self.sleepDebtHours = debt
                }
                if self.vo2maxEstimate == 0, let vo2 = scores["vo2max"], vo2 > 0 {
                    self.vo2maxEstimate = vo2
                }
                if self.poincaréSD1 == 0, let s1 = scores["poincare_sd1"], s1 > 0 {
                    self.poincaréSD1 = s1
                }
                if self.poincaréSD2 == 0, let s2 = scores["poincare_sd2"], s2 > 0 {
                    self.poincaréSD2 = s2
                }
                if self.lastAlcoholImpact == 0, let alc = scores["alcohol_impact"], alc > 0 {
                    self.lastAlcoholImpact = alc
                }

                // (restoreStageMinutesIfNeeded now runs at the top of this block,
                // before the server's stage split is applied.)
                // Restore overtraining streak (UserDefaults, date-gated to 2 days)
                self.restoreConsecutiveLowHRVDays()

                print("[Health] State restoration from Supabase complete")

                // Now that currentRMSSD is seeded, recompute recovery so the driver
                // breakdowns (HRV/RHR/Sleep/Resp contributions) populate. The new
                // computeRecovery() is no-op when recovery is already locked for
                // today — protects the morning value from being overwritten by
                // mid-day cold-start restoration.
                if self.currentRMSSD > 0 {
                    self.computeRecovery()
                }

                // Notify anyone listening (BLEManager uses this to push fresh data
                // into the App Group so widgets can render on cold start even before
                // the strap connects).
                NotificationCenter.default.post(name: .healthBaselineRestored, object: nil)
            }

            self.calibrateFromHistory(supabase: supabase)
        }
    }

    // MARK: - Safety Recalculation

    /// Safety recalc timer is now a no-op for Recovery (morning-locked) — kept
    /// only as a hook for future safety paths. Recovery cannot be re-derived
    /// from live HRV without reintroducing the 90 → 9% fluctuation bug.
    func startSafetyRecalcTimer() {
        guard safetyRecalcTimer == nil else { return }
        liveDataStartTime = Date()
        // Intentionally no scheduled work. The fallback compute is gated by
        // computeRecoveryFallbackIfNeeded() (only after 14:00 local, only once).
    }

    func retroactiveReplayIfNeeded(supabase: SupabaseClient) {
        // Date-gate the flag: only skip replay if the flag was set TODAY.
        // A permanent flag (old behaviour) meant replay never fired again even across days.
        let today = Calendar.current.startOfDay(for: Date())
        if let flagEpoch = UserDefaults.standard.object(forKey: sleepReplayFlag) as? Double {
            let flagDate = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: flagEpoch))
            if flagDate == today { return } // already replayed today
        }
        guard sleepScore < 10 else {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: sleepReplayFlag)
            return
        }

        print("[Health] Retroactive sleep replay — fetching today's gap readings from Supabase")
        Task {
            let readings = await supabase.fetchTodayGapReadings()
            guard !readings.isEmpty else {
                print("[Health] No gap readings found for today")
                DispatchQueue.main.async {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.sleepReplayFlag)
                }
                return
            }

            DispatchQueue.main.async {
                self.replayGapForSleep(readings: readings)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.sleepReplayFlag)
                print("[Health] Retroactive replay complete — \(readings.count) readings processed")
            }
        }
    }

    // MARK: - Battery Prediction

    func addBatteryReading(_ level: Double) {
        batteryLog.append((date: Date(), level: level))
        if batteryLog.count >= 3 { predictChargeTime() }
        if batteryLog.count % 10 == 0 { saveBatteryHistory() }
    }

    private func saveBatteryHistory() {
        let entries = batteryLog.map { ["t": $0.date.timeIntervalSince1970, "l": $0.level] }
        UserDefaults.standard.set(entries, forKey: batteryHistoryKey)
    }

    func loadBatteryHistory() {
        guard let entries = UserDefaults.standard.array(forKey: batteryHistoryKey) as? [[String: Double]] else { return }
        batteryLog = entries.compactMap { entry in
            guard let t = entry["t"], let l = entry["l"] else { return nil }
            return (date: Date(timeIntervalSince1970: t), level: l)
        }
    }

    var batteryHistory: [(date: Date, level: Double)] { batteryLog }

    private func predictChargeTime() {
        guard batteryLog.count >= 3 else { return }

        let recent = batteryLog.suffix(10)
        let first = recent.first!
        let last = recent.last!

        let timeDelta = last.date.timeIntervalSince(first.date) / 3600.0
        let levelDelta = first.level - last.level

        guard timeDelta > 0.5 && levelDelta > 0 else {
            DispatchQueue.main.async { self.estimatedChargeTime = "Stable" }
            return
        }

        let drainPerHour = levelDelta / timeDelta
        let hoursRemaining = last.level / drainPerHour

        let prediction: String
        if hoursRemaining > 48 {
            prediction = "2+ days"
        } else if hoursRemaining > 24 {
            prediction = "~\(Int(hoursRemaining))h"
        } else {
            let targetDate = Date().addingTimeInterval(hoursRemaining * 3600)
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            prediction = "~\(fmt.string(from: targetDate))"
        }

        DispatchQueue.main.async { self.estimatedChargeTime = prediction }
    }

    // MARK: - Reset All Learned Data

    func resetAllLearnedData() {
        baselineRMSSD.removeAll()
        UserDefaults.standard.removeObject(forKey: baselineKey)
        UserDefaults.standard.removeObject(forKey: morningRMSSDKey)
        UserDefaults.standard.removeObject(forKey: bedtimeHistoryKey)
        UserDefaults.standard.removeObject(forKey: waketimeHistoryKey)
        UserDefaults.standard.removeObject(forKey: dailyStrainKey)
        UserDefaults.standard.removeObject(forKey: "lucid_detection_corrections")
        UserDefaults.standard.removeObject(forKey: "lucid_suppressed_types")
        UserDefaults.standard.removeObject(forKey: calibrationKey)
        calibration = PersonalCalibration()

        currentSleepStage = .awake
        sleepDetected = false
        sustainedLowHRMinutes = 0
        sustainedHighHRMinutes = 0
        sustainedMovementMinutes = 0
        recoveryScore = 0
        sleepScore = 0
        strainScore = 0
        bodyBattery = 100
        trainingLoadRatio = 1.0
        trainingLoadStatus = "Optimal"
        sleepConsistencyScore = 50
        illnessAlert = nil

        print("[HealthEngine] ALL learned data wiped — fresh start (calibration will re-run)")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Math Helpers
    // ═══════════════════════════════════════════════════════════════

    /// Sigmoid: maps z-score to 0-1 (centered at 0.5 for z=0)
    func sigmoid(_ z: Double) -> Double {
        1.0 / (1.0 + exp(-z * 1.5))
    }

    /// Standard deviation of an array
    func standardDev(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }

    /// Compute z-score of a value vs a baseline array
    func zScore(value: Double, baseline: [Double], inverted: Bool = false) -> Double {
        guard baseline.count >= 5 else { return 0 }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        let variance = baseline.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(baseline.count)
        let sd = sqrt(variance)
        guard sd > 0.01 else { return 0 }
        return inverted ? (mean - value) / sd : (value - mean) / sd
    }

    /// Percentile helper (linear interpolation)
    private func percentile(_ sorted: [Double], p: Double) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }
        let k = (p / 100.0) * Double(n - 1)
        let f = Int(k)
        let c = min(f + 1, n - 1)
        return sorted[f] + (k - Double(f)) * (sorted[c] - sorted[f])
    }

    /// Sleep hours to recovery-like score (for calibration grid search)
    private func sleepToScore(hours: Double) -> Double {
        if hours >= 7 && hours <= 9 { return 100 }
        else if hours >= 6 { return 70 + (hours - 6) * 30 }
        else if hours >= 5 { return 40 + (hours - 5) * 30 }
        else { return max(hours / 5 * 40, 0) }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Personal Calibration
    // ═══════════════════════════════════════════════════════════════

    struct PersonalCalibration: Codable {
        var version: Int = 2
        var dataPoints: Int = 0
        var lastCalibratedDate: String = ""

        // Sleep detection — calibrated 2026-04-21, 453 nights ground truth, results/sleep_staging_v1.json
        var sleepThreshold: Double = 58   // P50 sleeping HR
        var wakeThreshold: Double = 81    // P90 sleeping HR
        var deepHRCeiling: Double = 54    // P25 sleeping HR

        // Recovery weights
        var recoveryHRVWeight: Double = 0.60
        var recoveryRHRWeight: Double = 0.20
        var recoverySleepWeight: Double = 0.10
        var recoveryRRWeight: Double = 0.10

        // Sleep score weights
        var sleepDurationWeight: Double = 0.35
        var sleepEfficiencyWeight: Double = 0.25
        var sleepStageWeight: Double = 0.20
        var sleepConsistencyWeight: Double = 0.20

        // Strain zone weights
        var strainZoneWeights: [Double] = [0.0, 0.001, 0.005, 0.015, 0.030]

        // Body battery recharge per 30s
        var rechargeDeep: Double = 0.155
        var rechargeREM: Double = 0.093
        var rechargeLight: Double = 0.054

        // Body battery depletion per 30s by HR zone
        var depletionRates: [Double] = [0.008, 0.025, 0.055, 0.11, 0.18]
        var restingRechargeRate: Double = 0.02

        // IMU thresholds
        var imuStillThreshold: Double = 30
        var imuMovingThreshold: Double = 150

        // Personal reference stats
        var medianRHR: Double = 58
        var medianHRV: Double = 52
        var meanSleepHours: Double = 7.4
        var p5RHR: Double = 52
        var p95RHR: Double = 71
        var greenRecoveryMeanRHR: Double = 56
        var redRecoveryMeanRHR: Double = 70
    }

    private func loadCalibration() {
        guard let data = UserDefaults.standard.data(forKey: calibrationKey),
              let saved = try? JSONDecoder().decode(PersonalCalibration.self, from: data) else {
            print("[Health] No calibration found — using defaults (654-day analysis)")
            return
        }
        calibration = saved
        print("[Health] Loaded calibration v\(saved.version): \(saved.dataPoints) data points, last calibrated \(saved.lastCalibratedDate)")
    }

    private func saveCalibration() {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        UserDefaults.standard.set(data, forKey: calibrationKey)
    }

    /// Auto-calibrate all thresholds from Supabase health_metrics history
    func calibrateFromHistory(supabase: SupabaseClient) {
        Task {
            let rows = await supabase.fetchCalibrationData()
            guard rows.count >= 30 else {
                print("[Health] Not enough data for calibration (\(rows.count) rows, need 30+)")
                return
            }

            if calibration.dataPoints > 0 && rows.count - calibration.dataPoints < 30 {
                print("[Health] Calibration still fresh (\(rows.count - calibration.dataPoints) new days since last)")
                return
            }

            print("[Health] Calibrating from \(rows.count) days of health data...")

            var newCal = PersonalCalibration()
            newCal.dataPoints = rows.count
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            newCal.lastCalibratedDate = fmt.string(from: Date())

            // --- RHR Distribution ---
            let rhrs = rows.compactMap { $0["resting_hr"] }.filter { $0 > 0 }
            if rhrs.count >= 30 {
                let sorted = rhrs.sorted()
                newCal.medianRHR = percentile(sorted, p: 50)
                newCal.p5RHR = percentile(sorted, p: 5)
                newCal.p95RHR = percentile(sorted, p: 95)
                newCal.sleepThreshold = percentile(sorted, p: 75)
                newCal.wakeThreshold = ceil(percentile(sorted, p: 95))
                newCal.deepHRCeiling = percentile(sorted, p: 25)
            }

            // --- HRV Distribution ---
            let hrvs = rows.compactMap { $0["hrv_avg"] }.filter { $0 > 0 }
            if hrvs.count >= 30 {
                newCal.medianHRV = percentile(hrvs.sorted(), p: 50)
            }

            // --- Sleep Stats ---
            let sleepHours = rows.compactMap { $0["sleep_hours"] }.filter { $0 > 0 }
            if sleepHours.count >= 30 {
                newCal.meanSleepHours = sleepHours.reduce(0, +) / Double(sleepHours.count)
            }

            // --- Recovery Tier RHR ---
            let greenRows = rows.filter { ($0["recovery_score"] ?? 0) >= 67 }
            let redRows = rows.filter { ($0["recovery_score"] ?? 0) > 0 && ($0["recovery_score"] ?? 0) < 34 }
            let greenRHRs = greenRows.compactMap { $0["resting_hr"] }.filter { $0 > 0 }
            let redRHRs = redRows.compactMap { $0["resting_hr"] }.filter { $0 > 0 }
            if !greenRHRs.isEmpty { newCal.greenRecoveryMeanRHR = greenRHRs.reduce(0, +) / Double(greenRHRs.count) }
            if !redRHRs.isEmpty { newCal.redRecoveryMeanRHR = redRHRs.reduce(0, +) / Double(redRHRs.count) }

            // --- Body Battery Recharge Rates ---
            let deepMins = rows.compactMap { $0["deep_sleep_min"] }.filter { $0 > 0 }
            let remMins = rows.compactMap { $0["rem_sleep_min"] }.filter { $0 > 0 }
            let lightMins = rows.compactMap { $0["light_sleep_min"] }.filter { $0 > 0 }
            if !deepMins.isEmpty && !remMins.isEmpty && !lightMins.isEmpty {
                let avgDeep = deepMins.reduce(0, +) / Double(deepMins.count)
                let avgREM = remMins.reduce(0, +) / Double(remMins.count)
                let avgLight = lightMins.reduce(0, +) / Double(lightMins.count)
                let baseRate = 80.0 / (avgDeep * 2.0 + avgREM * 1.2 + avgLight * 0.7)
                newCal.rechargeDeep = baseRate * 2.0 * 0.5
                newCal.rechargeREM = baseRate * 1.2 * 0.5
                newCal.rechargeLight = baseRate * 0.7 * 0.5
            }

            // --- Strain Zone Weights ---
            let strains = rows.compactMap { $0["strain_score"] }.filter { $0 > 0 }
            if strains.count >= 30 {
                let medianStrain = percentile(strains.sorted(), p: 50)
                let w1 = medianStrain / (5760.0 * (0.2 + 0.5 + 0.6 + 0.3))
                newCal.strainZoneWeights = [0.0, w1, w1 * 5, w1 * 15, w1 * 30]
            }

            // --- Recovery Weights (grid search) ---
            let fullRows = rows.filter {
                ($0["recovery_score"] ?? 0) > 0 &&
                ($0["resting_hr"] ?? 0) > 0 &&
                ($0["hrv_avg"] ?? 0) > 0 &&
                ($0["sleep_hours"] ?? 0) > 0
            }
            if fullRows.count >= 50 {
                var bestMSE = Double.infinity
                var bestW = (0.60, 0.20, 0.10, 0.10)
                for wHRV in stride(from: 0.30, through: 0.65, by: 0.05) {
                    for wRHR in stride(from: 0.15, through: 0.35, by: 0.05) {
                        for wSleep in stride(from: 0.05, through: 0.25, by: 0.05) {
                            let wRR = 1.0 - wHRV - wRHR - wSleep
                            guard wRR >= 0 && wRR <= 0.20 else { continue }

                            var mse: Double = 0
                            for r in fullRows {
                                let hrvScore = max(0, min(100, (r["hrv_avg"]! - 17) * (100 / 63)))
                                let rhrScore = max(0, min(100, 100 - (r["resting_hr"]! - 49) * (100 / 44)))
                                let slpScore = self.sleepToScore(hours: r["sleep_hours"]!)
                                let predicted = hrvScore * wHRV + rhrScore * wRHR + slpScore * wSleep + 50 * wRR
                                mse += (predicted - r["recovery_score"]!) * (predicted - r["recovery_score"]!)
                            }
                            mse /= Double(fullRows.count)
                            if mse < bestMSE { bestMSE = mse; bestW = (wHRV, wRHR, wSleep, wRR) }
                        }
                    }
                }
                newCal.recoveryHRVWeight = bestW.0
                newCal.recoveryRHRWeight = bestW.1
                newCal.recoverySleepWeight = bestW.2
                newCal.recoveryRRWeight = bestW.3
                print("[Health] Recovery weights: HRV=\(Int(bestW.0*100))% RHR=\(Int(bestW.1*100))% Sleep=\(Int(bestW.2*100))% RR=\(Int(bestW.3*100))% (RMSE=\(String(format: "%.1f", sqrt(bestMSE))))")
            }

            DispatchQueue.main.async {
                self.calibration = newCal
                self.saveCalibration()
                print("[Health] Calibration complete: \(newCal.dataPoints) days, sleepThr=\(Int(newCal.sleepThreshold)) wakeThr=\(Int(newCal.wakeThreshold)) deepCeil=\(Int(newCal.deepHRCeiling))")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Server Recompute Result
    // ═══════════════════════════════════════════════════════════════

    /// The one place a recompute_health_metrics() result is applied. Call on the
    /// main queue. Every call site used to wire recovery and sleepScore up by
    /// hand and drop sleepHours on the floor, which is how the sleep card stayed
    /// frozen at a stale value after a correct server recompute.
    func applyServerRecompute(_ result: (recovery: Double, sleepScore: Double, sleepHours: Double)) {
        // 0 is a valid recovery score (alcohol night, burnout). Only nil is no-data,
        // and the caller's `if let` has already handled that.
        if result.recovery >= 0 {
            recoveryScore = round(result.recovery)
            if result.recovery >= 67 { recoveryLabel = "Green" }
            else if result.recovery >= 34 { recoveryLabel = "Yellow" }
            else { recoveryLabel = "Red" }
            UserDefaults.standard.set(result.recovery, forKey: recoveryScoreTodayKey)
        }
        if result.sleepScore > 0 { sleepScore = round(result.sleepScore) }
        if result.sleepHours > 0 { sleepDurationHours = round(result.sleepHours * 10) / 10 }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Weekly Health Report
    // ═══════════════════════════════════════════════════════════════

    func generateWeeklyReport() -> String {
        let dailyStrain = UserDefaults.standard.array(forKey: dailyStrainKey) as? [Double] ?? []
        let last7Strain = Array(dailyStrain.suffix(7))
        let avgStrain = last7Strain.isEmpty ? 0 : last7Strain.reduce(0, +) / Double(last7Strain.count)

        let avgHRV = baselineRMSSD.isEmpty ? 0 : baselineRMSSD.reduce(0, +) / Double(baselineRMSSD.count)

        var report = "📊 Weekly Health Report\n"
        report += "Recovery: \(Int(recoveryScore))/100 (\(recoveryLabel))\n"
        report += "HRV avg: \(Int(avgHRV))ms | Baseline RHR: \(Int(baselineRHR))bpm\n"
        report += "Sleep Score: \(Int(sleepScore))/100 | Consistency: \(Int(sleepConsistencyScore))/100\n"
        report += "Avg Daily Strain: \(String(format: "%.1f", avgStrain))/21\n"
        report += "Training Load: \(trainingLoadStatus) (ratio \(String(format: "%.2f", trainingLoadRatio)))\n"
        report += "Body Battery: \(Int(bodyBattery))%\n"
        if let illness = illnessAlert { report += "⚠️ \(illness)\n" }
        return report
    }
}
