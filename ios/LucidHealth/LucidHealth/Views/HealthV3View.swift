import SwiftUI

// MARK: - Models

private struct HealthNight: Identifiable {
    let id: String
    let hours: Double
    let start: Date?
    let end: Date?
    let sleepScore: Double?
    let recovery: Double?
    let hrv: Double?
    let respiratory: Double?
    let skinTemp: Double?
}

private struct HealthBody {
    var weightKg: Double?
    var fatPct: Double?
    var leanKg: Double?
}

private struct HealthPart: Identifiable {
    let id = UUID()
    let value: Double
    let color: Color
}

private struct HealthBand {
    let lo: Double
    let hi: Double
    let color: Color
}

private struct HealthTick {
    let value: Double
    let label: String
}

private struct HealthCorrection: Identifiable {
    let id = UUID()
    let detector: String
}

private func healthMean(_ v: [Double]) -> Double? {
    v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
}

private func healthClock(_ h: Double) -> String {
    var total = Int((h * 60).rounded())
    total = ((total % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", total / 60, total % 60)
}

private func healthBedHour(_ d: Date) -> Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    return h < 12 ? h + 24 : h
}

private func healthStageColor(_ stage: String) -> Color {
    switch stage {
    case "deep": return V3.deep
    case "rem": return V3.rem
    case "light": return V3.lightSleep
    default: return V3.awake
    }
}

// MARK: - Network

private enum HealthV3Net {
    struct Auth {
        let base: String
        let anon: String
        let token: String
        let user: String
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    static func num(_ r: [String: Any], _ key: String) -> Double? {
        if let d = r[key] as? Double { return d }
        if let i = r[key] as? Int { return Double(i) }
        if let s = r[key] as? String { return Double(s) }
        return nil
    }

    static func auth() async -> Auth? {
        let c = SupabaseClient.shared
        do { try await c.ensureAuth() } catch { return nil }
        guard let token = c.accessToken else { return nil }
        return Auth(base: c.baseURL, anon: c.anonKey, token: token, user: c.userId)
    }

    static func rows(_ a: Auth, table: String, query: [(String, String)]) async -> [[String: Any]] {
        guard var comps = URLComponents(string: "\(a.base)/rest/v1/\(table)") else { return [] }
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue(a.anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(a.token)", forHTTPHeaderField: "Authorization")
        guard let result = try? await URLSession.shared.data(for: req) else { return [] }
        let parsed = try? JSONSerialization.jsonObject(with: result.0)
        return parsed as? [[String: Any]] ?? []
    }

    static func nights(_ a: Auth) async -> [HealthNight] {
        let cols = "metric_date,sleep_start,sleep_end,sleep_hours,sleep_score,recovery_score,hrv_avg,respiratory_rate,skin_temp"
        let r = await rows(a, table: "health_metrics", query: [
            ("select", cols),
            ("user_id", "eq.\(a.user)"),
            ("sleep_hours", "gt.0"),
            ("order", "metric_date.desc"),
            ("limit", "60")
        ])
        var out: [HealthNight] = []
        for row in r.reversed() {
            guard let day = row["metric_date"] as? String, let h = num(row, "sleep_hours") else { continue }
            var s: Date? = nil
            if let str = row["sleep_start"] as? String { s = date(str) }
            var e: Date? = nil
            if let str = row["sleep_end"] as? String { e = date(str) }
            out.append(HealthNight(id: day, hours: h, start: s, end: e,
                                   sleepScore: num(row, "sleep_score"), recovery: num(row, "recovery_score"),
                                   hrv: num(row, "hrv_avg"), respiratory: num(row, "respiratory_rate"),
                                   skinTemp: num(row, "skin_temp")))
        }
        return out
    }

    static func fatValue(_ row: [String: Any]) -> Double? {
        for key in row.keys {
            let k = key.lowercased()
            if k.contains("lean") || k.contains("free") { continue }
            let isFat = k == "body_fat" || (k.contains("fat") && (k.contains("pct") || k.contains("percent")))
            guard isFat, let v = num(row, key), v > 0 else { continue }
            return v < 1 ? v * 100 : v
        }
        return nil
    }

    static func leanValue(_ row: [String: Any]) -> Double? {
        for key in row.keys {
            let k = key.lowercased()
            if k.contains("pct") || k.contains("percent") { continue }
            guard k.contains("lean") || k.contains("fat_free") else { continue }
            if let v = num(row, key), v > 0 { return v }
        }
        return nil
    }

    static func bodyComp(_ a: Auth) async -> HealthBody {
        let r = await rows(a, table: "body_composition_log", query: [
            ("select", "*"),
            ("user_id", "eq.\(a.user)"),
            ("order", "measured_at.desc"),
            ("limit", "30")
        ])
        var out = HealthBody()
        for row in r {
            if out.weightKg == nil, let w = num(row, "weight_kg"), w > 0 { out.weightKg = w }
            if out.fatPct == nil { out.fatPct = fatValue(row) }
            if out.leanKg == nil { out.leanKg = leanValue(row) }
        }
        if out.leanKg == nil, let w = out.weightKg, let f = out.fatPct { out.leanKg = w * (1 - f / 100) }
        return out
    }

    static func hrMean(_ a: Auth, around t: Date) async -> Double? {
        let lo = isoPlain.string(from: t.addingTimeInterval(-150))
        let hi = isoPlain.string(from: t.addingTimeInterval(150))
        let r = await rows(a, table: "realtime_health", query: [
            ("select", "heart_rate"),
            ("user_id", "eq.\(a.user)"),
            ("recorded_at", "gte.\(lo)"),
            ("recorded_at", "lt.\(hi)"),
            ("limit", "400")
        ])
        var vals: [Double] = []
        for row in r {
            if let v = num(row, "heart_rate"), v > 30 { vals.append(v) }
        }
        return healthMean(vals)
    }

    static func hrCurve(_ a: Auth, start: Date, end: Date, buckets: Int) async -> [Double?] {
        let span = end.timeIntervalSince(start)
        guard span > 600, buckets > 1 else { return [] }
        let step = span / Double(buckets)
        return await withTaskGroup(of: (Int, Double?).self) { group -> [Double?] in
            for i in 0..<buckets {
                let mid = start.addingTimeInterval(step * (Double(i) + 0.5))
                group.addTask {
                    let v = await HealthV3Net.hrMean(a, around: mid)
                    return (i, v)
                }
            }
            var out = [Double?](repeating: nil, count: buckets)
            for await item in group { out[item.0] = item.1 }
            return out
        }
    }
}

// MARK: - Store

@MainActor
private final class HealthV3Store: ObservableObject {
    @Published var scores: [String: Double] = [:]
    @Published var loaded = false
    @Published var nights: [HealthNight] = []
    @Published var stages: [StageSegment] = []
    @Published var hrCurve: [Double?] = []
    @Published var restlessness: SleepRestlessness?
    @Published var weights: [SupabaseClient.WeightPoint] = []
    @Published var comp = HealthBody()
    @Published var biostate: ExperimentalFeaturesService.BiostateNow?
    @Published var biostateLoaded = false

    var night: BoardNight { BoardNight(scores: scores) }

    var window: (start: Date, end: Date)? {
        let n = night
        if let s = n.start, let e = n.end, e > s { return (s, e) }
        if let last = nights.last, let s = last.start, let e = last.end, e > s { return (s, e) }
        return nil
    }

    func load() async {
        let client = SupabaseClient.shared
        scores = await client.fetchLastScores()
        loaded = true
        guard let auth = await HealthV3Net.auth() else { return }
        async let nightRows = HealthV3Net.nights(auth)
        async let compRow = HealthV3Net.bodyComp(auth)
        async let weightRows = client.fetchWeightSeries(days: 60)
        async let restRow = client.fetchSleepRestlessness()
        nights = await nightRows
        comp = await compRow
        weights = await weightRows
        restlessness = await restRow
        if let w = window {
            stages = StageSegment.build(from: await client.fetchSleepStages(start: w.start, end: w.end))
            hrCurve = await HealthV3Net.hrCurve(auth, start: w.start, end: w.end, buckets: 24)
        }
    }

    func loadBiostate() async {
        biostate = await ExperimentalFeaturesService.shared.fetchBiostateNow()
        biostateLoaded = true
    }
}

private struct HealthMins {
    let deep: Double
    let rem: Double
    let light: Double
    let awake: Double
}

private struct HealthPreset: Identifiable {
    let id: String
    let value: Double
}

private func healthPresets(_ detector: String) -> [HealthPreset] {
    if detector == "drunk" {
        return [HealthPreset(id: "sober", value: 0), HealthPreset(id: "buzzed", value: 1),
                HealthPreset(id: "tipsy", value: 2), HealthPreset(id: "drunk", value: 3),
                HealthPreset(id: "wasted", value: 4)]
    }
    return [HealthPreset(id: "deep_calm", value: 1), HealthPreset(id: "relaxed", value: 3),
            HealthPreset(id: "neutral", value: 5), HealthPreset(id: "elevated", value: 7),
            HealthPreset(id: "high_arousal", value: 9)]
}

// MARK: - Screen

struct HealthV3View: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.selectTab) private var selectTab
    @StateObject private var store = HealthV3Store()
    @State private var segment: String
    @State private var showSleepSheet = false
    @State private var correction: HealthCorrection?

    private let need = 8.0

    init() {
        _segment = State(initialValue: LucidScreen.current == .healthDetail ? "Heart" : "Sleep")
    }

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        V3Header(date: "Last night", title: "Health") { V3KeledButton() }
                        V3Segmented(options: ["Sleep", "Heart", "Strain", "Body"], selection: $segment)
                            .padding(.bottom, 6)
                        segmentContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 90)
                }
                .refreshable { await store.load() }
                .task { await jumpToDetail(proxy) }
            }
        }
        .task { await store.load() }
        .task(id: segment) {
            if segment == "Heart" { await store.loadBiostate() }
        }
        .sheet(isPresented: $showSleepSheet) { sleepSheet }
        .confirmationDialog("What is it really?", isPresented: correctionBinding, titleVisibility: .visible, presenting: correction) { c in
            ForEach(healthPresets(c.detector)) { p in
                Button(healthSentence(p.id)) { submit(c.detector, p) }
            }
        }
        .lucidRendered(.health, .healthDetail)
    }

    private var correctionBinding: Binding<Bool> {
        Binding<Bool>(get: { correction != nil }, set: { shown in
            if !shown { correction = nil }
        })
    }

    private func jumpToDetail(_ proxy: ScrollViewProxy) async {
        guard LucidScreen.current == .healthDetail else { return }
        try? await Task.sleep(for: .seconds(2.5))
        proxy.scrollTo("health-detail", anchor: .top)
    }

    private func submit(_ detector: String, _ preset: HealthPreset) {
        Task {
            await ExperimentalFeaturesService.shared.logStateCorrection(detector: detector, correctedState: preset.id, correctedValue: preset.value, note: nil)
            await store.loadBiostate()
        }
    }

    @ViewBuilder private var segmentContent: some View {
        switch segment {
        case "Heart": heartSegment
        case "Strain": strainSegment
        case "Body": bodySegment
        default: sleepSegment
        }
    }

    private var consistencyValue: Double? {
        let e = bleManager.healthEngine
        guard e.lastNightHasData, e.sleepConsistencyScore != 50 else { return nil }
        return e.sleepConsistencyScore
    }

    private var sleepSheet: some View {
        HealthSleepSheet(night: store.night, nights: store.nights, stages: store.stages,
                         start: store.window?.start, end: store.window?.end, consistency: consistencyValue)
    }
}

