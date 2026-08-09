import Foundation
import UserNotifications

// ════════════════════════════════════════════════════════════
// Sleep Engine — Stage detection, scoring, smart alarm, IMU
// Extension on HealthEngine for all sleep-related computation
//
// Research basis:
//   - Sleep staging: Beattie et al. 2017 — HR + HRV ~80% accuracy
//   - Personal thresholds from 654 days of Whoop data (2024-06 → 2026-04)
//   - Stage balance targets: 467 nights — deep mean 23.4%, REM mean 26.2%
//   - REM detection: RR irregularity as independent signal
//   - IMU enhancement: body stillness discriminates deep/REM from light/awake
// ════════════════════════════════════════════════════════════

extension HealthEngine {

    // MARK: - HR Reading Input (Sleep Path)

    /// Feed HR reading for sleep stage detection
    func addHRReading(_ hr: Int) {
        guard hr > 30 else { return }

        recentHR.append(Double(hr))
        if recentHR.count > 30 { recentHR.removeFirst() }

        hrHistory.append(hr)
        if hrHistory.count > 60 { hrHistory.removeFirst() }

        // Track minimum HR during actual sleep stages (not awake) for accurate RHR
        if currentSleepStage != .awake && hr < 120 {
            sleepingMinHR = sleepingMinHR == 0 ? Double(hr) : min(sleepingMinHR, Double(hr))
        }

        // Detect sleep stage every ~30 seconds (3 readings at 10s intervals)
        if recentHR.count >= 10 && recentHR.count % 3 == 0 {
            detectSleepStage()
            checkSmartAlarm()
        }
    }

    // MARK: - Sleep Stage Detection

    /// Detect current sleep stage from HR + HRV patterns
    /// Research: Beattie et al. 2017 — HR + HRV achieves ~80% accuracy
    ///
    /// KEY INSIGHT: Thresholds are relative to YOUR personal baseline, not absolute numbers.
    /// - Deep sleep: HR drops 8-15% below YOUR sleeping RHR, very stable, HRV elevated
    /// - Light sleep: HR near YOUR RHR, moderate variability
    /// - REM: HR variable (bursts above AND below RHR), HRV suppressed (sympathetic activation)
    /// - Awake: HR clearly elevated above sleeping RHR
    ///
    /// From Fabi's data (March 2026):
    ///   Good night sleeping RHR: 52-55 bpm, HRV: 60-80ms
    ///   Bad night sleeping RHR: 65-77 bpm, HRV: 40-50ms
    ///   P50 nighttime HR: ~72 bpm (includes all stages)

    func detectSleepStage() {
        guard recentHR.count >= 10 else { return }

        // Wake-up lock: if we woke up after 7am, no sleep until 9pm
        if let lockUntil = wakeUpLockUntil, Date() < lockUntil {
            if sleepDetected {
                DispatchQueue.main.async {
                    self.currentSleepStage = .awake
                    self.sleepDetected = false
                }
            }
            return
        }

        let window = Array(recentHR.suffix(15))
        let avgHR = window.reduce(0, +) / Double(window.count)

        // HR variability (standard deviation of last 15 readings)
        let hrSD = sqrt(window.map { ($0 - avgHR) * ($0 - avgHR) }.reduce(0, +) / Double(window.count))

        // === DATA-DRIVEN PERSONAL THRESHOLDS (654 days, 2024-06 → 2026-04) ===
        // v98 — wakeThreshold is auto-calibrated from P95 of *resting* HR distribution
        // (not P95 of awake-active HR), which produces values too low for chronic-low-RHR
        // users like Fabi (RHR=54 → wakeThreshold=71). His morning lying-still HR can hit
        // 70-99 without him being awake by the engine's standards. Floor at baseline+25
        // bpm so the threshold is always meaningfully separated from "lying still in bed".
        let sleepRHR = baselineRHR
        let sleepThreshold = calibration.sleepThreshold
        let wakeThreshold = max(calibration.wakeThreshold, baselineRHR + 25)
        let deepHRCeiling = calibration.deepHRCeiling
        let deepSDMax: Double = 3.0
        let remSDMin: Double = 3.0
        let remHRVDrop = baselineHRV * 0.7

        // RR irregularity: ratio of successive-difference SD to mean RR
        let rrBuffer30 = Array(rrBuffer.suffix(30))
        let rrDataSparse = rrBuffer30.count < 10
        let rrIrregularity: Double = {
            guard !rrDataSparse else { return 0 }
            let diffs = (1..<rrBuffer30.count).map { abs(rrBuffer30[$0] - rrBuffer30[$0-1]) }
            let meanRR = rrBuffer30.reduce(0, +) / Double(rrBuffer30.count)
            guard meanRR > 0 else { return 0 }
            let diffSD = sqrt(diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count))
            return diffSD / meanRR
        }()

        // Time-based REM proxy: when RR data is sparse, use sleep-cycle timing
        // Research: REM cycles begin ~90min after sleep onset, recurring every ~90min
        // If 90min+ into sleep and HR is variable but can't confirm via RR → call it REM not light
        let rrFallbackREM: Bool = {
            guard rrDataSparse, let sleepStart = sleepStartTime else { return false }
            let minsAsleep = Date().timeIntervalSince(sleepStart) / 60.0
            guard minsAsleep >= 90 else { return false }
            // Only applies when not in a clear deep-sleep pattern
            let notDeep = !(avgHR < deepHRCeiling && hrSD < deepSDMax)
            return notDeep && hrSD > 1.8
        }()

