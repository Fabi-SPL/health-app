import Foundation
import Combine
import UserNotifications

/// Activity Auto-Detection Engine — state-machine pattern matchers
/// consuming live HR + HRV data to detect sauna, cold plunge, stress, and alcohol.
///
/// Architecture: Each activity type has its own state machine running in parallel.
/// Only commits (calls markAutoDetectedActivity) when confidence >= 0.7.
/// Integrates with BLEManager's double-tap deferred window automatically.
class ActivityDetector: ObservableObject {

    // MARK: - BLE Manager Reference (for callbacks)
    weak var bleManager: BLEManager?

    // MARK: - Published State
    @Published var activeDetections: [DetectedActivity] = []
    @Published var detectionHistory: [DetectedActivity] = []  // past detections (last 24h)
    @Published var detectorStatus: String = "Idle"
    private let maxHistoryItems = 50

    // MARK: - Rolling Buffers (30-min windows)
    private var hrBuffer: [(hr: Int, time: Date)] = []
    private var rmssdBuffer: [(rmssd: Double, time: Date)] = []
    private let bufferDuration: TimeInterval = 30 * 60  // 30 minutes

    // MARK: - Overnight Accumulator (12-hour retention for alcohol detection)
    // Separate from the short rolling buffer — survives the full sleep window so
    // detectOvernightAlcohol() can compare midnight-6am HR against baseline at wake-up.
    private var overnightHRBuffer: [(hr: Int, rmssd: Double, time: Date)] = []
    private let overnightBufferDuration: TimeInterval = 12 * 60 * 60  // 12 hours

    // MARK: - Configurable Thresholds (tunable from corrections later)
    struct Thresholds {
        // Personal baselines (Fabi)
        static let restingHR = 58       // sleeping
        static let awakeRestingHR = 68  // awake relaxed
        static let maxHR = 190

        // Sauna — threshold calibrated 2026-04-21, P10 of max_hr on 3 confirmed sauna days, results/activity_detection_v1.json
        static let saunaHR = 103                 // sustained HR threshold
        static let saunaMinDuration: TimeInterval = 8 * 60  // 8 minutes sustained
        static let saunaMaxClimbRate: Double = 3.0  // max bpm/min (slow climb)
        static let saunaCooldownHR = 100         // below this = ended
        static let saunaCooldownDuration: TimeInterval = 5 * 60

        // Cold Plunge
        static let coldPlungeSpikeThreshold = 20  // +20 bpm in <30s
        static let coldPlungeSpikeWindow: TimeInterval = 30
        static let coldPlugeMinDuration: TimeInterval = 60  // min 1 min below baseline
        static let coldPlungeMaxDuration: TimeInterval = 15 * 60
        static let coldPlungeSaunaBoostWindow: TimeInterval = 10 * 60  // boost if sauna ended <10 min ago

        // Stress/Anxiety
        static let stressHR = 75
        static let stressRMSSD: Double = 30.0
        static let stressHRSD: Double = 5.0      // low variance = not exercise
        static let stressMinDuration: TimeInterval = 10 * 60  // 10 min sustained

        // Alcohol (overnight) — HRVDrop calibrated 2026-04-21, 71 alcohol activities, results/activity_detection_v1.json
        // Note: HR signal near-zero (0.6 bpm delta); keeping deviation conservative at 8 bpm
        static let alcoholHRDeviation = 8        // bpm above baseline
        static let alcoholHRVDrop: Double = 0.23 // 23% below baseline

        // Confidence
        static let commitThreshold: Double = 0.7
    }

    // MARK: - Detector States

    // Sauna
    private enum SaunaState {
        case idle
        case warming(start: Date, initialHR: Int)
        case activeSauna(start: Date)
        case cooldown(start: Date, saunaStart: Date)
    }
    private var saunaState: SaunaState = .idle
    private var lastSaunaEnd: Date?
    private var saunaCommitted = false

    // Cold Plunge
    private enum ColdPlungeState {
        case idle
        case shockPhase(spikeTime: Date, preHR: Int)
        case adaptation(start: Date, spikeTime: Date)
    }
    private var coldPlungeState: ColdPlungeState = .idle
    private var coldPlungeCommitted = false

    // Stress
    private enum StressState {
        case idle
        case elevated(start: Date)
        case sustained(start: Date)
    }
    private var stressState: StressState = .idle
    private var stressCommitted = false