// MARK: - Sleep segment

private extension HealthV3View {
    var sleepSegment: some View {
        VStack(spacing: 12) {
            sleepSummary
            stagesCard
            heartOvernightCard
            weekCard
            bedtimeCard
        }
    }

    var sleepSummary: some View {
        let n = store.night
        let hours = n.hours
        let pct = hours.map { Int(($0 / need * 100).rounded()) }
        var range = ""
        if let w = store.window { range = V3Format.hhmm(w.start) + " – " + V3Format.hhmm(w.end) }
        return VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Asleep").font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
                    Text(hours.map { V3Format.duration(hours: $0) } ?? "–")
                        .font(V3Font.num(46)).tracking(-2.1).foregroundStyle(V3.t1)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Score").font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
                    Text(n.positive("sleep_score").map { BoardFormat.int($0) } ?? "–")
                        .font(V3Font.num(46)).tracking(-2.1).foregroundStyle(V3.sleep)
                }
            }
            .padding(.top, 12)
            V3Bar(fraction: min(1, (hours ?? 0) / need), color: V3.sleep, height: 8)
                .padding(.top, 8)
            HStack {
                Text(pct.map { "\($0)% of your 8h need" } ?? "").font(V3Font.text(12)).foregroundStyle(V3.t2)
                Spacer(minLength: 8)
                Text(range).font(V3Font.text(12)).foregroundStyle(V3.t2).monospacedDigit()
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    var stageMins: HealthMins? {
        let n = store.night
        let d = n.positive("deep_min") ?? 0
        let r = n.positive("rem_min") ?? 0
        let l = n.positive("light_min") ?? 0
        let a = n.positive("awake_min") ?? 0
        guard d + r + l > 0 else { return nil }
        return HealthMins(deep: d, rem: r, light: l, awake: a)
    }

    var stagesCard: some View {
        let eff = store.night.efficiencyPct.map { "\(Int($0.rounded()))% efficient" }
        return Button { showSleepSheet = true } label: {
            V3Card {
                V3CardHeader(title: "Stages", trailing: eff)
                HealthStagesBlock(segments: store.stages, start: store.window?.start, end: store.window?.end,
                                  mins: stageMins, height: 132, labels: true)
            }
        }
        .buttonStyle(.plain)
    }

    var heartOvernightCard: some View {
        let hrv = store.night.positive("hrv_avg").map { "HRV \(Int($0.rounded())) ms" }
        let have = store.hrCurve.compactMap { $0 }.count >= 3
        return V3Card {
            V3CardHeader(icon: "heart.fill", iconColor: V3.heart, title: "Heart rate overnight", trailing: hrv)
            if have, let w = store.window {
                HealthHRCurve(values: store.hrCurve, resting: store.night.positive("resting_hr"), start: w.start, end: w.end)
                    .frame(height: 110)
                HealthTimeAxis(labels: healthAxis(w.start, w.end)).padding(.top, 12)
            } else {
                V3EmptyLine(text: store.loaded ? "No heart rate samples for last night" : "Loading")
            }
        }
    }

    var weekCard: some View {
        let week = Array(store.nights.suffix(7))
        let avg = healthMean(week.map { $0.hours })
        return V3Card {
            V3CardHeader(title: "Last 7 nights", trailing: avg.map { "avg " + V3Format.duration(hours: $0) })
            if week.count >= 2 {
                HealthWeekBars(values: week.map { $0.hours },
                               labels: week.map { String(BoardFormat.weekdayShort($0.id).prefix(1)) },
                               need: need)
            } else {
                V3EmptyLine(text: store.loaded ? "Not enough nights yet" : "Loading")
            }
        }
    }

    var bedtimeCard: some View {
        var pairs: [(Double, Double?)] = []
        for n in store.nights {
            if let s = n.start { pairs.append((healthBedHour(s), n.recovery)) }
        }
        let recent = Array(pairs.suffix(14)).map { $0.0 }
        let avg = healthMean(recent)
        var early: [Double] = []
        var late: [Double] = []
        for p in pairs {
            guard let r = p.1 else { continue }
            if p.0 < 25 { early.append(r) } else { late.append(r) }
        }
        return V3Card {
            V3CardHeader(title: "Bedtime", trailing: avg.map { "avg " + healthClock($0) })
            if recent.count >= 2 {
                HealthBedtimeStrip(hours: recent, average: avg)
                HStack(spacing: 10) {
                    HealthSplitTile(title: "Asleep before 01:00", color: V3.green, values: early)
                    HealthSplitTile(title: "After 01:00", color: V3.amber, values: late)
                }
                .padding(.top, 14)
            } else {
                V3EmptyLine(text: store.loaded ? "Not enough nights yet" : "Loading")
            }
        }
    }
}