        let hrv = currentRMSSD > 0 ? currentRMSSD : baselineHRV
        let hour = Calendar.current.component(.hour, from: Date())
        let isSleepWindow = hour >= 21 || hour < 9

        // IMU enhancement — moved up so sustained-movement counter sees current state.
        let hasIMU = !recentAccel.isEmpty
        let still = hasIMU && isBodyStill
        let moving = hasIMU && isMoving

        // Track sustained low/high HR duration + sustained movement (v98).
        let now = Date()
        if let lastCheck = lastSleepCheckTime {
            let elapsed = now.timeIntervalSince(lastCheck) / 60.0
            if avgHR < sleepThreshold && hrSD < 6 {
                sustainedLowHRMinutes += elapsed
                sustainedHighHRMinutes = 0
            } else if avgHR > wakeThreshold {
                sustainedHighHRMinutes += elapsed
                if !sleepDetected {
                    sustainedLowHRMinutes = 0
                }
            }
            // v98 — independent movement counter. Decays toward zero when still,
            // accumulates while moving. 5-min threshold below means "actually
            // physically moving for 5 sustained minutes" — the bar to claim
            // someone is no longer asleep based on movement alone.
            if moving {
                sustainedMovementMinutes += elapsed
            } else if still {
                sustainedMovementMinutes = max(0, sustainedMovementMinutes - elapsed)
            }
        }
        lastSleepCheckTime = now

        let sleepSustained = sustainedLowHRMinutes >= 15 || sleepDetected

        // Wake detection: only block during deep-sleep hours (midnight-5am)
        let deepSleepProtection = hour >= 0 && hour < 5
        // v115 — the deep-sleep shield is no longer absolute. 10 sustained min
        // above wakeThreshold+20 is unambiguously awake even at 2am. On Jul 14
        // HR sat at 100–112 for over an hour and the latched detector still
        // called it "light sleep" because deepSleepProtection blocked every wake.
        let trulyAwakeFromSleep = sleepDetected && sustainedHighHRMinutes >= 10
            && (!deepSleepProtection || avgHR > wakeThreshold + 20)

        // v98 — movement-confirmed wake. If sustained movement ≥5 min during morning
        // hours (5am-12pm) while sleepDetected, fire wake regardless of HR threshold.
        // This handles Fabi-pattern wake: chronic-low HR baseline means HR alone may
        // never cross wakeThreshold even when actively up and moving.
        let inWakeWindow = hour >= 5 && hour < 12
        let movementConfirmedWake = sleepDetected && hasIMU && inWakeWindow && sustainedMovementMinutes >= 5

        let newStage: SleepStage

        if sleepDetected {
            // v98 — movement-confirmed wake takes priority. If you've been moving
            // for 5+ sustained minutes in the morning window, you're awake.
            if movementConfirmedWake {
                newStage = .awake
                sustainedLowHRMinutes = 0
                sustainedMovementMinutes = 0  // consumed
            } else if trulyAwakeFromSleep && avgHR > wakeThreshold {
                newStage = .awake
                sustainedLowHRMinutes = 0
            } else if moving && avgHR > sleepRHR * 1.2 {
                newStage = .light
            } else if avgHR < deepHRCeiling && hrSD < deepSDMax && hrv > baselineHRV * 0.8 {
                newStage = .deep
            } else if still && hrSD > remSDMin && (hrv < remHRVDrop || avgHR > sleepRHR * 1.1 || rrIrregularity > 0.08) {
                newStage = .rem
            } else if hrSD > remSDMin && !hasIMU && (hrv < remHRVDrop || rrIrregularity > 0.08 || rrFallbackREM) {
                newStage = .rem
            } else if rrFallbackREM {
                // RR data sparse + 90min+ into sleep + some HR variability → REM more likely than light
                newStage = .rem
            } else {
                newStage = .light
            }
            // v115 — do NOT reset sustainedHighHRMinutes here. The accumulator
            // (avgHR<sleepThreshold → 0, avgHR>wakeThreshold → +=) is the sole
            // owner. The old per-stage resets wiped it every 2-min tick, so it
            // never reached the 10-min wake threshold — the detector latched
            // into "asleep" at 21:07 and never released (Jul 14: called HR 112
            // "light sleep"). Only a genuine 10-min sustained elevation wakes.
        } else {
            if avgHR > sleepThreshold || hrSD > 8 {
                newStage = .awake
            } else if !isSleepWindow && !sleepSustained {
                newStage = .awake
            } else if avgHR < deepHRCeiling && hrSD < deepSDMax && hrv > baselineHRV * 0.8 && sleepSustained {
                newStage = .deep
            } else if hrSD > remSDMin && (hrv < remHRVDrop || rrIrregularity > 0.08) && sleepSustained {
                newStage = .rem
            } else if sleepSustained {
                newStage = .light
            } else {
                newStage = .awake
            }
        }

