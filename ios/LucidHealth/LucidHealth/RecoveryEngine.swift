import Foundation

// ════════════════════════════════════════════════════════════
// Recovery Engine — Recovery, Strain, Body Battery, Training Load
// Extension on HealthEngine for recovery-related scoring
//
// Research basis (rewritten 2026-05-03 to match published wearables):
//   - Recovery: MORNING-LOCKED snapshot. Computed once at markSleepEnd() from
//     sleep-window HRV (last hour of sleep) + sleepingMinHR + sleep score +
//     prior strain. Whoop's docs: "Recovery does not change over the day."
//     Buchheit 2014 + Plews 2013: daytime HRV is contaminated by task-state
//     (driving, work, walking suppress HRV by sympathetic activation), so it
//     CANNOT drive a recovery score. Weights: HRV 40%, RHR 25%, Sleep 25%,
//     Strain modifier -10%.
//   - Strain: cumulative HR zone-weighted load (Whoop model, 0–21 scale).
//     Continuous, resets at midnight.
//   - Body Battery: Firstbeat-style. Seeded at wake from recovery (NOT 100),
//     drains by HR-zone, recharges in sleep + parasympathetic rest.
//   - Training Load: ACWR (Gabbett 2016, IOC endorsed) + Foster Monotony
// ════════════════════════════════════════════════════════════

extension HealthEngine {

    // MARK: - Recovery Score (0–100, MORNING-LOCKED)

    /// Morning recovery hook.
    /// v102 (2026-05-13) — recovery_score is now computed SERVER-SIDE via
    /// Supabase pg function `compute_recovery_score` (personal-percentile
    /// formula). This function no longer computes a local score. Instead it:
    ///   1. Triggers the server recompute RPC for today
    ///   2. Lets the existing scoresResult fetch in HealthEngine.fetchBaseline
    ///      pick up the fresh value
    ///   3. Locks the day so we don't refetch on every wake-up event
    ///   4. Seeds Body Battery from whatever recovery value is now present
    ///
    /// Local debug contributions (HRV/RHR/Sleep) are still computed for the
    /// stats overlay but are no longer authoritative.
    func computeRecovery() {
        let today = Calendar.current.startOfDay(for: Date())
        if let locked = recoveryLockedDate, Calendar.current.isDate(locked, inSameDayAs: today) {
            return
        }

        // Debug-only HRV component for stats overlay
        let sleepHRV = medianSleepRMSSD()
        let hrvForCompute = sleepHRV > 0 ? sleepHRV : currentRMSSD
        let hrvBaseline = baselineRMSSD.isEmpty ? baselineHRV : (baselineRMSSD.reduce(0, +) / Double(baselineRMSSD.count))
        let hrvSD = baselineRMSSD.count >= 3 ? standardDev(baselineRMSSD) : max(hrvBaseline * 0.15, 5)
        let hrvZ = hrvSD > 0 && hrvForCompute > 0 ? (hrvForCompute - hrvBaseline) / hrvSD : 0
        let hrvComponent = hrvForCompute > 0 ? sigmoid(hrvZ) * 100 * 0.40 : 0

        let restingHRForCompute: Double
        if sleepingMinHR > 0 {
            restingHRForCompute = sleepingMinHR
        } else if !recentHR.isEmpty {
            let sorted = recentHR.suffix(30).sorted()
            restingHRForCompute = sorted[sorted.count / 2]
        } else {
            restingHRForCompute = baselineRHR
        }
        let rhrSD = max((calibration.p95RHR - calibration.p5RHR) / 4, 3)
        let rhrZ = rhrSD > 0 ? (calibration.medianRHR - restingHRForCompute) / rhrSD : 0
        let rhrComponent = sigmoid(rhrZ) * 100 * 0.25

        let sleepComponent = (sleepScore > 0 ? sleepScore : 50) * 0.25

        DispatchQueue.main.async {
            // Stats overlay debug values only — NOT the score
            self.recoveryHRVContribution = round(hrvComponent * 10) / 10
            self.recoveryRHRContribution = round(rhrComponent * 10) / 10
            self.recoverySleepContribution = round(sleepComponent * 10) / 10
            self.recoveryRRContribution = 0

            // The day is locked further down, only once the server recompute has
            // actually returned a value. Locking here meant a NULL result (called
            // mid-night, before a sleep window exists) silently kept yesterday's
            // number and froze it in place for the rest of the day, turning
            // computeRecoveryFallbackIfNeeded into a no-op.

            // v121: Body Battery is NO LONGER seeded from recovery here — recovery
            // is the memoryless source we moved away from. The tank now comes
            // from the server reservoir anchor (fetched in the Task below + by
            // fetchBaseline's body_battery column read). Nothing to seed locally.

            self.sleepPeriodRMSSDSamples.removeAll()
        }

        // Trigger server recompute. Fresh value lands back via the @Published
        // recoveryScore update inside recomputeHealthMetrics's return + the
        // call sites that wire result.recovery into healthEngine.recoveryScore
        // (BLEManager.swift:419 and TodayView.swift:200).
        Task { [weak self] in
            guard self != nil else { return }
            let result = await SupabaseClient.shared.recomputeHealthMetrics()
            await MainActor.run {
                guard let self else { return }
                guard let result else {
                    print("[Recovery] server recompute returned no window — day stays unlocked")
                    return
                }
                self.applyServerRecompute(result)
                print("[Recovery] v102 server recompute landed: \(Int(result.recovery))")
                // Lock the day only now that a real server value has landed.
                self.recoveryLockedDate = today
                UserDefaults.standard.set(today, forKey: self.recoveryLockedDateKey)
            }
            // Body Battery v2 — seed the live battery from the carry-over reservoir
            // anchor (server), NOT memoryless recovery. The live engine
            // (updateBodyBattery) drains this through the day. This is the fix for
            // "92% recovery but I feel like shit" — the tank remembers, recovery doesn't.
            let anchor = await SupabaseClient.shared.fetchBodyBatteryAnchor()
            await MainActor.run {
                guard let self else { return }
                if let a = anchor {
                    self.bodyBattery = min(max(a, 5), 100)
                    self.saveBodyBattery()
                    print("[BodyBattery] seeded from reservoir anchor: \(Int(a))")
                }
            }
        }
    }