private func healthAxis(_ s: Date, _ e: Date) -> [String] {
    let span = e.timeIntervalSince(s)
    var out: [String] = []
    for i in 0..<4 { out.append(V3Format.hhmm(s.addingTimeInterval(span * Double(i) / 3.0))) }
    return out
}

private func healthInt(_ v: Double?) -> String {
    v.map { "\(Int($0.rounded()))" } ?? "–"
}

private func healthOne(_ v: Double?) -> String {
    v.map { BoardFormat.one($0) } ?? "–"
}

private func healthUnit(_ v: Double) -> Double {
    min(1, max(0, v))
}

// MARK: - Heart segment

private extension HealthV3View {
    var heartSegment: some View {
        VStack(spacing: 12) {
            heartNow
            hrvCard
            dfaCard
            poincareCard
            restlessnessCard
            heartEmptyTiles
            bodyStateCard
        }
    }

    var heartNow: some View {
        let e = bleManager.healthEngine
        let bpm = bleManager.heartRate
        let rmssd = e.currentRMSSD
        var vo2: Double? = store.night.positive("vo2max")
        if vo2 == nil, e.vo2maxEstimate > 0 { vo2 = e.vo2maxEstimate }
        let resp = e.respiratoryRate
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(V3.heart).frame(width: 7, height: 7)
                        Text("Heart rate").font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
                    }
                    V3BigNumber(value: bpm > 0 ? "\(bpm)" : "–", unit: "bpm", size: 46)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("HRV now").font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
                    V3BigNumber(value: rmssd > 0 ? "\(Int(rmssd.rounded()))" : "–", unit: "ms", size: 46, color: V3.energy)
                }
            }
            .padding(.top, 12)
            HStack(spacing: 5) {
                if resp > 0 {
                    Text("Breathing").foregroundStyle(V3.t2)
                    Text(BoardFormat.one(resp) + " /min").foregroundStyle(V3.t1).fontWeight(.semibold)
                }
                if resp > 0, vo2 != nil { Text("·").foregroundStyle(V3.t2) }
                if let vo2 {
                    Text("VO2max").foregroundStyle(V3.t2)
                    Text(BoardFormat.one(vo2)).foregroundStyle(V3.t1).fontWeight(.semibold)
                }
            }
            .font(V3Font.text(13))
            .padding(.top, 6)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    var hrvCard: some View {
        let n = store.night
        let rmssd = n.positive("hrv_avg")
        let sdnn = n.positive("sdnn")
        let pnn = n.positive("pnn50")
        let avg30 = healthMean(store.nights.suffix(30).compactMap { $0.hrv })
        let hasData = rmssd != nil || sdnn != nil || pnn != nil
        return V3Card {
            V3CardHeader(icon: "waveform.path.ecg", iconColor: V3.energy, title: "Last night's HRV",
                         trailing: avg30.map { "avg \(Int($0.rounded())) ms" })
            if hasData {
                HStack(alignment: .top, spacing: 12) {
                    HealthStat(label: "RMSSD", value: healthInt(rmssd), unit: "ms")
                    HealthStat(label: "SDNN", value: healthOne(sdnn), unit: "ms")
                    HealthStat(label: "pNN50", value: healthOne(pnn), unit: "%")
                }
                HStack(spacing: 14) {
                    V3Bar(fraction: healthUnit((rmssd ?? 0) / 80), color: V3.energy)
                    V3Bar(fraction: healthUnit((sdnn ?? 0) / 100), color: V3.energy)
                    V3Bar(fraction: healthUnit((pnn ?? 0) / 100), color: V3.energy)
                }
                .padding(.top, 10)
            } else {
                V3EmptyLine(text: store.loaded ? "No HRV for last night" : "Loading")
            }
        }
        .id("health-detail")
    }

    var dfaCard: some View {
        let dfa = store.night.positive("dfa_alpha1")
        var chip = "Rested"
        var chipColor: Color = V3.green
        if let v = dfa {
            if v < 0.75 {
                chip = "Under strain"
                chipColor = V3.amber
            } else if v > 1.0 {
                chip = "Above range"
                chipColor = V3.t2
            }
        }
        return V3Card {
            HStack {
                Text("DFA alpha1").font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                Spacer(minLength: 8)
                if dfa != nil { HealthChip(text: chip, color: chipColor) }
            }
            .padding(.bottom, 12)
            if let v = dfa {
                V3BigNumber(value: String(format: "%.2f", v), size: 30).padding(.bottom, 10)
                HealthRangeStrip(lo: 0.5, hi: 1.5,
                                 bands: [HealthBand(lo: 0.75, hi: 1.0, color: V3.green.opacity(0.16))],
                                 value: v, color: chipColor,
                                 ticks: [HealthTick(value: 0.5, label: "0.5"), HealthTick(value: 0.75, label: "0.75"),
                                         HealthTick(value: 1.0, label: "1.0"), HealthTick(value: 1.5, label: "1.5")])
                Text("0.75 to 1.0 means rested").font(V3Font.text(12)).foregroundStyle(V3.t2).padding(.top, 6)
            } else {
                V3EmptyLine(text: store.loaded ? "Not computed for last night" : "Loading")
            }
        }
    }

    var poincareCard: some View {
        let sd1 = store.night.positive("poincare_sd1")
        let sd2 = store.night.positive("poincare_sd2")
        return V3Card {
            V3CardHeader(title: "Poincaré plot", trailing: "from the latest night")
            if let a = sd1, let b = sd2 {
                HealthPoincare(sd1: a, sd2: b).frame(height: 150)
                HStack(alignment: .top, spacing: 12) {
                    V3LegendItem(label: "Short term", value: "SD1 \(Int(a.rounded())) ms")
                    V3LegendItem(label: "Long term", value: "SD2 \(Int(b.rounded())) ms")
                    V3LegendItem(label: "Ratio", value: String(format: "%.2f", b / a))
                }
                .padding(.top, 14)
            } else {
                V3EmptyLine(text: store.loaded ? "Not computed yet" : "Loading")
            }
        }
    }

    @ViewBuilder var restlessnessCard: some View {
        if let r = store.restlessness {
            V3Card {
                V3CardHeader(icon: "moon.fill", iconColor: V3.sleep, title: "Restlessness",
                             trailing: "in bed " + BoardFormat.one(r.inBedH) + " h")
                HStack(alignment: .top, spacing: 12) {
                    HealthStat(label: "Restless", value: "\(r.restlessMin)", unit: "min")
                    HealthStat(label: "Wakeups", value: "\(r.wakeups)", unit: "")
                    HealthStat(label: "Stability", value: "\(r.stability)", unit: "/ 10")
                }
                V3Bar(fraction: healthUnit(Double(r.stability) / 10), color: V3.sleep).padding(.top, 10)
                Text("Higher stability means a calmer night.").font(V3Font.text(12)).foregroundStyle(V3.t2).padding(.top, 12)
            }
        }
    }

    var heartEmptyTiles: some View {
        HStack(alignment: .top, spacing: 12) {
            HealthEmptyTile(icon: "gauge.with.dots.needle.33percent", title: "Stress index", line: "Baevsky method")
            HealthEmptyTile(icon: "heart", title: "HR recovery", line: "At 1 and 2 min")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private func healthSentence(_ s: String) -> String {
    let t = s.replacingOccurrences(of: "_", with: " ")
    guard let first = t.first else { return t }
    return first.uppercased() + t.dropFirst()
}

private func healthSure(_ c: Double) -> String {
    let word = c >= 0.75 ? "sure" : (c >= 0.4 ? "likely" : "unsure")
    return word + ", " + String(format: "%.1f", c)
}

private func healthFat(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    if s.hasSuffix("0") { s.removeLast() }
    return s + "%"
}

// MARK: - Body state

private extension HealthV3View {
    var bodyStateCard: some View {
        let bs = store.biostate
        return V3Card {
            HStack {
                Text("Body state").font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                Spacer(minLength: 8)
                HealthChip(text: "Experimental", color: V3.strain)
            }
            .padding(.bottom, 14)
            drunkRow(bs?.drunk)
            Rectangle().fill(V3.line).frame(height: 1).padding(.vertical, 14)
            arousalRow(bs?.arousal)
        }
    }

    func wrongChip(_ detector: String) -> some View {
        Button { correction = HealthCorrection(detector: detector) } label: {
            Text("This is wrong").font(V3Font.text(12, .semibold)).foregroundStyle(V3.t1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(V3.card2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    func drunkRow(_ d: ExperimentalFeaturesService.DrunkReading?) -> some View {
        let label = (d?.label ?? "").replacingOccurrences(of: "_", with: " ")
        let conf = d?.confidence ?? 0
        var name = healthSentence(label)
        if label.isEmpty { name = store.biostateLoaded ? "No reading" : "Loading" }
        return HStack(spacing: 12) {
            V3IconWell(symbol: "wineglass", color: V3.kcal, size: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1)
                if !label.isEmpty {
                    HStack(spacing: 8) {
                        V3Bar(fraction: conf, color: label.lowercased() == "sober" ? V3.green : V3.amber)
                        Text(healthSure(conf)).font(V3Font.text(12)).foregroundStyle(V3.t2).fixedSize()
                    }
                }
            }
            if label.isEmpty { Spacer(minLength: 8) } else { wrongChip("drunk") }
        }
    }

    func arousalRow(_ a: ExperimentalFeaturesService.ArousalReading?) -> some View {
        let band = (a?.band ?? "").replacingOccurrences(of: "_", with: " ")
        let known = !band.isEmpty && band.lowercased() != "unknown"
        var sub = known ? healthSentence(band) : "Band unknown"
        if a == nil { sub = store.biostateLoaded ? "No reading" : "Loading" }
        return HStack(spacing: 12) {
            V3IconWell(symbol: "waveform.path.ecg", color: V3.t2, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Arousal").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1)
                Text(sub).font(V3Font.text(13)).foregroundStyle(V3.t2)
            }
            Spacer(minLength: 8)
            if a != nil { wrongChip("arousal") }
        }
    }
}

// MARK: - Strain segment

private extension HealthV3View {
    var strainSegment: some View {
        VStack(spacing: 12) {
            trainingLoadCard
            V3Button(title: "Open Strain") { selectTab(.strain) }
        }
    }

    var trainingLoadCard: some View {
        let n = store.night
        let acwr = n.positive("acwr")
        var word = "Steady"
        var color: Color = V3.green
        if let v = acwr {
            if v < 0.8 {
                word = "Low"
                color = V3.t2
            } else if v > 1.5 {
                word = "High"
                color = V3.red
            } else if v > 1.3 {
                word = "Rising"
                color = V3.amber
            }
        }
        let bands = [HealthBand(lo: 0.8, hi: 1.3, color: V3.green.opacity(0.16)),
                     HealthBand(lo: 1.3, hi: 1.5, color: V3.amber.opacity(0.16))]
        let ticks = [HealthTick(value: 0.5, label: "0.5"), HealthTick(value: 0.8, label: "0.8"),
                     HealthTick(value: 1.3, label: "1.3"), HealthTick(value: 1.5, label: "1.5"),
                     HealthTick(value: 2.0, label: "2.0")]
        return V3Card {
            HStack {
                Text("Training load").font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                Spacer(minLength: 8)
                if acwr != nil { HealthChip(text: word, color: color) }
            }
            .padding(.bottom, 12)
            if let v = acwr {
                V3BigNumber(value: String(format: "%.2f", v), size: 36).padding(.bottom, 10)
                HealthRangeStrip(lo: 0.5, hi: 2.0, bands: bands, value: v, color: color, ticks: ticks)
            } else {
                V3EmptyLine(text: store.loaded ? "Not computed yet" : "Loading")
            }
            HStack(alignment: .top, spacing: 12) {
                V3LegendItem(label: "Monotony", value: healthOne(n.positive("training_monotony")))
                V3LegendItem(label: "VO2max", value: healthOne(n.positive("vo2max")))
                V3LegendItem(label: "Steps", value: "Not synced", valueColor: V3.t2)
            }
            .padding(.top, 16)
        }
    }
}

// MARK: - Body segment

private extension HealthV3View {
    var bodySegment: some View {
        VStack(spacing: 12) {
            weightCard
            compositionCard
        }
    }

    var weekTrend: String? {
        guard let last = store.weights.last else { return nil }
        let since = last.date.addingTimeInterval(-7 * 86400)
        let week = store.weights.filter { $0.date >= since }
        guard week.count >= 2, let first = week.first else { return nil }
        let d = last.kg - first.kg
        if abs(d) < 0.15 { return "flat this week" }
        return (d < 0 ? "down " : "up ") + String(format: "%.1f", abs(d)) + " kg this week"
    }

    var cutPace: Double? {
        guard let last = store.weights.last else { return nil }
        let since = last.date.addingTimeInterval(-14 * 86400)
        let pts = store.weights.filter { $0.date >= since }
        guard pts.count >= 3, let first = pts.first, last.date.timeIntervalSince(first.date) >= 5 * 86400 else { return nil }
        let xs = pts.map { $0.date.timeIntervalSince(first.date) / 86400 }
        let ys = pts.map { $0.kg }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var cov = 0.0
        var variance = 0.0
        for i in 0..<xs.count {
            cov += (xs[i] - mx) * (ys[i] - my)
            variance += (xs[i] - mx) * (xs[i] - mx)
        }
        guard variance > 0 else { return nil }
        return cov / variance * 7
    }

    var weightCard: some View {
        let latest = store.weights.last?.kg ?? store.comp.weightKg
        let spark = store.weights.suffix(7).map { $0.kg }
        return V3Card {
            V3CardHeader(icon: "scalemass.fill", iconColor: V3.fat, title: "Weight", trailing: weekTrend)
            if let w = latest {
                V3BigNumber(value: String(format: "%.1f", w), unit: "kg", size: 46)
                if spark.count >= 2 {
                    V3Sparkline(values: spark, color: V3.fat).frame(height: 64).padding(.top, 12)
                }
            } else {
                V3EmptyLine(text: store.loaded ? "No weigh-ins yet" : "Loading")
            }
        }
    }

    var compositionCard: some View {
        let c = store.comp
        let weight = store.weights.last?.kg ?? c.weightKg
        var paceText = "Not yet"
        if let p = cutPace {
            paceText = abs(p) < 0.15 ? "Holding" : V3Format.signed(p, decimals: 1) + " kg/wk"
        }
        return V3Card {
            V3CardHeader(title: "Body composition")
            if c.fatPct != nil || c.leanKg != nil {
                if let lean = c.leanKg, let w = weight, w > lean {
                    HealthStageBar(parts: [HealthPart(value: lean, color: V3.t1.opacity(0.22)),
                                           HealthPart(value: w - lean, color: V3.fat)])
                        .padding(.bottom, 14)
                }
                HStack(alignment: .top, spacing: 12) {
                    V3LegendItem(label: "Lean mass", value: c.leanKg.map { String(format: "%.1f kg", $0) } ?? "–")
                    V3LegendItem(dot: V3.fat, label: "Body fat", value: c.fatPct.map { healthFat($0) } ?? "–")
                    V3LegendItem(label: "Cut pace", value: paceText)
                }
            } else {
                V3EmptyLine(text: store.loaded ? "No body composition logged" : "Loading")
            }
        }
    }
}

// MARK: - Sleep sheet

private func healthNightLabel(_ s: Date?, _ e: Date?) -> String {
    guard let e else { return "Last night" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.dateFormat = "d MMM"
    guard let s, !Calendar.current.isDate(s, inSameDayAs: e) else { return "Night of " + f.string(from: e) }
    f.dateFormat = Calendar.current.isDate(s, equalTo: e, toGranularity: .month) ? "d" : "d MMM"
    let first = f.string(from: s)
    f.dateFormat = "d MMM"
    return "Night of " + first + " to " + f.string(from: e)
}

private struct HealthSleepSheet: View {
    let night: BoardNight
    let nights: [HealthNight]
    let stages: [StageSegment]
    let start: Date?
    let end: Date?
    let consistency: Double?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    Capsule().fill(V3.chrome).frame(width: 36, height: 5).padding(.top, 8)
                    V3Header(date: healthNightLabel(start, end), title: "Sleep") {
                        V3IconButton(symbol: "xmark") { dismiss() }
                    }
                    hero
                    stagesCard
                    debtCard
                    HStack(alignment: .top, spacing: 12) {
                        dipTile
                        breathingTile
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 12) {
                        skinTile
                        spo2Tile
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .presentationDetents([.large])
        .presentationBackground(V3.sheet)
    }

    private var range: String {
        guard let s = start, let e = end else { return "" }
        return V3Format.hhmm(s) + " to " + V3Format.hhmm(e)
    }

    private var mins: HealthMins? {
        let d = night.positive("deep_min") ?? 0
        let r = night.positive("rem_min") ?? 0
        let l = night.positive("light_min") ?? 0
        let a = night.positive("awake_min") ?? 0
        guard d + r + l > 0 else { return nil }
        return HealthMins(deep: d, rem: r, light: l, awake: a)
    }

    private var hero: some View {
        let eff = night.efficiencyPct
        let score = night.positive("sleep_score")
        return V3HeroTrio(glow: V3.sleep) {
            V3SmallRing(value: eff.map { "\(Int($0.rounded()))%" } ?? "–",
                        progress: healthUnit((eff ?? 0) / 100), color: V3.sleep,
                        label: "Efficiency", sub: eff == nil ? "No data" : "asleep in bed", dashed: eff == nil)
        } middle: {
            V3HeroRing(value: score.map { BoardFormat.int($0) } ?? "–", unit: "",
                       progress: healthUnit((score ?? 0) / 100), color: V3.sleep,
                       label: "Sleep score", sub: range, subColor: V3.sleep)
        } right: {
            V3SmallRing(value: consistency.map { "\(Int($0.rounded()))%" } ?? "–",
                        progress: healthUnit((consistency ?? 0) / 100), color: V3.sleep,
                        label: "Consistency", sub: consistency == nil ? "No data" : "bed and wake", dashed: consistency == nil)
        }
    }

    private var stagesCard: some View {
        V3Card {
            V3CardHeader(icon: "moon.fill", iconColor: V3.sleep, title: "Stages",
                         trailing: night.hours.map { V3Format.duration(hours: $0) + " asleep" })
            HealthStagesBlock(segments: stages, start: start, end: end, mins: mins, height: 96, labels: false)
        }
        .padding(.top, 6)
    }

    private var debtCard: some View {
        let total = 14.0 * 8
        let debt = night.scores["sleep_debt_hours"]
        let missing = min(total, max(0, debt ?? 0))
        var parts = [HealthPart(value: total - missing, color: V3.sleep.opacity(0.45))]
        if missing > 0 { parts.append(HealthPart(value: missing, color: V3.amber)) }
        return V3Card {
            V3CardHeader(title: "Need and debt", trailing: "last 14 days")
            if debt != nil {
                HStack(alignment: .firstTextBaseline) {
                    V3BigNumber(value: String(format: "%.1f", missing), unit: "h short", size: 30,
                                color: missing > 0 ? V3.amber : V3.green)
                    Spacer(minLength: 8)
                    Text("need 8h a night").font(V3Font.text(13)).foregroundStyle(V3.t2)
                }
                HealthStageBar(parts: parts).padding(.top, 14)
                HStack(alignment: .top, spacing: 12) {
                    V3LegendItem(dot: V3.sleep.opacity(0.6), label: "Slept", value: String(format: "%.1f h", total - missing))
                    V3LegendItem(dot: V3.amber, label: "Missing", value: String(format: "%.1f h of %.0f h", missing, total))
                }
                .padding(.top, 14)
            } else {
                V3EmptyLine(text: "Not computed yet")
            }
        }
    }
}

private extension HealthSleepSheet {
    var dipTile: some View {
        let dip = night.positive("nocturnal_hr_dip")
        var note = "No reading"
        var noteColor: Color = V3.t2
        if let d = dip {
            note = d >= 10 ? "Healthy dip" : "Shallow dip"
            noteColor = d >= 10 ? V3.green : V3.amber
        }
        let bands = [HealthBand(lo: 10, hi: 40, color: V3.green.opacity(0.16))]
        let ticks = [HealthTick(value: 0, label: "0"), HealthTick(value: 10, label: "10"), HealthTick(value: 40, label: "40")]
        return HealthTile(icon: "heart.fill", iconColor: V3.heart, title: "Night dip",
                          value: dip.map { String(format: "%.1f", $0) } ?? "–", unit: dip == nil ? "" : "%",
                          note: note, noteColor: noteColor) {
            if let d = dip {
                HealthRangeStrip(lo: 0, hi: 40, bands: bands, value: min(d, 40), color: V3.heart, ticks: ticks)
            }
        }
    }

    var breathingTile: some View {
        let rate = night.positive("respiratory_rate")
        let week = nights.suffix(7).compactMap { $0.respiratory }.filter { $0 > 0 }
        let avg = healthMean(week)
        return HealthTile(icon: "lungs.fill", iconColor: V3.rem, title: "Breathing",
                          value: rate.map { String(format: "%.1f", $0) } ?? "–", unit: rate == nil ? "" : "/min",
                          note: avg.map { "7-night avg " + String(format: "%.1f", $0) } ?? "No reading") {
            if week.count >= 2 {
                V3Sparkline(values: week, color: V3.rem).frame(height: 36)
            }
        }
    }

    var skinTile: some View {
        let last = night.positive("skin_temp")
        let avg = healthMean(nights.suffix(30).compactMap { $0.skinTemp }.filter { $0 > 0 })
        let shown = last ?? avg
        return HealthTile(icon: "thermometer.medium", iconColor: V3.awake, title: "Skin temp",
                          value: shown.map { String(format: "%.1f", $0) } ?? "–", unit: shown == nil ? "" : "°C",
                          note: avg == nil ? "No data" : "30-day average") {
            if last == nil {
                HStack(spacing: 8) {
                    Circle().strokeBorder(V3.t2, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(width: 22, height: 22)
                    Text("Last night missing").font(V3Font.text(12, .semibold)).foregroundStyle(V3.t2)
                }
            }
        }
    }

    var spo2Tile: some View {
        HealthTile(icon: "drop.fill", iconColor: V3.rem, title: "SpO2",
                   note: "This strap firmware does not measure it") {
            HStack(spacing: 10) {
                Circle().strokeBorder(V3.t2, style: StrokeStyle(lineWidth: 3, dash: [3, 5])).frame(width: 40, height: 40)
                Text("No data").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2)
            }
            .padding(.bottom, 2)
        }
    }
}

// MARK: - Drawing and layout helpers

private struct HealthTile<Content: View>: View {
    let icon: String
    var iconColor: Color = V3.t2
    let title: String
    var value: String? = nil
    var unit: String = ""
    var note: String? = nil
    var noteColor: Color = V3.t2
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(iconColor)
                Text(title).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2).lineLimit(1)
            }
            if let value {
                V3BigNumber(value: value, unit: unit, size: 28).padding(.top, 8)
            }
            if let note {
                Text(note).font(V3Font.text(12, .semibold)).foregroundStyle(noteColor)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            content.padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(V3.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct HealthEmptyTile: View {
    let icon: String
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(V3.t2)
                Text(title).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2).lineLimit(1)
            }
            HStack(spacing: 10) {
                Circle().strokeBorder(V3.t2, style: StrokeStyle(lineWidth: 3, dash: [3, 5])).frame(width: 36, height: 36)
                Text("Not yet").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2)
            }
            .padding(.top, 10)
            Text(line).font(V3Font.text(12, .semibold)).foregroundStyle(V3.t2).padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(V3.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct HealthChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(V3Font.text(12, .semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct HealthStat: View {
    let label: String
    let value: String
    let unit: String
    var color: Color = V3.t1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(V3Font.num(22)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(V3Font.text(13)).foregroundStyle(V3.t2) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HealthStageBar: View {
    let parts: [HealthPart]

    var body: some View {
        GeometryReader { g in
            let shown = parts.filter { $0.value > 0 }
            let total = shown.reduce(0.0) { $0 + $1.value }
            let gaps = CGFloat(max(shown.count - 1, 0)) * 2
            let usable = max(g.size.width - gaps, 0)
            HStack(spacing: 2) {
                ForEach(shown) { p in
                    Rectangle().fill(p.color).frame(width: total > 0 ? usable * CGFloat(p.value / total) : 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(height: 10)
    }
}

private struct HealthDashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private struct HealthTimeAxis: View {
    let labels: [String]
    var trailingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                if i > 0 { Spacer(minLength: 0) }
                Text(t).font(V3Font.text(11)).foregroundStyle(V3.t2).monospacedDigit()
            }
        }
        .padding(.trailing, trailingInset)
    }
}

private struct HealthLegendCell: View {
    let dot: Color
    let name: String
    let value: String
    var note: String? = nil
    var noteColor: Color = V3.t2

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(name).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(1)
            }
            Text(value).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            if let note {
                Text(note).font(V3Font.text(11, .semibold)).foregroundStyle(noteColor)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HealthHypnogram: View {
    let segments: [StageSegment]
    let start: Date
    let end: Date
    let height: CGFloat
    let labels: Bool

    private static let rows = ["awake", "rem", "light", "deep"]
    private static let names = ["Awake", "REM", "Light", "Deep"]

    var body: some View {
        Canvas { ctx, size in
            let inset: CGFloat = labels ? 44 : 0
            let w = max(size.width - inset, 1)
            let span = max(end.timeIntervalSince(start), 1)
            let rh = size.height / 4
            let barH = max(rh - 5, 3)
            let ordered = segments.sorted { $0.start < $1.start }
            func xPos(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / span) * w }
            func rowOf(_ s: String) -> CGFloat { CGFloat(HealthHypnogram.rows.firstIndex(of: s) ?? 2) }
            if ordered.count >= 2 {
                for i in 1..<ordered.count {
                    let xx = xPos(ordered[i].start)
                    var p = Path()
                    p.move(to: CGPoint(x: xx, y: rowOf(ordered[i - 1].stage) * rh + rh / 2))
                    p.addLine(to: CGPoint(x: xx, y: rowOf(ordered[i].stage) * rh + rh / 2))
                    ctx.stroke(p, with: .color(V3.t1.opacity(0.14)), lineWidth: 1.5)
                }
            }
            for seg in ordered {
                let x0 = max(0, xPos(seg.start))
                let x1 = min(w, xPos(seg.end))
                if x1 <= x0 { continue }
                let r = CGRect(x: x0, y: rowOf(seg.stage) * rh + (rh - barH) / 2, width: max(x1 - x0, 2), height: barH)
                ctx.fill(Path(roundedRect: r, cornerRadius: min(4, barH / 2)), with: .color(healthStageColor(seg.stage)))
            }
            if labels {
                for (i, name) in HealthHypnogram.names.enumerated() {
                    let label = Text(name).font(V3Font.text(11, .semibold)).foregroundColor(V3.t2)
                    ctx.draw(label, at: CGPoint(x: w + 8, y: CGFloat(i) * rh + rh / 2), anchor: .leading)
                }
            }
        }
        .frame(height: height)
    }
}

private struct HealthStagesBlock: View {
    let segments: [StageSegment]
    let start: Date?
    let end: Date?
    let mins: HealthMins?
    let height: CGFloat
    let labels: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = start, let e = end, !segments.isEmpty {
                HealthHypnogram(segments: segments, start: s, end: e, height: height, labels: labels)
                HealthTimeAxis(labels: healthAxis(s, e), trailingInset: labels ? 44 : 0).padding(.top, 8)
            } else {
                V3EmptyLine(text: "No stage data for last night")
            }
            if let m = mins {
                HealthStageBar(parts: [HealthPart(value: m.deep, color: V3.deep), HealthPart(value: m.rem, color: V3.rem),
                                       HealthPart(value: m.light, color: V3.lightSleep), HealthPart(value: m.awake, color: V3.awake)])
                    .padding(.top, 16)
                legend(m).padding(.top, 14)
            }
        }
    }

    private func pct(_ v: Double, of total: Double) -> Int {
        total > 0 ? Int((v / total * 100).rounded()) : 0
    }

    private func legend(_ m: HealthMins) -> some View {
        let asleep = m.deep + m.rem + m.light
        let deepPct = pct(m.deep, of: asleep)
        let remPct = pct(m.rem, of: asleep)
        let lightPct = pct(m.light, of: asleep)
        let times = segments.filter { $0.stage == "awake" }.count
        let awakeNote = times > 0 ? "\(times) times" : "\(pct(m.awake, of: asleep + m.awake))%"
        return HStack(alignment: .top, spacing: 8) {
            HealthLegendCell(dot: V3.deep, name: "Deep", value: V3Format.duration(minutes: m.deep),
                             note: "\(deepPct)%" + (deepPct < 13 ? " · low" : ""), noteColor: deepPct < 13 ? V3.amber : V3.green)
            HealthLegendCell(dot: V3.rem, name: "REM", value: V3Format.duration(minutes: m.rem),
                             note: "\(remPct)%" + (remPct < 20 ? " · low" : ""), noteColor: remPct < 20 ? V3.amber : V3.t2)
            HealthLegendCell(dot: V3.lightSleep, name: "Light", value: V3Format.duration(minutes: m.light),
                             note: "\(lightPct)%")
            HealthLegendCell(dot: V3.awake, name: "Awake", value: V3Format.duration(minutes: m.awake), note: awakeNote)
        }
    }
}

private struct HealthRangeStrip: View {
    let lo: Double
    let hi: Double
    let bands: [HealthBand]
    let value: Double?
    let color: Color
    let ticks: [HealthTick]
    var hollow = false

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let cy: CGFloat = 10
            func xOf(_ v: Double) -> CGFloat { CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)) * w }
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: cy - 4, width: w, height: 8), cornerRadius: 4), with: .color(V3.track))
            for b in bands {
                let r = CGRect(x: xOf(b.lo), y: cy - 4, width: max(xOf(b.hi) - xOf(b.lo), 0), height: 8)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(b.color))
            }
            for (i, t) in ticks.enumerated() {
                let anchor: UnitPoint = i == 0 ? .leading : (i == ticks.count - 1 ? .trailing : .center)
                let label = Text(t.label).font(V3Font.text(11)).foregroundColor(V3.t2)
                ctx.draw(label, at: CGPoint(x: xOf(t.value), y: 29), anchor: anchor)
            }
            if let v = value {
                let x = min(max(xOf(v), 8), w - 8)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 9.5, y: cy - 9.5, width: 19, height: 19)), with: .color(V3.card))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 7, y: cy - 7, width: 14, height: 14)), with: .color(color))
                if hollow {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: cy - 3.5, width: 7, height: 7)), with: .color(V3.card))
                }
            }
        }
        .frame(height: 38)
    }
}