    // Alcohol
    private var alcoholCheckedToday = false
    private var lastAlcoholCheckDate: Date?

    // MARK: - Sleep awareness (don't detect stress during sleep)
    private var currentSleepStage: String = "awake"

    // Exercise detection
    private enum ExerciseState {
        case idle
        case elevated(start: Date)
        case active(start: Date)
    }
    private var exerciseState: ExerciseState = .idle
    private var exerciseCommitted = false

    // Nap detection
    private enum NapState {
        case idle
        case drowsy(start: Date)
        case napping(start: Date)
    }
    private var napState: NapState = .idle
    private var napCommitted = false
    private var lastNapEnd: Date?

    // Focus Work detection
    private enum FocusState {
        case idle
        case possible(start: Date)
        case deepFocus(start: Date)
    }
    private var focusState: FocusState = .idle
    private var focusCommitted = false
    private var focusMinutesAccumulated: Double = 0

    // MARK: - Main Entry Point

    /// Called every ~1 second with new HR + HRV data from BLEManager
    func processReading(hr: Int, rmssd: Double, timestamp: Date) {
        guard hr > 30 else { return }

        // Update short rolling buffers (30-min, for real-time detection)
        hrBuffer.append((hr: hr, time: timestamp))
        if rmssd > 0 {
            rmssdBuffer.append((rmssd: rmssd, time: timestamp))
        }
        trimBuffers(before: timestamp.addingTimeInterval(-bufferDuration))

        // Update overnight accumulator (12-hour retention, for alcohol detection at wake-up)
        overnightHRBuffer.append((hr: hr, rmssd: rmssd, time: timestamp))
        overnightHRBuffer.removeAll { $0.time < timestamp.addingTimeInterval(-overnightBufferDuration) }

        // Run all detectors
        //
        // v110 (2026-05-25) — ALL threshold-based HR/HRV auto-detectors disabled
        // per Fabi's 2026-05-25 feedback: "we kind of need to delete every single
        // auto-detection ... it's like kind of 80% correct but I don't want it
        // to be 80% correct I want it to be 99 or like almost 100% correct."
        //
        // Diagnosis: HR-threshold heuristics are a commercial-product pattern
        // (need to label activities for users who don't know what they did).
        // Single-user systems get higher accuracy via multi-signal AND-rules
        // (CMMotionActivity + CoreLocation visits + FocusFilterIntent + HealthKit
        // environmental audio) and end-of-day LLM interpretation against the
        // raw signal stream.
        //
        // The detector code stays dormant so the per-detector implementations
        // can be re-purposed later as Layer-1 *feature* writers (writing to a
        // separate features table that Layer-3 LLM consumes), not as authorities
        // over user-facing activity events.
        //
        // See research report: knowledge_entries id 2278cfe5-21e4 — "Single-User
        // High-Detail Activity Inference Beyond Commercial Auto-Detection".
        //
        // v99 (still): sauna + cold_plunge stayed off since 2026-05-08.
        // processSaunaDetector(hr: hr, timestamp: timestamp)
        // processColdPlungeDetector(hr: hr, timestamp: timestamp)
        // processStressDetector(hr: hr, rmssd: rmssd, timestamp: timestamp)
        // processExerciseDetector(hr: hr, timestamp: timestamp)
        // processNapDetector(hr: hr, rmssd: rmssd, timestamp: timestamp)
        // processFocusWorkDetector(hr: hr, rmssd: rmssd, timestamp: timestamp)

        // Update status
        updateStatus()
    }

    /// Called when HealthEngine detects sleep stage change
    func updateSleepStage(_ stage: String) {
        currentSleepStage = stage
    }

    /// Called when wake-up is detected — runs overnight analysis
    func processWakeUp() {
        guard !alcoholCheckedToday else { return }

        // Check if today's date is different from last check
        let today = Calendar.current.startOfDay(for: Date())
        if let lastCheck = lastAlcoholCheckDate, Calendar.current.isDate(lastCheck, inSameDayAs: today) {
            return
        }

        alcoholCheckedToday = true
        lastAlcoholCheckDate = today
        detectOvernightAlcohol()
        // Clear overnight accumulator after the check — next night starts fresh
        overnightHRBuffer.removeAll()
        pushMorningBriefing()

        // Reset daily state
        alcoholCheckedToday = false  // allow re-check next day
    }

    // MARK: - Morning Readiness Briefing

