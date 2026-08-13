import Foundation
import UIKit

/// Combined health + food Supabase client for LucidHealth.
/// Merges LucidBridge full client with LucidFoods food methods.
/// No dependencies — just URLSession.

/// Tonight's smart-alarm plan, decoded from the server `plan_tonight_auto` RPC.
/// `mode` is "alcohol" (recovery override — no early wake) or "normal".
/// Window minutes are local minutes-of-day (e.g. 540 = 09:00).
struct TonightPlan {
    let mode: String
    let note: String
    let windowStartMinutes: Int   // when smart-wake starts watching
    let windowEndMinutes: Int     // hard backstop
    let hrFloor: Double?          // alcohol nights: elevated sleeping-HR floor
    let targetSleepH: Double?
    var isAlcohol: Bool { mode == "alcohol" }
}

/// Verdict from the server `plan_back_to_sleep` RPC — the in-window "should I
/// go back to sleep or just get up?" coach. Computed from his personalized
/// sleep target + current 7-day sleep debt + a 90-min cycle.
struct BackToSleepPlan {
    let verdict: String        // "go_back" | "get_up"
    let headline: String
    let detail: String
    let wakeAt: Date?          // when to arm a gentle wake, if go_back
    let wakeLabel: String      // "08:27" (Berlin) — for the button label
    let minutesLeft: Int
    let sleptH: Double
    let debtH: Double
    var shouldGoBack: Bool { verdict == "go_back" }
}

/// Server `estimate_meal_from_text` — zero-cost carb/glycemic estimate from a
/// typed meal ("I ate lasagna"), no Gemini, no photo. Relative meal-impact proxy.
struct MealEstimate {
    let netCarbsG: Int
    let kcal: Int
    let glycemicLoad: Int
    let giBand: String        // high | medium | low
    let isAlcohol: Bool
    let confidence: String    // estimate | low | none
    let note: String
    let items: [DetectedItem]
    var recognized: Bool { confidence != "none" }
}

/// Server `sleep_restlessness` — MEASURED HR-spike arousals + autonomic
/// stability (real), plus a labeled-experimental dream estimate.
struct SleepRestlessness {
    let date: String
    let inBedH: Double
    let sleepingHr: Int
    let restlessMin: Int
    let wakeups: Int
    let stability: Int        // 0-10
    let dreamPeriodsEst: Int
    let note: String
}

/// Server `illness_risk_now` — RHR-up + HRV-down vs 30d baseline, alcohol-
/// excluded, 2-night sustain gate. level: clear | watch | elevated | no_data.
struct IllnessRisk {
    let level: String
    let risk: Int
    let note: String
    let rhr: Double?
    let hrv: Double?
    var isSignal: Bool { level == "watch" || level == "elevated" }
}

/// Server `compute_sleep_readiness` (v111) — live Sleep Readiness Index from the
/// last 10 min of strap stream vs personal baselines. The wind-down coach.
/// Server-computed, read-only. sri is HR-gated 0-100.
struct SleepReadiness {
    let sri: Int
    let hrNow: Double
    let hrFloor: Double      // personal sleeping-HR floor
    let hrGap: Double        // hrNow - floor
    let rmssdNow: Double
    let respNow: Double
    let ready: Bool
    let etaMin: Int          // minutes of wind-down still needed
    let status: String       // "ready" | "getting there" | "wired" | "no data"
    let message: String      // plain coaching line
}

/// v154 smart-wake need components — the four drivers that shape tonight's
/// sleep target (each a signed hours delta baked into `target_h`).
struct SmartWakeComponents {
    let debt: Double
    let strain: Double
    let quality: Double
    let circadian: Double
}

/// Result of arming the v154 smart-wake engine (`arm_smart_wake` RPC). The
/// clock only starts when he actually falls asleep; `targetH` is the
/// onset-anchored sleep need, `safetyFloorH` the hard "never wake short" floor.
/// `deadlineBelowFloor` = the requested "up by" is sooner than the floor → the
/// UI must warn him to also set a normal alarm.
struct SmartWakePlan {
    let sessionId: String
    let status: String            // "armed"
    let targetH: Double           // e.g. 8.9
    let baseH: Double
    let safetyFloorH: Double       // e.g. 6.23
    let latestWakeLabel: String?   // "07:30" or nil
    let latestWakeAtISO: String?
    let deadlineBelowFloor: Bool
    let prepMin: Int
    let note: String               // calm-voice explainer
    let needBreakdown: String      // "base 8.00h +0.75 debt … → 8.90h"
    let components: SmartWakeComponents
}

/// Live status of the v154 smart-wake engine (`smart_wake_status` RPC).
/// Idle → armed=false. Armed pre-onset → target + latestWakeLabel only.
/// Armed post-onset → the richer window/onset/earliest/backstop fields.
struct SmartWakeStatus {
    let armed: Bool
    let status: String             // idle | armed | asleep | ready
    let note: String
    let sessionId: String?
    let targetH: Double?
    let strapStreaming: Bool
    let latestWakeLabel: String?
    // post-onset (nil until he falls asleep)
    let onsetLabel: String?        // "23:42"
    let asleepH: Double?           // hours asleep so far
    let earliestWakeLabel: String? // hard floor time "05:48"
    let earliestInMin: Int?        // minutes until the floor (nil once past it)
    let targetWakeLabel: String?   // ideal target time
    let backstopLabel: String?     // humane latest time
    let projectedWindow: String?   // "05:48–08:30"
    let currentStage: String?      // deep | light_rem | no_signal
    let currentDeepProb: Double?
}

class SupabaseClient {

    // Singleton — shared by app + BLEManager + Foods views
    static let shared = SupabaseClient()

    // CI replaces these at build time via sed injection
    static let prefilledEmail: String = "BUILD_EMAIL"
    static let prefilledPassword: String = "BUILD_PASSWORD"

    let baseURL = ProcessInfo.processInfo.environment["LUCID_SUPABASE_URL"] ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "BUILD_SUPABASE_URL"
    let anonKey = ProcessInfo.processInfo.environment["LUCID_SUPABASE_ANON_KEY"] ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? "BUILD_ANON_KEY"
    let userId = ProcessInfo.processInfo.environment["LUCID_USER_ID"] ?? Bundle.main.object(forInfoDictionaryKey: "HERMES_USER_ID") as? String ?? "BUILD_USER_ID"

    internal var accessToken: String?
    private var tokenExpiry: Date?
    private let session = URLSession.shared

    // On-screen logger — set by BLEManager
    var onLog: ((String) -> Void)?

    private func log(_ msg: String) {
        let full = "[SB] \(msg)"
        print(full)
        onLog?(full)
    }

    // Auth credentials — always read fresh from UserDefaults (lucidhealth sandbox)
    private var email: String {
        UserDefaults.standard.string(forKey: "lucidhealth_email") ?? ""
    }
    private var password: String {
        UserDefaults.standard.string(forKey: "lucidhealth_password") ?? ""
    }

    var isAuthenticated: Bool { accessToken != nil && tokenExpiry.map { Date() < $0 } ?? false }

    // Offline write queue — saves failed pushes to UserDefaults, flushes on next success
    private let queueKey = "lucid_offline_write_queue"
    private var isFlushingQueue = false

    init() {
        // Flush any queued writes from previous sessions
        Task { await flushOfflineQueue() }
    }

    private func queueOfflineWrite(_ body: [String: Any], endpoint: String, extraHeaders: [String: String] = [:]) {
        var queue = UserDefaults.standard.array(forKey: queueKey) as? [[String: Any]] ?? []
        var entry: [String: Any] = ["body": body, "endpoint": endpoint, "ts": Date().timeIntervalSince1970]
        if !extraHeaders.isEmpty { entry["headers"] = extraHeaders }
        queue.append(entry)
        // Cap at 500 entries (~8 hours of 10s readings)
        if queue.count > 500 { queue = Array(queue.suffix(500)) }
        UserDefaults.standard.set(queue, forKey: queueKey)
        log("Queued offline write (\(queue.count) pending)")
    }