private struct HealthHRCurve: View {
    let values: [Double?]
    let resting: Double?
    let start: Date
    let end: Date

    var body: some View {
        Canvas { ctx, size in
            let n = values.count
            let present = values.compactMap { $0 }
            guard n > 1, let vmin = present.min(), let vmax = present.max() else { return }
            let lo = min(vmin, resting ?? vmin) - 4
            let hi = max(vmax, resting ?? vmax) + 4
            let top: CGFloat = 20
            let bottom: CGFloat = 6
            let plotH = size.height - top - bottom
            func yOf(_ v: Double) -> CGFloat { top + plotH * CGFloat(1 - (v - lo) / (hi - lo)) }
            func xOf(_ i: Int) -> CGFloat { (CGFloat(i) + 0.5) / CGFloat(n) * size.width }
            var pts: [CGPoint] = []
            var minIndex = 0
            var minValue = Double.infinity
            for i in 0..<n {
                guard let v = values[i] else { continue }
                pts.append(CGPoint(x: xOf(i), y: yOf(v)))
                if v < minValue {
                    minValue = v
                    minIndex = i
                }
            }
            guard pts.count >= 2, let first = pts.first, let last = pts.last else { return }
            if let r = resting {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: yOf(r)))
                line.addLine(to: CGPoint(x: size.width, y: yOf(r)))
                ctx.stroke(line, with: .color(V3.t1.opacity(0.3)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                let tag = Text("resting \(Int(r.rounded()))").font(V3Font.text(11, .semibold)).foregroundColor(V3.t2)
                ctx.draw(tag, at: CGPoint(x: size.width, y: yOf(r) + 9), anchor: .trailing)
            }
            let curve = v3SmoothPath(pts)
            var area = curve
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            let fade = Gradient(colors: [V3.heart.opacity(0.28), V3.heart.opacity(0)])
            ctx.fill(area, with: .linearGradient(fade, startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(curve, with: .color(V3.heart), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            let dot = CGPoint(x: xOf(minIndex), y: yOf(minValue))
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 6.5, y: dot.y - 6.5, width: 13, height: 13)), with: .color(V3.card))
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(V3.heart))
            let when = start.addingTimeInterval(end.timeIntervalSince(start) * (Double(minIndex) + 0.5) / Double(n))
            let text = "\(Int(minValue.rounded())) bpm · " + V3Format.hhmm(when)
            let minTag = Text(text).font(V3Font.text(11, .semibold)).foregroundColor(V3.t1)
            ctx.draw(minTag, at: CGPoint(x: min(max(dot.x, 50), size.width - 50), y: max(dot.y - 12, 8)), anchor: .center)
        }
    }
}