    private func pushMorningBriefing() {
        let recentRMSSD = rmssdBuffer.suffix(30).map { $0.rmssd }
        guard recentRMSSD.count >= 5 else { return }

        let avgRMSSD = recentRMSSD.reduce(0, +) / Double(recentRMSSD.count)
        let baselineRMSSD = loadBaselineRMSSD()
        let hrvRatio = baselineRMSSD > 0 ? avgRMSSD / baselineRMSSD : 1.0

        let readinessLevel: String
        let strainBudget: String

        if hrvRatio >= 0.95 {
            readinessLevel = "GREEN \u{1F7E2}"
            strainBudget = "14-18"
        } else if hrvRatio >= 0.80 {
            readinessLevel = "YELLOW \u{1F7E1}"
            strainBudget = "8-14"
        } else {
            readinessLevel = "RED \u{1F534}"
            strainBudget = "4-8"
        }

        let briefing = "\u{2600}\u{FE0F} Morning readiness: \(readinessLevel). HRV \(Int(avgRMSSD))ms (\(Int(hrvRatio * 100))% of baseline). Strain budget: \(strainBudget)."

        bleManager?.supabase.pushBrainDump(
            content: briefing,
            tags: ["morning-briefing", "readiness", "auto-detect"]
        )
    }

    // MARK: - Sauna Detector

    private func processSaunaDetector(hr: Int, timestamp: Date) {
        switch saunaState {
        case .idle:
            if hr >= Thresholds.saunaHR {
                saunaState = .warming(start: timestamp, initialHR: hr)
            }

        case .warming(let start, let initialHR):
            let duration = timestamp.timeIntervalSince(start)

            if hr < Thresholds.saunaHR - 10 {
                // HR dropped significantly — not sauna
                saunaState = .idle
            } else if duration >= Thresholds.saunaMinDuration {
                // Check if climb was gradual (not exercise)
                let climbRate = Double(hr - initialHR) / (duration / 60.0)
                if climbRate < Thresholds.saunaMaxClimbRate || hr >= Thresholds.saunaHR {
                    // Sustained high HR with slow climb = sauna
                    saunaState = .activeSauna(start: start)
                    if !saunaCommitted {
                        saunaCommitted = true
                        bleManager?.markAutoDetectedActivity(type: "sauna")
                        addDetection(DetectedActivity(
                            type: "sauna",
                            confidence: 0.8,
                            startTime: start,
                            status: "active"
                        ))
                    }
                } else {
                    // Fast climb = likely exercise, not sauna
                    saunaState = .idle
                }
            }

        case .activeSauna(let start):
            if hr < Thresholds.saunaCooldownHR {
                saunaState = .cooldown(start: timestamp, saunaStart: start)
            }

        case .cooldown(let cooldownStart, let saunaStart):
            if hr >= Thresholds.saunaHR {
                // Back up — still in sauna
                saunaState = .activeSauna(start: saunaStart)
            } else if timestamp.timeIntervalSince(cooldownStart) >= Thresholds.saunaCooldownDuration {
                // Cooled down long enough — sauna ended
                if saunaCommitted {
                    bleManager?.markAutoDetectedActivityEnd(type: "sauna")
                    lastSaunaEnd = timestamp
                }
                saunaState = .idle
                saunaCommitted = false
                removeDetection(type: "sauna")
            }
        }
    }

    // MARK: - Cold Plunge Detector