    /// Median of sleep-window RMSSD samples. Whoop uses last-SWS HRV; we use
    /// the last hour of sleep (last 60 samples at 1/min). Median is more
    /// robust than mean to artifacts at sleep onset / brief arousals.
    private func medianSleepRMSSD() -> Double {
        let samples = sleepPeriodRMSSDSamples.suffix(60)
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    /// Fallback: if wake-up never fires by 14:00 local, compute recovery
    /// once from whatever data we have so the user doesn't see a stale value
    /// all afternoon. Only fires once per day.
    func computeRecoveryFallbackIfNeeded() {
        guard !fallbackRecoveryFired else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if let locked = recoveryLockedDate, Calendar.current.isDate(locked, inSameDayAs: today) {
            return
        }
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 14 else { return }
        fallbackRecoveryFired = true
        print("[Recovery] Fallback compute (wake-up never detected) — using available data")
        computeRecovery()
    }

    // MARK: - Strain Score (0–21)

    /// Classify HR into zone (0-4)
    func hrZone(for hr: Double) -> Int {
        let thresholds = zoneThresholds
        if hr < thresholds[0] { return 0 }
        if hr < thresholds[1] { return 1 }
        if hr < thresholds[2] { return 2 }
        if hr < thresholds[3] { return 3 }
        return 4
    }

    /// Feed HR reading for strain computation — call every ~10s
    func updateStrain(hr: Int) {
        // Reset daily
        let today = Calendar.current.startOfDay(for: Date())
        if lastStrainReset == nil || !Calendar.current.isDate(lastStrainReset!, inSameDayAs: today) {
            strainAccumulator = 0
            zoneMinutes = [0, 0, 0, 0, 0]
            hrZoneReadingCount = 0
            lastStrainReset = today
            DispatchQueue.main.async { self.edwardsTRIMP = 0 }
        }

        let zone = hrZone(for: Double(hr))
        hrZoneReadingCount += 1

        // Each reading ≈ 10 seconds. 6 readings = 1 minute.
        if hrZoneReadingCount % 6 == 0 {
            DispatchQueue.main.async {
                if zone < self.zoneMinutes.count {
                    self.zoneMinutes[zone] += 1
                }
                self.edwardsTRIMP = self.computeEdwardsTRIMP()
            }
        }

        // Strain contribution per reading (weighted by zone intensity)
        let zoneWeights = calibration.strainZoneWeights
        strainAccumulator += zoneWeights[min(zone, 4)]

        let strain = min(strainAccumulator, 21.0)

        DispatchQueue.main.async {
            self.strainScore = round(strain * 10) / 10
            self.currentHRZone = zone
        }
    }

    /// Edwards TRIMP — weighted training load (P4, openwhoop community pattern)
    func computeEdwardsTRIMP() -> Double {
        guard zoneMinutes.count == 5 else { return 0 }
        let weights = [1.0, 2.0, 3.0, 4.0, 5.0]
        var total: Double = 0
        for i in 0..<5 { total += Double(zoneMinutes[i]) * weights[i] }
        return round(total)
    }

    /// Zone name for display
    static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 0: return "Rest"
        case 1: return "Fat Burn"
        case 2: return "Cardio"
        case 3: return "Peak"
        case 4: return "Max"
        default: return "—"
        }
    }

    static func zoneColor(_ zone: Int) -> String {
        switch zone {
        case 0: return "gray"
        case 1: return "blue"
        case 2: return "green"
        case 3: return "orange"
        case 4: return "red"
        default: return "gray"
        }
    }

    // MARK: - Body Battery (Real-time energy 0–100, Firstbeat-style)
    // Wake-up value seeded from recovery in computeRecovery() — does NOT reset
    // to 100 daily. Drains by HR-zone, recharges in sleep + parasympathetic rest.
    // VO2max modifier reduces drain rate for fitter users (Firstbeat doc).

    /// Update body battery — DISABLED (v121). Body Battery is now 100%
    /// server-authoritative: the carry-over reservoir anchor (v118) minus a
    /// server-side intraday drain (v119), refreshed every 15 min. The old
    /// on-device engine RECHARGED during waking rest (sitting tired read as
    /// "recovering"), drifted up to ~90, and overwrote the correct server value
    /// in the DB. No-op now — the app only fetches + displays. Tune the model
    /// server-side; do NOT reintroduce on-device drain/recharge here.
    func updateBodyBattery(hr: Int) {
        return
    }

    // MARK: - Training Load Intelligence
    // ACWR (Gabbett 2016, IOC endorsed) + Foster Monotony/Strain (1998)

    func updateTrainingLoad() {
        var dailyStrain = UserDefaults.standard.array(forKey: dailyStrainKey) as? [Double] ?? []
        dailyStrain.append(strainScore)
        if dailyStrain.count > 28 { dailyStrain.removeFirst(dailyStrain.count - 28) }
        UserDefaults.standard.set(dailyStrain, forKey: dailyStrainKey)

        guard dailyStrain.count >= 7 else { return }

        // ACWR: 7-day acute load / 28-day chronic weekly average
        let last7 = Array(dailyStrain.suffix(7))
        let acuteLoad = last7.reduce(0, +)
        let chronicWeeklyAvg = dailyStrain.reduce(0, +) / (Double(dailyStrain.count) / 7.0)
        let acwr = chronicWeeklyAvg > 0 ? acuteLoad / chronicWeeklyAvg : 1.0

        // Foster Training Monotony & Strain (1998)
        let mean7 = acuteLoad / 7.0
        let variance7 = last7.map { ($0 - mean7) * ($0 - mean7) }.reduce(0, +) / 7.0
        let sd7 = sqrt(variance7)
        let monotony = sd7 > 0.01 ? mean7 / sd7 : 0
        let fosterStrain = acuteLoad * monotony

        DispatchQueue.main.async {
            self.trainingLoadRatio = round(acwr * 100) / 100
            self.trainingMonotony = round(monotony * 100) / 100
            self.trainingStrain = round(fosterStrain * 10) / 10

            // ACWR thresholds calibrated 2026-04-21, 634 days, P90=1.27, results/training_load_v1.json
            if acwr > 1.3 {
                self.trainingLoadStatus = "Overreaching"
            } else if acwr > 1.1 {
                self.trainingLoadStatus = "High"
            } else if acwr >= 0.8 {
                self.trainingLoadStatus = "Optimal"
            } else {
                self.trainingLoadStatus = "Detraining"
            }

            // Monotony cutoff calibrated 2026-04-21, P90=2.87, results/training_load_v1.json
            if monotony > 2.87 && self.trainingLoadStatus == "Optimal" {
                self.trainingLoadStatus = "Monotonous"
            }
        }
    }

    // MARK: - Nocturnal HR Dip % (Finding 2.1)
    // Dip% = (daytimeHR - sleepHR) / daytimeHR × 100
    // <10% = "non-dipper" — 2.4x cardiovascular event risk (Hermida 2013)

    /// Feed awake HR readings (non-exercise) for daytime baseline
    func addDaytimeHRReading(_ hr: Double) {
        guard hr > 40 && hr < 150 else { return } // filter exercise/artifacts
        daytimeHRReadings.append(hr)
        if daytimeHRReadings.count > 360 { // ~1 hour at 10s intervals
            daytimeHRReadings.removeFirst()
        }
    }

    /// Compute nocturnal dip after sleep ends
    func computeNocturnalDip() {
        guard !daytimeHRReadings.isEmpty else { return }

        let daytimeAvg = daytimeHRReadings.reduce(0, +) / Double(daytimeHRReadings.count)

        // The night HR must come from inside the sleep window. recentHR is the live
        // rolling buffer, and this runs from the wake callback when he is already up,
        // so the "sleep" average came out ABOVE the daytime average and the dip went
        // negative (-33.6 and -41.6 are both stored in the DB), which badged him a
        // permanent Non-Dipper. sleepingMinHR is reset per night and is already what
        // computeRecovery uses as the resting marker.
        guard sleepingMinHR > 0, daytimeAvg > 0 else { return }
        let dip = ((daytimeAvg - sleepingMinHR) / daytimeAvg) * 100

        // A negative dip is not a physiological finding, it is missing data. Keep
        // the previous value rather than writing a number that cannot be true.
        guard dip >= 0 else { return }

        DispatchQueue.main.async {
            self.nocturnalHRDip = round(dip * 10) / 10
            self.nocturnalDipStatus = dip >= 10 ? "Normal" : "Non-Dipper"
        }
    }

    // MARK: - Heart Rate Recovery (Finding 3.1)
    // HRR₁ ≤ 12 bpm = abnormal, predicts all-cause mortality (Cole 1999 NEJM)

    /// Call when exercise ends — captures peak HR for HRR computation
    func markExerciseEnd(peakHR: Int) {
        exerciseEndHR = peakHR
        exerciseEndTime = Date()
    }

    /// Call 60s after exercise end with current HR
    func computeHRR1(currentHR: Int) {
        guard exerciseEndHR > 0 else { return }
        let hrr1 = exerciseEndHR - currentHR

        DispatchQueue.main.async {
            self.lastHRR1 = hrr1
            if hrr1 >= 25 { self.hrrStatus = "Excellent" }
            else if hrr1 >= 15 { self.hrrStatus = "Good" }
            else if hrr1 >= 12 { self.hrrStatus = "Fair" }
            else { self.hrrStatus = "Impaired" }
        }
    }

    /// Call 120s after exercise end with current HR
    func computeHRR2(currentHR: Int) {
        guard exerciseEndHR > 0 else { return }
        DispatchQueue.main.async {
            self.lastHRR2 = self.exerciseEndHR - currentHR
        }
    }

    // MARK: - VO2max Estimate (Finding 3.2)
    // Uth-Sørensen 2004: VO₂max ≈ (HRmax / HRrest) × 15.3 mL/kg/min

    func computeVO2max() {
        guard historicalMaxHR > 100 else { return } // need real measured max
        let rhr7d = baselineRHR > 0 ? baselineRHR : 60
        guard rhr7d > 30 else { return }

        let vo2 = (historicalMaxHR / rhr7d) * 15.3

        DispatchQueue.main.async {
            self.vo2maxEstimate = round(vo2 * 10) / 10
        }
    }

    /// Update historical max HR from exercise session
    func updateMaxHR(sessionMaxHR: Int) {
        if Double(sessionMaxHR) > historicalMaxHR {
            historicalMaxHR = Double(sessionMaxHR)
            UserDefaults.standard.set(historicalMaxHR, forKey: "lucid_historical_max_hr")
            computeVO2max()
        }
    }

    // MARK: - Overtraining Risk Flag (Finding 5.5)
    // RMSSD declining >10% below 7-day baseline for 3+ consecutive days

    private var lowHRVStreakKey: String { "lucid_consecutive_low_hrv_days" }
    private var lowHRVStreakDateKey: String { "lucid_low_hrv_streak_date" }

    /// Restore consecutiveLowHRVDays from UserDefaults.
    /// Only valid if the streak was updated within the last 2 days (skips stale data).
    func restoreConsecutiveLowHRVDays() {
        guard let epoch = UserDefaults.standard.object(forKey: lowHRVStreakDateKey) as? Double else { return }
        let savedDay = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: epoch))
        let today = Calendar.current.startOfDay(for: Date())
        let daysDiff = Calendar.current.dateComponents([.day], from: savedDay, to: today).day ?? 99
        guard daysDiff <= 2 else {
            // Streak is stale — a long gap means it should have reset
            UserDefaults.standard.removeObject(forKey: lowHRVStreakKey)
            UserDefaults.standard.removeObject(forKey: lowHRVStreakDateKey)
            return
        }
        consecutiveLowHRVDays = UserDefaults.standard.integer(forKey: lowHRVStreakKey)
        print("[Health] Restored consecutiveLowHRVDays: \(consecutiveLowHRVDays)")
    }

    func checkOvertrainingRisk() {
        guard !baselineRMSSD.isEmpty else { return }
        let baseline = baselineRMSSD.reduce(0, +) / Double(baselineRMSSD.count)
        let baselineSD = standardDev(baselineRMSSD)
        let threshold = baseline - 1.5 * baselineSD

        if currentRMSSD > 0 && currentRMSSD < threshold {
            consecutiveLowHRVDays += 1
        } else {
            consecutiveLowHRVDays = 0
        }

        // Persist streak so it survives cold starts and reinstalls
        UserDefaults.standard.set(consecutiveLowHRVDays, forKey: lowHRVStreakKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lowHRVStreakDateKey)

        DispatchQueue.main.async {
            if self.consecutiveLowHRVDays >= 5 {
                self.overtrainingRisk = "High Risk"
            } else if self.consecutiveLowHRVDays >= 3 {
                self.overtrainingRisk = "Warning"
            } else {
                self.overtrainingRisk = "None"
            }
        }
    }

    // MARK: - Sleep Debt (Finding 2.4)
    // Rolling 14-day cumulative deficit from personal optimal (P75 = 7.8h)

    func computeSleepDebt() {
        var dailySleep = UserDefaults.standard.array(forKey: sleepDebtKey) as? [Double] ?? []
        let todaySleep = sleepDurationHours > 0 ? sleepDurationHours : runningSleepHours
        if todaySleep > 0 {
            dailySleep.append(todaySleep)
            if dailySleep.count > 14 { dailySleep.removeFirst(dailySleep.count - 14) }
            UserDefaults.standard.set(dailySleep, forKey: sleepDebtKey)
        }

        guard !dailySleep.isEmpty else { return }

        let debt = dailySleep.reduce(0) { $0 + max(0, optimalSleepHours - $1) }

        DispatchQueue.main.async {
            self.sleepDebtHours = round(debt * 10) / 10
        }
    }
}