private struct HealthWeekBars: View {
    let values: [Double]
    let labels: [String]
    let need: Double

    private var chartH: CGFloat { 110 }

    private func clock(_ v: Double) -> String {
        let total = Int((v * 60).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        let hi = max(need, values.max() ?? need) + 0.5
        VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text(clock(v)).font(V3Font.num(11, .semibold)).foregroundStyle(V3.t2)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(i == values.count - 1 ? V3.sleep : V3.sleep.opacity(0.55))
                                .frame(height: max(chartH * CGFloat(v / hi), 3))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: chartH + 18)
                    }
                }
                HealthDashLine()
                    .stroke(V3.t2, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                    .frame(height: 2)
                    .offset(y: -(chartH * CGFloat(need / hi)))
            }
            HStack(spacing: 8) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                    Text(t).font(V3Font.text(12, .semibold))
                        .foregroundStyle(i == labels.count - 1 ? V3.t1 : V3.t2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct HealthBedtimeStrip: View {
    let hours: [Double]
    let average: Double?

    private var from: Double { 22 }
    private var to: Double { 28 }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let cy: CGFloat = 20
            func xOf(_ h: Double) -> CGFloat { CGFloat((min(max(h, from), to) - from) / (to - from)) * w }
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: cy - 8, width: w, height: 16), cornerRadius: 8), with: .color(V3.track))
            let band = CGRect(x: xOf(22), y: cy - 8, width: xOf(25) - xOf(22), height: 16)
            ctx.fill(Path(roundedRect: band, cornerRadius: 8), with: .color(V3.green.opacity(0.16)))
            if let a = average {
                var line = Path()
                line.move(to: CGPoint(x: xOf(a), y: cy - 14))
                line.addLine(to: CGPoint(x: xOf(a), y: cy + 14))
                ctx.stroke(line, with: .color(V3.t1.opacity(0.4)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            for (i, h) in hours.enumerated() {
                let x = xOf(h)
                if i == hours.count - 1 {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 7, y: cy - 7, width: 14, height: 14)), with: .color(V3.sleep))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: cy - 5, width: 10, height: 10)), with: .color(V3.sleep.opacity(0.45)))
                }
            }
            let marks: [(Double, String)] = [(22, "22:00"), (24, "00:00"), (26, "02:00"), (28, "04:00")]
            for (i, m) in marks.enumerated() {
                let anchor: UnitPoint = i == 0 ? .leading : (i == marks.count - 1 ? .trailing : .center)
                let label = Text(m.1).font(V3Font.text(11)).foregroundColor(V3.t2)
                ctx.draw(label, at: CGPoint(x: xOf(m.0), y: 46), anchor: anchor)
            }
        }
        .frame(height: 56)
    }
}