    private func processColdPlungeDetector(hr: Int, timestamp: Date) {
        switch coldPlungeState {
        case .idle:
            // Look for sharp HR spike (dive response)
            let recentHR = hrBuffer.suffix(5).map { $0.hr }
            guard recentHR.count >= 5 else { return }
            let avgRecent = recentHR.prefix(3).reduce(0, +) / 3
            let spike = hr - avgRecent

            if spike >= Thresholds.coldPlungeSpikeThreshold {
                var confidence = 0.5
                // Boost if sauna ended recently
                if let lastSauna = lastSaunaEnd,
                   timestamp.timeIntervalSince(lastSauna) < Thresholds.coldPlungeSaunaBoostWindow {
                    confidence += 0.2
                }
                coldPlungeState = .shockPhase(spikeTime: timestamp, preHR: avgRecent)
            }

        case .shockPhase(let spikeTime, let preHR):
            let elapsed = timestamp.timeIntervalSince(spikeTime)

            if elapsed > Thresholds.coldPlungeSpikeWindow {
                // Spike window expired — check if HR dropped below pre-spike
                if hr < preHR - 5 {
                    coldPlungeState = .adaptation(start: timestamp, spikeTime: spikeTime)
                    if !coldPlungeCommitted {
                        coldPlungeCommitted = true
                        var confidence = 0.7
                        if let lastSauna = lastSaunaEnd,
                           timestamp.timeIntervalSince(lastSauna) < Thresholds.coldPlungeSaunaBoostWindow {
                            confidence = 0.9
                        }
                        bleManager?.markAutoDetectedActivity(type: "cold_plunge")
                        addDetection(DetectedActivity(
                            type: "cold_plunge",
                            confidence: confidence,
                            startTime: spikeTime,
                            status: "active"
                        ))
                    }
                } else {
                    // HR didn't drop — false alarm
                    coldPlungeState = .idle
                }
            }

        case .adaptation(let start, _):
            let elapsed = timestamp.timeIntervalSince(start)

            if hr > Thresholds.awakeRestingHR + 10 || elapsed > Thresholds.coldPlungeMaxDuration {
                // HR back up or max duration — plunge ended
                if coldPlungeCommitted {
                    bleManager?.markAutoDetectedActivityEnd(type: "cold_plunge")
                }
                coldPlungeState = .idle
                coldPlungeCommitted = false
                removeDetection(type: "cold_plunge")
            }
        }
    }

    // MARK: - Stress / Anxiety Detector

    private func processStressDetector(hr: Int, rmssd: Double, timestamp: Date) {
        // Don't detect stress during sleep or active physical activities
        if currentSleepStage != "awake" { stressState = .idle; return }
        if saunaCommitted || coldPlungeCommitted { stressState = .idle; return }

        switch stressState {
        case .idle:
            if hr > Thresholds.stressHR && rmssd > 0 && rmssd < Thresholds.stressRMSSD {
                // Check HR variance (low = not exercise)
                let hrSD = computeHRSD(windowSeconds: 120, before: timestamp)
                if hrSD < Thresholds.stressHRSD {
                    stressState = .elevated(start: timestamp)
                }
            }

        case .elevated(let start):
            let duration = timestamp.timeIntervalSince(start)

            if hr <= Thresholds.stressHR || rmssd >= Thresholds.stressRMSSD + 10 {
                // Calmed down
                stressState = .idle
            } else if duration >= Thresholds.stressMinDuration {
                // Sustained stress
                stressState = .sustained(start: start)
                if !stressCommitted {
                    stressCommitted = true
                    bleManager?.markAutoDetectedActivity(type: "anxiety")
                    addDetection(DetectedActivity(
                        type: "anxiety",
                        confidence: 0.75,
                        startTime: start,
                        status: "active"
                    ))
                }
            }

        case .sustained(let start):
            if hr <= Thresholds.awakeRestingHR || rmssd >= Thresholds.stressRMSSD + 15 {
                // Stress resolved
                if stressCommitted {
                    bleManager?.markAutoDetectedActivityEnd(type: "anxiety")
                }
                stressState = .idle
                stressCommitted = false
                removeDetection(type: "anxiety")
            }
        }
    }

    // MARK: - Overnight Alcohol Detection

    private func detectOvernightAlcohol() {
        // Use the 12h overnight accumulator — the 30-min rolling buffer has already
        // discarded the midnight-6am window by the time processWakeUp() fires at ~11:30.
        let now = Date()
        let nightStart = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: now) ?? now
        let nightEnd = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now

        let overnightRows = overnightHRBuffer.filter { $0.time >= nightStart && $0.time <= nightEnd }
        let overnightHR = overnightRows.map { $0.hr }
        let overnightRMSSD = overnightRows.map { $0.rmssd }.filter { $0 > 0 }

        guard overnightHR.count >= 100, overnightRMSSD.count >= 20 else {
            print("[ActivityDetector] Alcohol check: not enough overnight data (\(overnightHR.count) HR, \(overnightRMSSD.count) HRV readings in midnight-6am window)")
            return
        }

        let avgOvernightHR = Double(overnightHR.reduce(0, +)) / Double(overnightHR.count)
        let avgOvernightRMSSD = overnightRMSSD.reduce(0, +) / Double(overnightRMSSD.count)

        let baseline7dRMSSD = loadBaselineRMSSD()

