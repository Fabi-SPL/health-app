import SwiftUI
import Combine
import UIKit

enum TodayV3Mode {
    case morning, day, evening, early
}

enum TodayV3SheetKind: String, Identifiable {
    case log, food, recovery
    var id: String { rawValue }
}

struct TodayV3View: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        TodayV3Screen(ble: bleManager, engine: bleManager.healthEngine)
    }
}

private let todayV3Dash = "\u{2013}"
private let todayV3Range = " \u{2013} "

private struct TodayV3Screen: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var engine: HealthEngine
    @ObservedObject private var store = BoardStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lucid_goback_handled_date") private var handledDate: String = ""

    @State private var now = Date()
    @State private var page = 0
    @State private var battery: [BodyBatteryPoint] = []
    @State private var readiness: SleepReadiness?
    @State private var backPlan: BackToSleepPlan?
    @State private var cut: SupabaseClient.CutStatus?
    @State private var tonight: TonightPlan?
    @State private var yesterdayStrain: Double?
    @State private var dayBattery: [StrainBatteryPoint] = []
    @State private var dayBatteryLive = false
    @State private var sheet: TodayV3SheetKind? = nil

    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(ble: BLEManager, engine: HealthEngine) {
        self.ble = ble
        self.engine = engine
    }

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    header
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .refreshable { await load() }
        }
        .task { await load() }
        .onReceive(tick) { d in now = d }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .task { await openForScreenshot() }
        .sheet(item: $sheet) { (k: TodayV3SheetKind) in
            switch k {
            case .log:
                LogV3Sheet().environmentObject(ble)
            case .food:
                FoodV3Sheet().environmentObject(ble)
            case .recovery:
                RecoveryV3Sheet().environmentObject(ble)
            }
        }
        .lucidRendered(.today, .todayLight, .todayMorning, .todayEvening)
    }
}

// MARK: - Mode and derived values

extension TodayV3Screen {
    var hour: Int { Calendar.current.component(.hour, from: now) }

    var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    var freshNight: BoardNight? {
        let n = store.night
        if n.loaded && !n.isFallback { return n }
        return nil
    }

    var wakeTime: Date? {
        let cands: [Date?] = [engine.sleepEndTime, freshNight?.end]
        let ok: [Date] = cands.compactMap { $0 }.filter { $0 <= now && now.timeIntervalSince($0) < 18 * 3600 }
        return ok.max()
    }

    var isEarlyWake: Bool {
        guard hour < 12, handledDate != todayKey, engine.sleepStartTime != nil else { return false }
        guard !engine.sleepDetected || engine.isLikelyAwakeNow else { return false }
        if let w = wakeTime, now.timeIntervalSince(w) > 3 * 3600 { return false }
        guard let p = backPlan, p.shouldGoBack, let at = p.wakeAt else { return false }
        return at > now
    }

    var resolvedMode: TodayV3Mode {
        if isEarlyWake { return .early }
        if engine.sleepDetected && hour < 12 && wakeTime == nil { return .evening }
        if hour >= 21 { return .evening }
        if hour < 5 { return wakeTime != nil ? .morning : .evening }
        if hour < 12 { return .morning }
        return .day
    }

    var mode: TodayV3Mode {
        if let s = LucidScreen.current {
            switch s {
            case .todayMorning: return .morning
            case .todayEvening: return .evening
            case .today, .todayLight: return .day
            default: break
            }
        }
        return resolvedMode
    }

    var recovery: Double? {
        if engine.recoveryScore > 0 { return engine.recoveryScore }
        if !engine.lastNightHasData { return nil }
        if let n = freshNight, let r = n.scores["recovery"] { return r }
        return nil
    }

    var sleepScoreValue: Double? {
        if engine.sleepScore > 0 { return engine.sleepScore }
        return freshNight?.positive("sleep_score")
    }

    var sleepHoursValue: Double? {
        if engine.sleepDurationHours > 0 { return engine.sleepDurationHours }
        return freshNight?.hours
    }

    var strainFresh: Double? {
        if let s = freshNight?.positive("strain"), s < 20.95 { return s }
        if engine.strainScore > 0 && engine.strainScore < 20.95 { return engine.strainScore }
        return nil
    }

    var strainSaturated: Bool {
        if let s = freshNight?.positive("strain"), s >= 20.95 { return true }
        return engine.strainScore >= 20.95
    }

    var strainToday: Double? {
        if let s = strainFresh { return s }
        if strainSaturated { return 21.0 }
        return nil
    }

    var wakeHour: Double {
        if let w = wakeTime { return min(max(V3Format.hourOfDay(w, relativeTo: now), 0), 14) }
        return 7
    }

    func one(_ v: Double) -> String { String(format: "%.1f", v) }
    func zero(_ v: Double) -> String { String(format: "%.0f", v) }