private struct HealthSplitTile: View {
    let title: String
    let color: Color
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(V3Font.text(12, .semibold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.8)
            if values.count >= 3, let m = healthMean(values) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(m.rounded()))").font(V3Font.num(22)).foregroundStyle(V3.t1)
                    Text("recovery").font(V3Font.text(12)).foregroundStyle(V3.t2)
                }
                Text("\(values.count) nights").font(V3Font.text(11)).foregroundStyle(V3.t2)
            } else {
                Text("Not yet").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HealthPoincare: View {
    let sd1: Double
    let sd2: Double

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2 + 2
            let k = min(0.72, 66 / max(sd1, sd2, 1))
            let a = CGFloat(sd2 * k)
            let b = CGFloat(sd1 * k)
            let q = CGFloat(0.5).squareRoot()
            let reach = min(74, size.height / 2 - 4)
            let axis = V3.t1.opacity(0.08)
            var frame = Path()
            frame.move(to: CGPoint(x: cx + 96, y: size.height - 4))
            frame.addLine(to: CGPoint(x: cx - 96, y: size.height - 4))
            frame.addLine(to: CGPoint(x: cx - 96, y: 4))
            ctx.stroke(frame, with: .color(axis), lineWidth: 2)
            let thisBeat = Text("this beat").font(V3Font.text(11)).foregroundColor(V3.t2)
            ctx.draw(thisBeat, at: CGPoint(x: cx + 104, y: size.height - 4), anchor: .leading)
            let nextBeat = Text("next beat").font(V3Font.text(11)).foregroundColor(V3.t2)
            ctx.draw(nextBeat, at: CGPoint(x: cx - 104, y: 14), anchor: .trailing)
            var diag = Path()
            diag.move(to: CGPoint(x: cx - reach, y: cy + reach))
            diag.addLine(to: CGPoint(x: cx + reach, y: cy - reach))
            ctx.stroke(diag, with: .color(V3.t1.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            let ring = Path(ellipseIn: CGRect(x: -a, y: -b, width: 2 * a, height: 2 * b))
            let placed = ring.applying(CGAffineTransform(translationX: cx, y: cy).rotated(by: -.pi / 4))
            ctx.fill(placed, with: .color(V3.energy.opacity(0.10)))
            ctx.stroke(placed, with: .color(V3.energy), lineWidth: 2)
            var long = Path()
            long.move(to: CGPoint(x: cx - a * q, y: cy + a * q))
            long.addLine(to: CGPoint(x: cx + a * q, y: cy - a * q))
            ctx.stroke(long, with: .color(V3.energy), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            var short = Path()
            short.move(to: CGPoint(x: cx - b * q, y: cy - b * q))
            short.addLine(to: CGPoint(x: cx + b * q, y: cy + b * q))
            ctx.stroke(short, with: .color(V3.t1), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let tag2 = Text("SD2 \(Int(sd2.rounded()))").font(V3Font.text(12, .semibold)).foregroundColor(V3.energy)
            ctx.draw(tag2, at: CGPoint(x: cx + a * q + 8, y: cy - a * q + 4), anchor: .leading)
            let tag1 = Text("SD1 \(Int(sd1.rounded()))").font(V3Font.text(12, .semibold)).foregroundColor(V3.t1)
            ctx.draw(tag1, at: CGPoint(x: cx + b * q + 8, y: cy + b * q + 8), anchor: .leading)
        }
    }
}