        // === DEBUG LOGGING (every 2 min during sleep window) ===
        if isSleepWindow, let sb = debugSupabase {
            let shouldLog = lastDebugLog == nil || now.timeIntervalSince(lastDebugLog!) > 120
            if shouldLog {
                lastDebugLog = now
                let debugInfo: [String: Any] = [
                    "stage": newStage.rawValue,
                    "avgHR": round(avgHR * 10) / 10,
                    "hrSD": round(hrSD * 100) / 100,
                    "hrv": round(hrv * 10) / 10,
                    "baseRHR": baselineRHR,
                    "baseHRV": baselineHRV,
                    "deepCeiling": deepHRCeiling,
                    "sleepThresh": sleepThreshold,
                    "wakeThresh": wakeThreshold,
                    "sleepDetected": sleepDetected,
                    "sustainedLow": round(sustainedLowHRMinutes * 10) / 10,
                    "sustainedHigh": round(sustainedHighHRMinutes * 10) / 10,
                    "sustainedMovement": round(sustainedMovementMinutes * 10) / 10,
                    "movementConfirmedWake": movementConfirmedWake,
                    "alarmEnabled": alarmEnabled,
                    "imuActive": hasIMU,
                    "movementScore": round(movementScore * 10) / 10,
                    "bodyStill": still,
                    "bodyMoving": moving,
                    "rrIrregularity": round(rrIrregularity * 1000) / 1000
                ]
                let json = (try? JSONSerialization.data(withJSONObject: debugInfo))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                sb.pushDebugLog(event: "sleep_stage", details: json, tags: ["sleep-staging", "smart-alarm"])
            }
        }

        // Detect wake-up transition
        let wasAsleep = sleepDetected
        // v98 — accept either HR-based or movement-based wake confirmation.
        let justWokeUp = wasAsleep && newStage == .awake && (trulyAwakeFromSleep || movementConfirmedWake)

