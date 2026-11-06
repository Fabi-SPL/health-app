import Foundation

/// Service layer for the 4 experimental Whoop-pattern features:
///   - Discord HR broadcast (replaces Pulsoid/HypeRate)
///   - Hue ambient mirror (foundation only)
///   - Spiral alerts log
///   - Coherence drill sessions
///
/// All Supabase CRUD lives here. No business logic — that's in the views.
final class ExperimentalFeaturesService {
    static let shared = ExperimentalFeaturesService()
    private init() {}

    private var baseURL: String { SupabaseClient.shared.baseURL }
    private var anonKey: String { SupabaseClient.shared.anonKey }
    private func ensureAuth() async throws { try await SupabaseClient.shared.ensureAuth() }
    private var accessToken: String? { SupabaseClient.shared.accessToken }
    private var userId: String { SupabaseClient.shared.userId }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Discord broadcast
    // ════════════════════════════════════════════════════════════════

    struct BroadcastSettings: Codable {
        var enabled: Bool
        var discord_webhook: String?
        var show_hr: Bool
        var show_hrv: Bool
        var show_strain: Bool
        var show_state: Bool
        var refresh_seconds: Int
        var custom_label: String?
        var push_count: Int?
        var last_pushed_at: String?
    }

    func fetchBroadcastSettings() async -> BroadcastSettings? {
        do { try await ensureAuth() } catch { return nil }
        guard let token = accessToken else { return nil }
        let urlStr = "\(baseURL)/rest/v1/broadcast_settings?user_id=eq.\(userId)&select=*"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let arr = try JSONDecoder().decode([BroadcastSettings].self, from: data)
            return arr.first
        } catch { return nil }
    }

    func upsertBroadcastSettings(_ s: BroadcastSettings) async -> Bool {
        do { try await ensureAuth() } catch { return false }
        guard let token = accessToken else { return false }
        // v100 — same on_conflict fix as health_metrics. Without explicit
        // on_conflict, settings updates after the first save 409-fail silently.
        let urlStr = "\(baseURL)/rest/v1/broadcast_settings?on_conflict=user_id"
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")

        var body: [String: Any] = [
            "user_id": userId,
            "enabled": s.enabled,
            "show_hr": s.show_hr,
            "show_hrv": s.show_hrv,
            "show_strain": s.show_strain,
            "show_state": s.show_state,
            "refresh_seconds": s.refresh_seconds,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let webhook = s.discord_webhook { body["discord_webhook"] = webhook }
        if let label = s.custom_label { body["custom_label"] = label }
        if s.enabled {
            body["started_at"] = ISO8601DateFormatter().string(from: Date())
            body["push_count"] = 0
            body["discord_message_id"] = NSNull()  // reset so broadcaster posts new message
        }

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
        } catch { return false }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Hue settings (foundation only)
    // ════════════════════════════════════════════════════════════════

    struct HueSettings: Codable {
        var enabled: Bool
        var bridge_ip: String?
        var bridge_token: String?
        var group_id: String?
        var only_after_sundown: Bool
    }

    func fetchHueSettings() async -> HueSettings? {
        do { try await ensureAuth() } catch { return nil }
        guard let token = accessToken else { return nil }
        let urlStr = "\(baseURL)/rest/v1/hue_settings?user_id=eq.\(userId)&select=*"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let arr = try JSONDecoder().decode([HueSettings].self, from: data)
            return arr.first
        } catch { return nil }
    }

    func upsertHueSettings(_ s: HueSettings) async -> Bool {
        do { try await ensureAuth() } catch { return false }
        guard let token = accessToken else { return false }
        let urlStr = "\(baseURL)/rest/v1/hue_settings?on_conflict=user_id"
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        var body: [String: Any] = [
            "user_id": userId,
            "enabled": s.enabled,
            "only_after_sundown": s.only_after_sundown,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let ip = s.bridge_ip { body["bridge_ip"] = ip }
        if let tok = s.bridge_token { body["bridge_token"] = tok }
        if let gid = s.group_id { body["group_id"] = gid }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
        } catch { return false }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - High-frequency broadcast
    // (wire field names osc_host/osc_port + table `vrc_settings` are kept
    //  as-is — an external desktop bridge consumes this exact contract.)
    // ════════════════════════════════════════════════════════════════

    struct HFBSettings: Codable {
        var enabled: Bool
        var osc_host: String
        var osc_port: Int
        var refresh_seconds: Double
        var mode: String                       // 'compact' / 'rotate' / 'custom' / 'vibe'
        var show_hr: Bool
        var show_hrv: Bool
        var show_baevsky: Bool
        var show_strain: Bool
        var show_state: Bool
        var show_recovery: Bool
        var show_body_battery: Bool
        var show_skin_temp: Bool
        var show_coherence: Bool
        var show_streak: Bool
        var show_spiral_count: Bool
        var show_label: Bool
        var custom_template: String?
        var custom_label: String?
        var rotate_seconds: Int
        var push_count: Int?
        var last_message: String?
        // v93 — privacy + vibe
        var privacy_mode: Bool?
        var vibe_style: String?                // 'heart' / 'aura' / 'persona'
        var show_vibe_duration: Bool?
        // v94 — energy + drunk bars
        var show_energy_bar: Bool?
        var show_drunk_bar: Bool?
        var drunk_only_when_tagged: Bool?
        var energy_bar_chars: Int?
        var drunk_bar_chars: Int?
    }

    func fetchHFBSettings() async -> HFBSettings? {
        do { try await ensureAuth() } catch { return nil }
        guard let token = accessToken else { return nil }
        let urlStr = "\(baseURL)/rest/v1/vrc_settings?user_id=eq.\(userId)&select=*"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([HFBSettings].self, from: data))?.first
        } catch { return nil }
    }

    func upsertHFBSettings(_ s: HFBSettings) async -> Bool {
        do { try await ensureAuth() } catch { return false }
        guard let token = accessToken else { return false }
        let urlStr = "\(baseURL)/rest/v1/vrc_settings?on_conflict=user_id"
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        var body: [String: Any] = [
            "user_id": userId,
            "enabled": s.enabled,
            "osc_host": s.osc_host,
            "osc_port": s.osc_port,
            "refresh_seconds": s.refresh_seconds,
            "mode": s.mode,
            "show_hr": s.show_hr,
            "show_hrv": s.show_hrv,
            "show_baevsky": s.show_baevsky,
            "show_strain": s.show_strain,
            "show_state": s.show_state,
            "show_recovery": s.show_recovery,
            "show_body_battery": s.show_body_battery,
            "show_skin_temp": s.show_skin_temp,
            "show_coherence": s.show_coherence,
            "show_streak": s.show_streak,
            "show_spiral_count": s.show_spiral_count,
            "show_label": s.show_label,
            "rotate_seconds": s.rotate_seconds,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let t = s.custom_template { body["custom_template"] = t }
        if let l = s.custom_label { body["custom_label"] = l }
        if let p = s.privacy_mode { body["privacy_mode"] = p }
        if let vs = s.vibe_style { body["vibe_style"] = vs }
        if let svd = s.show_vibe_duration { body["show_vibe_duration"] = svd }
        if let eb = s.show_energy_bar { body["show_energy_bar"] = eb }
        if let db = s.show_drunk_bar { body["show_drunk_bar"] = db }
        if let dt = s.drunk_only_when_tagged { body["drunk_only_when_tagged"] = dt }
        if let ec = s.energy_bar_chars { body["energy_bar_chars"] = ec }
        if let dc = s.drunk_bar_chars { body["drunk_bar_chars"] = dc }
        if s.enabled { body["started_at"] = ISO8601DateFormatter().string(from: Date()) }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
        } catch { return false }
    }

    /// v235 — the desktop bridge stamps pc_live_until while it runs. true = that stamp is
    /// still in the future, false = NULL/past/no row, nil = couldn't ask (caller keeps its last value).
    func fetchHFBDesktopLive() async -> Bool? {
        do { try await ensureAuth() } catch { return nil }
        guard let token = accessToken else { return nil }
        let urlStr = "\(baseURL)/rest/v1/vrc_settings?user_id=eq.\(userId)&select=enabled,pc_live_until"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Row: Decodable { let pc_live_until: String? }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300,
                  let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
            guard let iso = rows.first?.pc_live_until else { return false }
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let until = withFrac.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return false }
            return until > Date()
        } catch { return nil }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Spiral alerts log
    // ════════════════════════════════════════════════════════════════

    struct SpiralAlert: Codable, Identifiable {
        var id: String
        var fired_at: String
        var hrv_drop_pct: Double?
        var hr_rise_pct: Double?
        var hmm_state: String?
        var user_response: String?
    }

    func fetchSpiralAlerts(limit: Int = 10) async -> [SpiralAlert] {
        do { try await ensureAuth() } catch { return [] }
        guard let token = accessToken else { return [] }
        let urlStr = "\(baseURL)/rest/v1/spiral_alerts?user_id=eq.\(userId)&select=id,fired_at,hrv_drop_pct,hr_rise_pct,hmm_state,user_response&order=fired_at.desc&limit=\(limit)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([SpiralAlert].self, from: data)) ?? []
        } catch { return [] }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Coherence sessions
    // ════════════════════════════════════════════════════════════════

    struct CoherenceSession: Codable {
        var duration_sec: Int
        var coherence_score: Double
        var avg_rmssd: Double
        var avg_hr: Double
        var peak_coherence: Double
        var pre_session_baevsky: Double?
        var post_session_baevsky: Double?
        var target_breath_per_min: Double
    }

    func saveCoherenceSession(_ s: CoherenceSession) async -> Bool {
        do { try await ensureAuth() } catch { return false }
        guard let token = accessToken else { return false }
        let urlStr = "\(baseURL)/rest/v1/coherence_sessions"
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "user_id": userId,
            "duration_sec": s.duration_sec,
            "coherence_score": round(s.coherence_score * 100) / 100,
            "avg_rmssd": round(s.avg_rmssd * 10) / 10,
            "avg_hr": round(s.avg_hr * 10) / 10,
            "peak_coherence": round(s.peak_coherence * 100) / 100,
            "target_breath_per_min": s.target_breath_per_min
        ]
        if let pre = s.pre_session_baevsky { body["pre_session_baevsky"] = pre }
        if let post = s.post_session_baevsky { body["post_session_baevsky"] = post }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
        } catch { return false }
    }

    func fetchRecentCoherenceSessions(limit: Int = 14) async -> [(date: String, score: Double)] {
        do { try await ensureAuth() } catch { return [] }
        guard let token = accessToken else { return [] }
        let urlStr = "\(baseURL)/rest/v1/coherence_sessions?user_id=eq.\(userId)&select=started_at,coherence_score&order=started_at.desc&limit=\(limit)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Row: Codable { let started_at: String; let coherence_score: Double }
            let rows = (try? JSONDecoder().decode([Row].self, from: data)) ?? []
            return rows.map { ($0.started_at, $0.coherence_score) }
        } catch { return [] }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Culprit correlations (read-only — populated by nightly cron)
    // ════════════════════════════════════════════════════════════════

    struct Culprit: Codable, Identifiable {
        var id: String
        var tag: String
        var occurrences: Int
        var hrv_delta_pct: Double?
        var rhr_delta_bpm: Double?
        var sleep_delta_min: Double?
        var confidence: Double?
        var is_culprit: Bool?
        var computed_at: String
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Daily Insights (Claude routine + Vercel cron output)
    // ════════════════════════════════════════════════════════════════

    struct DailyInsight: Codable, Identifiable {
        var id: String
        var generated_at: String
        var generated_for_date: String
        var title: String
        var body: String
        var category: String                // 'pc' | 'food' | 'sleep' | 'weather' | 'cross' | 'recovery' | 'spiral'
        var priority: Int?
        var confidence: Double?
        var effect_type: String?            // 'positive' | 'negative' | 'neutral' | 'curious'
        var sample_n: Int?
        var data_sources: [String]?
        var action_text: String?
        var action_kind: String?
        var user_response: String?
        var model_used: String?
    }

    func fetchDailyInsights(limit: Int = 8) async -> [DailyInsight] {
        do { try await ensureAuth() } catch { return [] }
        guard let token = accessToken else { return [] }
        let urlStr = "\(baseURL)/rest/v1/daily_insights?user_id=eq.\(userId)&select=id,generated_at,generated_for_date,title,body,category,priority,confidence,effect_type,sample_n,data_sources,action_text,action_kind,user_response,model_used&order=priority.desc,confidence.desc&limit=\(limit)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([DailyInsight].self, from: data)) ?? []
        } catch { return [] }
    }

    func respondToInsight(id: String, response: String) async -> Bool {
        do { try await ensureAuth() } catch { return false }
        guard let token = accessToken else { return false }
        let urlStr = "\(baseURL)/rest/v1/daily_insights?id=eq.\(id)"
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "user_response": response,
            "responded_at": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 300
        } catch { return false }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Weather (read-only — fed by Vercel cron)
    // ════════════════════════════════════════════════════════════════

    struct WeatherDay: Codable {
        var date: String
        var temp_min_c: Double?
        var temp_max_c: Double?
        var temp_avg_c: Double?
        var feels_like_c: Double?
        var pressure_hpa: Double?
        var pressure_change_hpa: Double?
        var humidity_pct: Double?
        var wind_avg_kmh: Double?
        var wind_gust_kmh: Double?
        var conditions_code: Int?
        var conditions_label: String?
        var precipitation_mm: Double?
        var cloud_cover_pct: Double?
        var uv_index: Double?
        var sunrise: String?
        var sunset: String?
        var daylight_min: Int?
    }

    func fetchTodayWeather() async -> WeatherDay? {
        do { try await ensureAuth() } catch { return nil }
        guard let token = accessToken else { return nil }
        let urlStr = "\(baseURL)/rest/v1/weather_daily?user_id=eq.\(userId)&select=date,temp_min_c,temp_max_c,temp_avg_c,feels_like_c,pressure_hpa,pressure_change_hpa,humidity_pct,wind_avg_kmh,wind_gust_kmh,conditions_code,conditions_label,precipitation_mm,cloud_cover_pct,uv_index,sunrise,sunset,daylight_min&order=date.desc&limit=1"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([WeatherDay].self, from: data))?.first
        } catch { return nil }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - PC activity (read-only — fed by lucid-pc-bridge)
    // ════════════════════════════════════════════════════════════════

    struct PCAppRollup: Codable, Identifiable {
        var category: String
        var app: String
        var minutes: Int
        var sessions: Int
        var avg_hr: Double?
        var avg_hrv: Double?
        var avg_cpu_pct: Double?
        var avg_gpu_pct: Double?
        var id: String { "\(category)|\(app)" }
    }

    /// Calls the pc_daily_summary RPC. Empty array if bridge isn't running.
    func fetchPCDailySummary(date: Date = Date()) async -> [PCAppRollup] {
        do { try await ensureAuth() } catch { return [] }
        guard let token = accessToken else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)

        let urlStr = "\(baseURL)/rest/v1/rpc/pc_daily_summary"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["p_user_id": userId, "p_date": dateStr]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([PCAppRollup].self, from: data)) ?? []
        } catch { return [] }
    }

    /// Most-recent foreground app — for the "Now on PC" line.
    struct PCNowSnapshot: Codable {
        var exe: String
        var app: String?
        var category: String?
        var window_title: String?
        var started_at: String
    }

    func fetchPCNow() async -> PCNowSnapshot? {
        do { try await ensureAuth() } catch { return nil }
        guard let token = accessToken else { return nil }
        // Open session = ended_at is null
        let urlStr = "\(baseURL)/rest/v1/pc_activity?user_id=eq.\(userId)&ended_at=is.null&select=exe,app,category,window_title,started_at&order=started_at.desc&limit=1"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([PCNowSnapshot].self, from: data))?.first
        } catch { return nil }
    }

    func fetchTopCulprits(limit: Int = 5) async -> [Culprit] {
        do { try await ensureAuth() } catch { return [] }
        guard let token = accessToken else { return [] }
        let urlStr = "\(baseURL)/rest/v1/culprit_correlations?user_id=eq.\(userId)&select=id,tag,occurrences,hrv_delta_pct,rhr_delta_bpm,sleep_delta_min,confidence,is_culprit,computed_at&order=computed_at.desc,is_culprit.desc&limit=\(limit)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([Culprit].self, from: data)) ?? []
        } catch { return [] }
    }

    // ════════════════════════════════════════════════════════════════
    // MARK: - Biostate engine (EXPERIMENTAL — drunk / arousal / respiration)
    //
    // Server-side detectors v141-v146. Everything here is experimental:true —
    // never consume as ground truth. Live read = biostate_all_now (one round-trip),
    // week-graph = biostate_history (15-min cron samples), corrections =
    // log_state_correction (trains namespaced biostate_* priors only).
    // ════════════════════════════════════════════════════════════════

    struct ArousalReading: Codable {
        var arousal: Double?
        var arousal_raw: Double?
        var band: String?
        var emoji: String?
        var confidence: Double?
        var rmssd: Double?
        var baseline_rmssd: Double?
        var rmssd_drop_pct: Double?
        var hr: Double?
        var baseline_hr: Double?
        var hr_rise: Double?
        var signals_disagree: Bool?
        var sleep_stage: String?
        var activity_state: String?
        var reason: String?
    }

    struct DrunkReading: Codable {
        var gated: Bool?
        var alcohol_mode: Bool?
        var stage: Int?
        var label: String?
        var raw_label: String?
        var confidence: Double?
        var rmssd: Double?
        var baseline_rmssd: Double?
        var rmssd_ratio: Double?
        var hr: Double?
        var hr_rise: Double?
        var hr_corroborated: Bool?
        var dfa_alpha1: Double?
        var dfa_booster_fired: Bool?
        var sleep_stage: String?
        var activity_state: String?
        var reason: String?
    }

    struct RespReading: Codable {
        var resp_rate: Double?
        var resp_raw: Double?
        var error_bpm: Double?
        var range_low: Double?
        var range_high: Double?
        var method: String?
        var confidence: Double?
        var rr_derived: Double?
        var strap: Double?
        var strap_usable: Bool?
        var sources_agree: Bool?
        var sleep_stage: String?
        var activity_state: String?
        var reason: String?
    }

    struct BiostateNow: Codable {
        var experimental: Bool?
        var ts: String?
        var arousal: ArousalReading?
        var drunk: DrunkReading?
        var respiration: RespReading?
    }

    /// One round-trip live read of all three detectors. persist=true keeps the
    /// server's live biostate_state fresh.
    func fetchBiostateNow() async -> BiostateNow? {
        do { try await ensureAuth() } catch { return nil }
        guard let token = accessToken else { return nil }
        let urlStr = "\(baseURL)/rest/v1/rpc/biostate_all_now"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // empty body → function defaults (p_user=Fabi, p_end=now(), p_persist=true)
        let body: [String: Any] = ["p_persist": true]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            return try? JSONDecoder().decode(BiostateNow.self, from: data)
        } catch { return nil }
    }

    /// Log a ground-truth correction. detector ∈ {arousal,drunk,respiration}.
    /// Server logs it to state_truth_log and (if the window is clean) updates the
    /// namespaced biostate_* priors. Returns true on success.
    @discardableResult
    func logStateCorrection(detector: String,
                            correctedState: String? = nil,
                            correctedValue: Double? = nil,
                            note: String? = nil) async -> Bool {
        do { try await ensureAuth() } catch { return false }
        guard let token = accessToken else { return false }
        let urlStr = "\(baseURL)/rest/v1/rpc/log_state_correction"
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["p_detector": detector]
        if let s = correctedState { body["p_corrected_state"] = s }
        if let v = correctedValue { body["p_corrected_value"] = v }
        if let n = note { body["p_note"] = n }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
        } catch { return false }
    }

    struct BiostateHistoryPoint: Codable, Identifiable {
        var id: Int
        var ts: String
        var arousal: Double?
        var arousal_band: String?
        var drunk_stage: Int?
        var resp_rate: Double?
        var hr: Double?
        var rmssd: Double?
        var quality: Double?
        var has_signal: Bool?
    }

    /// Week-graph data: the 15-min cron samples over the last `hours`.
    func fetchBiostateHistory(hours: Int = 168) async -> [BiostateHistoryPoint] {
        do { try await ensureAuth() } catch { return [] }
        guard let token = accessToken else { return [] }
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(hours) * 3600))
        let sel = "id,ts,arousal,arousal_band,drunk_stage,resp_rate,hr,rmssd,quality,has_signal"
        let urlStr = "\(baseURL)/rest/v1/biostate_history?user_id=eq.\(userId)&ts=gte.\(cutoff)&order=ts.asc&select=\(sel)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([BiostateHistoryPoint].self, from: data)) ?? []
        } catch { return [] }
    }

    struct TruthLogEntry: Codable, Identifiable {
        var id: String
        var ts: String
        var detector: String
        var detected_state: String?
        var detected_value: Double?
        var corrected_state: String?
        var corrected_value: Double?
        var note: String?
    }

    /// Recent ground-truth corrections — the training timeline.
    func fetchTruthLog(limit: Int = 25) async -> [TruthLogEntry] {
        do { try await ensureAuth() } catch { return [] }
        guard let token = accessToken else { return [] }
        let sel = "id,ts,detector,detected_state,detected_value,corrected_state,corrected_value,note"
        let urlStr = "\(baseURL)/rest/v1/state_truth_log?user_id=eq.\(userId)&order=ts.desc&limit=\(limit)&select=\(sel)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([TruthLogEntry].self, from: data)) ?? []
        } catch { return [] }
    }
}