        let hrElevation = avgOvernightHR - Double(Thresholds.restingHR)
        let hrvDrop = baseline7dRMSSD > 0 ? (baseline7dRMSSD - avgOvernightRMSSD) / baseline7dRMSSD : 0

        if hrElevation >= Double(Thresholds.alcoholHRDeviation) && hrvDrop >= Thresholds.alcoholHRVDrop {
            // Alcohol detected — push as previous evening activity
            let lastEvening = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0,
                                                     of: now.addingTimeInterval(-86400)) ?? now

            bleManager?.supabase.pushActivity(
                type: "alcohol",
                source: "auto",
                startedAt: lastEvening,
                endedAt: nightStart,
                hrAvg: Int(avgOvernightHR),
                hrvAvg: avgOvernightRMSSD,
                notes: "Auto-detected: overnight HR +\(Int(hrElevation))bpm, HRV -\(Int(hrvDrop * 100))%",
                category: "physical",
                metadata: [
                    "overnight_hr_avg": avgOvernightHR,
                    "overnight_hrv_avg": avgOvernightRMSSD,
                    "baseline_hrv": baseline7dRMSSD,
                    "hr_elevation": hrElevation,
                    "hrv_drop_pct": hrvDrop * 100
                ]
            )

            addDetection(DetectedActivity(
                type: "alcohol",
                confidence: min(0.5 + hrvDrop + hrElevation / 20.0, 0.95),
                startTime: lastEvening,
                status: "completed"
            ))
        }
    }

    // MARK: - Exercise Auto-Detection

    private func processExerciseDetector(hr: Int, timestamp: Date) {
        // Don't detect exercise during sleep or sauna/cold
        if currentSleepStage != "awake" { exerciseState = .idle; return }
        if saunaCommitted || coldPlungeCommitted { return }

        switch exerciseState {
        case .idle:
            if hr > 120 {
                exerciseState = .elevated(start: timestamp)
            }

        case .elevated(let start):
            let duration = timestamp.timeIntervalSince(start)
            if hr < 110 {
                exerciseState = .idle
            } else if duration >= 10 * 60 {
                // 10+ min sustained HR > 120 with variance = exercise
                let hrSD = computeHRSD(windowSeconds: 300, before: timestamp)
                if hrSD > 5 {  // exercise has variable HR, unlike sauna
                    exerciseState = .active(start: start)
                    if !exerciseCommitted {
                        exerciseCommitted = true
                        bleManager?.markAutoDetectedActivity(type: "exercise")
                        addDetection(DetectedActivity(
                            type: "exercise",
                            confidence: 0.8,
                            startTime: start,
                            status: "active"
                        ))
                    }
                }
            }

        case .active:
            // End when HR drops below 100 for 5+ minutes
            let recentLow = hrBuffer.suffix(30).filter { $0.hr < 100 }
            if recentLow.count >= 25 {
                if exerciseCommitted {
                    bleManager?.markAutoDetectedActivityEnd(type: "exercise")
                }
                exerciseState = .idle
                exerciseCommitted = false
                removeDetection(type: "exercise")
            }
        }
    }

    // MARK: - Nap Detection

    private func processNapDetector(hr: Int, rmssd: Double, timestamp: Date) {
        // Only detect naps during daytime (10am - 6pm)
        let hour = Calendar.current.component(.hour, from: timestamp)
        guard hour >= 10 && hour < 18 else { napState = .idle; return }

        // Cooldown: no nap detection within 2 hours of last nap
        if let lastNap = lastNapEnd, timestamp.timeIntervalSince(lastNap) < 7200 {
            return
        }

        switch napState {
        case .idle:
            if hr < Thresholds.awakeRestingHR - 5 && rmssd > 0 {
                napState = .drowsy(start: timestamp)
            }

        case .drowsy(let start):
            let duration = timestamp.timeIntervalSince(start)
            if hr > Thresholds.awakeRestingHR + 5 {
                napState = .idle
            } else if duration >= 5 * 60 {
                // 5+ min of low HR during daytime = nap
                napState = .napping(start: start)
                if !napCommitted {
                    napCommitted = true
                    bleManager?.markAutoDetectedActivity(type: "nap")
                    addDetection(DetectedActivity(
                        type: "nap",
                        confidence: 0.7,
                        startTime: start,
                        status: "active"
                    ))
                }
            }

        case .napping(let start):
            let duration = timestamp.timeIntervalSince(start)
            // End when HR goes back up or duration > 90 min
            if hr > Thresholds.awakeRestingHR + 10 || duration > 90 * 60 {
                if napCommitted {
                    bleManager?.markAutoDetectedActivityEnd(type: "nap", metadata: [
                        "duration_min": Int(duration / 60)
                    ])
                    lastNapEnd = timestamp
                }
                napState = .idle
                napCommitted = false
                removeDetection(type: "nap")
            }
        }
    }

    // MARK: - Focus Work Detection

    private func processFocusWorkDetector(hr: Int, rmssd: Double, timestamp: Date) {
        // Don't detect focus during sleep or active physical activities
        if currentSleepStage != "awake" { focusState = .idle; return }
        if saunaCommitted || coldPlungeCommitted || exerciseCommitted { focusState = .idle; return }

        // Focus signature: HR 55-80, low HR variance (<6), decent HRV (>30), during work hours
        let hour = Calendar.current.component(.hour, from: timestamp)
        guard hour >= 8 && hour < 22 else { focusState = .idle; return }

        let hrSD = computeHRSD(windowSeconds: 300, before: timestamp)
        let isFocusHR = hr >= 55 && hr <= 80
        let isLowVariance = hrSD < 6 && hrSD != 999  // 999 = not enough data
        let hasGoodHRV = rmssd > 30 || rmssd == 0   // 0 = no measurement, don't block

        switch focusState {
        case .idle:
            if isFocusHR && isLowVariance && hasGoodHRV {
                focusState = .possible(start: timestamp)
            }

        case .possible(let start):
            let duration = timestamp.timeIntervalSince(start)

            if !isFocusHR || !isLowVariance {
                // Lost focus signature — reset if too short
                if duration < 5 * 60 {
                    focusState = .idle
                }
                // Otherwise keep the session — brief interruptions are normal
            } else if duration >= 15 * 60 {
                // 15+ minutes of sustained focus HR = deep work
                focusState = .deepFocus(start: start)
                if !focusCommitted {
                    focusCommitted = true
                    bleManager?.markAutoDetectedActivity(type: "deep_work")
                    addDetection(DetectedActivity(
                        type: "deep_work",
                        confidence: 0.7,
                        startTime: start,
                        status: "active"
                    ))
                }
            }

        case .deepFocus(let start):
            focusMinutesAccumulated = timestamp.timeIntervalSince(start) / 60.0

            // End when HR goes high (stood up, exercise) or sustained non-focus
            let recentHighHR = hrBuffer.suffix(60).filter { $0.hr > 90 }
            if recentHighHR.count >= 30 {
                // 30+ seconds of HR > 90 = no longer in focus
                if focusCommitted {
                    bleManager?.markAutoDetectedActivityEnd(type: "deep_work", metadata: [
                        "duration_min": Int(focusMinutesAccumulated)
                    ])
                }
                focusState = .idle
                focusCommitted = false
                focusMinutesAccumulated = 0
                removeDetection(type: "deep_work")
            }
        }
    }

    // MARK: - Helpers

    private func trimBuffers(before cutoff: Date) {
        hrBuffer.removeAll { $0.time < cutoff }
        rmssdBuffer.removeAll { $0.time < cutoff }
    }

    private func averageHR(from start: Date, to end: Date) -> Int {
        let readings = hrBuffer.filter { $0.time >= start && $0.time <= end }
        guard !readings.isEmpty else { return 0 }
        return readings.map { $0.hr }.reduce(0, +) / readings.count
    }

    private func computeHRSD(windowSeconds: TimeInterval, before timestamp: Date) -> Double {
        let cutoff = timestamp.addingTimeInterval(-windowSeconds)
        let readings = hrBuffer.filter { $0.time >= cutoff && $0.time <= timestamp }.map { Double($0.hr) }
        guard readings.count >= 10 else { return 999 }  // not enough data = assume high variance

        let mean = readings.reduce(0, +) / Double(readings.count)
        let variance = readings.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(readings.count)
        return sqrt(variance)
    }

    private func loadBaselineRMSSD() -> Double {
        // Load 7-day baseline from UserDefaults (same key as HealthEngine)
        let baseline = UserDefaults.standard.array(forKey: "lucid_rmssd_baseline_7d") as? [Double] ?? []
        guard !baseline.isEmpty else { return 50.0 }  // fallback
        return baseline.reduce(0, +) / Double(baseline.count)
    }

    private func addDetection(_ detection: DetectedActivity) {
        // Check if this type is suppressed by feedback
        let hr = hrBuffer.last?.hr ?? 0
        let rmssd = rmssdBuffer.last?.rmssd ?? 0
        if DetectionFeedback.shared.shouldSuppress(type: detection.type, hr: Double(hr), hrv: rmssd) {
            print("[ActivityDetector] Suppressed \(detection.type) — user feedback")
            return
        }

        DispatchQueue.main.async {
            // Remove existing detection of same type
            self.activeDetections.removeAll { $0.type == detection.type }
            self.activeDetections.append(detection)
        }

        // v112 (2026-05-30) — iOS-local "Activity Detected" banner disabled.
        // v110 commented out the processors in processReading() but the
        // notification call here would still fire if any other path called
        // addDetection (e.g. history replay, future re-arm). Belt-and-suspenders:
        // kill the notification call too. iOS = stupid transmitter.
        // sendActivityNotification(detection: detection)
    }

    private func removeDetection(type: String) {
        DispatchQueue.main.async {
            // Move to history before removing
            if let idx = self.activeDetections.firstIndex(where: { $0.type == type }) {
                var item = self.activeDetections[idx]
                item.endTime = Date()
                item.status = "completed"
                self.detectionHistory.insert(item, at: 0)
                // Trim history
                if self.detectionHistory.count > self.maxHistoryItems {
                    self.detectionHistory = Array(self.detectionHistory.prefix(self.maxHistoryItems))
                }
            }
            self.activeDetections.removeAll { $0.type == type }
        }
    }

    /// Dismiss a detection as wrong — records feedback so the engine learns
    func dismissDetection(type: String, correctedType: String? = nil) {
        let hr = hrBuffer.last.map { Double($0.hr) } ?? 0
        let hrv = rmssdBuffer.last?.rmssd ?? 0

        DetectionFeedback.shared.recordCorrection(
            detected: type,
            corrected: correctedType,
            hr: hr,
            hrv: hrv
        )

        // Move to history as dismissed
        DispatchQueue.main.async {
            if let idx = self.activeDetections.firstIndex(where: { $0.type == type }) {
                var item = self.activeDetections[idx]
                item.endTime = Date()
                item.status = "dismissed"
                self.detectionHistory.insert(item, at: 0)
                if self.detectionHistory.count > self.maxHistoryItems {
                    self.detectionHistory = Array(self.detectionHistory.prefix(self.maxHistoryItems))
                }
            }
            self.activeDetections.removeAll { $0.type == type }
        }

        // Reset the committed state so it doesn't re-add immediately
        switch type {
        case "sauna": saunaCommitted = false; saunaState = .idle
        case "cold_plunge": coldPlungeCommitted = false; coldPlungeState = .idle
        case "anxiety": stressCommitted = false; stressState = .idle
        case "exercise": exerciseCommitted = false; exerciseState = .idle
        case "nap": napCommitted = false; napState = .idle
        case "deep_work": focusCommitted = false; focusState = .idle
        default: break
        }

        bleManager?.markAutoDetectedActivityEnd(type: type)
    }

    /// Dismiss a detection from history — retroactive correction
    func dismissHistoryItem(id: UUID) {
        guard let idx = detectionHistory.firstIndex(where: { $0.id == id }) else { return }
        let item = detectionHistory[idx]

        let hr = hrBuffer.last.map { Double($0.hr) } ?? 0
        let hrv = rmssdBuffer.last?.rmssd ?? 0

        DetectionFeedback.shared.recordCorrection(
            detected: item.type,
            corrected: nil,
            hr: hr,
            hrv: hrv
        )

        detectionHistory[idx].status = "dismissed"
    }

    /// Remove a history item entirely
    func removeHistoryItem(id: UUID) {
        detectionHistory.removeAll { $0.id == id }
    }

    // MARK: - Push Notifications for Activity Detection

    private func sendActivityNotification(detection: DetectedActivity) {
        let content = UNMutableNotificationContent()
        content.title = "\(activityEmoji(detection.type)) Activity Detected"
        content.body = "\(detection.type.replacingOccurrences(of: "_", with: " ").capitalized) — \(Int(detection.confidence * 100))% confidence. Open to dismiss if wrong."
        content.sound = .default
        content.categoryIdentifier = "ACTIVITY_DETECTION"

        let request = UNNotificationRequest(
            identifier: "activity-\(detection.type)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[ActivityDetector] Notification failed: \(error)")
            }
        }
    }

    private func activityEmoji(_ type: String) -> String {
        switch type {
        case "sauna": return "🧖"
        case "cold_plunge": return "🥶"
        case "exercise", "workout": return "🏋️"
        case "skiing": return "⛷️"
        case "nap": return "😴"
        case "anxiety": return "😰"
        case "alcohol": return "🍺"
        default: return "🎯"
        }
    }

    private func updateStatus() {
        let active = activeDetections.map { $0.type }.joined(separator: ", ")
        let status = active.isEmpty ? "Monitoring" : active
        DispatchQueue.main.async {
            if self.detectorStatus != status { self.detectorStatus = status }
        }
    }
}