    private func flushOfflineQueue() async {
        guard !isFlushingQueue else { return }
        isFlushingQueue = true
        defer { isFlushingQueue = false }

        guard var queue = UserDefaults.standard.array(forKey: queueKey) as? [[String: Any]], !queue.isEmpty else { return }

        do {
            try await ensureAuth()
            guard let token = accessToken else { return }

            var flushed = 0
            while !queue.isEmpty {
                var entry = queue.removeFirst()
                guard let body = entry["body"] as? [String: Any],
                      let endpoint = entry["endpoint"] as? String else { continue }

                let url = URL(string: "\(baseURL)/rest/v1/\(endpoint)")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                // Apply any per-entry extra headers (e.g. Prefer for health_metrics upserts)
                if let extra = entry["headers"] as? [String: String] {
                    for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                if statusCode == 401 || statusCode == 403 {
                    // v141 — token rejected: put entry back, clear token so the next
                    // flush re-auths. Never dead-letter on auth failure (loses good rows).
                    queue.insert(entry, at: 0)
                    accessToken = nil
                    tokenExpiry = nil
                    break
                }
                if statusCode >= 500 || statusCode == 0 {
                    // Server/network transient — retry this entry later, bounded so a
                    // permanently-5xx row can't wedge the queue head forever.
                    let attempts = (entry["attempts"] as? Int ?? 0) + 1
                    if attempts >= 6 {
                        log("Evicting offline entry after \(attempts) failed attempts")
                        continue
                    }
                    entry["attempts"] = attempts
                    queue.insert(entry, at: 0)
                    break
                }
                if statusCode >= 300 {
                    // v141 — non-retryable 4xx (malformed / RLS / schema): dead-letter this
                    // ONE entry and CONTINUE. Was `break`, so a single poison row blocked
                    // every newer queued reading behind head-of-line blocking for up to ~8h.
                    log("Dropping poison offline entry (HTTP \(statusCode))")
                    continue
                }
                flushed += 1
            }

            UserDefaults.standard.set(queue, forKey: queueKey)
            if flushed > 0 { log("Flushed \(flushed) offline writes (\(queue.count) remaining)") }
        } catch {
            log("Queue flush error: \(error.localizedDescription)")
        }
    }

    // MARK: - Auth

    internal func ensureAuth() async throws {
        // If we have a valid token, reuse it
        if let token = accessToken, let expiry = tokenExpiry, Date() < expiry {
            return
        }

        guard !email.isEmpty, !password.isEmpty else {
            log("NO CREDENTIALS! Email empty: \(email.isEmpty), PW empty: \(password.isEmpty)")
            return
        }

        log("Authenticating as \(email.prefix(3))***...")

        let url = URL(string: "\(baseURL)/auth/v1/token?grant_type=password")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        let body: [String: String] = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["access_token"] as? String,
           let expiresIn = json["expires_in"] as? Int {
            self.accessToken = token
            self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            log("Auth OK! Token valid for \(expiresIn/60) min")
        } else {
            // Auth failed — show the error
            let body = String(data: data, encoding: .utf8) ?? "no body"
            log("AUTH FAILED HTTP \(statusCode): \(body.prefix(200))")
        }
    }

    // MARK: - Push Realtime Reading

    func pushReading(hr: Int, rr: [Int], hrv: Double, battery: Double,
                     respiratoryRate: Double = 0, sleepStage: String = "awake",
                     readiness: String = "unknown", skinTemp: Double = 0, spo2: Double = 0,
                     sdnn: Double = 0, pnn50: Double = 0, dfaAlpha1: Double = 0,
                     cognitiveCapacity: Double = 0, cognitiveLabel: String = "",
                     illnessRisk: Int = 0,
                     accelMagMg: Int = 0, movementScore: Double = 0) {
        // v141 — build the FULL body up-front so BOTH the HTTP-failure branch and the
        // network-error catch queue the identical complete row. Previously the catch
        // queued a stripped 4-field stub (user_id/hr/hrv/source), silently dropping
        // rr / respiratory / sleep_stage / skin_temp / all HI-v2 / movement on every
        // network blip. NOTE: recorded_at is deliberately NOT sent — the v138 gap-check
        // (fetchSyncCursor) depends on live rows stamping server now(); do not add it.
        var body: [String: Any] = [
            "user_id": userId,
            "heart_rate": hr,
            "rr_intervals": rr,
            "hrv_rmssd": round(hrv * 10) / 10,
            "battery_pct": round(battery * 10) / 10,
            "source": "whoop_ble"
        ]
        if respiratoryRate > 0 {
            body["respiratory_rate"] = round(respiratoryRate * 100) / 100
        }
        if !sleepStage.isEmpty {
            body["sleep_stage"] = sleepStage.lowercased()
        }
        if !readiness.isEmpty && readiness != "—" {
            body["readiness"] = readiness.lowercased()
        }
        if skinTemp > 0 {
            body["skin_temp"] = round(skinTemp * 10) / 10
        }
        if spo2 > 0 {
            body["blood_oxygen_pct"] = round(spo2 * 10) / 10
        }
        // Health Intelligence v2 metrics
        if sdnn > 0 {
            body["sdnn"] = round(sdnn * 10) / 10
        }
        if pnn50 > 0 {
            body["pnn50"] = round(pnn50 * 10) / 10
        }
        if dfaAlpha1 > 0 {
            body["dfa_alpha1"] = round(dfaAlpha1 * 100) / 100
        }
        if cognitiveCapacity > 0 {
            body["cognitive_capacity"] = round(cognitiveCapacity)
            body["cognitive_label"] = cognitiveLabel
        }
        if illnessRisk > 0 {
            body["illness_risk"] = illnessRisk
        }
        // v98 — IMU-derived movement signal. Critical for wake-up detection:
        // without this, only HR drives wake/sleep decisions and Fabi's
        // chronic-low baseline overlaps awake-low-activity HR, causing
        // missed wake events (May 8 incident).
        if accelMagMg > 0 {
            body["accel_mag_mg"] = accelMagMg
        }
        if movementScore > 0 {
            body["movement_score"] = round(movementScore * 1000) / 1000
        }

        Task {
            // v141 — hold a background-task assertion so a push started inside a brief
            // BLE wake window actually finishes instead of being cancelled when iOS
            // re-suspends the app mid-request (URLSession.shared tasks die on suspend).
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: "lucid-push-reading")
            }
            defer {
                let t = bgTask
                if t != .invalid {
                    Task { @MainActor in UIApplication.shared.endBackgroundTask(t) }
                }
            }

            func send() async throws -> Int {
                let url = URL(string: "\(baseURL)/rest/v1/realtime_health")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode >= 300 {
                    let errBody = String(data: data, encoding: .utf8) ?? "?"
                    log("PUSH FAILED HTTP \(statusCode): \(errBody.prefix(150))")
                }
                return statusCode
            }

            do {
                try await ensureAuth()
                guard accessToken != nil else {
                    log("Skip push — no auth token")
                    return
                }

                var statusCode = try await send()

                // v141 — token rejected mid-session: force one refresh + retry before
                // queuing, instead of 401-ing every push (queued-not-live) until the
                // token naturally expires — up to ~1h of live-stream stall.
                if statusCode == 401 || statusCode == 403 {
                    log("Push \(statusCode) — refreshing auth, retrying once")
                    accessToken = nil
                    tokenExpiry = nil
                    try await ensureAuth()
                    if accessToken != nil { statusCode = try await send() }
                }

                if statusCode < 300 {
                    log("Pushed HR:\(hr) HRV:\(String(format: "%.1f", hrv))")
                    // Flush any queued writes while we have connectivity
                    await flushOfflineQueue()
                } else {
                    queueOfflineWrite(body, endpoint: "realtime_health")
                }
            } catch {
                log("PUSH ERROR: \(error.localizedDescription)")
                // Network error — queue the FULL body for later (was a 4-field stub)
                queueOfflineWrite(body, endpoint: "realtime_health")
            }
        }
    }

    // MARK: - Upsert Daily Metrics

    func upsertDailyMetrics(restingHR: Int, hrvAvg: Double,
                            sleepHours: Double = 0, deepMin: Int = 0, remMin: Int = 0, lightMin: Int = 0,
                            sleepStart: Date? = nil, sleepEnd: Date? = nil,
                            recoveryScore: Double = 0, strainScore: Double = 0,
                            respiratoryRate: Double = 0, bodyBattery: Double = 0,
                            sdnnAvg: Double = 0, pnn50Avg: Double = 0, dfaAlpha1Avg: Double = 0,
                            cognitiveCapacity: Double = 0, cognitiveLabel: String = "",
                            illnessRisk: Int = 0, illnessAlert: String? = nil,
                            trainingMonotony: Double = 0, trainingStrain: Double = 0, acwr: Double = 0,
                            poincaréSD1: Double = 0, poincaréSD2: Double = 0, poincaréRatio: Double = 0,
                            nocturnalHRDip: Double = 0, sleepFragmentation: Double = 0,
                            sleepDebt: Double = 0, vo2max: Double = 0,
                            overtrainingRisk: String = "None", alcoholImpact: Double = 0,
                            skinTemp: Double = 0, awakeMin: Int = 0,
                            readinessLevel: String = "", readinessScore: Double = 0,
                            strainPhysical: Double = -1, strainStress: Double = -1, strainAutonomic: Double = -1,
                            hrr1: Double = 0, hrr2: Double = 0) {
        Task {
            do {
                try await ensureAuth()
                guard accessToken != nil else { return }

                // v103 — single source of truth. iOS is UPDATE-ONLY for the
                // side-channel experimental metrics: PATCH an EXISTING daily
                // row, never create one. The daily aggregate row and every
                // pg-owned column (recovery_score, sleep_*, hrv_avg, resting_hr,
                // readiness_*, source) are owned exclusively by
                // recompute_health_metrics() + pg_cron. If no row exists yet
                // for `today`, this PATCH updates 0 rows (clean no-op) so the
                // day reads as "no data" instead of a fabricated stale row.
                // (The old POST-upsert created source='health_engine' rows
                // that permanently polluted every day pg_recompute never ran —
                // null/stale recovery the app then displayed as a stuck value.)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                // The server anchors every metric_date to Berlin. Device-local
                // would PATCH the wrong day while travelling or on a DST edge.
                formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
                let today = formatter.string(from: Date())

                let url = URL(string: "\(baseURL)/rest/v1/health_metrics?user_id=eq.\(userId)&metric_date=eq.\(today)")!
                var request = URLRequest(url: url)
                request.httpMethod = "PATCH"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
                request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

                // Side-channel experimental metrics ONLY. NEVER write:
                // recovery_score, sleep_score, sleep_hours, deep/rem/light/awake_min,
                // sleep_start, sleep_end, sleep_efficiency_pct, hrv_avg, resting_hr,
                // readiness_level, readiness_score, source, body_battery,
                // skin_temp, alcohol_impact — owned by pg_recompute.
                var body: [String: Any] = [:]
                if strainScore > 0 { body["strain_score"] = round(strainScore * 10) / 10 }
                if respiratoryRate > 0 { body["respiratory_rate"] = round(respiratoryRate * 10) / 10 }
                // v152: skin_temp is server-owned via clean_skin_temp_day() (range
                // gate + cross-day slew reject). The raw strap value written from
                // here was overwriting the cleaned one.
                if strainPhysical >= 0 { body["strain_physical"] = round(strainPhysical * 10) / 10 }
                if strainStress >= 0 { body["strain_stress"] = round(strainStress * 10) / 10 }
                if strainAutonomic >= 0 { body["strain_autonomic"] = round(strainAutonomic * 10) / 10 }

                // Health Intelligence v2
                if sdnnAvg > 0 { body["sdnn_avg"] = round(sdnnAvg * 10) / 10 }
                if pnn50Avg > 0 { body["pnn50_avg"] = round(pnn50Avg * 10) / 10 }
                if dfaAlpha1Avg > 0 { body["dfa_alpha1_avg"] = round(dfaAlpha1Avg * 100) / 100 }
                if cognitiveCapacity > 0 {
                    body["cognitive_capacity_score"] = round(cognitiveCapacity)
                    body["cognitive_label"] = cognitiveLabel
                }
                if illnessRisk > 0 { body["illness_risk"] = illnessRisk }
                if let alert = illnessAlert { body["illness_alert"] = alert }
                if trainingMonotony > 0 { body["training_monotony"] = round(trainingMonotony * 100) / 100 }
                if trainingStrain > 0 { body["training_strain"] = round(trainingStrain * 10) / 10 }
                if acwr > 0 { body["acwr"] = round(acwr * 100) / 100 }
                // v121: do NOT write body_battery — the server owns this column now
                // (reservoir + live drain). The app writing its on-device value was
                // overwriting the correct server value. Read-only from here.

                // Quick-win health experiments (Apr 2026)
                if poincaréSD1 > 0 { body["poincare_sd1"] = round(poincaréSD1 * 10) / 10 }
                if poincaréSD2 > 0 { body["poincare_sd2"] = round(poincaréSD2 * 10) / 10 }
                if poincaréRatio > 0 { body["poincare_ratio"] = round(poincaréRatio * 100) / 100 }
                if nocturnalHRDip != 0 { body["nocturnal_hr_dip"] = round(nocturnalHRDip * 10) / 10 }
                if sleepFragmentation > 0 { body["sleep_fragmentation"] = round(sleepFragmentation * 10) / 10 }
                if sleepDebt > 0 { body["sleep_debt_hours"] = round(sleepDebt * 10) / 10 }
                if vo2max > 0 { body["vo2max_estimate"] = round(vo2max * 10) / 10 }
                if overtrainingRisk != "None" { body["overtraining_risk"] = overtrainingRisk }
                // alcohol_impact is server-owned (audit #39 guard against clearing a
                // real flag). The device wrote an RMSSD-depression percentage into a
                // column the server treats as a 1.0 marker.
                if hrr1 > 0 { body["hrr_1min"] = round(hrr1) }
                if hrr2 > 0 { body["hrr_2min"] = round(hrr2) }

                guard !body.isEmpty else {
                    log("No side-channel metrics ready for \(today) — skipping PATCH")
                    return
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode < 300 {
                    log("Side-channel metrics patched for \(today)")
                } else {
                    // Non-critical: the periodic 30-min cycle re-PATCHes. Do NOT
                    // offline-queue a POST here — that is exactly what re-created
                    // polluted source='health_engine' rows. Drop; next cycle retries.
                    log("Side-channel PATCH failed HTTP \(statusCode) — retry next cycle")
                }
            } catch {
                // Network-level error (no response at all). The 30-min periodic upsert
                // will retry. No body available here to queue since it was built inside do{}.
                log("Daily upsert network error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Server-side Health Recompute (v100 architecture migration)

    /// Calls the Postgres RPC recompute_health_metrics(p_user_id, p_target_date).
    /// This replaces the iOS-side computeRecovery / computeSleepScore on
    /// "I'm awake" (manual or auto). Postgres reads realtime_health, runs the
    /// authoritative algorithms, writes health_metrics, returns the row.
    ///
    /// Returns the freshly-computed (recoveryScore, sleepScore, sleepHours) on
    /// success — caller updates HealthEngine @Published vars from these so UI
    /// reflects the server's truth instead of stale local state.
    @discardableResult
    func recomputeHealthMetrics(date: Date = Date()) async -> (recovery: Double, sleepScore: Double, sleepHours: Double)? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            let body: [String: Any] = [
                "p_user_id": userId,
                "p_target_date": dateFmt.string(from: date),
            ]

            let url = URL(string: "\(baseURL)/rest/v1/rpc/recompute_health_metrics")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else {
                log("recompute_health_metrics HTTP \(code)")
                return nil
            }

            // RPC returns the health_metrics row as a JSON object (not array)
            // when defined RETURNS health_metrics. Some PostgREST versions wrap
            // in a single-element array; handle both shapes.
            let parsed: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                parsed = arr.first
            } else if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsed = obj
            } else {
                parsed = nil
            }
            guard let row = parsed else { return nil }

            let recovery   = (row["recovery_score"] as? NSNumber)?.doubleValue ?? 0
            let sleepScore = (row["sleep_score"]    as? NSNumber)?.doubleValue ?? 0
            let sleepHours = (row["sleep_hours"]    as? NSNumber)?.doubleValue ?? 0
            log("recompute_health_metrics → recovery=\(Int(recovery)) sleepScore=\(Int(sleepScore)) sleepHours=\(sleepHours)")
            return (recovery, sleepScore, sleepHours)
        } catch {
            log("recompute_health_metrics error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Alcohol Mode (Smart Alarm Module 7)

    /// Pre-flag (or clear) "drinking tonight" for tomorrow's wake date. Server
    /// also recomputes + stores tonight's plan immediately on this call.
    func setDrinkingTonight(_ drinking: Bool) async -> Bool {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return false }
            let body: [String: Any] = ["p_user_id": userId, "p_drinking": drinking]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/set_drinking_tonight")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            log("set_drinking_tonight(\(drinking)) HTTP \(code)")
            return code < 300
        } catch {
            log("set_drinking_tonight error: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetch tonight's plan (alcohol-aware). Returns nil on any failure so the
    /// app safely falls back to the user's local alarm settings.
    func fetchTonightPlan() async -> TonightPlan? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/plan_tonight_auto")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("plan_tonight_auto HTTP \(code)"); return nil }

            // RPC returns the jsonb object directly (some PostgREST versions wrap
            // it in a single-element array) — handle both.
            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                obj = arr.first
            } else {
                obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard let p = obj else { return nil }

            let mode = (p["mode"] as? String) ?? "normal"
            let note = (p["note"] as? String) ?? ""
            let start = localMinutes(fromISO: p["wake_window_start"] as? String) ?? 0
            // alcohol plan exposes hard_backstop; normal plan uses wake_window_end
            let endISO = (p["hard_backstop"] as? String) ?? (p["wake_window_end"] as? String)
            let end = localMinutes(fromISO: endISO) ?? 0
            let floor = (p["hr_floor"] as? NSNumber)?.doubleValue
            let tgt = (p["target_sleep_h"] as? NSNumber)?.doubleValue
            log("plan_tonight_auto → mode=\(mode) window=\(start)-\(end)")
            return TonightPlan(mode: mode, note: note,
                               windowStartMinutes: start, windowEndMinutes: end,
                               hrFloor: floor, targetSleepH: tgt)
        } catch {
            log("plan_tonight_auto error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse an ISO8601 timestamptz string into local minutes-of-day.
    private func localMinutes(fromISO iso: String?) -> Int? {
        guard let iso = iso else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: - v154 Smart Wake (onset-anchored adaptive wake engine)

    /// Arm the server-side smart-wake engine. It decides tonight's exact wake
    /// moment (onset-anchored sleep need, hard floor, never-in-deep) and, on
    /// fire, writes an alarm nudge the app turns into a strap buzz. `latestWake`
    /// is an optional hard "up by" deadline; `prepMin` shifts the wake earlier
    /// to leave prep time. Returns nil on any failure so the UI can fall back.
    func armSmartWake(latestWake: Date? = nil, prepMin: Int = 30) async -> SmartWakePlan? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            var body: [String: Any] = ["p_user_id": userId, "p_prep_min": prepMin]
            if let latestWake = latestWake {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                body["p_latest_wake"] = iso.string(from: latestWake)
            }
            let url = URL(string: "\(baseURL)/rest/v1/rpc/arm_smart_wake")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("arm_smart_wake HTTP \(code)"); return nil }

            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                obj = arr.first
            } else {
                obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard let p = obj else { return nil }
            let comp = p["components"] as? [String: Any] ?? [:]
            let plan = SmartWakePlan(
                sessionId: (p["session_id"] as? String) ?? "",
                status: (p["status"] as? String) ?? "armed",
                targetH: (p["target_h"] as? NSNumber)?.doubleValue ?? 0,
                baseH: (p["base_h"] as? NSNumber)?.doubleValue ?? 0,
                safetyFloorH: (p["safety_floor_h"] as? NSNumber)?.doubleValue ?? 0,
                latestWakeLabel: p["latest_wake_label"] as? String,
                latestWakeAtISO: p["latest_wake_at"] as? String,
                deadlineBelowFloor: (p["deadline_below_floor"] as? Bool) ?? false,
                prepMin: (p["prep_min"] as? NSNumber)?.intValue ?? prepMin,
                note: (p["note"] as? String) ?? "",
                needBreakdown: (p["need_breakdown"] as? String) ?? "",
                components: SmartWakeComponents(
                    debt: (comp["debt"] as? NSNumber)?.doubleValue ?? 0,
                    strain: (comp["strain"] as? NSNumber)?.doubleValue ?? 0,
                    quality: (comp["quality"] as? NSNumber)?.doubleValue ?? 0,
                    circadian: (comp["circadian"] as? NSNumber)?.doubleValue ?? 0
                )
            )
            log("arm_smart_wake → target=\(plan.targetH)h floor=\(plan.safetyFloorH)h belowFloor=\(plan.deadlineBelowFloor)")
            return plan
        } catch {
            log("arm_smart_wake error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Cancel any armed smart-wake session. Returns true on success.
    @discardableResult
    func cancelSmartWake() async -> Bool {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return false }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/cancel_smart_wake")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("cancel_smart_wake HTTP \(code)"); return false }
            log("cancel_smart_wake ok")
            return true
        } catch {
            log("cancel_smart_wake error: \(error.localizedDescription)")
            return false
        }
    }

    /// Read the live smart-wake status (idle / armed / asleep / ready). Returns
    /// nil on any failure so the UI just hides the plan surface.
    func fetchSmartWakeStatus() async -> SmartWakeStatus? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/smart_wake_status")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("smart_wake_status HTTP \(code)"); return nil }

            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                obj = arr.first
            } else {
                obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard let p = obj else { return nil }
            let st = SmartWakeStatus(
                armed: (p["armed"] as? Bool) ?? false,
                status: (p["status"] as? String) ?? "idle",
                note: (p["note"] as? String) ?? "",
                sessionId: p["session_id"] as? String,
                targetH: (p["target_h"] as? NSNumber)?.doubleValue,
                strapStreaming: (p["strap_streaming"] as? Bool) ?? false,
                latestWakeLabel: p["latest_wake_label"] as? String,
                onsetLabel: p["onset_label"] as? String,
                asleepH: (p["asleep_h"] as? NSNumber)?.doubleValue,
                earliestWakeLabel: p["earliest_wake_label"] as? String,
                earliestInMin: (p["earliest_in_min"] as? NSNumber)?.intValue,
                targetWakeLabel: p["target_wake_label"] as? String,
                backstopLabel: p["backstop_label"] as? String,
                projectedWindow: p["projected_window"] as? String,
                currentStage: p["current_stage"] as? String,
                currentDeepProb: (p["current_deep_prob"] as? NSNumber)?.doubleValue
            )
            log("smart_wake_status → armed=\(st.armed) status=\(st.status)")
            return st
        } catch {
            log("smart_wake_status error: \(error.localizedDescription)")
            return nil
        }
    }

    /// In-window wake coach. Pass when the user fell asleep (HealthEngine
    /// .sleepStartTime); the server returns a go-back / get-up verdict tuned to
    /// his personalized sleep target + debt + a 90-min cycle. Returns nil on
    /// any failure so the card just hides itself.
    func planBackToSleep(sleepStart: Date) async -> BackToSleepPlan? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let body: [String: Any] = [
                "p_user_id": userId,
                "p_sleep_start": iso.string(from: sleepStart)
            ]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/plan_back_to_sleep")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("plan_back_to_sleep HTTP \(code)"); return nil }

            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                obj = arr.first
            } else {
                obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard let p = obj else { return nil }

            let verdict = (p["verdict"] as? String) ?? "get_up"
            let headline = (p["headline"] as? String) ?? ""
            let detail = (p["detail"] as? String) ?? ""
            let wakeLabel = (p["wake_label"] as? String) ?? ""
            let minsLeft = (p["minutes_left"] as? NSNumber)?.intValue ?? 0
            let sleptH = (p["slept_h"] as? NSNumber)?.doubleValue ?? 0
            let debtH = (p["debt_h"] as? NSNumber)?.doubleValue ?? 0
            let wakeAt = localDate(fromISO: p["wake_at"] as? String)
            log("plan_back_to_sleep → \(verdict) left=\(minsLeft)m")
            return BackToSleepPlan(verdict: verdict, headline: headline, detail: detail,
                                   wakeAt: wakeAt, wakeLabel: wakeLabel, minutesLeft: minsLeft,
                                   sleptH: sleptH, debtH: debtH)
        } catch {
            log("plan_back_to_sleep error: \(error.localizedDescription)")
            return nil
        }
    }

    /// v111 wind-down coach. Live Sleep Readiness Index — how calm the body is vs
    /// his personal sleep baselines, with a plain coaching message + ETA-to-ready.
    /// Read-only server RPC. nil when no recent strap data (sri null row).
    func fetchSleepReadiness() async -> SleepReadiness? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/compute_sleep_readiness")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("compute_sleep_readiness HTTP \(code)"); return nil }
            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] { obj = arr.first }
            else { obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] }
            guard let p = obj, let sriNum = p["sri"] as? NSNumber else { return nil }
            return SleepReadiness(
                sri: sriNum.intValue,
                hrNow: (p["hr_now"] as? NSNumber)?.doubleValue ?? 0,
                hrFloor: (p["hr_floor"] as? NSNumber)?.doubleValue ?? 0,
                hrGap: (p["hr_gap"] as? NSNumber)?.doubleValue ?? 0,
                rmssdNow: (p["rmssd_now"] as? NSNumber)?.doubleValue ?? 0,
                respNow: (p["resp_now"] as? NSNumber)?.doubleValue ?? 0,
                ready: (p["ready"] as? Bool) ?? false,
                etaMin: (p["eta_min"] as? NSNumber)?.intValue ?? 0,
                status: (p["status"] as? String) ?? "",
                message: (p["message"] as? String) ?? ""
            )
        } catch {
            log("compute_sleep_readiness error: \(error.localizedDescription)")
            return nil
        }
    }

    /// v110 personalization. Live percentile (0-100) of a value vs his OWN rolling
    /// history ("62nd pct for you"). Read-only RPC. nil if no usable baseline.
    /// metric ∈ hrv_avg | resting_hr | sleep_hours | deep_sleep_min | rem_sleep_min
    ///          | recovery_score | sleep_score
    func fetchPersonalPercentile(metric: String, value: Double, windowDays: Int = 30) async -> Double? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = [
                "p_user_id": userId, "p_metric": metric,
                "p_value": value, "p_window_days": windowDays
            ]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/personal_percentile")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { return nil }
            let any = try JSONSerialization.jsonObject(with: data)
            if let n = any as? NSNumber { return n.doubleValue }
            if let arr = any as? [Any], let n = arr.first as? NSNumber { return n.doubleValue }
            if let obj = any as? [String: Any], let n = obj["personal_percentile"] as? NSNumber { return n.doubleValue }
            return nil
        } catch {
            return nil
        }
    }

    /// Parse an ISO8601 timestamptz string into a full Date (for scheduling).
    private func localDate(fromISO iso: String?) -> Date? {
        guard let iso = iso else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFrac.date(from: iso) ?? plain.date(from: iso)
    }

    // MARK: - Meal-glucose proxy (text → carbs → post-prandial HR)

    /// Zero-cost server estimate for a typed meal. Returns nil on failure so the
    /// sheet falls back to Gemini / manual. No quota, instant, no photo.
    func estimateMealFromText(_ text: String) async -> MealEstimate? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_text": text]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/estimate_meal_from_text")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("estimate_meal_from_text HTTP \(code)"); return nil }
            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] { obj = arr.first }
            else { obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] }
            guard let p = obj else { return nil }
            let rawItems = (p["items"] as? [[String: Any]]) ?? []
            let items: [DetectedItem] = rawItems.map { it in
                DetectedItem(
                    name: (it["name"] as? String) ?? "Food",
                    grams: 0,
                    kcal: (it["kcal"] as? NSNumber)?.intValue ?? 0,
                    carbsG: (it["net_carbs_g"] as? NSNumber)?.doubleValue,
                    novaClass: 0,
                    mindTags: [],
                    isAlcohol: (it["is_alcohol"] as? Bool) ?? false
                )
            }
            log("estimate_meal_from_text → \(items.count) items, GL \((p["glycemic_load"] as? NSNumber)?.intValue ?? 0)")
            return MealEstimate(
                netCarbsG: (p["net_carbs_g"] as? NSNumber)?.intValue ?? 0,
                kcal: (p["kcal"] as? NSNumber)?.intValue ?? 0,
                glycemicLoad: (p["glycemic_load"] as? NSNumber)?.intValue ?? 0,
                giBand: (p["gi_band"] as? String) ?? "low",
                isAlcohol: (p["is_alcohol"] as? Bool) ?? false,
                confidence: (p["confidence"] as? String) ?? "none",
                note: (p["note"] as? String) ?? "",
                items: items
            )
        } catch {
            log("estimate_meal_from_text error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Last-night signals (sleep restlessness + illness early-warning)

    /// Server `sleep_restlessness` for the latest night. nil on failure / no window.
    func fetchSleepRestlessness() async -> SleepRestlessness? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/sleep_restlessness")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("sleep_restlessness HTTP \(code)"); return nil }
            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] { obj = arr.first }
            else { obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] }
            guard let p = obj, p["error"] == nil else { return nil }
            return SleepRestlessness(
                date: (p["date"] as? String) ?? "",
                inBedH: (p["in_bed_h"] as? NSNumber)?.doubleValue ?? 0,
                sleepingHr: (p["sleeping_hr"] as? NSNumber)?.intValue ?? 0,
                restlessMin: (p["restless_min"] as? NSNumber)?.intValue ?? 0,
                wakeups: (p["wakeups"] as? NSNumber)?.intValue ?? 0,
                stability: (p["stability"] as? NSNumber)?.intValue ?? 0,
                dreamPeriodsEst: (p["dream_periods_est"] as? NSNumber)?.intValue ?? 0,
                note: (p["note"] as? String) ?? ""
            )
        } catch {
            log("sleep_restlessness error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Server `illness_risk_now` for the latest night. nil on failure.
    func fetchIllnessRisk() async -> IllnessRisk? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/illness_risk_now")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("illness_risk_now HTTP \(code)"); return nil }
            let obj: [String: Any]?
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] { obj = arr.first }
            else { obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] }
            guard let p = obj else { return nil }
            return IllnessRisk(
                level: (p["level"] as? String) ?? "no_data",
                risk: (p["risk"] as? NSNumber)?.intValue ?? 0,
                note: (p["note"] as? String) ?? "",
                rhr: (p["rhr"] as? NSNumber)?.doubleValue,
                hrv: (p["hrv"] as? NSNumber)?.doubleValue
            )
        } catch {
            log("illness_risk_now error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Body Battery v2 (reservoir tank)

    /// Refresh the server reservoir and return today's anchor — the carry-over
    /// tank level the live on-device battery seeds from at wake. nil on failure
    /// (app safely falls back to its local battery value).
    func fetchBodyBatteryAnchor() async -> Double? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/refresh_body_battery")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("refresh_body_battery HTTP \(code)"); return nil }
            // RPC returns a bare numeric (e.g. 52.8) — allow JSON fragments.
            if let n = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSNumber {
                return n.doubleValue
            }
            if let s = String(data: data, encoding: .utf8),
               let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return d
            }
            return nil
        } catch {
            log("refresh_body_battery error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch the smooth 24h body-battery curve (server-reconstructed from realtime HR).
    /// Returns [] on failure — the hero just hides the chart, the big number still shows.
    func fetchBodyBatterySeries() async -> [BodyBatteryPoint] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }
            let body: [String: Any] = ["p_user_id": userId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/body_battery_series")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { log("body_battery_series HTTP \(code)"); return [] }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            var pts: [BodyBatteryPoint] = []
            for row in rows {
                guard let ts = row["at"] as? String else { continue }
                let v = (row["value"] as? NSNumber)?.doubleValue
                    ?? (row["value"] as? Double)
                    ?? Double((row["value"] as? String) ?? "")
                guard let value = v, let date = iso.date(from: ts) ?? isoPlain.date(from: ts) else { continue }
                pts.append(BodyBatteryPoint(at: date, value: value))
            }
            return pts
        } catch {
            log("body_battery_series error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Wake-Up Notification

    func notifyWakeUp(completion: @escaping (Bool) -> Void) {
        Task {
            do {
                try await ensureAuth()
                guard accessToken != nil else {
                    log("Skip wake-up notify — no auth")
                    completion(false)
                    return
                }

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                // Insert a wake-up event into brain_dumps as a system notification
                let row: [String: Any] = [
                    "user_id": userId,
                    "content": "🌅 Auto wake-up detected by Whoop BLE bridge. Morning briefing ready to compute.",
                    "project": "Health",
                    "tags": ["wake-up", "auto-detect", "morning-briefing"],
                    "created_at": formatter.string(from: Date())
                ]

                let url = URL(string: "\(baseURL)/rest/v1/brain_dumps")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: row)

                let (_, response) = try await URLSession.shared.data(for: request)
                let httpResp = response as? HTTPURLResponse
                let success = httpResp?.statusCode == 201
                if !success {
                    log("Wake-up notify status: \(httpResp?.statusCode ?? 0)")
                }
                completion(success)
            } catch {
                log("Wake-up notify error: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    // MARK: - Push Brain Dump (auto-generated summaries)

    func pushBrainDump(content: String, tags: [String] = [], project: String = "Health") {
        Task {
            do {
                try await ensureAuth()
                guard accessToken != nil else { return }

                let url = URL(string: "\(baseURL)/rest/v1/brain_dumps")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                let row: [String: Any] = [
                    "user_id": userId,
                    "content": content,
                    "project": project,
                    "tags": tags,
                    "created_at": formatter.string(from: Date())
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: row)

                let (_, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode < 300 {
                    log("Brain dump pushed: \(content.prefix(50))...")
                } else {
                    log("Brain dump push failed: HTTP \(statusCode)")
                }
            } catch {
                log("Brain dump push error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Push Historical Batch (Gap Sync)

    /// Compute RMSSD from a sliding window of RR intervals across multiple readings
    private func computeRMSSDFromHistory(_ readings: [HRReading], centerIndex: Int, windowSize: Int = 10) -> Double {
        // Collect RR intervals from surrounding readings
        var allRR: [Double] = []
        let start = max(0, centerIndex - windowSize / 2)
        let end = min(readings.count, centerIndex + windowSize / 2 + 1)
        for i in start..<end {
            for rr in readings[i].rrIntervals {
                if rr > 200 && rr < 2000 { // Filter physiological range (200-2000ms)
                    allRR.append(Double(rr))
                }
            }
        }
        guard allRR.count >= 3 else { return 0 }

        // Filter ectopic beats (>20% deviation from median)
        let sorted = allRR.sorted()
        let median = sorted[sorted.count / 2]
        let filtered = allRR.filter { abs($0 - median) / median < 0.20 }
        guard filtered.count >= 3 else { return 0 }

        // RMSSD = sqrt(mean of squared successive differences)
        var sumSqDiff: Double = 0
        for i in 1..<filtered.count {
            let diff = filtered[i] - filtered[i-1]
            sumSqDiff += diff * diff
        }
        let rmssd = sqrt(sumSqDiff / Double(filtered.count - 1))
        return round(rmssd * 10) / 10
    }

    func pushHistoricalBatch(readings: [HRReading], completion: @escaping (Bool) -> Void) {
        Task {
            do {
                try await ensureAuth()
                guard accessToken != nil else {
                    log("Skip history push — no auth token")
                    completion(false)
                    return
                }

                // Pre-compute RMSSD for each reading from surrounding RR intervals
                var hrvValues: [Double] = []
                for i in 0..<readings.count {
                    hrvValues.append(computeRMSSDFromHistory(readings, centerIndex: i))
                }

                // Push in chunks of 20 with short delays to avoid network timeouts
                let chunkSize = 20
                var uploaded = 0
                var failed = false

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                for chunkStart in stride(from: 0, to: readings.count, by: chunkSize) {
                    // Re-auth if needed (long uploads may outlast the token)
                    try await ensureAuth()
                    guard accessToken != nil else {
                        failed = true
                        break
                    }

                    let chunkEnd = min(chunkStart + chunkSize, readings.count)
                    let chunk = Array(readings[chunkStart..<chunkEnd])

                    let rows: [[String: Any]] = chunk.enumerated().map { (localIdx, reading) in
                        let globalIdx = chunkStart + localIdx
                        let date = reading.distributedDate ?? Date(timeIntervalSince1970: TimeInterval(reading.timestamp))
                        let hrv = globalIdx < hrvValues.count ? hrvValues[globalIdx] : 0.0
                        return [
                            "user_id": userId,
                            "heart_rate": Int(reading.heartRate),
                            "rr_intervals": reading.rrIntervals.map { Int($0) },
                            "hrv_rmssd": hrv,
                            "battery_pct": 0,
                            "source": "whoop_ble_history",
                            "recorded_at": formatter.string(from: date)
                        ]
                    }

                    let url = URL(string: "\(baseURL)/rest/v1/realtime_health")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(anonKey, forHTTPHeaderField: "apikey")
                    request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONSerialization.data(withJSONObject: rows)

                    do {
                        let (data, response) = try await session.data(for: request)
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                        if statusCode < 300 {
                            uploaded += chunk.count
                            if uploaded % 200 == 0 || uploaded == readings.count {
                                log("History: \(uploaded)/\(readings.count) uploaded")
                            }
                        } else {
                            let errBody = String(data: data, encoding: .utf8) ?? "?"
                            log("History chunk FAILED HTTP \(statusCode): \(errBody.prefix(100))")
                            failed = true
                            break
                        }
                    } catch {
                        log("History chunk error: \(error.localizedDescription)")
                        // Retry once after a short delay
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        do {
                            let (data, response) = try await session.data(for: request)
                            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                            if statusCode < 300 {
                                uploaded += chunk.count
                                log("History retry OK: \(uploaded)/\(readings.count)")
                            } else {
                                log("History retry FAILED")
                                failed = true
                                break
                            }
                        } catch {
                            log("History retry error: \(error.localizedDescription)")
                            failed = true
                            break
                        }
                    }

                    // Small delay between chunks to avoid overwhelming the connection
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                log("History upload done: \(uploaded)/\(readings.count)")
                completion(!failed)
            } catch {
                log("History push error: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    // MARK: - Manual 72h Backfill Helpers
    //
    // Used by the Settings → Manual Backfill button. Two pieces:
    //   1. fetchMinutesWithData — calls the v96 RPC to get the set of unix-minute
    //      buckets that already have ≥1 row in realtime_health within the window.
    //      iOS uses this to skip strap records whose minute is already covered.
    //   2. pushBackfillBatch — uploads strap records with their REAL embedded
    //      timestamps (not distributed across a synthetic gap). source =
    //      'whoop_ble_backfill' so we can distinguish from regular history sync.

    /// Returns set of unix-second-epochs of minutes that already have realtime_health
    /// rows in the window. iOS converts to a Set<Int> for O(1) lookup during dedup.
    func fetchMinutesWithData(since: Date, until: Date) async -> Set<Int> {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let body: [String: Any] = [
                "p_user_id": userId,
                "p_since":   isoFmt.string(from: since),
                "p_until":   isoFmt.string(from: until),
            ]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/minutes_with_realtime_data")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Bug fix v97: PostgREST defaults to 1000 rows for RPC TABLE returns.
            // 72h has up to 4320 minutes — without this header, the dedup set is
            // truncated and the client over-counts real gaps, causing duplicate
            // uploads when the strap returns records covering already-covered minutes.
            req.setValue("items", forHTTPHeaderField: "Range-Unit")
            req.setValue("0-99999", forHTTPHeaderField: "Range")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let httpResp = resp as? HTTPURLResponse
            let code = httpResp?.statusCode ?? 0
            guard code < 300,
                  let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("fetchMinutesWithData failed HTTP \(code)")
                return []
            }
            // Sanity: warn if response was still truncated (i.e. >100k minutes,
            // which would mean a multi-month window — shouldn't happen).
            if let cr = httpResp?.value(forHTTPHeaderField: "Content-Range"),
               cr.contains("/") {
                let parts = cr.split(separator: "/")
                if parts.count == 2, let total = Int(parts[1]), total > arr.count {
                    log("⚠️ fetchMinutesWithData truncated: got \(arr.count) of \(total) — bump Range header")
                }
            }
            return Set(arr.compactMap { ($0["minute_epoch"] as? NSNumber)?.intValue })
        } catch {
            log("fetchMinutesWithData error: \(error.localizedDescription)")
            return []
        }
    }

    /// Upload backfill records with their actual strap-embedded timestamps.
    /// Caller is expected to have already deduped against fetchMinutesWithData().
    /// Returns (uploaded, failed) counts.
    func pushBackfillBatch(records: [(timestamp: Date, hr: UInt8, rrIntervals: [UInt16], hrv: Double)]) async -> (uploaded: Int, failed: Int) {
        guard !records.isEmpty else { return (0, 0) }
        do {
            try await ensureAuth()
            guard accessToken != nil else { return (0, records.count) }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var uploaded = 0
            var failed = 0
            let chunkSize = 50

            for chunkStart in stride(from: 0, to: records.count, by: chunkSize) {
                try await ensureAuth()
                guard let token = accessToken else { failed += (records.count - uploaded); break }

                let chunkEnd = min(chunkStart + chunkSize, records.count)
                let chunk = Array(records[chunkStart..<chunkEnd])

                let rows: [[String: Any]] = chunk.map { rec in
                    [
                        "user_id":     userId,
                        "heart_rate":  Int(rec.hr),
                        "rr_intervals": rec.rrIntervals.map { Int($0) },
                        "hrv_rmssd":   rec.hrv,
                        "battery_pct": 0,
                        "source":      "whoop_ble_backfill",
                        "recorded_at": formatter.string(from: rec.timestamp),
                    ]
                }

                let url = URL(string: "\(baseURL)/rest/v1/realtime_health")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(anonKey, forHTTPHeaderField: "apikey")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.httpBody = try JSONSerialization.data(withJSONObject: rows)

                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code < 300 {
                    uploaded += chunk.count
                } else {
                    let errBody = String(data: data, encoding: .utf8) ?? "?"
                    log("Backfill chunk FAILED HTTP \(code): \(errBody.prefix(120))")
                    failed += chunk.count
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            log("Backfill done: \(uploaded) uploaded, \(failed) failed (of \(records.count) deduped records)")
            return (uploaded, failed)
        } catch {
            log("Backfill push error: \(error.localizedDescription)")
            return (0, records.count)
        }
    }

    // MARK: - Fetch Health Baseline

    /// Fetch personal RHR/HRV baseline from health_metrics (last 14 good nights)
    func fetchHealthBaseline() async -> [String: Double] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [:] }

            // Get last 14 days with valid resting_hr
            let url = URL(string: "\(baseURL)/rest/v1/health_metrics?user_id=eq.\(userId)&resting_hr=gt.0&order=metric_date.desc&limit=14&select=resting_hr,hrv_avg")!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard statusCode == 200 else {
                log("Baseline fetch failed: HTTP \(statusCode)")
                return [:]
            }

            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return [:]
            }

            var rhrs: [Double] = []
            var hrvs: [Double] = []
            for row in rows {
                if let rhr = row["resting_hr"] as? Double, rhr > 0 { rhrs.append(rhr) }
                if let hrv = row["hrv_avg"] as? Double, hrv > 0 { hrvs.append(hrv) }
            }

            let avgRHR = rhrs.isEmpty ? 0 : rhrs.reduce(0, +) / Double(rhrs.count)
            let avgHRV = hrvs.isEmpty ? 0 : hrvs.reduce(0, +) / Double(hrvs.count)

            log("Baseline: RHR=\(String(format: "%.0f", avgRHR)) (\(rhrs.count) days), HRV=\(String(format: "%.0f", avgHRV)) (\(hrvs.count) days)")
            return ["rhr": avgRHR, "hrv": avgHRV]
        } catch {
            log("Baseline fetch error: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Fetch Last Known Scores

    /// Fetch today's state from health_metrics — restores all running scores on app relaunch.
    /// Falls back to most recent day if today has no data yet.
    func fetchLastScores() async -> [String: Double] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [:] }

            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            // Match the server, which anchors metric_date to Berlin.
            fmt.timeZone = TimeZone(identifier: "Europe/Berlin")
            let today = fmt.string(from: Date())

            // Try today first, fall back to most recent
            let todayURL = URL(string: "\(baseURL)/rest/v1/health_metrics?user_id=eq.\(userId)&metric_date=eq.\(today)&select=recovery_score,strain_score,sleep_hours,sleep_score,sleep_efficiency_pct,deep_sleep_min,rem_sleep_min,light_sleep_min,awake_min,body_battery,hrv_avg,resting_hr,respiratory_rate,cognitive_capacity_score,cognitive_label,illness_risk,training_monotony,training_strain,acwr,sleep_start,sleep_end,sdnn_avg,pnn50_avg,dfa_alpha1_avg,skin_temp,poincare_sd1,poincare_sd2,nocturnal_hr_dip,sleep_fragmentation,sleep_debt_hours,vo2max_estimate,alcohol_impact,readiness_score,strain_physical,strain_stress,strain_autonomic")!
            var todayReq = URLRequest(url: todayURL)
            todayReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            todayReq.setValue(anonKey, forHTTPHeaderField: "apikey")
            todayReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (todayData, todayRes) = try await session.data(for: todayReq)
            if let code = (todayRes as? HTTPURLResponse)?.statusCode, code == 200,
               let rows = try JSONSerialization.jsonObject(with: todayData) as? [[String: Any]],
               let row = rows.first {
                return parseScoresRow(row, label: "today")
            }

            // Fall back to most recent day with scores
            let url = URL(string: "\(baseURL)/rest/v1/health_metrics?user_id=eq.\(userId)&hrv_avg=gt.0&order=metric_date.desc&limit=1&select=recovery_score,strain_score,sleep_hours,sleep_score,sleep_efficiency_pct,deep_sleep_min,rem_sleep_min,light_sleep_min,awake_min,body_battery,hrv_avg,resting_hr,respiratory_rate,cognitive_capacity_score,cognitive_label,illness_risk,training_monotony,training_strain,acwr,sleep_start,sleep_end,sdnn_avg,pnn50_avg,dfa_alpha1_avg,skin_temp,poincare_sd1,poincare_sd2,nocturnal_hr_dip,sleep_fragmentation,sleep_debt_hours,vo2max_estimate,alcohol_impact,readiness_score,strain_physical,strain_stress,strain_autonomic")!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard statusCode == 200,
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = rows.first else {
                log("Last scores fetch: no data")
                return [:]
            }

            return parseScoresRow(row, label: "fallback")
        } catch {
            log("Last scores fetch error: \(error.localizedDescription)")
            return [:]
        }
    }

    private func parseScoresRow(_ row: [String: Any], label: String) -> [String: Double] {
        var result: [String: Double] = [:]
        // Marks the row as another day's, so the caller can use it for baselines
        // without painting it on as today's scores.
        if label == "fallback" { result["is_fallback"] = 1 }
        // Core scores
        if let r = row["recovery_score"] as? Double { result["recovery"] = r }
        if let s = row["strain_score"] as? Double { result["strain"] = s }
        if let h = row["sleep_hours"] as? Double { result["sleep_hours"] = h }
        // The server's own sleep score and efficiency. Re-deriving these on device
        // from sleep_hours produced a different number than the server's (65 -> 50,
        // 83 -> 90) and printed the score in the efficiency slot.
        if let ss = row["sleep_score"] as? Double { result["sleep_score"] = ss }
        if let se = row["sleep_efficiency_pct"] as? Double { result["sleep_efficiency"] = se }
        if let d = row["deep_sleep_min"] as? Double { result["deep_min"] = d }
        if let r = row["rem_sleep_min"] as? Double { result["rem_min"] = r }
        if let l = row["light_sleep_min"] as? Double { result["light_min"] = l }
        if let a = row["awake_min"] as? Double { result["awake_min"] = a }
        if let b = row["body_battery"] as? Double { result["body_battery"] = b }
        if let h = row["hrv_avg"] as? Double { result["hrv_avg"] = h }
        if let r = row["resting_hr"] as? Double { result["resting_hr"] = r }
        if let rr = row["respiratory_rate"] as? Double { result["respiratory_rate"] = rr }
        if let c = row["cognitive_capacity_score"] as? Double { result["cognitive"] = c }
        if let i = row["illness_risk"] as? Double { result["illness_risk"] = i }
        if let a = row["acwr"] as? Double { result["acwr"] = a }
        // Training load
        if let tm = row["training_monotony"] as? Double { result["training_monotony"] = tm }
        if let ts = row["training_strain"] as? Double { result["training_strain"] = ts }
        // HRV research metrics
        if let s = row["sdnn_avg"] as? Double { result["sdnn"] = s }
        if let p = row["pnn50_avg"] as? Double { result["pnn50"] = p }
        if let d = row["dfa_alpha1_avg"] as? Double { result["dfa_alpha1"] = d }
        // Skin temperature
        if let t = row["skin_temp"] as? Double { result["skin_temp"] = t }
        // Quick-win health metrics (v32)
        if let s1 = row["poincare_sd1"] as? Double { result["poincare_sd1"] = s1 }
        if let s2 = row["poincare_sd2"] as? Double { result["poincare_sd2"] = s2 }
        if let dip = row["nocturnal_hr_dip"] as? Double { result["nocturnal_hr_dip"] = dip }
        if let frag = row["sleep_fragmentation"] as? Double { result["sleep_fragmentation"] = frag }
        if let debt = row["sleep_debt_hours"] as? Double { result["sleep_debt_hours"] = debt }
        if let vo2 = row["vo2max_estimate"] as? Double { result["vo2max"] = vo2 }
        // v114 — alcohol_impact is a DATE-SPECIFIC event flag. Never carry it
        // through the "fallback to most recent day" path: a Friday alcohol night
        // must not badge Sunday's ring just because today's row wasn't fetched yet.
        // Only surface it when these scores are genuinely today's.
        if label != "fallback", let alc = row["alcohol_impact"] as? Double { result["alcohol_impact"] = alc }
        // Readiness + strain sub-scores (v45)
        if let rs = row["readiness_score"] as? Double { result["readiness_score"] = rs }
        if let sp = row["strain_physical"] as? Double { result["strain_physical"] = sp }
        if let ss = row["strain_stress"] as? Double { result["strain_stress"] = ss }
        if let sa = row["strain_autonomic"] as? Double { result["strain_autonomic"] = sa }
        // Encode sleep timestamps as Unix epoch seconds so they fit [String: Double]
        let iso = ISO8601DateFormatter()
        if let s = row["sleep_start"] as? String, let d = iso.date(from: s) { result["sleep_start_epoch"] = d.timeIntervalSince1970 }
        if let s = row["sleep_end"] as? String, let d = iso.date(from: s) { result["sleep_end_epoch"] = d.timeIntervalSince1970 }

        log("Scores (\(label)): recovery=\(result["recovery"] ?? 0), strain=\(result["strain"] ?? 0), sleep=\(result["sleep_hours"] ?? 0)h, battery=\(result["body_battery"] ?? 0)")
        return result
    }

    // MARK: - Fetch Gap Readings (for sleep replay)

    /// Fetch today's gap sync HR readings from realtime_health to replay through sleep engine.
    /// Used when the app updates and needs to retroactively fix today's sleep score.
    func fetchTodayGapReadings() async -> [(hr: Int, time: Date)] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            // Get today's midnight in UTC
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: Date())
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let since = formatter.string(from: startOfDay.addingTimeInterval(-12 * 3600)) // yesterday 12pm (catch overnight sleep)

            let url = URL(string: "\(baseURL)/rest/v1/realtime_health?user_id=eq.\(userId)&source=eq.whoop_ble_history&recorded_at=gte.\(since)&order=recorded_at.asc&select=heart_rate,recorded_at&limit=5000")!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard statusCode == 200,
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("Gap readings fetch failed: HTTP \(statusCode)")
                return []
            }

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let readings: [(hr: Int, time: Date)] = rows.compactMap { row in
                guard let hr = row["heart_rate"] as? Int, hr > 30,
                      let dateStr = row["recorded_at"] as? String,
                      let date = isoFormatter.date(from: dateStr) else { return nil }
                return (hr: hr, time: date)
            }

            log("Fetched \(readings.count) gap readings for sleep replay")
            return readings
        } catch {
            log("Gap readings fetch error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Fetch Calibration Data (full history for auto-calibration)

    /// Fetch all health_metrics for personal algorithm calibration.
    /// Returns array of dictionaries with: resting_hr, hrv_avg, sleep_hours,
    /// deep_sleep_min, rem_sleep_min, light_sleep_min, recovery_score, strain_score
    func fetchCalibrationData() async -> [[String: Double]] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            let fields = "resting_hr,hrv_avg,sleep_hours,deep_sleep_min,rem_sleep_min,light_sleep_min,recovery_score,strain_score,respiratory_rate"
            let url = URL(string: "\(baseURL)/rest/v1/health_metrics?user_id=eq.\(userId)&select=\(fields)&order=metric_date.asc&limit=800")!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard statusCode == 200,
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("Calibration data fetch failed: HTTP \(statusCode)")
                return []
            }

            let result: [[String: Double]] = rows.map { row in
                var dict: [String: Double] = [:]
                for key in ["resting_hr", "hrv_avg", "sleep_hours", "deep_sleep_min",
                            "rem_sleep_min", "light_sleep_min", "recovery_score",
                            "strain_score", "respiratory_rate"] {
                    if let val = row[key] as? Double { dict[key] = val }
                    else if let val = row[key] as? Int { dict[key] = Double(val) }
                }
                return dict
            }

            log("Calibration data: \(result.count) rows fetched")
            return result
        } catch {
            log("Calibration data fetch error: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch per-day health_metrics for the Insights correlation engine.
    /// Returns dated rows so food (by day) can be joined to recovery/sleep/HRV.
    func fetchDailyMetrics(days: Int = 120) async -> [DailyMetric] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            let fields = "metric_date,recovery_score,sleep_score,sleep_hours,hrv_avg,resting_hr,alcohol_impact"
            let url = URL(string: "\(baseURL)/rest/v1/health_metrics?user_id=eq.\(userId)&select=\(fields)&order=metric_date.desc&limit=\(days)")!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200,
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("Daily metrics fetch failed: HTTP \(statusCode)")
                return []
            }

            func num(_ row: [String: Any], _ k: String) -> Double? {
                if let v = row[k] as? Double { return v }
                if let v = row[k] as? Int { return Double(v) }
                if let v = row[k] as? NSNumber { return v.doubleValue }
                return nil
            }

            let result: [DailyMetric] = rows.compactMap { row in
                guard let date = row["metric_date"] as? String else { return nil }
                return DailyMetric(
                    date: date,
                    recovery: num(row, "recovery_score"),
                    sleepScore: num(row, "sleep_score"),
                    sleepHours: num(row, "sleep_hours"),
                    hrv: num(row, "hrv_avg"),
                    restingHr: num(row, "resting_hr"),
                    alcoholImpact: num(row, "alcohol_impact")
                )
            }
            log("Daily metrics: \(result.count) days fetched")
            return result
        } catch {
            log("Daily metrics fetch error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Cross-Domain Insights (two-tier: Lucid computed + Gemini speculative)

    /// Rows written by scripts/insight-engine.mjs. Each carries a `source` (lucid|gemini)
    /// so the Insights tab can badge computed vs AI-generated connections.
    func fetchCrossDomainInsights() async -> [FoodPattern] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            let fields = "source,title,subtitle,confidence,confidence_value,effect_description,effect_positive,data_quality_note"
            let url = URL(string: "\(baseURL)/rest/v1/cross_domain_insights?user_id=eq.\(userId)&active=eq.true&select=\(fields)&order=source.asc,confidence_value.desc")!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200,
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("Cross-domain insights fetch failed: HTTP \(statusCode)")
                return []
            }

            func num(_ row: [String: Any], _ k: String) -> Double? {
                if let v = row[k] as? Double { return v }
                if let v = row[k] as? Int { return Double(v) }
                if let v = row[k] as? NSNumber { return v.doubleValue }
                return nil
            }
            func tier(_ s: String?) -> FoodPattern.ConfidenceTier {
                switch s { case "high": return .high; case "low": return .low; default: return .medium }
            }

            let result: [FoodPattern] = rows.compactMap { row in
                guard let title = row["title"] as? String else { return nil }
                let src: FoodPattern.Source = (row["source"] as? String) == "gemini" ? .gemini : .lucid
                return FoodPattern(
                    title: title,
                    subtitle: (row["subtitle"] as? String) ?? "",
                    confidenceTier: tier(row["confidence"] as? String),
                    confidenceValue: num(row, "confidence_value") ?? 0.5,
                    effectDescription: row["effect_description"] as? String,
                    effectPositive: (row["effect_positive"] as? Bool) ?? true,
                    source: src,
                    dataQualityNote: row["data_quality_note"] as? String
                )
            }
            log("Cross-domain insights: \(result.count) fetched")
            return result
        } catch {
            log("Cross-domain insights fetch error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Debug Log (push to Supabase for remote debugging)

    /// Push structured debug event (for sleep staging, smart alarm etc.)
    func pushDebugLog(event: String, details: String, tags: [String] = ["ble-debug"]) {
        pushDebugLog(key: event, value: details)
    }

    func pushDebugLog(key: String, value: String) {
        Task {
            do {
                try await ensureAuth()
                guard accessToken != nil else { return }

                // v85: writes to bridge_logs (no embedding) instead of brain_dumps
                // to keep the neural network clean. See migration v85.
                let url = URL(string: "\(baseURL)/rest/v1/bridge_logs")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

                let body: [String: Any] = [
                    "user_id": userId,
                    "source": "whoop-ble",
                    "category": key,
                    "key": key,
                    "value": value,
                    "content": "[BLE_DEBUG] \(key): \(value)"
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode >= 300 {
                    let respBody = String(data: data, encoding: .utf8) ?? ""
                    log("Debug log FAILED: HTTP \(statusCode) — \(respBody.prefix(200))")
                } else {
                    log("Debug log pushed: \(key)")
                }
            } catch {
                log("Debug log error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Double Tap Events

    func pushActivity(type: String, source: String, startedAt: Date, endedAt: Date? = nil,
                       hrAvg: Int? = nil, hrPeak: Int? = nil, hrvAvg: Double? = nil,
                       notes: String? = nil, category: String = "physical",
                       metadata: [String: Any]? = nil) {
        Task {
            do {
                try await ensureAuth()
                guard accessToken != nil else { return }

                let url = URL(string: "\(baseURL)/rest/v1/activities")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                var body: [String: Any] = [
                    "user_id": userId,
                    "activity_type": type,
                    "source": source,
                    "started_at": fmt.string(from: startedAt),
                    "event_category": category
                ]
                if let endedAt = endedAt { body["ended_at"] = fmt.string(from: endedAt) }
                if let hrAvg = hrAvg { body["hr_avg"] = hrAvg }
                if let hrPeak = hrPeak { body["hr_peak"] = hrPeak }
                if let hrvAvg = hrvAvg { body["hrv_avg"] = hrvAvg }
                if let notes = notes { body["notes"] = notes }
                if let metadata = metadata { body["metadata"] = metadata }

                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode < 300 {
                    log("Activity pushed: \(type) (\(source))")
                } else {
                    log("Activity push failed: HTTP \(statusCode)")
                }
            } catch {
                log("Activity push error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Whoop Full Signal Capture (v66)
    // Every discrete strap event lands in whoop_events; every IMU frame (after decimation)
    // lands in whoop_imu. Design: iOS never blocks on these pushes — fire-and-forget Task.

    /// Push a discrete Whoop event to whoop_events. Non-blocking.
    /// eventType examples: "firmware_version", "extended_battery", "afe_reset",
    /// "ch1_saturation", "ch2_saturation", "accel_saturation", "haptic_fired",
    /// "strap_condition", "raw_data_on", "raw_data_off", "memfault_crash",
    /// "body_location", "console_log".
    func pushWhoopEvent(type eventType: String,
                        data eventData: [String: Any]? = nil,
                        rawBytes: Data? = nil) {
        Task {
            do {
                try await ensureAuth()
                guard let token = accessToken else { return }

                let url = URL(string: "\(baseURL)/rest/v1/whoop_events")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                var body: [String: Any] = [
                    "user_id": userId,
                    "event_type": eventType,
                    "recorded_at": ISO8601DateFormatter().string(from: Date()),
                    "source": "whoop_ble"
                ]
                if let ed = eventData { body["event_data"] = ed }
                if let raw = rawBytes {
                    body["raw_bytes"] = raw.map { String(format: "%02x", $0) }.joined()
                }

                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                _ = try await session.data(for: request)
            } catch {
                log("whoop_events push error (\(eventType)): \(error.localizedDescription)")
            }
        }
    }

    /// Push a batch of raw PPG samples to whoop_raw_optical.
    /// Each row must include channel + adc + recorded_at; user_id auto-injected.
    func pushWhoopOpticalBatch(_ rows: [[String: Any]]) {
        guard !rows.isEmpty else { return }
        Task {
            do {
                try await ensureAuth()
                guard let token = accessToken else { return }

                let url = URL(string: "\(baseURL)/rest/v1/whoop_raw_optical")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                let withUser = rows.map { row -> [String: Any] in
                    var r = row
                    r["user_id"] = userId
                    return r
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: withUser)
                _ = try await session.data(for: request)
            } catch {
                log("whoop_raw_optical push error: \(error.localizedDescription)")
            }
        }
    }

    /// Push a batch of IMU frames to whoop_imu. Batches are decimated on-device.
    func pushWhoopIMUBatch(_ rows: [[String: Any]]) {
        guard !rows.isEmpty else { return }
        Task {
            do {
                try await ensureAuth()
                guard let token = accessToken else { return }

                let url = URL(string: "\(baseURL)/rest/v1/whoop_imu")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                // Ensure every row has user_id
                let withUser = rows.map { row -> [String: Any] in
                    var r = row
                    r["user_id"] = userId
                    return r
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: withUser)
                _ = try await session.data(for: request)
            } catch {
                log("whoop_imu push error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Whoop Realtime Raw (v69) — full type-40 packet capture for RE
    //
    // Captures the undecoded data0 + data1 fields from every Nth HR packet so we
    // can offline-diff them against known states and find SpO2 / respiration /
    // additional signals buried in the payload.
    // Battery: raw reverse-engineering capture (whoop_realtime_raw + whoop_packet_debug)
    // is DEV-ONLY and OFF by default. It was POSTing ~85-120k rows/day (~1 write/sec) and
    // was the single largest avoidable background drain. Re-enable for a focused Whoop-RE
    // session by setting UserDefaults "lucid_capture_raw_debug" = true.
    static var captureRawDebugStreams: Bool {
        UserDefaults.standard.bool(forKey: "lucid_capture_raw_debug")
    }

    func pushRealtimeRaw(hr: Int,
                         rrIntervals: [Int],
                         data0Hex: String,
                         data1Hex: String,
                         fullHex: String,
                         activityState: String? = nil,
                         packetType: Int? = nil,
                         seq: Int? = nil,
                         counter: Int? = nil,
                         timestampUnix: Int64? = nil,
                         timestampFrac: Int64? = nil,
                         parsedFloats: [Float]? = nil) {
        guard Self.captureRawDebugStreams else { return }
        Task {
            do {
                try await ensureAuth()
                guard let token = accessToken else { return }

                let url = URL(string: "\(baseURL)/rest/v1/whoop_realtime_raw")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

                var body: [String: Any] = [
                    "user_id": userId,
                    "recorded_at": ISO8601DateFormatter().string(from: Date()),
                    "hr": hr,
                    "rr_count": rrIntervals.count,
                    "rr_intervals_ms": rrIntervals,
                    "data0_hex": data0Hex,
                    "data1_hex": data1Hex,
                    "full_hex": fullHex
                ]
                if let act = activityState { body["activity_state"] = act }
                if let pt = packetType       { body["packet_type"] = pt }
                if let s  = seq              { body["seq"] = s }
                if let c  = counter          { body["counter"] = c }
                if let ts = timestampUnix    { body["timestamp_unix"] = NSNumber(value: ts) }
                if let tf = timestampFrac    { body["timestamp_frac"] = NSNumber(value: tf) }
                if let f  = parsedFloats     {
                    // Convert to [Double] so JSONSerialization handles it; floats serialise badly in Swift dicts.
                    body["parsed_floats"] = f.map { Double($0) }
                }

                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                _ = try await session.data(for: request)
            } catch {
                // Silent — high-volume RE path. Don't spam logs.
            }
        }
    }

    // MARK: - Whoop Packet Debug Capture (v68) — RE / reverse-engineering only
    //
    // Logs every incoming BLE packet with session grouping so we can mine for:
    //   - Unknown packet types that might be PPG / SpO2 / skin temp streams
    //   - CMD sweep responses across opcode space
    //   - Firmware-version-specific quirks
    //
    // Fire-and-forget. High volume — enable sparingly via UserDefaults.
    func pushPacketDebug(sessionId: String,
                         characteristic: String,
                         packetType: Int,
                         packetCmd: Int,
                         packetLength: Int,
                         dataHex: String,
                         note: String? = nil) {
        guard Self.captureRawDebugStreams else { return }
        Task {
            do {
                try await ensureAuth()
                guard let token = accessToken else { return }

                let url = URL(string: "\(baseURL)/rest/v1/whoop_packet_debug")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

                var body: [String: Any] = [
                    "user_id": userId,
                    "session_id": sessionId,
                    "characteristic": characteristic,
                    "packet_type": packetType,
                    "packet_cmd": packetCmd,
                    "packet_length": packetLength,
                    "data_hex": dataHex,
                    "recorded_at": ISO8601DateFormatter().string(from: Date())
                ]
                if let note = note { body["note"] = note }

                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                _ = try await session.data(for: request)
            } catch {
                // Silent — debug table. Don't spam logs if a few packets fail to push.
            }
        }
    }

    // MARK: - Personal Model + Activities (Health Intelligence UI)

    func fetchPersonalModel() async -> [PersonalModelEntry] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            let url = URL(string: "\(baseURL)/rest/v1/personal_model?user_id=eq.\(userId)&order=last_updated.desc")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await session.data(for: request)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            return rows.compactMap { row in
                guard let modelType = row["model_type"] as? String,
                      let modelKey = row["model_key"] as? String else { return nil }
                let modelData = row["model_data"] as? [String: Any] ?? [:]
                let confidence = row["confidence"] as? Double ?? 0.5
                let dataPoints = row["data_points"] as? Int ?? 0
                return PersonalModelEntry(modelType: modelType, modelKey: modelKey, modelData: modelData, confidence: confidence, dataPoints: dataPoints)
            }
        } catch {
            log("fetchPersonalModel error: \(error.localizedDescription)")
            return []
        }
    }

    func fetchTodayActivities() async -> [ActivityEvent] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            // Use proper UTC day bounds computed from local midnight — prevents
            // evening/early-morning detections from being excluded due to timezone drift
            let cal = Calendar.current
            let localStartOfDay = cal.startOfDay(for: Date())
            let localEndOfDay = cal.date(byAdding: .day, value: 1, to: localStartOfDay) ?? Date()
            let boundsFmt = ISO8601DateFormatter()
            boundsFmt.formatOptions = [.withInternetDateTime]
            let startBound = boundsFmt.string(from: localStartOfDay)
            let endBound = boundsFmt.string(from: localEndOfDay)

            let urlStr = "\(baseURL)/rest/v1/activities?user_id=eq.\(userId)&started_at=gte.\(startBound)&started_at=lt.\(endBound)&order=started_at"
            let url = URL(string: urlStr)!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await session.data(for: request)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFmtNoFrac = ISO8601DateFormatter()
            isoFmtNoFrac.formatOptions = [.withInternetDateTime]

            func parseDate(_ str: String?) -> Date? {
                guard let s = str else { return nil }
                return isoFmt.date(from: s) ?? isoFmtNoFrac.date(from: s)
            }

            return rows.compactMap { row in
                guard let id = row["id"] as? String,
                      let type = row["activity_type"] as? String,
                      let source = row["source"] as? String,
                      let startStr = row["started_at"] as? String,
                      let startDate = parseDate(startStr) else { return nil }
                return ActivityEvent(
                    id: id,
                    activityType: type,
                    source: source,
                    startedAt: startDate,
                    endedAt: parseDate(row["ended_at"] as? String),
                    hrAvg: row["hr_avg"] as? Int,
                    hrvAvg: row["hrv_avg"] as? Double,
                    notes: row["notes"] as? String,
                    eventCategory: row["event_category"] as? String ?? "physical"
                )
            }
        } catch {
            log("fetchTodayActivities error: \(error.localizedDescription)")
            return []
        }
    }

    /// PATCH an existing activity row. Used by the timeline edit sheet so Fabi
    /// can correct auto-detected activities (rename, adjust start/end, add notes).
    /// Only non-nil parameters get written.
    func updateActivity(id: String,
                        activityType: String? = nil,
                        startedAt: Date? = nil,
                        endedAt: Date? = nil,
                        notes: String? = nil,
                        eventCategory: String? = nil) async -> Bool {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return false }

            let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            let url = URL(string: "\(baseURL)/rest/v1/activities?id=eq.\(safeId)&user_id=eq.\(userId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var body: [String: Any] = [:]
            if let t = activityType { body["activity_type"] = t }
            if let s = startedAt { body["started_at"] = fmt.string(from: s) }
            if let e = endedAt { body["ended_at"] = fmt.string(from: e) }
            if let n = notes { body["notes"] = n }
            if let c = eventCategory { body["event_category"] = c }

            guard !body.isEmpty else {
                log("Activity update: no fields to patch")
                return true
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode < 300 {
                log("Activity updated: \(id) — \(Array(body.keys).joined(separator: ","))")
                return true
            }
            log("Activity update failed: HTTP \(statusCode)")
            return false
        } catch {
            log("Activity update error: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetch raw physiology readings from `realtime_health` for a given time window.
    /// Powers the Timeline backtrack scrubber — user can find HR/HRV spikes to snap
    /// activity boundaries to them.
    ///
    /// Returns samples sorted ascending by recorded_at. Hard-capped at 2000 samples
    /// to keep the scrubber chart responsive.
    func fetchReadingsInRange(start: Date, end: Date) async -> [PhysioSample] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            let sinceStr = fmt.string(from: start)
            let untilStr = fmt.string(from: end)

            let urlStr = "\(baseURL)/rest/v1/realtime_health?user_id=eq.\(userId)&recorded_at=gte.\(sinceStr)&recorded_at=lt.\(untilStr)&order=recorded_at.asc&limit=2000&select=heart_rate,hrv_rmssd,recorded_at"
            guard let url = URL(string: urlStr) else { return [] }
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await session.data(for: request)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoNoFrac = ISO8601DateFormatter()
            isoNoFrac.formatOptions = [.withInternetDateTime]

            return rows.compactMap { row -> PhysioSample? in
                guard let ts = row["recorded_at"] as? String else { return nil }
                let date = iso.date(from: ts) ?? isoNoFrac.date(from: ts)
                guard let d = date else { return nil }
                let hr = (row["heart_rate"] as? Int) ?? Int((row["heart_rate"] as? Double) ?? 0)
                let hrv = (row["hrv_rmssd"] as? Double) ?? 0
                return PhysioSample(time: d, hr: hr, hrv: hrv)
            }
        } catch {
            log("fetchReadingsInRange error: \(error.localizedDescription)")
            return []
        }
    }

    func deleteActivity(id: String) async -> Bool {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return false }

            let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            let url = URL(string: "\(baseURL)/rest/v1/activities?id=eq.\(safeId)&user_id=eq.\(userId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode < 300 {
                log("Activity deleted: \(id)")
                return true
            }

            log("Activity delete failed: HTTP \(statusCode)")
            return false
        } catch {
            log("Activity delete error: \(error.localizedDescription)")
            return false
        }
    }

    /// Full PATCH for food entries — used by EditFoodEntrySheet.
    /// Updates caption, items array (JSONB), and recomputed totals.
    func updateFoodEntry(
        id: String,
        caption: String?,
        items: [DetectedItem],
        totalKcal: Int,
        novaAvg: Double,
        mindScore: Int?,
        capturedAt: Date? = nil
    ) async -> Bool {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return false }

            let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            let url = URL(string: "\(baseURL)/rest/v1/food_entries?id=eq.\(safeId)&user_id=eq.\(userId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let itemsJSON = try encoder.encode(items)
            let itemsArray = try JSONSerialization.jsonObject(with: itemsJSON)

            var body: [String: Any] = [
                "items": itemsArray,
                "total_kcal": totalKcal,
                "nova_avg": novaAvg
            ]
            if let caption = caption { body["caption"] = caption }
            if let mindScore = mindScore { body["mind_score"] = mindScore }
            if let capturedAt = capturedAt {
                body["captured_at"] = ISO8601DateFormatter().string(from: capturedAt)
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode < 300 {
                log("Food entry full-updated: \(id)")
                return true
            }
            log("Food entry update failed: HTTP \(statusCode)")
            return false
        } catch {
            log("Food entry update error: \(error.localizedDescription)")
            return false
        }
    }

    func updateFoodEntryCaption(id: String, caption: String) async -> Bool {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return false }

            let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            let url = URL(string: "\(baseURL)/rest/v1/food_entries?id=eq.\(safeId)&user_id=eq.\(userId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            let body = ["caption": caption]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode < 300 {
                log("Food entry caption updated: \(id)")
                return true
            }
            log("Food entry update failed: HTTP \(statusCode)")
            return false
        } catch {
            log("Food entry update error: \(error.localizedDescription)")
            return false
        }
    }

    func deleteFoodEntry(id: String) async -> Bool {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return false }

            let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            let url = URL(string: "\(baseURL)/rest/v1/food_entries?id=eq.\(safeId)&user_id=eq.\(userId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode < 300 {
                log("Food entry deleted: \(id)")
                return true
            }

            log("Food entry delete failed: HTTP \(statusCode)")
            return false
        } catch {
            log("Food entry delete error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Continuous App Log (structured remote debugging)

    /// Push a batch of debug log lines to a dedicated table for remote debugging.
    /// Uses knowledge_entries with category "device_log" so we can query by device/session.
    func pushAppLog(lines: [String], sessionId: String) {
        guard !lines.isEmpty else { return }
        Task {
            do {
                try await ensureAuth()
                guard accessToken != nil else { return }

                let url = URL(string: "\(baseURL)/rest/v1/knowledge_entries")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
                request.setValue(anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                let body: [String: Any] = [
                    "user_id": userId,
                    "category": "device_log",
                    "title": "LucidBridge Log Batch",
                    "summary": "[\(sessionId)] \(lines.count) lines — \(lines.last?.prefix(80) ?? "")",
                    "details": [
                        "session_id": sessionId,
                        "line_count": lines.count,
                        "lines": lines,
                        "device": UIDevice.current.name,
                        "timestamp": fmt.string(from: Date())
                    ] as [String: Any],
                    "source_type": "device_log",
                    "tags": ["ble-debug", "app-log", "auto"],
                    "project": "Health",
                    "workspace": "personal",
                    "entry_date": {
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd"
                        return df.string(from: Date())
                    }()
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode >= 300 {
                    let respBody = String(data: data, encoding: .utf8) ?? ""
                    print("[SB] App log push FAILED: HTTP \(statusCode) — \(respBody.prefix(200))")
                }
            } catch {
                print("[SB] App log push error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Credential Management

    static func saveCredentials(email: String, password: String) {
        UserDefaults.standard.set(email, forKey: "lucidhealth_email")
        UserDefaults.standard.set(password, forKey: "lucidhealth_password")
    }

    static var hasCredentials: Bool {
        let email = UserDefaults.standard.string(forKey: "lucidhealth_email") ?? ""
        return !email.isEmpty
    }

    // MARK: - Nudges (for NotificationListener)

    /// Fetch recent push-channel nudges.
    ///
    /// NOTE: sync-to-app.ts queueNudge() inserts nudges with status='delivered'
    /// at creation time (sync-to-app.ts:5544 — designed for synchronous web push).
    /// So we can't filter by status=pending. Instead we fetch recent push-channel
    /// rows and dedup locally via UserDefaults in NotificationListener.
    func fetchPendingNudges() async throws -> [PendingNudge] {
        try await ensureAuth()
        guard let token = accessToken else { return [] }

        // Only pick up nudges delivered in the last 5 minutes — everything older
        // has already been shown (or missed; too late to be useful).
        let fiveMinAgo = Date(timeIntervalSinceNow: -5 * 60)
        let sinceIso = ISO8601DateFormatter().string(from: fiveMinAgo)

        // channels && '{push}' means array-intersect — row if channels contains push
        let urlStr = "\(baseURL)/rest/v1/nudges"
            + "?user_id=eq.\(userId)"
            + "&channels=cs.%7Bpush%7D"      // cs = contains, %7B...%7D = {push}
            + "&deliver_at=gte.\(sinceIso)"  // only recent
            + "&order=deliver_at.desc"
            + "&limit=10"

        guard let url = URL(string: urlStr) else { return [] }
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let message = row["message"] as? String else { return nil }
            let title = row["title"] as? String
            let priority = row["priority"] as? String ?? "visual"
            let channels = row["channels"] as? [String] ?? ["push"]
            // v154: decode the smart-wake delivery fields. metadata is a jsonb
            // object; all fields optional so non-smart-wake rows are unaffected.
            let source = row["source"] as? String
            let meta = row["metadata"] as? [String: Any]
            return PendingNudge(
                id: id, title: title, message: message, priority: priority, channels: channels,
                source: source,
                metaKind: meta?["kind"] as? String,
                sessionId: meta?["session_id"] as? String,
                reason: meta?["reason"] as? String
            )
        }
    }

    // MARK: - Personal AI Stack (HMM, Forecasts, Causal Graph)

    /// Fetches the live current_state row — kept fresh by Postgres trigger
    /// (refresh_current_state_from_realtime fires on every BLE insert).
    /// Returns the live HMM state name + current vitals + baselines.
    /// Server-side computation; iOS just reads.
    func fetchCurrentState() async -> CurrentStateData? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }

            let urlStr = "\(baseURL)/rest/v1/current_state?user_id=eq.\(userId)&select=current_hmm_state,current_hmm_state_id,current_hr,current_hrv_rmssd,current_cognitive_capacity,current_cognitive_label,current_readiness,current_illness_risk,current_activity_state,baseline_hrv_avg,baseline_resting_hr,strap_connected,last_ble_sample_at,updated_at"
            guard let url = URL(string: urlStr) else { return nil }
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await session.data(for: req)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = rows.first else { return nil }

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()

            func parseDate(_ s: String?) -> Date? {
                guard let s = s else { return nil }
                return iso.date(from: s) ?? isoFallback.date(from: s)
            }

            return CurrentStateData(
                hmmState: row["current_hmm_state"] as? String,
                hmmStateId: row["current_hmm_state_id"] as? Int,
                hr: row["current_hr"] as? Int,
                hrvRmssd: row["current_hrv_rmssd"] as? Double,
                cognitiveCapacity: row["current_cognitive_capacity"] as? Int,
                cognitiveLabel: row["current_cognitive_label"] as? String,
                readiness: row["current_readiness"] as? String,
                illnessRisk: row["current_illness_risk"] as? Double,
                activityState: row["current_activity_state"] as? String,
                baselineHRV: row["baseline_hrv_avg"] as? Double,
                baselineRHR: row["baseline_resting_hr"] as? Int,
                strapConnected: row["strap_connected"] as? Bool ?? false,
                lastBleSampleAt: parseDate(row["last_ble_sample_at"] as? String),
                updatedAt: parseDate(row["updated_at"] as? String)
            )
        } catch {
            log("fetchCurrentState error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetches the next 7 days of forecasts from health_metrics_forecast.
    /// Populated nightly by scripts/forecast-health-metrics.py via Routine.
    /// Returns rows in target_date order (today+1 first).
    func fetchForecast(days: Int = 7) async -> [ForecastDay] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let today = fmt.string(from: Date())
            let cutoff = today  // any forecast targeting today or later

            let urlStr = "\(baseURL)/rest/v1/health_metrics_forecast?user_id=eq.\(userId)&target_date=gte.\(cutoff)&order=target_date.asc&limit=\(days)&select=target_date,horizon_days,hrv_avg_p10,hrv_avg_p50,hrv_avg_p90,recovery_score_p10,recovery_score_p50,recovery_score_p90,resting_hr_p50,sleep_hours_p50,cognitive_capacity_p50,model_name"
            guard let url = URL(string: urlStr) else { return [] }
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await session.data(for: req)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            return rows.compactMap { row in
                guard let dateStr = row["target_date"] as? String else { return nil }
                return ForecastDay(
                    targetDate: dateStr,
                    horizonDays: row["horizon_days"] as? Int ?? 1,
                    hrvP10: row["hrv_avg_p10"] as? Double,
                    hrvP50: row["hrv_avg_p50"] as? Double,
                    hrvP90: row["hrv_avg_p90"] as? Double,
                    recoveryP10: row["recovery_score_p10"] as? Double,
                    recoveryP50: row["recovery_score_p50"] as? Double,
                    recoveryP90: row["recovery_score_p90"] as? Double,
                    restingHrP50: row["resting_hr_p50"] as? Double,
                    sleepHoursP50: row["sleep_hours_p50"] as? Double,
                    cognitiveP50: row["cognitive_capacity_p50"] as? Double,
                    modelName: row["model_name"] as? String
                )
            }
        } catch {
            log("fetchForecast error: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetches the strongest causal edges from the latest PCMCI fit.
    /// Populated weekly by scripts/fit-pcmci-causal-graph.py via Routine.
    /// Sorted by |effect_size| × confidence descending.
    func fetchTopCausalEdges(limit: Int = 12) async -> [CausalEdge] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }

            // Use causal_graph_latest view (auto-filters to most recent fit)
            let urlStr = "\(baseURL)/rest/v1/causal_graph_latest?user_id=eq.\(userId)&order=effect_size.desc.nullslast&limit=\(limit * 2)&select=cause_var,effect_var,lag_days,effect_size,p_value,confidence,n_samples"
            guard let url = URL(string: urlStr) else { return [] }
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await session.data(for: req)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            let edges: [CausalEdge] = rows.compactMap { row in
                guard
                    let cause = row["cause_var"] as? String,
                    let effect = row["effect_var"] as? String
                else { return nil }
                return CausalEdge(
                    causeVar: cause,
                    effectVar: effect,
                    lagDays: row["lag_days"] as? Int ?? 0,
                    effectSize: row["effect_size"] as? Double ?? 0,
                    pValue: row["p_value"] as? Double ?? 1.0,
                    confidence: row["confidence"] as? Double ?? 0,
                    nSamples: row["n_samples"] as? Int ?? 0
                )
            }
            // Re-rank by |effect_size| × confidence and keep top N
            let ranked = edges.sorted { (abs($0.effectSize) * $0.confidence) > (abs($1.effectSize) * $1.confidence) }
            return Array(ranked.prefix(limit))
        } catch {
            log("fetchTopCausalEdges error: \(error.localizedDescription)")
            return []
        }
    }

    /// Marks a nudge's metadata with an iOS-delivery flag. NOT mandatory — the
    /// dedup guard in NotificationListener is our real source of truth.
    /// Kept as best-effort audit trail.
    func markNudgeDelivered(id: String) async throws {
        try await ensureAuth()
        guard let token = accessToken else { return }

        // v165 — an RPC, not a PATCH. PATCHing "metadata" REPLACED the whole jsonb
        // and destroyed `kind` and `session_id`: hangry_guardrail_check dedups on
        // metadata->>'kind', so the same nudge re-fired 4x in one day, and
        // NotificationListener lost the kind='smart_wake' buzzer escalation.
        let urlStr = "\(baseURL)/rest/v1/rpc/mark_nudge_delivered"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "p_nudge_id": id,
            "p_delivered_at": ISO8601DateFormatter().string(from: Date())
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        _ = try? await session.data(for: request)
    }
}

// MARK: - Personal AI Stack Data Models

/// Live `current_state` row — refreshed by Postgres trigger on every BLE sample.
/// HMM state name comes from the nightly fit (scripts/fit-hmm-states.py).
struct CurrentStateData {
    let hmmState: String?
    let hmmStateId: Int?
    let hr: Int?
    let hrvRmssd: Double?
    let cognitiveCapacity: Int?
    let cognitiveLabel: String?
    let readiness: String?
    let illnessRisk: Double?
    let activityState: String?
    let baselineHRV: Double?
    let baselineRHR: Int?
    let strapConnected: Bool
    let lastBleSampleAt: Date?
    let updatedAt: Date?

    /// Minutes since last BLE sample — used to detect stale state.
    var minutesSinceLastSample: Int? {
        guard let last = lastBleSampleAt else { return nil }
        return Int(Date().timeIntervalSince(last) / 60)
    }

    /// True if HMM state is fresh enough to display (< 30 min old).
    var isLive: Bool {
        guard let mins = minutesSinceLastSample else { return false }
        return mins < 30
    }
}

/// One day of zero-shot forecast (Chronos / ETS fallback). 7 rows per refit.
/// Populated nightly by scripts/forecast-health-metrics.py via Routine.
struct ForecastDay {
    let targetDate: String   // "YYYY-MM-DD"
    let horizonDays: Int     // 1..7
    let hrvP10: Double?
    let hrvP50: Double?
    let hrvP90: Double?
    let recoveryP10: Double?
    let recoveryP50: Double?
    let recoveryP90: Double?
    let restingHrP50: Double?
    let sleepHoursP50: Double?
    let cognitiveP50: Double?
    let modelName: String?

    /// Display label for the day ("Tomorrow", "Wed", etc.).
    var shortLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: targetDate) else { return targetDate }

        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let weekday = DateFormatter()
        weekday.dateFormat = "EEE"
        return weekday.string(from: d)
    }
}

/// One PCMCI-discovered causal edge: cause → effect at lag N days.
/// Populated weekly by scripts/fit-pcmci-causal-graph.py via Routine.
struct CausalEdge {
    let causeVar: String
    let effectVar: String
    let lagDays: Int
    let effectSize: Double
    let pValue: Double
    let confidence: Double
    let nSamples: Int

    /// Strength × confidence — used for ranking.
    var rank: Double { abs(effectSize) * confidence }

    /// Human-readable description: "alcohol → recovery (next day)"
    var displayText: String {
        let cause = humanize(causeVar)
        let effect = humanize(effectVar)
        let lag = lagDays == 0 ? "same day" : (lagDays == 1 ? "next day" : "+\(lagDays)d")
        let sign = effectSize >= 0 ? "↑" : "↓"
        return "\(cause) \(sign) \(effect) (\(lag))"
    }

    private func humanize(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: "act_", with: "")
                   .replacingOccurrences(of: "_", with: " ")
        return s
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Foods Extension (merged from LucidFoods SupabaseClient)

extension SupabaseClient {

    // MARK: - Auto-login (Foods pattern)

    /// Seeds UserDefaults with CI-injected credentials if not yet set, then signs in.
    /// Safe to call on every launch — idempotent, non-blocking.
    func signInIfNeeded() async {
        let filled = Self.prefilledEmail
        let filledPass = Self.prefilledPassword
        guard filled != "BUILD_EMAIL", filledPass != "BUILD_PASSWORD" else { return }
        if UserDefaults.standard.string(forKey: "lucidhealth_email")?.isEmpty ?? true {
            UserDefaults.standard.set(filled, forKey: "lucidhealth_email")
        }
        if UserDefaults.standard.string(forKey: "lucidhealth_password")?.isEmpty ?? true {
            UserDefaults.standard.set(filledPass, forKey: "lucidhealth_password")
        }
        guard !isAuthenticated else { return }
        try? await ensureAuth()
    }

    // MARK: - Re-auth helper for foods authed requests

    private func authedRequest(_ req: URLRequest) async throws -> (Data, URLResponse) {
        try await ensureAuth()
        var r = req
        if let token = accessToken {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        r.setValue(anonKey, forHTTPHeaderField: "apikey")
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 401 = no/invalid JWT. 403 from PostgREST/Storage often means JWT was
        // parsed but stale (auth.uid() returns NULL → RLS denies). Both are
        // recoverable by force-refreshing the JWT. Previously only 401 was
        // retried, which left food-photo uploads + food_entries inserts
        // returning 403 to the user when the iOS token expired in-flight.
        if code == 401 || code == 403 {
            accessToken = nil
            tokenExpiry = nil
            try await ensureAuth()
            var r2 = req
            if let token = accessToken { r2.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            r2.setValue(anonKey, forHTTPHeaderField: "apikey")
            return try await session.data(for: r2)
        }
        return (data, resp)
    }

    // MARK: - Food Entries

    func saveFoodEntry(_ entry: FoodEntry) async throws -> FoodEntry {
        let url = URL(string: "\(baseURL)/rest/v1/food_entries")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(entry)

        let (data, response) = try await authedRequest(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else {
            throw NSError(domain: "Supabase", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([FoodEntry].self, from: data)
        guard let saved = entries.first else { throw NSError(domain: "Supabase", code: 0) }
        return saved
    }

    func fetchRecentFoodEntries(limit: Int = 20) async throws -> [FoodEntry] {
        var comps = URLComponents(string: "\(baseURL)/rest/v1/food_entries")!
        comps.queryItems = [
            URLQueryItem(name: "order", value: "captured_at.desc"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await authedRequest(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else {
            throw NSError(domain: "Supabase", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Fast path: whole-array decode.
        if let all = try? decoder.decode([FoodEntry].self, from: data) {
            return all
        }
        // Tolerant fallback: one malformed row (e.g. gemini_raw_json stored as a
        // jsonb OBJECT instead of a String) used to throw for the ENTIRE list →
        // "Load failed" on every refresh while cached rows still showed. Decode
        // row-by-row and skip only the bad ones so a single shape-drift row can
        // never blank the food list again.
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "Supabase", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "food_entries: unexpected payload shape"])
        }
        var out: [FoodEntry] = []
        out.reserveCapacity(rows.count)
        for obj in rows {
            guard let rowData = try? JSONSerialization.data(withJSONObject: obj),
                  let entry = try? decoder.decode(FoodEntry.self, from: rowData) else { continue }
            out.append(entry)
        }
        return out
    }

    // MARK: - Food Favorites

    /// User's saved meals/drinks, most-relevant first (manual sort, then most-logged).
    func fetchFavorites() async throws -> [FoodFavorite] {
        var comps = URLComponents(string: "\(baseURL)/rest/v1/food_favorites")!
        comps.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "order", value: "sort_order.asc,times_logged.desc")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await authedRequest(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else {
            throw NSError(domain: "Supabase", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }
        let decoder = JSONDecoder()
        if let all = try? decoder.decode([FoodFavorite].self, from: data) { return all }
        // Tolerant fallback: skip a single shape-drift row instead of blanking the bar.
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [FoodFavorite] = []
        for obj in rows {
            guard let rowData = try? JSONSerialization.data(withJSONObject: obj),
                  let fav = try? decoder.decode(FoodFavorite.self, from: rowData) else { continue }
            out.append(fav)
        }
        return out
    }

    /// Scale a saved meal to the portion actually eaten. Saving the same dish
    /// twice at two sizes is how "Fusilli" ended up as two favorites 884 kcal
    /// apart — one recipe times a fraction is the fix.
    static func scale(_ items: [DetectedItem], by f: Double) -> [DetectedItem] {
        guard f != 1.0 else { return items }
        return items.map { i in
            var s = i
            s.grams = Int((Double(i.grams) * f).rounded())
            s.kcal = Int((Double(i.kcal) * f).rounded())
            s.caloriesLow = i.caloriesLow.map { Int((Double($0) * f).rounded()) }
            s.caloriesHigh = i.caloriesHigh.map { Int((Double($0) * f).rounded()) }
            s.proteinG = i.proteinG.map { ($0 * f * 10).rounded() / 10 }
            s.carbsG = i.carbsG.map { ($0 * f * 10).rounded() / 10 }
            s.fatG = i.fatG.map { ($0 * f * 10).rounded() / 10 }
            s.fiberG = i.fiberG.map { ($0 * f * 10).rounded() / 10 }
            return s
        }
    }

    /// One-tap re-log of a saved favorite → a normal food_entries row at `capturedAt`.
    func logFromFavorite(_ fav: FoodFavorite, capturedAt: Date = Date(), scale f: Double = 1.0) async throws -> FoodEntry {
        let scaled = Self.scale(fav.items, by: f)
        let entry = FoodEntry(
            id: nil,
            userId: userId,
            capturedAt: capturedAt,
            photoUrl: nil,
            geminiRawJson: nil,
            items: scaled,
            caption: f == 1.0 ? fav.name : "\(fav.name) · \(FoodFavorite.scaleLabel(f))",
            totalKcal: fav.totalKcal.map { Int((Double($0) * f).rounded()) },
            novaAvg: fav.novaAvg,
            mindScore: fav.mindScore,
            confidence: fav.confidence ?? "high",
            source: "favorite",
            createdAt: nil,
            logQuality: FoodEntry.computeLogQuality(source: "favorite", confidence: fav.confidence, items: scaled)
        )
        let saved = try await saveFoodEntry(entry)
        bumpFavoriteUsage(fav)
        return saved
    }

    /// Persist an existing entry as a reusable favorite.
    func saveFavorite(from entry: FoodEntry, name: String, emoji: String = "🍽️") async throws {
        struct FavoriteInsert: Encodable {
            let user_id: String
            let name: String
            let emoji: String
            let items: [DetectedItem]
            let total_kcal: Int?
            let nova_avg: Double?
            let mind_score: Int?
            let confidence: String?
            let source: String
            let sort_order: Int
        }
        let payload = FavoriteInsert(
            user_id: userId, name: name, emoji: emoji, items: entry.items,
            total_kcal: entry.totalKcal, nova_avg: entry.novaAvg, mind_score: entry.mindScore,
            confidence: entry.confidence, source: "manual", sort_order: 10
        )
        let url = URL(string: "\(baseURL)/rest/v1/food_favorites")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await authedRequest(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else {
            throw NSError(domain: "Supabase", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }
    }

    func deleteFavorite(id: String) async -> Bool {
        do {
            let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            let url = URL(string: "\(baseURL)/rest/v1/food_favorites?id=eq.\(safeId)&user_id=eq.\(userId)")!
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            let (_, response) = try await authedRequest(req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
        } catch { return false }
    }

    /// Fire-and-forget: bump times_logged + last_logged_at so the bar self-sorts. Never throws.
    private func bumpFavoriteUsage(_ fav: FoodFavorite) {
        guard let id = fav.id?.uuidString else { return }
        Task {
            do {
                let url = URL(string: "\(baseURL)/rest/v1/rpc/bump_food_favorite")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["p_id": id])
                _ = try await authedRequest(req)
            } catch {}
        }
    }

    // MARK: - Photo Upload

    func uploadFoodPhoto(_ data: Data, filename: String) async throws -> String {
        let path = "\(userId)/\(filename)"
        let url = URL(string: "\(baseURL)/storage/v1/object/food-photos/\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        // BUGFIX (2026-05-10): header value was literally "x-upsert: true" — the
        // header NAME got duplicated into the value, which Supabase Storage
        // accepted as a no-op string. With unique UUID filenames we never need
        // upsert anyway; remove the header entirely. Eliminates one possible
        // 403 source from "x-upsert means UPDATE which RLS denies" path.
        req.httpBody = data

        let (data2, response) = try await authedRequest(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else {
            let bodyStr = String(data: data2, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "Supabase", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Photo upload HTTP \(status): \(bodyStr.prefix(200))"])
        }

        return "\(baseURL)/storage/v1/object/public/food-photos/\(path)"
    }

    // MARK: - Quick Log

    func saveQuickLog(_ item: QuickLogItem) async throws -> FoodEntry {
        let detectedItem = DetectedItem(name: item.name, grams: 0, kcal: item.kcal,
                                        novaClass: item.novaClass, mindTags: item.mindTags)
        let entry = FoodEntry(
            id: nil,
            userId: userId,
            capturedAt: Date(),
            photoUrl: nil,
            geminiRawJson: nil,
            items: [detectedItem],
            caption: item.name,
            totalKcal: item.kcal,
            novaAvg: Double(item.novaClass),
            mindScore: nil,
            confidence: "quick_log",
            source: "quick_log",
            createdAt: nil,
            logQuality: FoodEntry.computeLogQuality(source: "quick_log", confidence: "quick_log", items: [detectedItem])
        )
        return try await saveFoodEntry(entry)
    }

    // MARK: - Client Error Logging

    /// Fire-and-forget: record a client-side failure (analyze/save/upload) to the
    /// server `client_error_log` so failures are diagnosable instead of vanishing.
    /// Never throws, never blocks the caller.
    func logClientError(area: String, message: String, context: String? = nil) {
        Task {
            do {
                try await ensureAuth()
                guard let token = accessToken else { return }
                var body: [String: Any] = ["p_area": area, "p_message": message]
                if let context { body["p_context"] = context }
                let url = URL(string: "\(baseURL)/rest/v1/rpc/log_client_error")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(anonKey, forHTTPHeaderField: "apikey")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 8
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                _ = try? await session.data(for: req)
            } catch { /* swallow — logging must never break the flow */ }
        }
    }

    // MARK: - Body Profile + Meal HR

    /// Upsert the user's body profile so the SERVER food-analysis prompts can
    /// calibrate portion sizes to THIS person (weight is the single biggest
    /// factor in intake estimation). Fire-and-forget; failures are logged only.
    func saveBodyProfile(weightKg: Double, heightCm: Double?, age: Int?, sex: String?) async {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return }
            var body: [String: Any] = ["user_id": userId, "weight_kg": weightKg,
                                       "updated_at": ISO8601DateFormatter().string(from: Date())]
            if let heightCm { body["height_cm"] = heightCm }
            if let age { body["age"] = age }
            if let sex { body["sex"] = sex }
            let url = URL(string: "\(baseURL)/rest/v1/user_body_profile?on_conflict=user_id")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await session.data(for: req)
            log("Body profile saved (\(Int(weightKg))kg) → HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            log("saveBodyProfile error: \(error.localizedDescription)")
        }
    }

    /// Log a blood-pressure reading (systolic/diastolic/pulse + optional weight)
    /// with an event-context tag so the analysis layer can correlate BP against
    /// caffeine / alcohol / rides / stress. When a weigh-in rides along it also
    /// updates the canonical user_body_profile weight. Fire-and-forget.
    func saveBPReading(systolic: Int, diastolic: Int, pulse: Int?, weightKg: Double?,
                       context: String, notes: String? = nil) async {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return }
            var body: [String: Any] = [
                "user_id": userId,
                "systolic": systolic,
                "diastolic": diastolic,
                "context": context,
                "measured_at": ISO8601DateFormatter().string(from: Date())
            ]
            if let pulse { body["pulse"] = pulse }
            if let weightKg { body["weight_kg"] = weightKg }
            if let notes { body["notes"] = notes }
            let url = URL(string: "\(baseURL)/rest/v1/blood_pressure_readings")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await session.data(for: req)
            log("BP saved (\(systolic)/\(diastolic)) → HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
            if let weightKg { await saveBodyProfile(weightKg: weightKg, heightCm: nil, age: nil, sex: nil) }
        } catch {
            log("saveBPReading error: \(error.localizedDescription)")
        }
    }

    /// Post-prandial HR response for a logged meal (server meal_hr_response RPC).
    /// Returns the raw dict: verdict, pre_hr, post_mean, adj_bump_bpm, note.
    func fetchMealHrResponse(mealId: String) async -> [String: Any]? {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return nil }
            let body: [String: Any] = ["p_user_id": userId, "p_meal_id": mealId]
            let url = URL(string: "\(baseURL)/rest/v1/rpc/meal_hr_response")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }

    // MARK: - Barcode Entry

    /// Save a barcode-scanned product as a food entry.
    /// - Parameter gramsOverride: when nil, use product.servingSizeG ?? 100. When
    ///   provided, scales calories proportionally — fixes the v70 bug where
    ///   the saved total_kcal was kcal-per-100g (not for the chosen portion),
    ///   and the gram amount silently defaulted to 100g regardless of what the
    ///   user actually consumed (e.g. whiskey shows kcal=0 for "100g" when the
    ///   real intake was 88g of a 250 kcal/100ml product).
    func saveBarcodeEntry(product: OpenFoodFactsProduct, gramsOverride: Int? = nil) async throws -> FoodEntry {
        let encoder = JSONEncoder()
        let productJson = (try? encoder.encode(product)).flatMap { String(data: $0, encoding: .utf8) }
        let grams = gramsOverride ?? product.servingSizeG ?? 100
        let kcalPer100g = product.kcalPer100g ?? 0
        let scaledKcal = Int((kcalPer100g * Double(grams)) / 100.0)
        let novaClass = product.novaGroup ?? 1
        let detectedItem = DetectedItem(name: product.productName ?? "Unknown",
                                        grams: grams,
                                        kcal: scaledKcal,
                                        novaClass: novaClass,
                                        mindTags: [])
        let entry = FoodEntry(
            id: nil,
            userId: userId,
            capturedAt: Date(),
            photoUrl: product.imageURL,
            geminiRawJson: productJson,
            items: [detectedItem],
            caption: product.productName,
            totalKcal: scaledKcal,
            novaAvg: Double(novaClass),
            mindScore: nil,
            confidence: "barcode",
            source: "barcode",
            createdAt: nil,
            logQuality: FoodEntry.computeLogQuality(source: "barcode", confidence: "barcode", items: [detectedItem])
        )
        return try await saveFoodEntry(entry)
    }

    /// Build a DetectedItem from an Open Food Facts product WITHOUT saving —
    /// used by the meal builder to add a barcoded ingredient to a draft.
    func barcodeItem(from product: OpenFoodFactsProduct, grams: Int? = nil) -> DetectedItem {
        let g = grams ?? product.servingSizeG ?? 100
        let kcal = Int(((product.kcalPer100g ?? 0) * Double(g)) / 100.0)
        return DetectedItem(name: product.productName ?? "Unknown", grams: g, kcal: kcal,
                            novaClass: product.novaGroup ?? 4, mindTags: [])
    }

    // MARK: - Supplements (v155)

    /// A shelf row: the product plus how much of it went in today.
    struct SupplementShelfItem: Identifiable, Hashable {
        let id: String
        let name: String
        let brand: String?
        let form: String
        let servingUnit: String
        let actives: [String: Double]
        let targetDaily: Double?
        let takenToday: Double
        let lastTaken: Date?

        /// "5 g creatine_g" style summary for one serving.
        var doseSummary: String {
            actives.sorted { $0.key < $1.key }
                .map { "\(Self.trim($0.value)) \($0.key.replacingOccurrences(of: "_", with: " "))" }
                .joined(separator: " · ")
        }

        static func trim(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
    }

    /// The number that gives food logging a reason to exist (v156).
    struct CutStatus {
        let tdee: Int
        let bmr: Int
        let activeKcal: Int
        let deficitTarget: Int
        let targetIntake: Int
        let consumed: Int
        let remaining: Int
        let proteinG: Double
        let proteinTarget: Int
        let nMeals: Int
        let headline: String

        var proteinPct: Double {
            proteinTarget > 0 ? min(proteinG / Double(proteinTarget), 1) : 0
        }
        var intakePct: Double {
            targetIntake > 0 ? min(Double(consumed) / Double(targetIntake), 1) : 0
        }
        var isOver: Bool { remaining < 0 }
    }

    func cutStatus() async throws -> CutStatus? {
        let rows = try await rpcRows("cut_status", ["p_user_id": userId])
        guard let r = rows.first else { return nil }
        func i(_ k: String) -> Int { (r[k] as? NSNumber)?.intValue ?? Int(r[k] as? String ?? "") ?? 0 }
        func d(_ k: String) -> Double { (r[k] as? NSNumber)?.doubleValue ?? Double(r[k] as? String ?? "") ?? 0 }

        return CutStatus(
            tdee: i("tdee"), bmr: i("bmr"), activeKcal: i("active_kcal"),
            deficitTarget: i("deficit_target"), targetIntake: i("target_intake"),
            consumed: i("consumed"), remaining: i("remaining"),
            proteinG: d("protein_g"), proteinTarget: i("protein_target"),
            nMeals: i("n_meals"), headline: r["headline"] as? String ?? ""
        )
    }

    /// POST an RPC and hand back the raw rows.
    private func rpcRows(_ name: String, _ body: [String: Any]) async throws -> [[String: Any]] {
        try await ensureAuth()
        guard let token = accessToken else {
            throw NSError(domain: "Supabase", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let url = URL(string: "\(baseURL)/rest/v1/rpc/\(name)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 300 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            log("\(name) HTTP \(code): \(msg)")
            throw NSError(domain: "Supabase", code: code,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // RETURNS TABLE gives an array of objects; RETURNS uuid gives a bare JSON
        // scalar. Normalise the scalar into a one-key row so callers stay simple.
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let arr = json as? [[String: Any]] { return arr }
        if let obj = json as? [String: Any] { return [obj] }
        if let scalar = json as? String { return [["value": scalar]] }
        return []
    }

    /// v166 — his own 30-night sleep-duration mean and SD, excluding nights the
    /// auto-excluder already flagged as broken. Returns nil when there are too
    /// few clean nights to mean anything; the caller must then not score
    /// deviation at all rather than invent a baseline.
    func fetchSleepDurationBaseline(days: Int = 30) async -> (mean: Double, sd: Double, nights: Int)? {
        do {
            let rows = try await rpcRows("sleep_duration_baseline", ["p_days": days])
            guard let row = rows.first else { return nil }

            // numeric comes back as a JSON number or a string depending on the
            // PostgREST build, so accept both rather than silently reading zero.
            func num(_ key: String) -> Double {
                if let d = row[key] as? Double { return d }
                if let i = row[key] as? Int { return Double(i) }
                if let s = row[key] as? String { return Double(s) ?? 0 }
                return 0
            }

            let nights = Int(num("n_nights"))
            let mean = num("mean_hours")
            guard nights >= 14, mean > 0 else { return nil }
            return (mean, num("sd_hours"), nights)
        } catch {
            log("sleep_duration_baseline failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Pot (v159) — weigh once at the stove, then eat fractions

    /// One canonical row per thing Fabi actually eats. Server-side, hardcoded,
    /// never re-estimated — which is what makes "does the brand matter?" a
    /// question he no longer has to answer at every meal.
    struct FoodIngredient: Identifiable, Hashable {
        let id: String          // key
        let name: String
        let nameLocal: String?
        let kcal100: Double
        let protein100: Double
        let defaultGrams: Double?
        let unitHint: String?
        let weightBasis: String  // raw | dry | ready | liquid
        let novaClass: Int

        var display: String { nameLocal ?? name }
        /// "weigh raw" / "weigh dry" is the whole trick — raw weight is easier to
        /// measure and survives cooking, water does not.
        var basisNote: String? {
            switch weightBasis {
            case "raw": return "raw"
            case "dry": return "dry"
            case "liquid": return "ml"
            default: return nil
            }
        }
    }

    struct FoodPot: Identifiable {
        let id: String
        let name: String
        let emoji: String?
        let cookedAt: Date
        let remaining: Double
        let totalKcal: Double
        let totalProtein: Double
        let leftKcal: Double
        let leftProtein: Double

        var remainingPct: Int { Int((remaining * 100).rounded()) }
    }

    func fetchIngredients() async throws -> [FoodIngredient] {
        try await ensureAuth()
        guard let token = accessToken else { return [] }
        var comps = URLComponents(string: "\(baseURL)/rest/v1/food_ingredients")!
        comps.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "order", value: "times_used.desc,name.asc")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []

        func d(_ r: [String: Any], _ k: String) -> Double {
            (r[k] as? NSNumber)?.doubleValue ?? Double(r[k] as? String ?? "") ?? 0
        }
        return rows.compactMap { r in
            guard let key = r["key"] as? String, let name = r["name"] as? String else { return nil }
            let def = (r["default_grams"] as? NSNumber)?.doubleValue
                ?? Double(r["default_grams"] as? String ?? "")
            return FoodIngredient(
                id: key, name: name, nameLocal: r["name_local"] as? String,
                kcal100: d(r, "kcal_100"), protein100: d(r, "protein_100"),
                defaultGrams: def, unitHint: r["unit_hint"] as? String,
                weightBasis: r["weight_basis"] as? String ?? "ready",
                novaClass: (r["nova_class"] as? NSNumber)?.intValue ?? 1
            )
        }
    }

    func openPots() async throws -> [FoodPot] {
        let rows = try await rpcRows("food_batches_open", ["p_user_id": userId])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        func d(_ r: [String: Any], _ k: String) -> Double {
            (r[k] as? NSNumber)?.doubleValue ?? Double(r[k] as? String ?? "") ?? 0
        }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
            let raw = r["cooked_at"] as? String ?? ""
            let when = iso.date(from: raw) ?? isoPlain.date(from: raw) ?? Date()
            return FoodPot(
                id: id, name: name, emoji: r["emoji"] as? String, cookedAt: when,
                remaining: d(r, "remaining"), totalKcal: d(r, "total_kcal"),
                totalProtein: d(r, "total_protein"),
                leftKcal: d(r, "left_kcal"), leftProtein: d(r, "left_protein")
            )
        }
    }

    /// items: [(ingredient key, grams)]
    @discardableResult
    func createPot(name: String, emoji: String?, items: [(String, Double)]) async throws -> String? {
        let payload = items.map { ["key": $0.0, "grams": $0.1] as [String: Any] }
        var body: [String: Any] = ["p_name": name, "p_items": payload]
        if let emoji { body["p_emoji"] = emoji }
        let rows = try await rpcRows("food_batch_create", body)
        return rows.first?["id"] as? String
    }

    @discardableResult
    func servePot(id: String, fraction: Double, at date: Date = Date()) async throws -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let rows = try await rpcRows("food_batch_serve", [
            "p_batch_id": id,
            "p_fraction": fraction,
            "p_captured_at": iso.string(from: date)
        ])
        return rows.first?["value"] as? String ?? rows.first?["id"] as? String
    }

    func supplementShelf() async throws -> [SupplementShelfItem] {
        let rows = try await rpcRows("supplement_shelf", ["p_user_id": userId])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return rows.compactMap { r in
            guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
            var actives: [String: Double] = [:]
            if let raw = r["actives"] as? [String: Any] {
                for (k, v) in raw {
                    if let d = v as? Double { actives[k] = d }
                    else if let n = v as? NSNumber { actives[k] = n.doubleValue }
                    else if let s = v as? String, let d = Double(s) { actives[k] = d }
                }
            }
            let taken = (r["taken_today"] as? NSNumber)?.doubleValue
                ?? Double(r["taken_today"] as? String ?? "0") ?? 0
            let target = (r["target_daily"] as? NSNumber)?.doubleValue
                ?? Double(r["target_daily"] as? String ?? "")

            return SupplementShelfItem(
                id: id,
                name: name,
                brand: r["brand"] as? String,
                form: r["form"] as? String ?? "capsule",
                servingUnit: r["serving_unit"] as? String ?? "capsule",
                actives: actives,
                targetDaily: target,
                takenToday: taken,
                lastTaken: (r["last_taken"] as? String).flatMap { iso.date(from: $0) }
            )
        }
    }

    @discardableResult
    func logSupplement(productId: String, servings: Double = 1, source: String = "tap") async throws -> String? {
        let rows = try await rpcRows("log_supplement", [
            "p_user_id": userId,
            "p_product_id": productId,
            "p_servings": servings,
            "p_source": source,
        ])
        return rows.first?.values.first as? String
    }

    /// Save a scanned/photographed product to the shelf. `actives` is free-form
    /// because German supplement labels do not agree on a schema.
    @discardableResult
    func upsertSupplementProduct(name: String, barcode: String? = nil, brand: String? = nil,
                                 form: String = "capsule", servingUnit: String = "capsule",
                                 servingSize: Double = 1, actives: [String: Double] = [:],
                                 source: String = "manual") async throws -> String? {
        var body: [String: Any] = [
            "p_user_id": userId,
            "p_name": name,
            "p_form": form,
            "p_serving_unit": servingUnit,
            "p_serving_size": servingSize,
            "p_actives": actives,
            "p_source": source,
        ]
        if let barcode { body["p_barcode"] = barcode }
        if let brand { body["p_brand"] = brand }
        let rows = try await rpcRows("upsert_supplement_product", body)
        return rows.first?.values.first as? String
    }

    /// Save a multi-source meal built from several items (barcode + described +
    /// photo) as ONE food_entry (source "combined").
    func saveCombinedMeal(items: [DetectedItem], caption: String, capturedAt: Date = Date()) async throws -> FoodEntry {
        let totalKcal = items.reduce(0) { $0 + $1.kcal }
        let novaVals = items.map { Double($0.novaClass) }
        let novaAvg = novaVals.isEmpty ? 1.0 : novaVals.reduce(0, +) / Double(novaVals.count)
        let entry = FoodEntry(
            id: nil, userId: userId, capturedAt: capturedAt, photoUrl: nil, geminiRawJson: nil,
            items: items,
            caption: caption.isEmpty ? items.map(\.name).joined(separator: ", ") : caption,
            totalKcal: totalKcal, novaAvg: novaAvg, mindScore: nil,
            confidence: "combined", source: "combined", createdAt: nil,
            logQuality: FoodEntry.computeLogQuality(source: "combined", confidence: "combined", items: items)
        )
        return try await saveFoodEntry(entry)
    }

    // MARK: - Recovery for Foods (renamed to avoid collision with Bridge's fetchLastScores)

    func fetchLatestRecoveryForFoods() async throws -> Double? {
        var comps = URLComponents(string: "\(baseURL)/rest/v1/health_metrics")!
        comps.queryItems = [
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "select", value: "recovery_score")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await authedRequest(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else { return nil }

        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = arr.first,
           let score = first["recovery_score"] as? Double {
            return score
        }
        return nil
    }

    // MARK: - Recovery Trend (14-day sparkline under HeroRecoveryRing)

    /// Last `days` server recovery scores, oldest → newest, NULL days dropped.
    /// Powers RecoveryTrendStrip so the (genuinely 9-100 swinging) score's
    /// movement is visible instead of looking "stuck" at one number.
    func fetchRecoveryTrend(days: Int = 14) async -> [Double] {
        do {
            try await ensureAuth()
            guard accessToken != nil else { return [] }
            var comps = URLComponents(string: "\(baseURL)/rest/v1/health_metrics")!
            comps.queryItems = [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "recovery_score", value: "not.is.null"),
                URLQueryItem(name: "order", value: "metric_date.desc"),
                URLQueryItem(name: "limit", value: "\(days)"),
                URLQueryItem(name: "select", value: "metric_date,recovery_score")
            ]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await authedRequest(req)
            guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { return [] }
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            // server gave newest-first; reverse to oldest → newest for the strip
            let scores = arr.reversed().compactMap { row -> Double? in
                (row["recovery_score"] as? NSNumber)?.doubleValue
            }
            return scores
        } catch {
            return []
        }
    }

    // MARK: - v104 BLE Sync Cursor (server-held, replaces UserDefaults.lastSync)

    /// Server's authoritative answer to "what's the latest BLE sample we have
    /// from this strap?". Powers the v104 architectural fix for the repeating
    /// backfill regression — see research_report_20260521_whoop_ble_backfill.md.
    struct BLESyncCursor {
        let lastSeq: Int64?
        let lastRecordedAt: Date?
        let minutesSinceLast: Double?  // nil if no rows ever
    }

    /// Latest LIVE BLE sample (`source = 'whoop_ble'`) recorded STRICTLY BEFORE
    /// `before` (the moment this connection started).
    ///
    /// v138 — why this no longer reads `v_ble_sync_cursor`, and why the `before`
    /// cutoff is load-bearing:
    ///   pushReading() sends no `recorded_at`, so the DB stamps now() on insert.
    ///   A single stray HR packet during the 2.5-3.5s reconnect handshake window
    ///   therefore lands a row at recorded_at ≈ now — which would poison
    ///   MAX(recorded_at) and make a real 7h overnight gap look 0 min old (the
    ///   exact silent-skip regression: May 7 / May 21 / Jun 13).
    ///   Only data captured BEFORE we connected can answer "how stale were we when
    ///   we reconnected?", so we query realtime_health directly with
    ///   recorded_at < before. We also scope to source='whoop_ble' (live stream)
    ///   so recovered backfill/history rows from a PRIOR gap-fill can't mask the
    ///   true live-stream boundary; the minute-level dedup on download makes the
    ///   resulting conservative re-check cheap.
    ///   `minutes_since_last` is computed client-side (now − server sample); only
    ///   the STORED last-sync timestamp is untrustworthy, the wall clock is fine.
    func fetchSyncCursor(before: Date) async -> BLESyncCursor? {
        do {
            try await ensureAuth()
            guard accessToken != nil else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let beforeStr = iso.string(from: before)
            var comps = URLComponents(string: "\(baseURL)/rest/v1/realtime_health")!
            comps.queryItems = [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "source", value: "eq.whoop_ble"),
                URLQueryItem(name: "heart_rate", value: "gt.20"),
                URLQueryItem(name: "recorded_at", value: "lt.\(beforeStr)"),
                URLQueryItem(name: "select", value: "recorded_at,device_seq"),
                URLQueryItem(name: "order", value: "recorded_at.desc"),
                URLQueryItem(name: "limit", value: "1")
            ]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await authedRequest(req)
            guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { return nil }
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = arr.first else {
                // HTTP OK but no live rows before connect time = genuine first sync
                // (or strap offline longer than retention). nil fields tell the
                // caller "backfill from scratch", never "skip".
                return BLESyncCursor(lastSeq: nil, lastRecordedAt: nil, minutesSinceLast: nil)
            }
            let lastSeq = (row["device_seq"] as? NSNumber)?.int64Value
            let lastRecordedAt: Date? = {
                guard let s = row["recorded_at"] as? String else { return nil }
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: s) { return d }
                f.formatOptions = [.withInternetDateTime]
                return f.date(from: s)
            }()
            let mins: Double? = lastRecordedAt.map { Date().timeIntervalSince($0) / 60.0 }
            return BLESyncCursor(lastSeq: lastSeq, lastRecordedAt: lastRecordedAt, minutesSinceLast: mins)
        } catch {
            return nil
        }
    }
}

// MARK: - Workouts (v174) + intake back-solve (v173)
//
// Both keep the same bargain as everything else in this file: the server owns
// the arithmetic, the app owns the pixels. Calorie calibration, heart-rate
// zones and the weight-trend regression all live in Postgres, so changing any
// of them is a migration, not an App Store review.

extension SupabaseClient {

    /// The picker is server-driven on purpose — adding "rowing" later is an
    /// INSERT into workout_types, not a new build.
    struct WorkoutType: Identifiable, Hashable {
        let id: String              // key
        let label: String
        let emoji: String
        let category: String
        let tracksDistance: Bool
        let tracksLoad: Bool
    }

    struct WorkoutSession: Identifiable {
        let id: String
        let typeKey: String
        let label: String
        let emoji: String
        let startedAt: Date
        let tracksDistance: Bool
        let tracksLoad: Bool
    }

    struct WorkoutLive {
        let elapsedSec: Int
        let hrNow: Int?
        let hrAvg: Int?
        let hrPeak: Int?
        let kcal: Int
        let zone: String
    }

    struct WorkoutSummary {
        let durationSec: Int
        let distanceKm: Double?
        let kcal: Int
        /// "hr" when the strap carried the ride, "estimate" when the resistance
        /// dial had to stand in for it. Worth showing — they are not equal.
        let kcalSource: String
        let hrAvg: Int?
        let headline: String
    }

    struct WorkoutRecord: Identifiable {
        let id: String
        let label: String
        let emoji: String
        let startedAt: Date
        let durationSec: Int
        let distanceKm: Double?
        let loadLevel: Int?
        let rpe: Int?
        let hrAvg: Int?
        let kcal: Int
        let kcalSource: String
        let kmh: Double?

        var minutes: Int { max(1, durationSec / 60) }
    }

    struct IntakeBacksolve {
        let nWeighins: Int
        let spanDays: Int
        let firstKg: Double?
        let lastKg: Double?
        let trendKgPerWeek: Double?
        let avgTdee: Int
        let estIntake: Int?
        let estBalance: Int?
        /// none | low | ok | good — decides whether a number is shown at all.
        let confidence: String
        let headline: String

        var hasNumber: Bool { estIntake != nil && confidence != "none" }
    }

    // MARK: Row parsing
    // PostgREST returns numeric as a JSON number on some builds and a string on
    // others. Reading only one shape silently yields zero.

    private func wNum(_ r: [String: Any], _ k: String) -> Double? {
        if let d = r[k] as? Double { return d }
        if let n = r[k] as? NSNumber { return n.doubleValue }
        if let s = r[k] as? String { return Double(s) }
        return nil
    }
    private func wInt(_ r: [String: Any], _ k: String) -> Int? {
        if let d = wNum(r, k) { return Int(d) }
        return nil
    }
    private func wDate(_ r: [String: Any], _ k: String) -> Date? {
        guard let s = r[k] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func workoutSession(from r: [String: Any]) -> WorkoutSession? {
        guard let id = r["id"] as? String, let started = wDate(r, "started_at") else { return nil }
        return WorkoutSession(
            id: id,
            typeKey: r["type_key"] as? String ?? "",
            label: r["label"] as? String ?? "Activity",
            emoji: r["emoji"] as? String ?? "\u{1F4AA}",
            startedAt: started,
            tracksDistance: r["tracks_distance"] as? Bool ?? false,
            tracksLoad: r["tracks_load"] as? Bool ?? false
        )
    }

    // MARK: Calls

    func fetchWorkoutTypes() async -> [WorkoutType] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }
            var comps = URLComponents(string: "\(baseURL)/rest/v1/workout_types")!
            comps.queryItems = [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "active", value: "eq.true"),
                URLQueryItem(name: "order", value: "sort_order.asc")
            ]
            var req = URLRequest(url: comps.url!)
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            return rows.compactMap { r -> WorkoutType? in
                guard let key = r["key"] as? String else { return nil }
                return WorkoutType(
                    id: key,
                    label: r["label"] as? String ?? key,
                    emoji: r["emoji"] as? String ?? "\u{1F4AA}",
                    category: r["category"] as? String ?? "cardio",
                    tracksDistance: r["tracks_distance"] as? Bool ?? false,
                    tracksLoad: r["tracks_load"] as? Bool ?? false
                )
            }
        } catch {
            log("fetchWorkoutTypes failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Starting twice returns the session already running rather than failing —
    /// a double tap on Start is a fat finger, not a second workout.
    func workoutStart(type: String) async -> WorkoutSession? {
        do {
            let rows = try await rpcRows("workout_start", ["p_type": type, "p_user_id": userId])
            if let first = rows.first { return workoutSession(from: first) }
            return nil
        } catch {
            log("workout_start failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Survives the app being backgrounded or killed mid-ride.
    func workoutOpen() async -> WorkoutSession? {
        do {
            let rows = try await rpcRows("workout_open", ["p_user_id": userId])
            if let first = rows.first { return workoutSession(from: first) }
            return nil
        } catch { return nil }
    }

    func workoutLive(id: String) async -> WorkoutLive? {
        do {
            let rows = try await rpcRows("workout_live", ["p_id": id])
            guard let r = rows.first else { return nil }
            return WorkoutLive(
                elapsedSec: wInt(r, "elapsed_sec") ?? 0,
                hrNow: wInt(r, "hr_now"),
                hrAvg: wInt(r, "hr_avg"),
                hrPeak: wInt(r, "hr_peak"),
                kcal: wInt(r, "kcal") ?? 0,
                zone: r["zone"] as? String ?? ""
            )
        } catch { return nil }
    }

    func workoutFinish(id: String, distanceKm: Double?, load: Int?, rpe: Int?, notes: String? = nil) async -> WorkoutSummary? {
        var body: [String: Any] = ["p_id": id]
        if let d = distanceKm { body["p_distance_km"] = d }
        if let l = load { body["p_load"] = l }
        if let r = rpe { body["p_rpe"] = r }
        if let n = notes, !n.isEmpty { body["p_notes"] = n }
        do {
            let rows = try await rpcRows("workout_finish", body)
            guard let r = rows.first else { return nil }
            return WorkoutSummary(
                durationSec: wInt(r, "duration_sec") ?? 0,
                distanceKm: wNum(r, "distance_km"),
                kcal: wInt(r, "kcal") ?? 0,
                kcalSource: r["kcal_source"] as? String ?? "",
                hrAvg: wInt(r, "hr_avg"),
                headline: r["headline"] as? String ?? ""
            )
        } catch {
            log("workout_finish failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Started it, never rode. Deletes rather than storing a four-second ride.
    func workoutCancel(id: String) async {
        _ = try? await rpcRows("workout_cancel", ["p_id": id])
    }

    func workoutRecent(limit: Int = 30) async -> [WorkoutRecord] {
        do {
            let rows = try await rpcRows("workout_recent", ["p_user_id": userId, "p_limit": limit])
            return rows.compactMap { r -> WorkoutRecord? in
                guard let id = r["id"] as? String, let started = wDate(r, "started_at") else { return nil }
                return WorkoutRecord(
                    id: id,
                    label: r["label"] as? String ?? "Activity",
                    emoji: r["emoji"] as? String ?? "\u{1F4AA}",
                    startedAt: started,
                    durationSec: wInt(r, "duration_sec") ?? 0,
                    distanceKm: wNum(r, "distance_km"),
                    loadLevel: wInt(r, "load_level"),
                    rpe: wInt(r, "rpe"),
                    hrAvg: wInt(r, "hr_avg"),
                    kcal: wInt(r, "kcal") ?? 0,
                    kcalSource: r["kcal_source"] as? String ?? "",
                    kmh: wNum(r, "kmh")
                )
            }
        } catch {
            log("workout_recent failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Weight and back-solved intake (v173)

    /// The whole point: one number a morning replaces logging every meal.
    @discardableResult
    func logWeight(kg: Double) async -> Bool {
        do {
            _ = try await rpcRows("log_weight", ["p_kg": kg, "p_user_id": userId])
            return true
        } catch {
            log("log_weight failed: \(error.localizedDescription)")
            return false
        }
    }

    func intakeBacksolve(days: Int = 14) async -> IntakeBacksolve? {
        do {
            let rows = try await rpcRows("intake_backsolve", ["p_user_id": userId, "p_days": days])
            guard let r = rows.first else { return nil }
            return IntakeBacksolve(
                nWeighins: wInt(r, "n_weighins") ?? 0,
                spanDays: wInt(r, "span_days") ?? 0,
                firstKg: wNum(r, "first_kg"),
                lastKg: wNum(r, "last_kg"),
                trendKgPerWeek: wNum(r, "trend_kg_per_week"),
                avgTdee: wInt(r, "avg_tdee") ?? 0,
                estIntake: wInt(r, "est_intake"),
                estBalance: wInt(r, "est_balance"),
                confidence: r["confidence"] as? String ?? "none",
                headline: r["headline"] as? String ?? ""
            )
        } catch {
            log("intake_backsolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Weigh-ins for the trend chart. Reads the table directly rather than an
    /// RPC — it is two columns and no arithmetic.
    func fetchWeightSeries(days: Int = 60) async -> [WeightPoint] {
        do {
            try await ensureAuth()
            guard let token = accessToken else { return [] }
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone(identifier: "Europe/Berlin")
            let since = df.string(from: Date().addingTimeInterval(-Double(days) * 86400))

            var comps = URLComponents(string: "\(baseURL)/rest/v1/body_composition_log")!
            comps.queryItems = [
                URLQueryItem(name: "select", value: "measured_at,weight_kg"),
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "measured_at", value: "gte.\(since)"),
                URLQueryItem(name: "weight_kg", value: "not.is.null"),
                URLQueryItem(name: "order", value: "measured_at.asc")
            ]
            var req = URLRequest(url: comps.url!)
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            return rows.compactMap { r -> WeightPoint? in
                guard let s = r["measured_at"] as? String, let d = df.date(from: s),
                      let kg = wNum(r, "weight_kg") else { return nil }
                return WeightPoint(date: d, kg: kg)
            }
        } catch {
            return []
        }
    }

    struct WeightPoint: Identifiable {
        let date: Date
        let kg: Double
        var id: Date { date }
    }
}