        DispatchQueue.main.async {
            let previousStage = self.currentSleepStage
            self.currentSleepStage = newStage

            if previousStage != newStage {
                self.trackStageChange(from: previousStage, to: newStage)
            }

            if newStage != .awake {
                let wasAwake = !self.sleepDetected
                self.sleepDetected = true
                self.markSleepStart()

                if wasAwake {
                    // v112 (2026-05-30) — iOS-local "😴 Sleep Detected" banner
                    // disabled. iOS = stupid transmitter, no auto-detection
                    // notifications. Sleep stage still detected internally for
                    // sleepDetected state (AppMode wake-up logic depends on it),
                    // just no user-facing notification fires.
                    // self.sendSleepNotification(stage: newStage)
                }
                if let lastNotif = self.lastWakeUpNotification {
                    let hoursSince = Date().timeIntervalSince(lastNotif) / 3600
                    if hoursSince >= self.wakeUpCooldownHours {
                        self.wakeUpNotified = false
                    }
                } else {
                    self.wakeUpNotified = false
                }
            }

            if justWokeUp && previousStage != .awake && !self.wakeUpNotified {
                self.wakeUpNotified = true
                self.lastWakeUpNotification = Date()
                self.sleepDetected = false
                self.sustainedLowHRMinutes = 0
                let wakeHour = Calendar.current.component(.hour, from: Date())
                print("[WakeUp] Detected at \(wakeHour):00! \(previousStage.rawValue) → Awake")

                if wakeHour >= 5 && wakeHour < 12 {
                    self.wakeUpCallback?()

                    var cal = Calendar.current
                    cal.timeZone = .current
                    if let tonight9pm = cal.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) {
                        self.wakeUpLockUntil = tonight9pm
                        print("[WakeUp] Morning wake — sleep locked until 9pm")
                    }
                } else {
                    self.markSleepEnd()
                    print("[WakeUp] Nap/evening wake — session ended, sleep can restart")
                }
            }
        }
    }

    // MARK: - Smart Alarm

    /// Check if we should trigger the smart alarm
    func checkSmartAlarm() {
        let now = Date()
        let calendar = Calendar.current
        let minuteOfDay = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        // Auto-reset alarmFiredToday if it's a new day. Without this, alarm never
        // fires on day 2+ because resetAlarmForNewDay() only runs at app init.
        if alarmFiredToday, let lastFire = alarmLastFireDate,
           !calendar.isDate(lastFire, inSameDayAs: now) {
            alarmFiredToday = false
            DispatchQueue.main.async { self.smartAlarmTriggered = false }
            print("[SmartAlarm] Auto-reset for new day (last fired \(lastFire))")
        }
        // Same reset for the pre-alarm micro-ping.
        if microPingFiredToday, let lastPing = microPingLastFireDate,
           !calendar.isDate(lastPing, inSameDayAs: now) {
            microPingFiredToday = false
        }

        // Pre-alarm micro-ping — 20-25 min before window start, fire a single
        // gentle haptic to briefly arouse → re-enter N1/N2 → guarantees a
        // clean light-sleep detection window at wake time.
        // Alcohol nights skip the pre-wake micro-ping entirely — we do NOT want
        // to arouse him early; the back-half rebound is the recovery he needs.
        if alarmEnabled && !microPingFiredToday && !microPingFiredPersistedToday && alarmWindowStart > 0 && !alcoholActive {
            let microPingStart = alarmWindowStart - 25
            let microPingEnd = alarmWindowStart - 20
            if minuteOfDay >= microPingStart && minuteOfDay <= microPingEnd {
                microPingFiredToday = true
                persistMicroPingFired()
                microPingLastFireDate = now
                preAlarmMicroPingCallback?()
                print("[SmartAlarm] MICRO-PING fired at \(minuteOfDay / 60):\(String(format: "%02d", minuteOfDay % 60)) — seeding N1 transition")
            }
        }

        // Log alarm state every 5 min inside the window for debugging
        if alarmEnabled && !alarmFiredToday && minuteOfDay >= alarmWindowStart && minuteOfDay <= alarmWindowEnd {
            let shouldLogAlarm = lastAlarmDebugLog == nil || now.timeIntervalSince(lastAlarmDebugLog!) > 300
            if shouldLogAlarm {
                lastAlarmDebugLog = now
                let timeStr = "\(minuteOfDay / 60):\(String(format: "%02d", minuteOfDay % 60))"
                let windowStr = "\(alarmWindowStart / 60):\(String(format: "%02d", alarmWindowStart % 60))-\(alarmWindowEnd / 60):\(String(format: "%02d", alarmWindowEnd % 60))"
                print("[SmartAlarm] Checking: time=\(timeStr), window=\(windowStr), stage=\(currentSleepStage.rawValue), sleepDetected=\(sleepDetected)")
                debugSupabase?.pushDebugLog(
                    event: "smart_alarm_check",
                    details: "{\"time\":\"\(timeStr)\",\"window\":\"\(windowStr)\",\"stage\":\"\(currentSleepStage.rawValue)\",\"sleepDetected\":\(sleepDetected)}",
                    tags: ["smart-alarm"]
                )
            }
        }

        guard alarmEnabled, !alarmFiredToday, !alarmFiredPersistedToday else { return }
        guard minuteOfDay >= alarmWindowStart && minuteOfDay <= alarmWindowEnd else { return }

        // ROUND-ALARM GUARD: inside the wake window, if he's already up (HR-based —
        // the stage classifier is unreliable on his low-HR mornings), retire
        // today's alarm and cancel the pending noon fallback so it can't "good
        // morning" him at 1pm after he's been awake for hours. (Gated to the
        // window so it never retires tomorrow's alarm while he's up this evening.)
        if isLikelyAwakeNow {
            alarmFiredToday = true
            persistAlarmFired()
            cancelFallbackCallback?()
            print("[SmartAlarm] Already awake in-window — suppressing alarm + cancelling fallback")
            debugSupabase?.pushDebugLog(event: "evt_alarm_suppressed_awake",
                details: "stage=\(currentSleepStage.rawValue) reason=already-awake-in-window")
            return
        }

        // Trigger on light sleep OR REM (both are good wake moments).
        // Accept immediately if stage matches. Also accept if RMSSD is trending up
        // for 3 consecutive 5-min windows — that's the N3→N2→N1 transition signal
        // (AUC 0.85, research-backed) even if stage classifier hasn't flipped yet.
        //
        // Circadian sensitivity weighting (two-process model):
        //   • Target < 06:00 → pre-nadir of Process C → tight gate, need confirmed light/REM
        //   • Target ≥ 07:30 → Process C rising fast → loose gate, slope alone is enough
        //   • Between (06:00–07:30) → slope OK but require non-deep stage as sanity check
        let stageOK = currentSleepStage == .light || currentSleepStage == .rem
        let slopeOK = isRmssdTrendingUp
        let targetIsEarly = alarmWindowStart > 0 && alarmWindowStart < 6 * 60
        let targetIsLate = alarmWindowStart >= 7 * 60 + 30
        var canTrigger: Bool
        if targetIsEarly {
            canTrigger = stageOK
        } else if targetIsLate {
            canTrigger = stageOK || slopeOK
        } else {
            canTrigger = stageOK || (slopeOK && currentSleepStage != .deep)
        }
        // Alcohol mode: NO proactive smart-wake at all. He's always classified
        // "light", so any light-sleep trigger fires the instant the window opens
        // (that was the 9am buzz). On a recovery night only the humane noon
        // backstop below is allowed — "no early alarm" stays literally true.
        if alcoholActive { canTrigger = false }
        if canTrigger {
            alarmFiredToday = true
            persistAlarmFired()
            alarmLastFireDate = now
            DispatchQueue.main.async {
                self.smartAlarmTriggered = true
            }
            sleepStageCallback?(currentSleepStage)
            let trigger = stageOK ? currentSleepStage.rawValue : "RMSSD-slope-up"
            let weighting = targetIsEarly ? "tight" : (targetIsLate ? "loose" : "normal")
            print("[SmartAlarm] TRIGGERED — \(trigger) at \(minuteOfDay / 60):\(String(format: "%02d", minuteOfDay % 60)) [circadian:\(weighting)]")
            debugSupabase?.pushDebugLog(
                event: "smart_alarm_triggered",
                details: "{\"stage\":\"\(currentSleepStage.rawValue)\",\"time\":\"\(minuteOfDay / 60):\(String(format: "%02d", minuteOfDay % 60))\"}",
                tags: ["smart-alarm", "triggered"]
            )
        }

        // Safety net — end of window. (Already-awake case returned above, so
        // this only fires when he's genuinely still down by HR.)
        if minuteOfDay >= alarmWindowEnd - 1 {
            alarmFiredToday = true
            persistAlarmFired()
            alarmLastFireDate = now
            DispatchQueue.main.async {
                self.smartAlarmTriggered = true
            }
            sleepStageCallback?(currentSleepStage)
            print("[SmartAlarm] SAFETY NET — end of window, forcing alarm")
            debugSupabase?.pushDebugLog(
                event: "smart_alarm_safety_net",
                details: "{\"stage\":\"\(currentSleepStage.rawValue)\"}",
                tags: ["smart-alarm", "safety-net"]
            )
        }
    }

    func resetAlarmForNewDay() {
        alarmFiredToday = false
        smartAlarmTriggered = false
    }

    // MARK: - Sleep Session Tracking

    /// Call when sleep is first detected
    func markSleepStart() {
        // Defense in depth: also reset if the stored sleepStartTime is older
        // than 18h. Cold-start restore was removed in HealthEngine but if any
        // future code path reintroduces stale state, this catches it.
        let isStale = sleepStartTime.map { Date().timeIntervalSince($0) > 18 * 3600 } ?? false
        if sleepStartTime == nil || isStale {
            if isStale {
                print("[Health] markSleepStart: discarding stale sleepStartTime (\(sleepStartTime!))")
            }
            sleepStartTime = Date()
            sleepEndTime = nil
            lastStageChangeTime = Date()
            stageMinutes = [.awake: 0, .light: 0, .deep: 0, .rem: 0]
            stageTransitionCount = 0
            sleepingMinHR = 0  // reset so this night's minimum is tracked fresh
        }
    }

    /// Call when wake-up is confirmed
    func markSleepEnd() {
        sleepEndTime = Date()
        computeSleepScore()
    }

    /// v98 — User manually tapped "I'm awake". Forces wake-up regardless of
    /// detector state. Writes sleep_end, locks sleep state until tonight 9pm so
    /// the engine doesn't immediately re-detect sleep. Used as a safety net
    /// when the auto-detector misses (chronic-low HR users whose awake-low-
    /// activity HR overlaps with REM/light sleep HR).
    ///
    /// v100 (architecture migration): Recovery + sleep score are NO LONGER
    /// computed on-device. We call the Postgres RPC recompute_health_metrics
    /// which reads realtime_health and runs the authoritative algorithm
    /// server-side. The returned values overwrite local @Published vars so the
    /// UI reflects server truth. Eliminates the cache-overwrite race that kept
    /// recovery stuck at stale values for weeks.
    func manualWakeUp() {
        // Only meaningful while sleep is currently detected. Otherwise no-op.
        guard sleepDetected || sleepStartTime != nil else {
            print("[ManualWake] No sleep session active — ignored")
            return
        }
        print("[ManualWake] User tapped I'm awake — forcing wake-up")

        // Local: just stamp the wake time. Sleep-stage minute counts in memory
        // are now ground-truth ONLY for the live UI; the persisted daily
        // numbers come from pg_recompute.
        sleepEndTime = Date()

        // Server-side authoritative recompute. Fire-and-forget — UI updates
        // when the RPC returns. If offline, pg_cron at 05:00 UTC tomorrow
        // will compute today's metrics during its run.
        Task { [weak self] in
            guard let self = self else { return }
            if let result = await self.debugSupabase?.recomputeHealthMetrics() {
                await MainActor.run {
                    self.applyServerRecompute(result)
                }
                print("[ManualWake] Server recompute → recovery=\(Int(result.recovery)) sleepScore=\(Int(result.sleepScore)) sleepHours=\(result.sleepHours)")
            } else {
                print("[ManualWake] Server recompute failed — keeping local in-memory values")
            }
        }

        // Match the auto-wake morning lock: prevent re-detection until 9pm.
        var cal = Calendar.current
        cal.timeZone = .current
        if let tonight9pm = cal.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) {
            wakeUpLockUntil = tonight9pm
        }

        DispatchQueue.main.async {
            self.sleepDetected = false
            self.currentSleepStage = .awake
            self.sustainedLowHRMinutes = 0
            self.sustainedHighHRMinutes = 0
            self.sustainedMovementMinutes = 0
            self.wakeUpNotified = true
            self.lastWakeUpNotification = Date()
        }

        debugSupabase?.pushDebugLog(
            event: "manual_wake_up",
            details: "{\"trigger\":\"user_tap\",\"backend\":\"pg_recompute\"}",
            tags: ["sleep-staging", "manual", "v100-arch-migration"]
        )
    }

    private var stageMinutesKey: String { "lucid_stage_minutes_v1" }
    private var stageMinutesDateKey: String { "lucid_stage_minutes_date" }

    /// Persist stageMinutes to UserDefaults so they survive a force-quit during sleep.
    func saveStageMinutes() {
        let dict: [String: Double] = [
            "awake": stageMinutes[.awake] ?? 0,
            "light": stageMinutes[.light] ?? 0,
            "deep":  stageMinutes[.deep]  ?? 0,
            "rem":   stageMinutes[.rem]   ?? 0
        ]
        UserDefaults.standard.set(dict, forKey: stageMinutesKey)
        UserDefaults.standard.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970,
                                  forKey: stageMinutesDateKey)
    }

    /// Restore stageMinutes from UserDefaults if they were saved today.
    func restoreStageMinutesIfNeeded() {
        guard let savedEpoch = UserDefaults.standard.object(forKey: stageMinutesDateKey) as? Double else { return }
        let savedDay = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: savedEpoch))
        guard savedDay == Calendar.current.startOfDay(for: Date()) else { return }
        guard let dict = UserDefaults.standard.dictionary(forKey: stageMinutesKey) as? [String: Double] else { return }
        stageMinutes[.awake] = dict["awake"] ?? 0
        stageMinutes[.light] = dict["light"] ?? 0
        stageMinutes[.deep]  = dict["deep"]  ?? 0
        stageMinutes[.rem]   = dict["rem"]   ?? 0
        print("[Health] Restored stageMinutes from UserDefaults: D=\(Int(dict["deep"] ?? 0))m R=\(Int(dict["rem"] ?? 0))m L=\(Int(dict["light"] ?? 0))m")
    }

    /// Track time in each stage + count transitions for fragmentation index
    func trackStageChange(from: SleepStage, to: SleepStage) {
        if let lastChange = lastStageChangeTime {
            let minutes = Date().timeIntervalSince(lastChange) / 60.0
            stageMinutes[from, default: 0] += minutes
        }
        lastStageChangeTime = Date()
        previousStageForTracking = to
        stageTransitionCount += 1
        saveStageMinutes()  // Persist after each stage change — survives force-quit
    }

    // MARK: - Sleep Score (0–100)
    // Components: duration (35%), efficiency (25%), stage balance (20%), consistency (20%)

    func computeSleepScore() {
        guard let start = sleepStartTime, let end = sleepEndTime else { return }

        // Flush last stage duration
        if let lastChange = lastStageChangeTime {
            let minutes = end.timeIntervalSince(lastChange) / 60.0
            stageMinutes[previousStageForTracking, default: 0] += minutes
        }

        let totalMinutes = end.timeIntervalSince(start) / 60.0
        let asleepMinutes = (stageMinutes[.light] ?? 0) + (stageMinutes[.deep] ?? 0) + (stageMinutes[.rem] ?? 0)
        let durationHours = asleepMinutes / 60.0

        // 1. Duration score (35%) — optimal 7-9 hours
        let durationScore: Double
        if durationHours >= 7 && durationHours <= 9 {
            durationScore = 100
        } else if durationHours >= 6 {
            durationScore = 70 + (durationHours - 6) * 30
        } else if durationHours >= 5 {
            durationScore = 40 + (durationHours - 5) * 30
        } else {
            durationScore = max(durationHours / 5.0 * 40, 0)
        }

        // 2. Efficiency score (25%)
        let efficiency = totalMinutes > 0 ? (asleepMinutes / totalMinutes) * 100 : 0
        let efficiencyScore: Double
        if efficiency >= 90 {
            efficiencyScore = 100
        } else if efficiency >= 80 {
            efficiencyScore = 70 + (efficiency - 80) * 3
        } else {
            efficiencyScore = max(efficiency / 80.0 * 70, 0)
        }

        // 3. Stage balance (20%) — from 467 nights: deep mean 23.4%, REM mean 26.2%
        let deepPct = asleepMinutes > 0 ? (stageMinutes[.deep] ?? 0) / asleepMinutes * 100 : 0
        let remPct = asleepMinutes > 0 ? (stageMinutes[.rem] ?? 0) / asleepMinutes * 100 : 0
        let deepScore = deepPct >= 18 && deepPct <= 30 ? 100.0 : max(0, 100 - abs(deepPct - 23) * 5)
        let remScore = remPct >= 20 && remPct <= 32 ? 100.0 : max(0, 100 - abs(remPct - 26) * 5)
        let stageScore = (deepScore + remScore) / 2.0

        // 4. Consistency (20%)
        let consistencyScore = sleepConsistencyScore

        let score = durationScore * calibration.sleepDurationWeight
                  + efficiencyScore * calibration.sleepEfficiencyWeight
                  + stageScore * calibration.sleepStageWeight
                  + consistencyScore * calibration.sleepConsistencyWeight

        // Sleep Fragmentation Index — transitions per hour of sleep
        let fragIndex = durationHours > 0 ? Double(stageTransitionCount) / durationHours : 0

        // v115 — server is authoritative for the persisted daily numbers.
        // recompute_health_metrics (server) + HealthEngine's restore own
        // duration / score / efficiency / stage-minutes. computeSleepScore's
        // on-device values are built on the live stage accumulator, which
        // latches on chronic-low-HR nights and wrote a 1.1h clobber over the
        // server's correct 6.8h on Jul 14. Publish ONLY the fragmentation index
        // (no server equivalent); everything else stays server-owned.
        print("[SleepScore] on-device estimate (NOT published, server wins): score=\(Int(min(score, 100))) dur=\(String(format: "%.1f", durationHours))h eff=\(Int(efficiency))")
        DispatchQueue.main.async {
            self.sleepFragmentationIndex = round(fragIndex * 10) / 10
        }

        // Reset for next night — sleep cycle is fully scored, all per-cycle
        // accumulators must zero out so tomorrow's stage minutes don't pile
        // on top of tonight's. Bug fix: previously stageMinutes leaked,
        // producing 12h+ "deep sleep" totals after a few nights.
        sleepStartTime = nil
        sleepEndTime = nil
        stageMinutes = [.awake: 0, .light: 0, .deep: 0, .rem: 0]
        stageTransitionCount = 0
        lastStageChangeTime = nil
        // Wipe persisted UserDefaults too so a subsequent
        // restoreStageMinutesIfNeeded() won't re-hydrate stale values
        UserDefaults.standard.removeObject(forKey: stageMinutesKey)
        UserDefaults.standard.removeObject(forKey: stageMinutesDateKey)
    }

    // MARK: - Gap Sleep Replay

    /// Replay gap history readings through sleep analysis.
    /// Call after history download completes with the distributed readings.
    func replayGapForSleep(readings: [(hr: Int, time: Date)]) {
        guard !readings.isEmpty else { return }

        let sleepThreshold = calibration.sleepThreshold
        // v98 — same floor as the live path. Without this, gap-fill staging would
        // disagree with live staging, producing inconsistent stage minute totals.
        let wakeThreshold = max(calibration.wakeThreshold, baselineRHR + 25)
        let deepCeiling = calibration.deepHRCeiling

        let wasSleepingBeforeGap = sleepDetected || sleepStartTime != nil

        var gapDeepMin: Double = 0
        var gapLightMin: Double = 0
        var gapRemMin: Double = 0
        var gapAwakeMin: Double = 0
        var wakeUpTime: Date?
        var consecutiveAwakeMinutes: Double = 0

        for i in 0..<readings.count {
            let hr = Double(readings[i].hr)
            let time = readings[i].time

            let dt: Double
            if i + 1 < readings.count {
                dt = readings[i + 1].time.timeIntervalSince(time) / 60.0
            } else {
                dt = 10.0 / 60.0
            }

            let windowStart = max(0, i - 5)
            let windowEnd = min(readings.count, i + 5)
            let windowHRs = (windowStart..<windowEnd).map { Double(readings[$0].hr) }
            let avgWindow = windowHRs.reduce(0, +) / Double(windowHRs.count)
            let hrSD = sqrt(windowHRs.map { ($0 - avgWindow) * ($0 - avgWindow) }.reduce(0, +) / Double(windowHRs.count))

            if hr > wakeThreshold {
                gapAwakeMin += dt
                consecutiveAwakeMinutes += dt
                if consecutiveAwakeMinutes >= 10 && wakeUpTime == nil {
                    wakeUpTime = readings[max(0, i - Int(10 * 60 / max(dt * 60, 1)))].time
                }
            } else if hr < deepCeiling && hrSD < 3 {
                gapDeepMin += dt
                consecutiveAwakeMinutes = 0
            } else if hrSD > 3 {
                gapRemMin += dt
                consecutiveAwakeMinutes = 0
            } else if hr < sleepThreshold {
                gapLightMin += dt
                consecutiveAwakeMinutes = 0
            } else {
                gapLightMin += dt
                consecutiveAwakeMinutes = 0
            }
        }

        let gapSleepMin = gapDeepMin + gapLightMin + gapRemMin
        let gapTotalMin = readings.last!.time.timeIntervalSince(readings.first!.time) / 60.0

        print("[GapReplay] \(Int(gapTotalMin)) min gap: deep=\(Int(gapDeepMin))m light=\(Int(gapLightMin))m rem=\(Int(gapRemMin))m awake=\(Int(gapAwakeMin))m")

        guard gapSleepMin > 30 else {
            print("[GapReplay] Not enough sleep in gap (<30 min) — skipping")
            return
        }

        if wasSleepingBeforeGap && sleepStartTime != nil {
            stageMinutes[.deep, default: 0] += gapDeepMin
            stageMinutes[.light, default: 0] += gapLightMin
            stageMinutes[.rem, default: 0] += gapRemMin
            stageMinutes[.awake, default: 0] += gapAwakeMin
            print("[GapReplay] Extended existing sleep session with gap data")
        } else {
            sleepStartTime = readings.first!.time
            stageMinutes = [.deep: gapDeepMin, .light: gapLightMin, .rem: gapRemMin, .awake: gapAwakeMin]
            print("[GapReplay] Created sleep session from gap data starting at \(readings.first!.time)")
        }

        if let wakeTime = wakeUpTime {
            sleepEndTime = wakeTime
            computeSleepScore()
            computeRecovery()
            DispatchQueue.main.async {
                self.sleepDetected = false
                self.sustainedLowHRMinutes = 0
                self.sustainedHighHRMinutes = 0
            }
            print("[GapReplay] Wake-up detected at \(wakeTime) — sleep score computed")
        } else {
            DispatchQueue.main.async {
                self.sleepDetected = true
            }
            print("[GapReplay] Still sleeping at end of gap — waiting for live wake-up")
        }
    }

    // MARK: - Sleep Consistency Score (0–100)

    /// Save bedtime/waketime for consistency tracking
    func saveSleepTiming(bedtime: Date, waketime: Date) {
        var bedtimes = UserDefaults.standard.array(forKey: bedtimeHistoryKey) as? [Double] ?? []
        var waketimes = UserDefaults.standard.array(forKey: waketimeHistoryKey) as? [Double] ?? []

        let cal = Calendar.current
        let bedMin = Double(cal.component(.hour, from: bedtime) * 60 + cal.component(.minute, from: bedtime))
        let wakeMin = Double(cal.component(.hour, from: waketime) * 60 + cal.component(.minute, from: waketime))

        bedtimes.append(bedMin < 720 ? bedMin + 1440 : bedMin)
        waketimes.append(wakeMin)

        if bedtimes.count > 7 { bedtimes.removeFirst(bedtimes.count - 7) }
        if waketimes.count > 7 { waketimes.removeFirst(waketimes.count - 7) }

        UserDefaults.standard.set(bedtimes, forKey: bedtimeHistoryKey)
        UserDefaults.standard.set(waketimes, forKey: waketimeHistoryKey)

        computeSleepConsistency()
    }

    func computeSleepConsistency() {
        let bedtimes = UserDefaults.standard.array(forKey: bedtimeHistoryKey) as? [Double] ?? []
        let waketimes = UserDefaults.standard.array(forKey: waketimeHistoryKey) as? [Double] ?? []

        guard bedtimes.count >= 3, waketimes.count >= 3 else {
            DispatchQueue.main.async { self.sleepConsistencyScore = 50 }
            return
        }

        func sd(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            return sqrt(variance)
        }

        let bedSD = sd(bedtimes)
        let wakeSD = sd(waketimes)
        let avgSD = (bedSD + wakeSD) / 2.0

        let score = max(0, min(100, 100 - (avgSD - 15) * (100.0 / 75.0)))
        DispatchQueue.main.async { self.sleepConsistencyScore = round(score) }
    }

    // MARK: - Sleep User Corrections

    /// Dismiss current sleep detection — user says "I'm not sleeping"
    func dismissSleepDetection() {
        let hr = recentHR.isEmpty ? 0 : recentHR.suffix(10).reduce(0, +) / Double(min(recentHR.count, 10))

        DetectionFeedback.shared.recordCorrection(
            detected: "sleep_\(currentSleepStage.rawValue.lowercased())",
            corrected: nil,
            hr: hr,
            hrv: currentRMSSD
        )

        currentSleepStage = .awake
        sleepDetected = false
        sustainedLowHRMinutes = 0
        sustainedHighHRMinutes = 5
    }

    /// Override sleep stage to a specific stage
    func overrideSleepStage(_ stage: SleepStage) {
        let oldStage = currentSleepStage
        currentSleepStage = stage

        DetectionFeedback.shared.recordCorrection(
            detected: "sleep_\(oldStage.rawValue.lowercased())",
            corrected: "sleep_\(stage.rawValue.lowercased())",
            hr: recentHR.isEmpty ? 0 : recentHR.suffix(10).reduce(0, +) / Double(min(recentHR.count, 10)),
            hrv: currentRMSSD
        )

        if stage != .awake {
            sleepDetected = true
        }
    }

    /// Send push notification when sleep is first detected (max once per 2 hours)
    func sendSleepNotification(stage: SleepStage) {
        if let last = lastSleepNotification, Date().timeIntervalSince(last) < 7200 {
            return
        }
        lastSleepNotification = Date()

        let content = UNMutableNotificationContent()
        content.title = "😴 Sleep Detected"
        content.body = "Stage: \(stage.rawValue). Not sleeping? Open Lucid Bridge to dismiss."
        content.sound = .default
        content.categoryIdentifier = "SLEEP_DETECTION"

        let request = UNNotificationRequest(
            identifier: "sleep-detect-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - IMU / Movement Data

    /// Feed IMU reading for movement-enhanced sleep staging
    func addIMUReading(accelMagnitude: Double, gyroMagnitude: Double) {
        recentAccel.append(accelMagnitude)
        recentGyro.append(gyroMagnitude)
        if recentAccel.count > 30 { recentAccel.removeFirst() }
        if recentGyro.count > 30 { recentGyro.removeFirst() }

        guard recentAccel.count >= 10 else { return }
        let mean = recentAccel.reduce(0, +) / Double(recentAccel.count)
        let variance = recentAccel.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(recentAccel.count)
        let sd = sqrt(variance)

        DispatchQueue.main.async {
            self.movementScore = sd
        }
    }

    // MARK: - Wake-Up Callbacks

    func onWakeUpDetected(_ callback: @escaping () -> Void) {
        wakeUpCallback = callback
    }

    func onSmartAlarmTrigger(_ callback: @escaping (SleepStage) -> Void) {
        sleepStageCallback = callback
    }

    /// Register a callback fired 20-25 min before the wake window.
    /// A single gentle haptic pulse to briefly arouse → re-enter N1/N2 →
    /// virtually guarantees a clean light-sleep detection window at wake time.
    func onPreAlarmMicroPing(_ callback: @escaping () -> Void) {
        preAlarmMicroPingCallback = callback
    }

    // MARK: - RMSSD Slope Gate (wake-readiness signal)
    // Research: rising RMSSD direction = N3→N2→N1 transition, AUC 0.85.
    // Use 3-5 min EMA of 10s RMSSD samples, then slope across 3 consecutive windows.

    /// Feed a fresh RMSSD reading and update the slope-detection state.
    /// Called from HRVEngine.computeRMSSD on every RMSSD update.
    func feedRmssdForSlope(_ rmssd: Double) {
        guard rmssd > 0 else { return }
        let now = Date()

        // Store raw sample, trim to last 20 minutes (covers 3 EMAs + headroom)
        rmssdSamples.append((time: now, value: rmssd))
        rmssdSamples.removeAll { now.timeIntervalSince($0.time) > 20 * 60 }

        // Every 5 minutes, compute an EMA of the last 5-min window and append to the ring.
        let needsEma = lastRmssdEmaTime == nil ||
            now.timeIntervalSince(lastRmssdEmaTime!) >= 5 * 60
        if needsEma {
            let windowStart = now.addingTimeInterval(-5 * 60)
            let windowSamples = rmssdSamples
                .filter { $0.time >= windowStart }
                .map { $0.value }
            if windowSamples.count >= 3 {
                // Simple EMA: alpha = 2/(N+1) where N = sample count
                let alpha = 2.0 / (Double(windowSamples.count) + 1.0)
                var ema = windowSamples[0]
                for v in windowSamples.dropFirst() { ema = alpha * v + (1 - alpha) * ema }
                rmssdEmaWindow.append(ema)
                if rmssdEmaWindow.count > 3 { rmssdEmaWindow.removeFirst() }
                lastRmssdEmaTime = now
            }
        }
    }

    /// True when RMSSD EMA has been rising across the last 3 windows (15 min).
    /// Strongest single wake-readiness signal in the research.
    var isRmssdTrendingUp: Bool {
        guard rmssdEmaWindow.count >= 3 else { return false }
        let a = rmssdEmaWindow[0]
        let b = rmssdEmaWindow[1]
        let c = rmssdEmaWindow[2]
        // Require monotonic rise OR net rise of >10% over the 15-min span
        return (b > a && c > b) || (a > 0 && (c - a) / a > 0.10)
    }
}