// MARK: - Data Structures

struct DetectedActivity: Identifiable {
    let id: UUID
    let type: String
    let confidence: Double
    let startTime: Date
    var endTime: Date?
    var status: String  // "active", "completed", "dismissed"

    init(type: String, confidence: Double, startTime: Date, status: String) {
        self.id = UUID()
        self.type = type
        self.confidence = confidence
        self.startTime = startTime
        self.status = status
    }
}

// MARK: - Detection Feedback System

/// Stores user corrections so the engine learns over time
class DetectionFeedback: ObservableObject {
    static let shared = DetectionFeedback()

    private let storageKey = "lucid_detection_corrections"
    private let suppressionKey = "lucid_suppressed_types"

    /// Recent corrections with context (for pattern learning)
    @Published var corrections: [Correction] = []

    /// Types the user has suppressed too many times (auto-suppress threshold)
    @Published var suppressedTypes: Set<String> = []

    struct Correction: Codable, Identifiable {
        let id: String
        let detectedType: String
        let correctedType: String?  // nil = "nothing was happening"
        let hrAtMoment: Double
        let hrvAtMoment: Double
        let hourOfDay: Int
        let timestamp: Date
    }

    init() {
        load()
    }

    /// Record a correction — user says "this detection was wrong"
    func recordCorrection(detected: String, corrected: String?, hr: Double, hrv: Double) {
        let hour = Calendar.current.component(.hour, from: Date())
        let correction = Correction(
            id: UUID().uuidString,
            detectedType: detected,
            correctedType: corrected,
            hrAtMoment: hr,
            hrvAtMoment: hrv,
            hourOfDay: hour,
            timestamp: Date()
        )
        corrections.append(correction)

        // Keep last 100 corrections
        if corrections.count > 100 {
            corrections = Array(corrections.suffix(100))
        }

        // Auto-suppress: if same type dismissed 5+ times in 7 days, suppress it
        let recentDismissals = corrections.filter {
            $0.detectedType == detected &&
            $0.correctedType == nil &&
            $0.timestamp > Date().addingTimeInterval(-7 * 86400)
        }
        if recentDismissals.count >= 5 {
            suppressedTypes.insert(detected)
        }

        save()
    }