    func baseline(_ pick: (DailyMetric) -> Double?) -> Double? {
        let vals: [Double] = store.lastFullDays(7).compactMap { pick($0) }
        if vals.count < 3 { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    func series(_ pick: (DailyMetric) -> Double?) -> [Double] {
        store.lastFullDays(7).compactMap { pick($0) }
    }

    func clock(minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

// MARK: - Loading

extension TodayV3Screen {
    @MainActor
    func openForScreenshot() async {
        guard let s = LucidScreen.current else { return }
        var kind: TodayV3SheetKind? = nil
        switch s {
        case .log: kind = .log
        case .foodList, .mealDetail: kind = .food
        case .recovery: kind = .recovery
        default: kind = nil
        }
        guard let k = kind else { return }
        try? await Task.sleep(for: .seconds(1.5))
        sheet = k
    }

    func load() async {
        now = Date()
        await ble.syncTonightPlan()
        tonight = await ble.supabase.fetchTonightPlan()
        if !engine.sleepDetected {
            if let r = await ble.supabase.recomputeHealthMetrics() { engine.applyServerRecompute(r) }
        }
        if let bb = await ble.supabase.fetchBodyBatteryAnchor() { engine.bodyBattery = bb }
        battery = await ble.supabase.fetchBodyBatterySeries()
        await store.refresh(force: true)
        now = Date()
        await loadModeData()
        await ble.refreshSmartWakeStatus()
    }

    @MainActor
    func loadModeData() async {
        let h = Calendar.current.component(.hour, from: Date())
        if h >= 12 || h < 5 {
            readiness = await SupabaseClient.shared.fetchSleepReadiness()
        } else {
            readiness = nil
        }
        if h < 12, handledDate != todayKey, let s = engine.sleepStartTime {
            backPlan = await SupabaseClient.shared.planBackToSleep(sleepStart: s)
        } else {
            backPlan = nil
        }
        if let c = try? await SupabaseClient.shared.cutStatus() { cut = c }
        yesterdayStrain = await fetchYesterdayStrain()
        let rhr: Double? = engine.baselineRHR > 30 ? engine.baselineRHR : nil
        let day = await StrainDayAPI.loadDay(day: Calendar.current.startOfDay(for: Date()),
                                             rhrFallback: rhr, monotonyFallback: nil, vo2Fallback: nil)
        dayBattery = day.battery
        dayBatteryLive = day.batteryLive
    }

    @MainActor
    func fetchYesterdayStrain() async -> Double? {
        let client = SupabaseClient.shared
        do { try await client.ensureAuth() } catch { return nil }
        guard let token = client.accessToken else { return nil }
        var berlin = Calendar(identifier: .gregorian)
        if let tz = TimeZone(identifier: "Europe/Berlin") { berlin.timeZone = tz }
        guard let y = berlin.date(byAdding: .day, value: -1, to: Date()) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = berlin
        f.timeZone = berlin.timeZone
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: y)
        let path = "\(client.baseURL)/rest/v1/health_metrics?user_id=eq.\(client.userId)&metric_date=eq.\(day)&select=strain_score"
        guard let url = URL(string: path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(client.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { return nil }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            guard let n = rows.first?["strain_score"] as? NSNumber else { return nil }
            let v = n.doubleValue
            return v > 0 ? v : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Header and mode content

extension TodayV3Screen {
    var header: some View {
        V3Header(date: mode == .early ? "You woke early" : V3Format.dayTitle(now), title: "Today") {
            if mode != .early {
                V3IconButton(symbol: "plus") { sheet = .log }
            }
            V3StrapPill()
            V3KeledButton()
        }
    }

    @ViewBuilder
    var content: some View {
        switch mode {
        case .day: dayContent
        case .morning: morningContent
        case .evening: eveningContent
        case .early: earlyContent
        }
    }

    var dayContent: some View {
        VStack(spacing: 12) {
            dayHero
            if page == 1 { threeTiles }
            batteryCard
            vitalsGrid
            sleepCard
            foodLine
            caffeineCard
            tonightCard(showDrinking: true)
            alarmCard
        }
    }

    var morningContent: some View {
        VStack(spacing: 12) {
            morningHero
            morningCallout
            yesterdayCard
            nightCard
            tonightCard(showDrinking: false)
        }
    }

    var eveningContent: some View {
        VStack(spacing: 12) {
            eveningHero
            eveningCallout
            descentCard
            caffeineCard
            tonightCard(showDrinking: true)
            alarmCard
        }
    }

    var earlyContent: some View {
        VStack(spacing: 12) {
            earlyHero
            earlyCallout
            earlyActions
            cyclesCard
            alarmCard
        }
    }
}

// MARK: - Hero rings

extension TodayV3Screen {
    @ViewBuilder
    var sleepSmallRing: some View {
        if let s = sleepScoreValue {
            V3SmallRing(value: zero(s), progress: min(s / 100, 1), color: V3.sleep, label: "Sleep",
                        sub: sleepHoursValue.map { V3Format.duration(hours: $0) } ?? todayV3Dash)
        } else {
            V3SmallRing(value: todayV3Dash, progress: 0, color: V3.sleep, label: "Sleep", sub: "Not synced", dashed: true)
        }
    }

    @ViewBuilder
    var recoveryHeroRing: some View {
        if let r = recovery {
            V3HeroRing(value: zero(r), progress: min(r / 100, 1), color: V3.recovery(r), label: "Recovery",
                       sub: V3.recoveryWord(r), subColor: V3.recovery(r))
                .contentShape(Rectangle())
                .onTapGesture { sheet = .recovery }
        } else {
            V3HeroRing(value: todayV3Dash, unit: "", progress: 0, color: V3.t3, label: "Recovery", sub: "Not synced")
        }
    }

    @ViewBuilder
    func recoverySmallRing(sub: String) -> some View {
        if let r = recovery {
            V3SmallRing(value: zero(r), progress: min(r / 100, 1), color: V3.recovery(r), label: "Recovery", sub: sub)
        } else {
            V3SmallRing(value: todayV3Dash, progress: 0, color: V3.t3, label: "Recovery", sub: sub, dashed: true)
        }
    }

    @ViewBuilder
    func strainRing(_ v: Double?, sub: String) -> some View {
        if let s = v {
            V3SmallRing(value: one(s), progress: min(s / 21, 1), color: V3.strain, label: "Strain", sub: sub)
        } else {
            V3SmallRing(value: todayV3Dash, progress: 0, color: V3.strain, label: "Strain", sub: sub, dashed: true)
        }
    }

    @ViewBuilder
    var readyHeroRing: some View {
        if let r = readiness, r.status != "no data" {
            V3HeroRing(value: "\(r.sri)", progress: min(Double(r.sri) / 100, 1), color: V3.sleep, label: "Ready for sleep",
                       sub: r.ready ? "Ready now" : "About \(r.etaMin) min to go", subColor: V3.sleep)
        } else {
            V3HeroRing(value: todayV3Dash, unit: "", progress: 0, color: V3.t3, label: "Ready for sleep", sub: "No reading yet")
        }
    }

    var ringTrio: some View {
        V3HeroTrio(glow: recovery.map { V3.recovery($0) } ?? V3.t3) {
            sleepSmallRing
        } middle: {
            recoveryHeroRing
        } right: {
            strainRing(strainToday, sub: "of 21")
        }
    }

    var clockHero: some View {
        TodayV3ClockHero(
            now: now,
            recovery: recovery,
            sleepStart: engine.sleepStartTime ?? freshNight?.start,
            sleepEnd: engine.sleepEndTime ?? freshNight?.end,
            meals: todaysMeals.map { $0.capturedAt },
            tonightBed: tonightBedMinutes,
            tonightWake: tonight.map { $0.windowEndMinutes }
        )
    }

    var dayHero: some View {
        VStack(spacing: 6) {
            TabView(selection: $page) {
                ringTrio
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(0)
                clockHero
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: page == 0 ? 254 : 392)
            .animation(.easeInOut(duration: 0.25), value: page)
            V3PageDots(count: 2, index: page)
        }
    }

    var morningHero: some View {
        V3HeroTrio(glow: recovery.map { V3.recovery($0) } ?? V3.t3) {
            sleepSmallRing
        } middle: {
            recoveryHeroRing
        } right: {
            strainRing(yesterdayStrain, sub: "yesterday")
        }
    }

    var eveningHero: some View {
        V3HeroTrio(glow: V3.sleep) {
            recoverySmallRing(sub: "this morning")
        } middle: {
            readyHeroRing
        } right: {
            strainRing(strainToday, sub: "of 21")
        }
    }

    var threeTiles: some View {
        HStack(spacing: 10) {
            sleepTile
            strainTile
            hrvTile
        }
    }
}

// MARK: - Callouts

extension TodayV3Screen {
    func recoveredRest(_ r: Double) -> String {
        guard let h = sleepHoursValue else { return "Recovery is " + zero(r) + "." }
        return "Recovery is " + zero(r) + " after " + V3Format.duration(hours: h) + " of sleep."
    }

    func nextWakeText(_ p: BackToSleepPlan) -> String {
        if let at = p.wakeAt { return V3Format.hhmm(at) }
        return p.wakeLabel
    }

    @ViewBuilder
    var morningCallout: some View {
        if let r = recovery {
            if r >= 67 {
                let rest: String = recoveredRest(r)
                V3Callout(color: V3.green, bold: "Recovered.", rest: rest)
            } else if let y = yesterdayStrain, y >= 14, y < 20.95 {
                V3Callout(color: V3.amber, bold: "Yesterday cost you.", rest: "Strain was \(one(y)) and recovery is \(zero(r)).")
            } else {
                V3Callout(color: r >= 34 ? V3.amber : V3.red, bold: "Recovery is \(zero(r)).", rest: "Go easy on the first hours.")
            }
        }
    }

    @ViewBuilder
    var eveningCallout: some View {
        if let r = readiness, r.status != "no data" {
            if r.hrGap > 1 {
                V3Callout(color: V3.sleep, bold: "Heart rate \(zero(r.hrGap)) bpm above your floor.",
                          rest: r.ready ? "Lights down." : "Wind down a little longer.")
            } else {
                V3Callout(color: V3.sleep, bold: "Heart rate is at your floor.", rest: r.ready ? "Lights down." : "Almost there.")
            }
        }
    }

    @ViewBuilder
    var earlyCallout: some View {
        if let p = backPlan {
            V3Callout(color: V3.green, bold: "Go back or get up?", rest: "Next clean wake is " + nextWakeText(p) + ".")
        }
    }
}

// MARK: - Early wake

extension TodayV3Screen {
    var cycleInfo: (end: Date, left: Int, elapsed: Double)? {
        guard let s = engine.sleepStartTime else { return nil }
        let len: TimeInterval = 90 * 60
        let since: TimeInterval = now.timeIntervalSince(s)
        if since < 0 { return nil }
        let k: Double = floor(since / len) + 1
        let end: Date = s.addingTimeInterval(k * len)
        let left: Int = Int(ceil(end.timeIntervalSince(now) / 60))
        let elapsed: Double = (since - (k - 1) * len) / len
        return (end, left, elapsed)
    }

    @ViewBuilder
    var earlyRing: some View {
        if let c = cycleInfo {
            V3HeroRing(value: "\(max(c.left, 0))", unit: "min", progress: min(max(c.elapsed, 0), 1), color: V3.sleep,
                       label: "Left in this cycle", sub: "It ends at \(V3Format.hhmm(c.end))", subColor: V3.sleep)
        } else {
            V3HeroRing(value: todayV3Dash, unit: "", progress: 0, color: V3.t3, label: "Left in this cycle", sub: "No sleep start yet")
        }
    }

    var earlyHero: some View {
        earlyRing
            .padding(.top, 26)
            .padding(.bottom, 4)
            .background(V3Glow(color: V3.sleep))
    }

    @ViewBuilder
    var earlyActions: some View {
        if let p = backPlan, let at = p.wakeAt {
            VStack(spacing: 8) {
                V3Button(title: "Go back to sleep", symbol: "moon.fill") {
                    ble.armGoBackWake(at: at)
                    handledDate = todayKey
                }
                Text("The alarm moves to \(V3Format.hhmm(at)), the end of the next cycle")
                    .font(V3Font.text(13))
                    .foregroundStyle(V3.t2)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 4)
                V3Button(title: "Get up now", symbol: "sun.max", secondary: true) {
                    handledDate = todayKey
                }
            }
        }
    }

    @ViewBuilder
    var cyclesCard: some View {
        if let c = cycleInfo {
            V3Card {
                VStack(alignment: .leading, spacing: 14) {
                    V3CardHeader(icon: "moon.fill", iconColor: V3.sleep, title: "Sleep cycles", trailing: "90 min each")
                    TodayV3CycleStrip(now: now, cycleEnd: c.end, wakeAt: backPlan?.wakeAt)
                    HStack(spacing: 14) {
                        legendDot(V3.sleep, "This cycle", hollow: false)
                        legendDot(V3.sleep, "One more cycle", hollow: true)
                        legendDot(V3.t1, "Now \(V3Format.hhmm(now))", hollow: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func legendDot(_ color: Color, _ text: String, hollow: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(color, lineWidth: hollow ? 1.5 : 0)
                .background(Circle().fill(hollow ? Color.clear : color))
                .frame(width: 8, height: 8)
            Text(text)
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
        }
    }
}

// MARK: - Data helpers

extension TodayV3Screen {
    var todaysMeals: [FoodEntry] {
        store.meals.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: now) }
    }

    var tonightBedMinutes: Int? {
        guard let p = tonight, let t = p.targetSleepH else { return nil }
        return ((p.windowEndMinutes - Int((t * 60).rounded())) % 1440 + 1440) % 1440
    }

    var hrvValue: Double? { freshNight?.positive("hrv_avg") }
    var rhrValue: Double? { freshNight?.positive("resting_hr") }
    var respValue: Double? { freshNight?.positive("respiratory_rate") }

    var hrvBase: Double? { baseline { $0.hrv } }
    var rhrBase: Double? { baseline { $0.restingHr } }
    var hrvSeries: [Double] { series { $0.hrv } }
    var rhrSeries: [Double] { series { $0.restingHr } }

    func deltaText(_ v: Double, _ avg: Double?, unit: String) -> String? {
        guard let a = avg else { return nil }
        let d: Double = v - a
        if abs(d) < 0.5 { return "No change" }
        return V3Format.signed(d) + " " + unit
    }

    func deltaColor(_ v: Double, _ avg: Double?, higherIsBetter: Bool) -> Color {
        guard let a = avg else { return V3.t2 }
        return (v >= a) == higherIsBetter ? V3.green : V3.amber
    }

    var previousDay: DailyMetric? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        let key: String = f.string(from: now)
        return store.lastFullDays(14).last(where: { $0.date < key })
    }

    func signedDuration(_ minutes: Double) -> String {
        (minutes < 0 ? "\u{2212}" : "+") + V3Format.duration(minutes: abs(minutes))
    }
}

// MARK: - Tiles

extension TodayV3Screen {
    @ViewBuilder
    var sleepTile: some View {
        if let h = sleepHoursValue {
            V3Tile(icon: "moon.fill", iconColor: V3.sleep, title: "Sleep", value: V3Format.duration(hours: h),
                   delta: sleepScoreValue.map { "\(zero($0)) score" })
        } else {
            V3Tile(icon: "moon.fill", iconColor: V3.sleep, title: "Sleep", value: "", empty: "No data")
        }
    }

    @ViewBuilder
    var strainTile: some View {
        if let s = strainToday {
            V3Tile(icon: "flame.fill", iconColor: V3.strain, title: "Strain", value: one(s), unit: "/ 21",
                   delta: strainSaturated ? nil : V3.strainWord(s))
        } else {
            V3Tile(icon: "flame.fill", iconColor: V3.strain, title: "Strain", value: "", empty: "No data")
        }
    }

    @ViewBuilder
    var hrvTile: some View {
        if let v = hrvValue {
            V3Tile(icon: "waveform.path.ecg", iconColor: V3.energy, title: "HRV", value: zero(v), unit: "ms",
                   delta: deltaText(v, hrvBase, unit: "ms"),
                   deltaColor: deltaColor(v, hrvBase, higherIsBetter: true),
                   spark: hrvSeries, sparkColor: V3.energy)
        } else {
            V3Tile(icon: "waveform.path.ecg", iconColor: V3.energy, title: "HRV", value: "", empty: "No data")
        }
    }

    @ViewBuilder
    var rhrTile: some View {
        if let v = rhrValue {
            V3Tile(icon: "heart.fill", iconColor: V3.heart, title: "Resting HR", value: zero(v), unit: "bpm",
                   delta: deltaText(v, rhrBase, unit: "bpm"),
                   deltaColor: deltaColor(v, rhrBase, higherIsBetter: false),
                   spark: rhrSeries, sparkColor: V3.heart)
        } else {
            V3Tile(icon: "heart.fill", iconColor: V3.heart, title: "Resting HR", value: "", empty: "No data")
        }
    }

    @ViewBuilder
    var bedtimeTile: some View {
        if let s = freshNight?.start {
            V3Tile(icon: "moon.fill", iconColor: V3.sleep, title: "Bedtime", value: V3Format.hhmm(s))
        } else {
            V3Tile(icon: "moon.fill", iconColor: V3.sleep, title: "Bedtime", value: "", empty: "No data")
        }
    }

    @ViewBuilder
    var respTile: some View {
        if let v = respValue {
            V3Tile(icon: "lungs.fill", iconColor: V3.rem, title: "Respiration", value: one(v), unit: "/min")
        } else {
            V3Tile(icon: "lungs.fill", iconColor: V3.rem, title: "Respiration", value: "", empty: "No data")
        }
    }

    var vitalsGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                hrvTile
                rhrTile
            }
            HStack(spacing: 10) {
                bedtimeTile
                respTile
            }
        }
    }
}

// MARK: - Body battery

extension TodayV3Screen {
    var batteryPoints: [V3AreaChart.P] {
        var seen = Set<Double>()
        var out: [V3AreaChart.P] = []
        for p in dayBattery.sorted(by: { $0.at < $1.at }) {
            let x: Double = V3Format.hourOfDay(p.at, relativeTo: now)
            if x < 0 || x > 24 { continue }
            if seen.insert(x).inserted { out.append(V3AreaChart.P(x: x, y: p.value)) }
        }
        return out
    }

    var batteryRightText: String? {
        let pts = dayBattery.sorted(by: { $0.at < $1.at })
        guard let f = pts.first, let l = pts.last else { return nil }
        _ = l
        return "\(zero(f.value)) at wake"
    }

    var batteryRateText: String? {
        let pts = dayBattery.sorted(by: { $0.at < $1.at })
        guard let f = pts.first, let l = pts.last else { return nil }
        var parts: [String] = dayBatteryLive ? [] : ["estimated"]
        let hrs: Double = l.at.timeIntervalSince(f.at) / 3600
        if hrs >= 1.5 && f.value > l.value {
            parts.append(V3Format.signed(-(f.value - l.value) / hrs, decimals: 1) + " an hour")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    var batteryChart: some View {
        let pts: [V3AreaChart.P] = batteryPoints
        let lo: Double = floor(min(pts.first?.x ?? 7, 20))
        let tickList: [Double] = [9, 12, 15, 18, 21, 24].filter { $0 > lo }
        V3AreaChart(past: pts, color: V3.energy, xDomain: lo...24, yDomain: 0...100,
                    ticks: tickList, gridLines: [25, 50, 75])
    }

    var batteryCard: some View {
        V3Card {
            VStack(alignment: .leading, spacing: 12) {
                V3CardHeader(icon: "bolt.fill", iconColor: V3.energy, title: "Body battery", chevron: true)
                if batteryPoints.count < 2 {
                    V3EmptyLine(text: "Battery not synced yet")
                } else {
                    HStack(alignment: .lastTextBaseline) {
                        V3BigNumber(value: zero(dayBattery.max(by: { $0.at < $1.at })?.value ?? 0), unit: "/ 100")
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let w = batteryRightText {
                                Text(w).font(V3Font.text(13)).foregroundStyle(V3.t2)
                            }
                            if let r = batteryRateText {
                                Text(r).font(V3Font.text(12)).foregroundStyle(V3.t3)
                            }
                        }
                    }
                    batteryChart
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sleep card

extension TodayV3Screen {
    var sleepRangeText: String? {
        let s: Date? = freshNight?.start ?? engine.sleepStartTime
        let e: Date? = freshNight?.end ?? engine.sleepEndTime
        guard let a = s, let b = e, b > a else { return nil }
        return V3Format.hhmm(a) + todayV3Range + V3Format.hhmm(b)
    }

    func stageItem(_ label: String, _ key: String, _ color: Color) -> some View {
        V3LegendItem(dot: color, label: label,
                     value: freshNight?.positive(key).map { V3Format.duration(minutes: $0) } ?? todayV3Dash)
    }

    var sleepCard: some View {
        V3Card {
            VStack(alignment: .leading, spacing: 12) {
                V3CardHeader(icon: "moon.fill", iconColor: V3.sleep, title: "Sleep", trailing: sleepRangeText, chevron: true)
                if let h = sleepHoursValue {
                    HStack(alignment: .firstTextBaseline) {
                        V3BigNumber(value: V3Format.duration(hours: h), unit: "asleep")
                        Spacer()
                        if let s = sleepScoreValue {
                            Text("\(zero(s)) score")
                                .font(V3Font.text(14, .semibold))
                                .foregroundStyle(V3.sleep)
                        }
                    }
                    hypnogramBlock
                    HStack(alignment: .top, spacing: 8) {
                        stageItem("Deep", "deep_min", V3.deep)
                        stageItem("REM", "rem_min", V3.rem)
                        stageItem("Light", "light_min", V3.lightSleep)
                        stageItem("Awake", "awake_min", V3.awake)
                    }
                } else {
                    V3EmptyLine(text: "No sleep recorded for last night")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    var hypnogramBlock: some View {
        if let n = freshNight, let a = n.start, let b = n.end, b > a, !store.stages.isEmpty {
            VStack(spacing: 6) {
                TodayV3Hypnogram(segments: store.stages, start: a, end: b)
                HStack {
                    Text(V3Format.hhmm(a))
                    Spacer()
                    Text(V3Format.hhmm(b))
                }
                .font(V3Font.num(11, .medium))
                .foregroundStyle(V3.t3)
            }
        }
    }
}

// MARK: - Food line

extension TodayV3Screen {
    var foodLine: some View {
        Button { sheet = .food } label: {
            V3Card {
                HStack(spacing: 14) {
                    foodRings
                    VStack(alignment: .leading, spacing: 3) {
                        foodTitle
                        foodSub
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(V3.t3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    var foodRings: some View {
        ZStack {
            V3Ring(progress: cut?.intakePct ?? 0, color: V3.kcal, lineWidth: 6)
                .frame(width: 52, height: 52)
            V3Ring(progress: cut?.proteinPct ?? 0, color: V3.protein, lineWidth: 5)
                .frame(width: 32, height: 32)
        }
        .frame(width: 52, height: 52)
    }

    @ViewBuilder
    var foodTitle: some View {
        if let c = cut {
            Text("\(c.consumed) of \(c.targetIntake) kcal")
                .font(V3Font.num(20))
                .foregroundStyle(V3.t1)
        } else {
            Text("Food")
                .font(V3Font.text(17, .semibold))
                .foregroundStyle(V3.t1)
        }
    }

    @ViewBuilder
    var foodSub: some View {
        if let c = cut {
            HStack(spacing: 4) {
                Text("\(max(c.proteinTarget - Int(c.proteinG.rounded()), 0)) g")
                    .foregroundStyle(V3.protein)
                Text("protein to go")
                    .foregroundStyle(V3.t2)
            }
            .font(V3Font.text(13, .semibold))
        } else {
            Text("Tap to log a meal")
                .font(V3Font.text(13))
                .foregroundStyle(V3.t2)
        }
    }
}

// MARK: - Caffeine

private struct TodayV3CaffeineHit {
    let at: Date
    let mg: Double
}

extension TodayV3Screen {
    private var caffeineHits: [TodayV3CaffeineHit] {
        var out: [TodayV3CaffeineHit] = []
        for m in todaysMeals {
            let tagged: Bool = m.items.contains { $0.mindTags.contains("caffeine") }
            let cap: String = (m.caption ?? "").lowercased()
            if !(tagged || cap.contains("caffeine")) { continue }
            var mg: Double = 80
            if let r = cap.range(of: #"\d+(?=\s*mg)"#, options: .regularExpression), let v = Double(cap[r]) { mg = v }
            out.append(TodayV3CaffeineHit(at: m.capturedAt, mg: mg))
        }
        return out
    }

    private func caffeineMg(_ hits: [TodayV3CaffeineHit], at t: Date) -> Double {
        var total: Double = 0
        for h in hits {
            let dt: Double = t.timeIntervalSince(h.at)
            if dt >= 0 { total += h.mg * pow(0.5, dt / (5 * 3600)) }
        }
        return total
    }

    private func caffeineClear(_ hits: [TodayV3CaffeineHit]) -> Date? {
        guard let last = hits.map({ $0.at }).max() else { return nil }
        for m in 0...(36 * 60) {
            let t: Date = last.addingTimeInterval(Double(m) * 60)
            if caffeineMg(hits, at: t) <= 50 { return t }
        }
        return nil
    }

    private func caffeineCurve(_ hits: [TodayV3CaffeineHit]) -> [Double] {
        let day: Date = Calendar.current.startOfDay(for: now)
        var out: [Double] = []
        for i in 0...60 {
            let t: Date = day.addingTimeInterval((9 + Double(i) * 0.25) * 3600)
            out.append(caffeineMg(hits, at: t))
        }
        return out
    }

    private func caffeineClearLabel(_ c: Date?) -> String? {
        guard let t = c else { return nil }
        return (t > now ? "sleep-safe at " : "sleep-safe since ") + V3Format.hhmm(t)
    }

    @ViewBuilder
    var caffeineCard: some View {
        let hits: [TodayV3CaffeineHit] = caffeineHits
        let clear: Date? = caffeineClear(hits)
        V3Card {
            VStack(alignment: .leading, spacing: 12) {
                V3CardHeader(icon: "cup.and.saucer.fill", iconColor: V3.kcal, title: "Caffeine in you",
                             trailing: caffeineClearLabel(clear))
                if hits.isEmpty {
                    V3EmptyLine(text: "No caffeine logged today")
                } else {
                    V3BigNumber(value: zero(caffeineMg(hits, at: now)), unit: "mg now")
                    TodayV3CaffeineChart(curve: caffeineCurve(hits),
                                         nowHour: V3Format.hourOfDay(now, relativeTo: now),
                                         clearHour: clear.map { V3Format.hourOfDay($0, relativeTo: now) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tonight and alarm

extension TodayV3Screen {
    var drinkingBinding: Binding<Bool> {
        Binding<Bool>(
            get: { ble.tonightPlanMode == "alcohol" },
            set: { isOn in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    _ = await ble.supabase.setDrinkingTonight(isOn)
                    await ble.syncTonightPlan()
                    tonight = await ble.supabase.fetchTonightPlan()
                }
            }
        )
    }

    var alarmBinding: Binding<Bool> {
        Binding<Bool>(
            get: { ble.smartWakeArmed },
            set: { isOn in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    if isOn {
                        _ = await ble.armSmartWake(latestWake: nil)
                    } else {
                        await ble.cancelSmartWake()
                    }
                    await ble.refreshSmartWakeStatus()
                }
            }
        )
    }

    var tonightTitle: String {
        if let b = tonightBedMinutes { return "In bed by " + clock(minutes: b) }
        return "No plan yet"
    }

    var tonightSub: String {
        if let t = tonight?.targetSleepH, t > 0 {
            return "Gets you " + V3Format.duration(hours: t) + " before the alarm"
        }
        return ble.tonightPlanNote
    }

    var drinkRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(V3.line).frame(height: 1).padding(.top, 14)
            HStack(spacing: 14) {
                V3IconWell(symbol: "wineglass", color: V3.kcal, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drinking tonight")
                        .font(V3Font.text(15, .semibold))
                        .foregroundStyle(V3.t1)
                    Text("Tells recovery to expect it")
                        .font(V3Font.text(13))
                        .foregroundStyle(V3.t2)
                }
                Spacer(minLength: 0)
                V3Toggle(isOn: drinkingBinding)
            }
            .padding(.top, 14)
        }
    }

    func tonightCard(showDrinking: Bool) -> some View {
        V3Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    V3IconWell(symbol: "moon.fill", color: V3.sleep, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tonight")
                            .font(V3Font.text(13, .semibold))
                            .foregroundStyle(V3.t2)
                        Text(tonightTitle)
                            .font(V3Font.text(20, .bold))
                            .tracking(-0.6)
                            .foregroundStyle(V3.t1)
                        if !tonightSub.isEmpty {
                            Text(tonightSub)
                                .font(V3Font.text(13))
                                .foregroundStyle(V3.t2)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if showDrinking { drinkRow }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var alarmTitle: String {
        if ble.smartWakeArmed {
            if let w = ble.smartWakeStatus?.projectedWindow, !w.isEmpty { return w }
            if let a = ble.smartWakeStatus?.earliestWakeLabel, let b = ble.smartWakeStatus?.targetWakeLabel {
                return a + todayV3Range + b
            }
            if let l = ble.smartWakePlan?.latestWakeLabel { return "By " + l }
            return "Armed"
        }
        if let p = tonight {
            return clock(minutes: p.windowStartMinutes) + todayV3Range + clock(minutes: p.windowEndMinutes)
        }
        return "Off"
    }

    var alarmSub: String {
        if ble.smartWakeArmed {
            if let n = ble.smartWakeStatus?.note, !n.isEmpty { return n }
            if let n = ble.smartWakePlan?.note, !n.isEmpty { return n }
            return ""
        }
        return tonight == nil ? "" : "Switch on to wake in light sleep"
    }

    var alarmCard: some View {
        V3Card {
            HStack(spacing: 14) {
                V3IconWell(symbol: "alarm", color: V3.amber, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart alarm")
                        .font(V3Font.text(13, .semibold))
                        .foregroundStyle(V3.t2)
                    Text(alarmTitle)
                        .font(V3Font.num(22))
                        .tracking(-0.66)
                        .foregroundStyle(ble.smartWakeArmed ? V3.t1 : V3.t2)
                    if !alarmSub.isEmpty {
                        Text(alarmSub)
                            .font(V3Font.text(13))
                            .foregroundStyle(V3.t2)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                V3Toggle(isOn: alarmBinding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Morning cards

extension TodayV3Screen {
    var yesterdayLabel: String {
        let cal = Calendar.current
        let y: Date = cal.date(byAdding: .day, value: -1, to: now) ?? now
        return V3Format.shortDay(y)
    }

    var yesterdayCard: some View {
        V3Card {
            VStack(alignment: .leading, spacing: 12) {
                V3CardHeader(icon: "speedometer", iconColor: V3.strain, title: "Yesterday", trailing: yesterdayLabel)
                if let y = yesterdayStrain {
                    V3BigNumber(value: one(y),
                                unit: y >= 20.95 ? "strain" : "strain, " + V3.strainWord(y).lowercased(),
                                color: V3.strain)
                } else {
                    V3EmptyLine(text: "No strain recorded for yesterday")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func nightStat(_ title: String, _ value: String, _ unit: String, _ delta: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(V3Font.text(12, .semibold))
                .foregroundStyle(V3.t2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(V3Font.num(22))
                    .foregroundStyle(V3.t1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !unit.isEmpty {
                    Text(unit)
                        .font(V3Font.text(12))
                        .foregroundStyle(V3.t2)
                }
            }
            if let d = delta {
                Text(d)
                    .font(V3Font.text(12, .medium))
                    .foregroundStyle(V3.t2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var nightCard: some View {
        let prev: DailyMetric? = previousDay
        let hrvDelta: String? = diffText(hrvValue, prev?.hrv, "ms")
        let rhrDelta: String? = diffText(rhrValue, prev?.restingHr, "bpm")
        var sleepDelta: String?
        if let a = sleepHoursValue, let b = prev?.sleepHours { sleepDelta = signedDuration((a - b) * 60) }
        return V3Card {
            VStack(alignment: .leading, spacing: 14) {
                V3CardHeader(icon: "moon.fill", iconColor: V3.sleep, title: "Your night", trailing: "vs the night before")
                if freshNight == nil && sleepHoursValue == nil {
                    V3EmptyLine(text: "No night recorded yet")
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        nightStat("HRV", hrvValue.map { zero($0) } ?? todayV3Dash, "ms", hrvDelta)
                        nightStat("Resting HR", rhrValue.map { zero($0) } ?? todayV3Dash, "bpm", rhrDelta)
                        nightStat("Asleep", sleepHoursValue.map { V3Format.duration(hours: $0) } ?? todayV3Dash, "", sleepDelta)
                    }
                    if let s = freshNight?.start {
                        Rectangle().fill(V3.line).frame(height: 1)
                        Text("In bed at " + V3Format.hhmm(s))
                            .font(V3Font.text(13))
                            .foregroundStyle(V3.t2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func signedNumber(_ d: Double, _ unit: String) -> String {
        if abs(d) < 0.5 { return "No change" }
        return V3Format.signed(d) + " " + unit
    }

    func diffText(_ now: Double?, _ before: Double?, _ unit: String) -> String? {
        guard let a = now, let b = before else { return nil }
        return signedNumber(a - b, unit)
    }
}

// MARK: - Evening heart rate descent

extension TodayV3Screen {
    var descentValues: [Double] {
        let raw: [Double] = engine.recentHR.suffix(60).filter { $0 > 30 && $0 < 220 }
        if raw.count < 12 { return [] }
        var out: [Double] = []
        var i = 0
        while i < raw.count {
            let chunk: ArraySlice<Double> = raw[i..<min(i + 6, raw.count)]
            out.append(chunk.reduce(0, +) / Double(chunk.count))
            i += 6
        }
        return out
    }

    var descentCard: some View {
        let vals: [Double] = descentValues
        return V3Card {
            VStack(alignment: .leading, spacing: 12) {
                V3CardHeader(icon: "heart.fill", iconColor: V3.heart, title: "Heart rate, settling", trailing: "last 10 min")
                if let first = vals.first, let last = vals.last, vals.count >= 3 {
                    HStack(alignment: .firstTextBaseline) {
                        V3BigNumber(value: zero(last), unit: "bpm now")
                        Spacer()
                        if first - last >= 1 {
                            Text("from " + zero(first))
                                .font(V3Font.text(13, .semibold))
                                .foregroundStyle(V3.t2)
                        }
                    }
                    TodayV3Descent(values: vals, floorHR: readiness?.hrFloor)
                } else {
                    V3EmptyLine(text: "Waiting for the strap to stream heart rate")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Drawings

private struct TodayV3Hypnogram: View {
    let segments: [StageSegment]
    let start: Date
    let end: Date

    private func lane(_ s: String) -> Int {
        switch s {
        case "awake": return 0
        case "rem": return 1
        case "light": return 2
        default: return 3
        }
    }

    private func tint(_ s: String) -> Color {
        switch s {
        case "awake": return V3.awake
        case "rem": return V3.rem
        case "light": return V3.lightSleep
        default: return V3.deep
        }
    }

    private func xFor(_ d: Date, _ w: CGFloat) -> CGFloat {
        let total: Double = max(end.timeIntervalSince(start), 1)
        let f: Double = min(max(d.timeIntervalSince(start) / total, 0), 1)
        return CGFloat(f) * w
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(segments) { seg in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint(seg.stage))
                        .frame(width: max(xFor(seg.end, geo.size.width) - xFor(seg.start, geo.size.width), 2), height: 16)
                        .offset(x: xFor(seg.start, geo.size.width), y: CGFloat(lane(seg.stage)) * 22)
                }
            }
        }
        .frame(height: 82)
    }
}

private struct TodayV3CaffeineChart: View {
    let curve: [Double]
    let nowHour: Double
    let clearHour: Double?

    private let limit: Double = 50

    private var top: Double { max((curve.max() ?? 0) * 1.2, limit * 1.6) }

    private func yFor(_ mg: Double, _ h: CGFloat) -> CGFloat {
        h - CGFloat(min(mg / top, 1)) * (h - 8) - 4
    }

    private func xFor(_ hour: Double, _ w: CGFloat) -> CGFloat {
        CGFloat(min(max((hour - 9) / 15, 0), 1)) * w
    }

    private var nowIndex: Int {
        let f: Double = (nowHour - 9) / 15 * Double(max(curve.count - 1, 0))
        return Int(min(max(f.rounded(), 0), Double(max(curve.count - 1, 0))))
    }

    private func pts(_ lo: Int, _ hi: Int, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        let a: Int = max(lo, 0)
        let b: Int = min(hi, curve.count - 1)
        if curve.count < 2 || a > b { return [] }
        let step: CGFloat = w / CGFloat(curve.count - 1)
        var out: [CGPoint] = []
        for i in a...b { out.append(CGPoint(x: CGFloat(i) * step, y: yFor(curve[i], h))) }
        return out
    }

    private func areaPath(_ p: [CGPoint], _ h: CGFloat) -> Path {
        guard p.count > 1, let f = p.first, let l = p.last else { return Path() }
        var path = v3SmoothPath(p)
        path.addLine(to: CGPoint(x: l.x, y: h))
        path.addLine(to: CGPoint(x: f.x, y: h))
        path.closeSubpath()
        return path
    }

    private func limitLine(_ w: CGFloat, _ y: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: w, y: y))
        return p
    }

    @ViewBuilder
    private func plot(_ w: CGFloat, _ h: CGFloat) -> some View {
        let past: [CGPoint] = nowHour >= 9 ? pts(0, nowIndex, w, h) : []
        let future: [CGPoint] = pts(nowIndex, curve.count - 1, w, h)
        let yLimit: CGFloat = yFor(limit, h)
        ZStack(alignment: .topLeading) {
            areaPath(past, h)
                .fill(LinearGradient(colors: [V3.kcal.opacity(0.28), V3.kcal.opacity(0)], startPoint: .top, endPoint: .bottom))
            limitLine(w, yLimit)
                .stroke(V3.sleep, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            v3SmoothPath(future)
                .stroke(V3.kcal.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
            v3SmoothPath(past)
                .stroke(V3.kcal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            Text("50 mg, sleep-safe")
                .font(V3Font.text(11, .medium))
                .foregroundStyle(V3.sleep)
                .position(x: 56, y: yLimit - 9)
            if let c = clearHour, c >= 9, c <= 24 {
                Circle()
                    .fill(V3.card)
                    .overlay(Circle().stroke(V3.sleep, lineWidth: 2))
                    .frame(width: 10, height: 10)
                    .position(x: xFor(c, w), y: yLimit)
            }
            if let l = past.last {
                Circle()
                    .fill(V3.kcal)
                    .frame(width: 9, height: 9)
                    .position(x: l.x, y: l.y)
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                plot(geo.size.width, geo.size.height)
            }
            .frame(height: 96)
            HStack {
                Text("09")
                Spacer()
                Text("12")
                Spacer()
                Text("15")
                Spacer()
                Text("18")
                Spacer()
                Text("21")
                Spacer()
                Text("24")
            }
            .font(V3Font.num(11, .medium))
            .foregroundStyle(V3.t3)
        }
    }
}

private struct TodayV3Descent: View {
    let values: [Double]
    let floorHR: Double?

    private var lo: Double { min(values.min() ?? 0, floorHR ?? Double.greatestFiniteMagnitude) - 3 }
    private var hi: Double { (values.max() ?? 1) + 3 }

    private func yFor(_ v: Double, _ h: CGFloat) -> CGFloat {
        let span: Double = max(hi - lo, 1)
        return h - CGFloat((v - lo) / span) * h
    }

    private func pts(_ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        if values.count < 2 { return [] }
        let step: CGFloat = w / CGFloat(values.count - 1)
        var out: [CGPoint] = []
        for (i, v) in values.enumerated() { out.append(CGPoint(x: CGFloat(i) * step, y: yFor(v, h))) }
        return out
    }

    private func areaPath(_ p: [CGPoint], _ h: CGFloat) -> Path {
        guard p.count > 1, let f = p.first, let l = p.last else { return Path() }
        var path = v3SmoothPath(p)
        path.addLine(to: CGPoint(x: l.x, y: h))
        path.addLine(to: CGPoint(x: f.x, y: h))
        path.closeSubpath()
        return path
    }

    private func floorLine(_ w: CGFloat, _ y: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: w, y: y))
        return p
    }

    @ViewBuilder
    private func plot(_ w: CGFloat, _ h: CGFloat) -> some View {
        let p: [CGPoint] = pts(w, h)
        ZStack(alignment: .topLeading) {
            areaPath(p, h)
                .fill(LinearGradient(colors: [V3.heart.opacity(0.25), V3.heart.opacity(0)], startPoint: .top, endPoint: .bottom))
            if let f = floorHR {
                floorLine(w, yFor(f, h))
                    .stroke(V3.t2, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Text("floor " + String(format: "%.0f", f))
                    .font(V3Font.text(11, .medium))
                    .foregroundStyle(V3.t2)
                    .position(x: 30, y: yFor(f, h) - 9)
            }
            v3SmoothPath(p)
                .stroke(V3.heart, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            if let l = p.last {
                Circle()
                    .fill(V3.heart)
                    .frame(width: 9, height: 9)
                    .position(x: l.x, y: l.y)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            plot(geo.size.width, geo.size.height)
        }
        .frame(height: 96)
    }
}

private struct TodayV3ClockArc: Shape {
    let from: Double
    let span: Double
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if span <= 0 { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let steps: Int = max(Int((span / 0.1).rounded(.up)), 1)
        for i in 0...steps {
            let h: Double = from + span * Double(i) / Double(steps)
            let a: Double = h / 24 * 2 * Double.pi - Double.pi / 2
            let pt = CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

private struct TodayV3ClockTicks: Shape {
    let major: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        for h in 0..<24 {
            let isMajor: Bool = h % 6 == 0
            if isMajor != major { continue }
            let a: Double = Double(h) / 24 * 2 * Double.pi - Double.pi / 2
            let r2: CGFloat = isMajor ? 100 : 104
            p.move(to: CGPoint(x: c.x + 108 * CGFloat(cos(a)), y: c.y + 108 * CGFloat(sin(a))))
            p.addLine(to: CGPoint(x: c.x + r2 * CGFloat(cos(a)), y: c.y + r2 * CGFloat(sin(a))))
        }
        return p
    }
}

private struct TodayV3ClockHero: View {
    let now: Date
    let recovery: Double?
    let sleepStart: Date?
    let sleepEnd: Date?
    let meals: [Date]
    let tonightBed: Int?
    let tonightWake: Int?

    private let size: CGFloat = 300
    private let radius: CGFloat = 128

    private func pt(_ hour: Double, _ r: CGFloat) -> CGPoint {
        let a: Double = hour / 24 * 2 * Double.pi - Double.pi / 2
        return CGPoint(x: size / 2 + r * CGFloat(cos(a)), y: size / 2 + r * CGFloat(sin(a)))
    }

    private var nowHour: Double { V3Format.hourOfDay(now, relativeTo: now) }

    private var sleepSpan: (from: Double, span: Double)? {
        guard let s = sleepStart, let e = sleepEnd, e > s else { return nil }
        let a: Double = max(V3Format.hourOfDay(s, relativeTo: now), 0)
        let b: Double = min(V3Format.hourOfDay(e, relativeTo: now), 24)
        if b <= a { return nil }
        return (a, b - a)
    }

    private var sleepMinutes: Double? {
        guard sleepSpan != nil, let s = sleepStart, let e = sleepEnd else { return nil }
        return e.timeIntervalSince(s) / 60
    }

    private var tonightSpan: (from: Double, span: Double)? {
        guard let b = tonightBed, let w = tonightWake else { return nil }
        var span: Double = Double(w - b) / 60
        if span <= 0 { span += 24 }
        if span > 16 { return nil }
        return (Double(b) / 60, span)
    }

    private var mealText: String {
        meals.isEmpty ? "No meals logged" : meals.count == 1 ? "1 meal" : "\(meals.count) meals"
    }

    private var glowColor: Color { recovery.map { V3.recovery($0) } ?? V3.sleep }

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(V3.track, lineWidth: 16)
                .frame(width: radius * 2, height: radius * 2)
            if let s = sleepSpan {
                TodayV3ClockArc(from: s.from, span: s.span, radius: radius)
                    .stroke(V3.sleep, style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
            }
            if nowHour + 0.45 < 23.9 {
                TodayV3ClockArc(from: nowHour + 0.45, span: 23.9 - (nowHour + 0.45), radius: radius)
                    .stroke(V3.t1.opacity(0.3), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 7]))
            }
            if let t = tonightSpan {
                TodayV3ClockArc(from: t.from, span: t.span, radius: radius + 22)
                    .stroke(V3.sleep.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 6]))
            }
            Group {
                TodayV3ClockTicks(major: false)
                    .stroke(V3.t1.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                TodayV3ClockTicks(major: true)
                    .stroke(V3.t1.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            ForEach([0, 6, 12, 18], id: \.self) { h in
                Text(String(format: "%02d", h))
                    .font(V3Font.num(11, .semibold))
                    .foregroundStyle(V3.t3)
                    .position(pt(Double(h), radius - 40))
            }
            ForEach(Array(meals.enumerated()), id: \.offset) { _, m in
                ZStack {
                    Circle().fill(V3.bg).frame(width: 13.5, height: 13.5)
                    Circle().fill(V3.amber).frame(width: 8.5, height: 8.5)
                }
                .position(pt(V3Format.hourOfDay(m, relativeTo: now), radius))
            }
            ZStack {
                Circle().fill(V3.bg).frame(width: 23, height: 23)
                Circle().fill(V3.t1).frame(width: 17, height: 17)
            }
            .position(pt(nowHour, radius))
            if let t = tonightSpan {
                ZStack {
                    Circle().fill(V3.bg).frame(width: 18, height: 18)
                    Circle().stroke(V3.sleep, lineWidth: 1.5).frame(width: 18, height: 18)
                    Image(systemName: "moon.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(V3.sleep)
                }
                .position(pt(t.from, radius + 22))
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var center: some View {
        VStack(spacing: 0) {
            Text("Recovery")
                .font(V3Font.text(13, .semibold))
                .foregroundStyle(V3.t2)
            if let r = recovery {
                Text(String(format: "%.0f", r))
                    .font(V3Font.num(64, .bold))
                    .tracking(-3)
                    .foregroundStyle(V3.recovery(r))
                Text(V3.recoveryWord(r))
                    .font(V3Font.text(13, .semibold))
                    .foregroundStyle(V3.t1)
                    .padding(.top, 4)
            } else {
                Text(todayV3Dash)
                    .font(V3Font.num(64, .bold))
                    .foregroundStyle(V3.t3)
                Text("Not synced")
                    .font(V3Font.text(13, .semibold))
                    .foregroundStyle(V3.t2)
                    .padding(.top, 4)
            }
        }
    }

    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t)
                .font(V3Font.text(13))
                .foregroundStyle(V3.t2)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                dial
                center
            }
            .background(V3Glow(color: glowColor))
            HStack(spacing: 18) {
                if let m = sleepMinutes {
                    legendItem(V3.sleep, "Slept " + V3Format.duration(minutes: m))
                }
                legendItem(V3.amber, mealText)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }
}

private struct TodayV3CycleStrip: View {
    let now: Date
    let cycleEnd: Date
    let wakeAt: Date?

    private let barY: CGFloat = 30
    private let barH: CGFloat = 18
    private let boxH: CGFloat = 80

    private var windowStart: Date {
        let hourStart: Date = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        return hourStart.addingTimeInterval(-2 * 3600)
    }

    private func xFor(_ d: Date, _ w: CGFloat) -> CGFloat {
        CGFloat(d.timeIntervalSince(windowStart) / (6 * 3600)) * w
    }

    private func hourLabel(_ i: Int) -> String {
        let h: Int = Calendar.current.component(.hour, from: windowStart.addingTimeInterval(Double(i) * 3600))
        return String(format: "%02d", h)
    }

    @ViewBuilder
    private func cycleBar(_ k: Int, _ w: CGFloat) -> some View {
        let cStart: Date = cycleEnd.addingTimeInterval(Double(k - 1) * 5400)
        let cEnd: Date = cStart.addingTimeInterval(5400)
        let x0: CGFloat = max(xFor(cStart, w), 0) + 1.5
        let x1: CGFloat = min(xFor(cEnd, w), w) - 1.5
        let width: CGFloat = x1 - x0
        let mid: CGFloat = (x0 + x1) / 2
        let midY: CGFloat = barY + barH / 2
        if width > 3 {
            if k == 1 {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(V3.sleep, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(width: width, height: barH)
                    .position(x: mid, y: midY)
            } else if k == 2 {
                RoundedRectangle(cornerRadius: 7)
                    .fill(V3.t1.opacity(0.05))
                    .frame(width: width, height: barH)
                    .position(x: mid, y: midY)
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(V3.sleep.opacity(0.35))
                    .frame(width: width, height: barH)
                    .position(x: mid, y: midY)
                if k == 0 {
                    let ex: CGFloat = min(max(xFor(now, w), x0), x1) - x0
                    RoundedRectangle(cornerRadius: 7)
                        .fill(V3.sleep)
                        .frame(width: max(ex, 0), height: barH)
                        .position(x: x0 + max(ex, 0) / 2, y: midY)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ d: Date, _ color: Color, _ w: CGFloat) -> some View {
        let x: CGFloat = xFor(d, w)
        if x >= 0 && x <= w {
            Capsule()
                .fill(color)
                .frame(width: 2, height: barH + 12)
                .position(x: x, y: barY + barH / 2)
            Text(V3Format.hhmm(d))
                .font(V3Font.num(12, .semibold))
                .foregroundStyle(color)
                .position(x: min(max(x, 18), w - 18), y: barY - 14)
        }
    }

    private func strip(_ w: CGFloat) -> some View {
        let sameMark: Bool = wakeAt.map { abs($0.timeIntervalSince(cycleEnd)) < 60 } ?? false
        return ZStack(alignment: .topLeading) {
            ForEach([-2, -1, 0, 1, 2], id: \.self) { k in
                cycleBar(k, w)
            }
            if !sameMark {
                marker(cycleEnd, V3.t1, w)
            }
            if let wk = wakeAt {
                marker(wk, V3.green, w)
            }
            ZStack {
                Circle().fill(V3.card).frame(width: 19, height: 19)
                Circle().fill(V3.t1).frame(width: 14, height: 14)
            }
            .position(x: min(max(xFor(now, w), 0), w), y: barY + barH / 2)
            ForEach(0..<7, id: \.self) { i in
                Text(hourLabel(i))
                    .font(V3Font.num(11, .medium))
                    .foregroundStyle(V3.t3)
                    .position(x: min(max(CGFloat(i) / 6 * w, 8), w - 8), y: barY + barH + 24)
            }
        }
        .frame(width: w, height: boxH)
    }

    var body: some View {
        GeometryReader { geo in
            strip(geo.size.width)
        }
        .frame(height: boxH)
    }
}