    /// Un-suppress a type (user re-enables it)
    func unsuppress(type: String) {
        suppressedTypes.remove(type)
        save()
    }

    /// Check if a detection should be suppressed based on feedback patterns
    func shouldSuppress(type: String, hr: Double, hrv: Double) -> Bool {
        // Hard suppress
        if suppressedTypes.contains(type) { return true }

        // Pattern suppress: if dismissed 3+ times in similar conditions (±10 HR, ±15 HRV, same time window)
        let hour = Calendar.current.component(.hour, from: Date())
        let similarDismissals = corrections.filter {
            $0.detectedType == type &&
            $0.correctedType == nil &&
            abs($0.hrAtMoment - hr) < 10 &&
            abs($0.hrvAtMoment - hrv) < 15 &&
            abs($0.hourOfDay - hour) <= 2 &&
            $0.timestamp > Date().addingTimeInterval(-14 * 86400)  // last 14 days
        }
        return similarDismissals.count >= 3
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(corrections) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
        UserDefaults.standard.set(Array(suppressedTypes), forKey: suppressionKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Correction].self, from: data) {
            corrections = decoded
        }
        if let suppressed = UserDefaults.standard.stringArray(forKey: suppressionKey) {
            suppressedTypes = Set(suppressed)
        }
    }
}

