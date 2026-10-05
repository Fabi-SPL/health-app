import SwiftUI
import Charts

// MARK: - Screenshot harness (DEBUG only, driven by -LucidScreen <name>)

enum LucidScreen: String {
    case today, health, food, insights, wake, offline, settings
    case healthDetail = "health-detail"
    case todayLight = "today-light"

    static let current: LucidScreen? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-LucidScreen"), i + 1 < args.count else { return nil }
        return LucidScreen(rawValue: args[i + 1])
        #else
        return nil
        #endif
    }()

    var tab: AppTab {
        switch self {
        case .health, .healthDetail: return .health
        case .food, .offline: return .food
        case .insights: return .insights
        default: return .today
        }
    }

    static func installGuard() {
        #if DEBUG
        guard current != nil, !guardInstalled else { return }
        guardInstalled = true
        URLProtocol.registerClass(LucidReadOnlyGuard.self)
        #endif
    }
    private static var guardInstalled = false

    static func markRendered(_ screens: [LucidScreen]) {
        #if DEBUG
        guard let cur = current, screens.contains(cur) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? Data("ok".utf8).write(to: dir.appendingPathComponent("lucid-screen-\(cur.rawValue).ok"))
        }
        #endif
    }
}

/// Screenshot runs read real data but may never write: every non-GET request except sign-in is refused.
final class LucidReadOnlyGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        if LucidScreen.current == .offline { return true }
        let method = (request.httpMethod ?? "GET").uppercased()
        if method == "GET" || method == "HEAD" { return false }
        if method == "POST", request.url?.path.hasSuffix("/auth/v1/token") == true { return false }
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

extension View {
    func lucidRendered(_ screens: LucidScreen...) -> some View {
        onAppear { LucidScreen.markRendered(screens) }
    }
}

// MARK: - Tab switching from inside a tab

private struct SelectTabKey: EnvironmentKey {
    static let defaultValue: (AppTab) -> Void = { _ in }
}

extension EnvironmentValues {
    var selectTab: (AppTab) -> Void {
        get { self[SelectTabKey.self] }
        set { self[SelectTabKey.self] = newValue }
    }
}

// MARK: - Formatting

enum BoardFormat {
    static func duration(hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        if total < 60 { return "\(total) min" }
        return "\(total / 60) h " + String(format: "%02d", total % 60)
    }

    static func minutes(_ m: Double) -> String { duration(hours: m / 60) }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = pattern
        return f
    }
    private static let clockF = formatter("HH:mm")
    private static let shortClockF = formatter("H:mm")
    private static let dayMonthF = formatter("d MMMM")
    private static let weekdayF = formatter("EEEE")
    private static let shortDayF = formatter("EEE d MMM")
    private static let isoDayF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func clock(_ d: Date) -> String { clockF.string(from: d) }
    static func shortClock(_ d: Date) -> String { shortClockF.string(from: d) }
    static func dayMonth(_ d: Date) -> String { dayMonthF.string(from: d) }
    static func weekday(_ d: Date) -> String { weekdayF.string(from: d) }
    static func shortDay(_ d: Date) -> String { shortDayF.string(from: d) }
    static func metricDate(_ s: String) -> Date? { isoDayF.date(from: s) }

    static func weekdayShort(_ s: String) -> String {
        guard let d = metricDate(s) else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return names[cal.component(.weekday, from: d) - 1]
    }

    static func one(_ v: Double) -> String { String(format: "%.1f", v) }
    static func int(_ v: Double) -> String { "\(Int(v.rounded()))" }

    static func band(_ score: Double) -> String {
        if score >= 67 { return "Green" }
        if score >= 34 { return "Yellow" }
        return "Red"
    }

    static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Last night, read from the server's scores row

struct BoardNight {
    let scores: [String: Double]

    init(scores: [String: Double]?) { self.scores = scores ?? [:] }

    var loaded: Bool { !scores.isEmpty }
    var isFallback: Bool { (scores["is_fallback"] ?? 0) > 0 }

    func positive(_ key: String) -> Double? {
        guard let v = scores[key], v > 0 else { return nil }
        return v
    }

    var start: Date? { positive("sleep_start_epoch").map { Date(timeIntervalSince1970: $0) } }
    var end: Date? { positive("sleep_end_epoch").map { Date(timeIntervalSince1970: $0) } }

    var hours: Double? {
        if let h = positive("sleep_hours") { return h }
        if let s = start, let e = end, e > s { return e.timeIntervalSince(s) / 3600 }
        return nil
    }

    var efficiencyPct: Double? {
        guard let e = positive("sleep_efficiency") else { return nil }
        return e <= 1 ? e * 100 : e
    }

    var dateLabel: String {
        guard let e = end else { return "" }
        return BoardFormat.shortDay(e)
    }
}

// MARK: - Sleep stage segments (live per-second stages, bucketed to minutes)

struct StageSegment: Identifiable {
    let id = UUID()
    let stage: String
    let start: Date
    let end: Date

    static func build(from raw: [(time: Date, stage: String)]) -> [StageSegment] {
        guard let first = raw.first else { return [] }
        let t0 = first.time.timeIntervalSince1970
        var buckets: [Int: [String: Int]] = [:]
        for r in raw where ["awake", "rem", "light", "deep"].contains(r.stage) {
            let k = Int((r.time.timeIntervalSince1970 - t0) / 60)
            buckets[k, default: [:]][r.stage, default: 0] += 1
        }
        var segs: [StageSegment] = []
        for k in buckets.keys.sorted() {
            guard let stage = buckets[k]?.max(by: { $0.value < $1.value })?.key else { continue }
            let s = Date(timeIntervalSince1970: t0 + Double(k) * 60)
            let e = s.addingTimeInterval(60)
            if let last = segs.last, last.stage == stage, s.timeIntervalSince(last.end) < 180 {
                segs[segs.count - 1] = StageSegment(stage: stage, start: last.start, end: e)
            } else {
                segs.append(StageSegment(stage: stage, start: s, end: e))
            }
        }
        // Fold blips under 3 min into the stage before them so the chart stays readable.
        var out: [StageSegment] = []
        for seg in segs {
            if let last = out.last, seg.end.timeIntervalSince(seg.start) < 180 {
                out[out.count - 1] = StageSegment(stage: last.stage, start: last.start, end: seg.end)
            } else if let last = out.last, last.stage == seg.stage {
                out[out.count - 1] = StageSegment(stage: last.stage, start: last.start, end: seg.end)
            } else {
                out.append(seg)
            }
        }
        return out
    }

    static func stage(at date: Date, in segs: [StageSegment]) -> String? {
        segs.last(where: { $0.start <= date })?.stage
    }
}

// MARK: - Shared data for the board screens

@MainActor
final class BoardStore: ObservableObject {
    static let shared = BoardStore()

    @Published var scores: [String: Double]?
    @Published var metrics: [DailyMetric] = []
    @Published var stages: [StageSegment] = []
    @Published var meals: [FoodEntry] = []
    @Published var mealsFailed = false
    @Published var loadedOnce = false
    private var loading = false
    private var lastLoad: Date?

    var night: BoardNight { BoardNight(scores: scores) }

    /// Most recent days first dropped; returned oldest to newest.
    func lastDays(_ n: Int) -> [DailyMetric] {
        Array(metrics.sorted { $0.date < $1.date }.suffix(n))
    }

    func lastFullDays(_ n: Int) -> [DailyMetric] {
        Array(metrics.filter { $0.recovery != nil }.sorted { $0.date < $1.date }.suffix(n))
    }

    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, let l = lastLoad, Date().timeIntervalSince(l) < 120 { return }
        loading = true
        let client = SupabaseClient.shared
        let s = await client.fetchLastScores()
        let m = await client.fetchDailyMetrics(days: 14)
        scores = s
        metrics = m
        let n = BoardNight(scores: s)
        if let a = n.start, let b = n.end, b > a {
            stages = StageSegment.build(from: await client.fetchSleepStages(start: a, end: b))
        }
        do {
            meals = try await client.fetchRecentFoodEntries(limit: 30)
            mealsFailed = false
        } catch {
            mealsFailed = true
        }
        lastLoad = Date()
        loadedOnce = true
        loading = false
    }
}

// MARK: - Primitives

struct BoardHeader: View {
    let kicker: String
    let title: String
    var gear = false

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kicker)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.secondaryLabel)
                Text(title)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(DS.Colors.label)
            }
            Spacer()
            if gear { SettingsGearButton() }
        }
        .padding(.top, 8)
    }
}

struct BoardSectionTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(DS.Colors.label)
    }
}

struct BoardDivider: View {
    var body: some View {
        Rectangle().fill(DS.Colors.separator).frame(height: 0.5)
    }
}

struct BandChip: View {
    let text: String
    let score: Double?

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(score.map { DS.Colors.recoveryColor($0) } ?? DS.Colors.secondaryLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(score.map { DS.Colors.recoveryBg($0) } ?? DS.Colors.raised2))
    }
}

struct BoardRecoveryRing: View {
    let score: Double?
    var size: CGFloat = 176
    var footnote: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(DS.Colors.chartTrack, lineWidth: 14)
            if let s = score {
                Circle()
                    .trim(from: 0, to: max(0.005, min(1, s / 100)))
                    .stroke(DS.Colors.recoveryColor(s), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(s.rounded()))")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.label)
                    Text("%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.secondaryLabel)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(DS.Colors.accent)
                    Text("Syncing")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.Colors.label)
                    if let footnote {
                        Text(footnote)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.secondaryLabel)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct BoardStat: View {
    let label: String
    let value: String
    let unit: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.secondaryLabel)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.label)
                Text(unit)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.secondaryLabel)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.secondaryLabel)
            }
        }
    }
}

struct BoardActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(DS.Colors.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(DS.Colors.label)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.secondaryLabel)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

struct BoardBanner: View {
    let icon: String
    let title: String
    let subtitle: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DS.Colors.warning)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.Colors.label)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.secondaryLabel)
                }
                Spacer(minLength: 0)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Colors.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(DS.Colors.primaryFill))
                        .buttonStyle(.plain)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(DS.Colors.raised))
    }
}

struct BoardValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(DS.Colors.secondaryLabel)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.label)
        }
        .padding(.vertical, 3)
    }
}

struct BoardExpandable<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var open = LucidScreen.current == .healthDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(DS.Anim.quick) { open.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.Colors.accent)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colors.accent)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(DS.Colors.raised))
            }
        }
    }
}

/// Last night's value as a dot on the line spanning the last 7 days, low to high.
struct BoardRangeRow: View {
    let label: String
    let value: Double?
    let unit: String
    let history: [Double]
    var decimals = 0

    private func fmt(_ v: Double) -> String { decimals == 0 ? BoardFormat.int(v) : BoardFormat.one(v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 17)).foregroundStyle(DS.Colors.label)
                Spacer()
                Text(value.map(fmt) ?? "—")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.label)
                Text(unit).font(.system(size: 13)).foregroundStyle(DS.Colors.secondaryLabel)
            }
            if let lo = history.min(), let hi = history.max(), hi > lo {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Rectangle().fill(DS.Colors.separator).frame(height: 1)
                        Circle().fill(DS.Colors.chartNeutral).frame(width: 5, height: 5)
                        Circle().fill(DS.Colors.chartNeutral).frame(width: 5, height: 5).offset(x: w - 5)
                        if let v = value {
                            let t = min(1, max(0, (v - lo) / (hi - lo)))
                            Circle().fill(DS.Colors.label).frame(width: 12, height: 12)
                                .offset(x: t * (w - 12))
                        }
                    }
                    .frame(height: 12)
                }
                .frame(height: 12)
                HStack {
                    Text(fmt(lo))
                    Spacer()
                    Text(fmt(hi))
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.secondaryLabel)
            }
        }
    }
}

struct BoardStageChart: View {
    let segments: [StageSegment]
    let start: Date
    let end: Date
    var marker: Date? = nil

    private static let rows = ["awake", "rem", "light", "deep"]
    private static let names = ["Awake", "REM", "Light", "Deep"]

    private func color(_ stage: String) -> Color {
        switch stage {
        case "deep": return DS.Colors.accent
        case "rem": return DS.Colors.secondaryLabel
        case "awake": return DS.Colors.label
        default: return DS.Colors.chartNeutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.names, id: \.self) { n in
                        Text(n)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.secondaryLabel)
                            .frame(height: 22)
                    }
                }
                .frame(width: 40, alignment: .leading)
                Canvas { ctx, size in
                    let span = end.timeIntervalSince(start)
                    guard span > 0 else { return }
                    func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / span) * size.width }
                    func y(_ stage: String) -> CGFloat { CGFloat(Self.rows.firstIndex(of: stage) ?? 2) * 22 + 11 }
                    for i in 0..<4 {
                        var line = Path()
                        let yy = CGFloat(i) * 22 + 11
                        line.move(to: CGPoint(x: 0, y: yy))
                        line.addLine(to: CGPoint(x: size.width, y: yy))
                        ctx.stroke(line, with: .color(DS.Colors.chartTrack), lineWidth: 0.5)
                    }
                    for (a, b) in zip(segments, segments.dropFirst()) {
                        var c = Path()
                        let xx = x(b.start)
                        c.move(to: CGPoint(x: xx, y: y(a.stage)))
                        c.addLine(to: CGPoint(x: xx, y: y(b.stage)))
                        ctx.stroke(c, with: .color(DS.Colors.separator), lineWidth: 1)
                    }
                    for s in segments {
                        let x0 = x(s.start), x1 = x(s.end)
                        let rect = CGRect(x: x0, y: y(s.stage) - 5, width: max(4, x1 - x0), height: 10)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(color(s.stage)))
                    }
                    if let m = marker {
                        var l = Path()
                        let xx = min(size.width - 1, x(m))
                        l.move(to: CGPoint(x: xx, y: 0))
                        l.addLine(to: CGPoint(x: xx, y: size.height))
                        ctx.stroke(l, with: .color(DS.Colors.accent), lineWidth: 2)
                    }
                }
                .frame(height: 88)
            }
            HStack {
                Text(BoardFormat.clock(start))
                Spacer()
                Text(BoardFormat.clock(end))
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(DS.Colors.secondaryLabel)
            .padding(.leading, 46)
        }
    }
}

struct BoardStageTotals: View {
    let night: BoardNight

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell("deep_min", "Deep", DS.Colors.accent)
            cell("rem_min", "REM", DS.Colors.secondaryLabel)
            cell("light_min", "Light", DS.Colors.chartNeutral)
            cell("awake_min", "Awake", DS.Colors.label)
        }
    }

    private func cell(_ key: String, _ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(night.positive(key).map(BoardFormat.minutes) ?? "—")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.label)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.system(size: 13)).foregroundStyle(DS.Colors.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 7-day line, gaps where a day has no value, last point emphasised.
struct BoardSparkline: View {
    let values: [Double?]
    let labels: [String]

    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let present = values.compactMap { $0 }
                guard let lo = present.min(), let hi = present.max(), values.count > 1 else { return }
                let range = max(hi - lo, 0.001)
                let step = size.width / CGFloat(values.count - 1)
                func pt(_ i: Int, _ v: Double) -> CGPoint {
                    CGPoint(x: CGFloat(i) * step, y: 6 + (1 - CGFloat((v - lo) / range)) * (size.height - 12))
                }
                var path = Path()
                var started = false
                for (i, v) in values.enumerated() {
                    guard let v else { started = false; continue }
                    if started { path.addLine(to: pt(i, v)) } else { path.move(to: pt(i, v)); started = true }
                }
                ctx.stroke(path, with: .color(DS.Colors.chartNeutral), lineWidth: 1.5)
                for (i, v) in values.enumerated() {
                    guard let v else { continue }
                    let last = i == values.count - 1
                    let r: CGFloat = last ? 5 : 3.5
                    let p = pt(i, v)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(last ? DS.Colors.label : DS.Colors.secondaryLabel))
                }
            }
            .frame(height: 64)
            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    Text(l)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.secondaryLabel)
                    if i < labels.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
    }
}

struct BoardMiniBars: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let hi = max(values.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Capsule()
                        .fill(i == values.count - 1 ? DS.Colors.label : DS.Colors.chartNeutral)
                        .frame(height: max(6, geo.size.height * CGFloat(v / hi)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Recovery per morning for the last 7 days. A day the strap has not delivered yet is a hollow tick.
struct BoardWeekStrip: View {
    let days: [DailyMetric]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days, id: \.date) { d in
                VStack(spacing: 4) {
                    if let r = d.recovery {
                        Text(BoardFormat.int(r))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.recoveryColor(r))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(DS.Colors.recoveryColor(r))
                            .frame(height: max(4, 44 * CGFloat(r / 100)))
                    } else {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.secondaryLabel)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(DS.Colors.separator, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .frame(height: 44)
                    }
                    Text(BoardFormat.weekdayShort(d.date).prefix(1))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.secondaryLabel)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Wake screen (full screen after the smart alarm, no tab bar)

struct WakeScreen: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject private var store = BoardStore.shared
    let fireDate: Date?
    let onClose: () -> Void
    @State private var liveSegments: [StageSegment] = []

    private var engine: HealthEngine { bleManager.healthEngine }
    private var night: BoardNight { store.night }

    private var window: (start: Date, end: Date)? {
        if let s = engine.sleepStartTime, let f = fireDate, f > s { return (s, f) }
        if let s = night.start, let e = night.end, e > s { return (s, e) }
        return nil
    }

    private var segments: [StageSegment] { liveSegments.isEmpty ? store.stages : liveSegments }
    private var wakeTime: Date? { fireDate ?? night.end }

    private var reason: String {
        guard let t = wakeTime, let stage = StageSegment.stage(at: t, in: segments) else {
            return "Your smart alarm went off."
        }
        switch stage {
        case "light": return "You were in light sleep, so this is a good moment to get up."
        case "rem": return "You were in REM, close to the surface, so this is a good moment to get up."
        case "awake": return "You were already stirring, so this is a good moment to get up."
        default: return "The alarm reached its latest time, so it woke you from deep sleep."
        }
    }

    private var recovery: Double? {
        if night.loaded, night.isFallback { return nil }
        guard engine.lastNightHasData else { return nil }
        return night.scores["recovery"] ?? (engine.recoveryScore > 0 ? engine.recoveryScore : nil)
    }

    private var sleepHours: Double? {
        if fireDate != nil, engine.sleepDurationHours > 0 { return engine.sleepDurationHours }
        return night.hours
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "alarm").foregroundStyle(DS.Colors.accent)
                Text("Smart alarm").foregroundStyle(DS.Colors.secondaryLabel)
            }
            .font(.system(size: 15))
            .padding(.top, 16)

            Text(wakeTime.map(BoardFormat.shortClock) ?? "—")
                .font(.system(size: 120, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(reason)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(DS.Colors.label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)

            if let w = window, !segments.isEmpty {
                BoardStageChart(segments: segments, start: w.start, end: w.end, marker: wakeTime)
            } else {
                Text("The stage chart appears once the night has synced from the strap.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.secondaryLabel)
            }

            BoardDivider().padding(.vertical, 24)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recovery").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                    Text(recovery.map { "\(Int($0.rounded()))%" } ?? "Syncing")
                        .font(.system(size: recovery == nil ? 20 : 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(recovery.map { DS.Colors.recoveryColor($0) } ?? DS.Colors.secondaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Heart rate").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                        if bleManager.heartRate > 0 { Circle().fill(DS.Colors.accent).frame(width: 7, height: 7) }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(bleManager.heartRate > 0 ? "\(bleManager.heartRate)" : "—")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("bpm").font(.system(size: 13)).foregroundStyle(DS.Colors.secondaryLabel)
                    }
                    .foregroundStyle(DS.Colors.label)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sleep").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                    Text(sleepHours.map { BoardFormat.duration(hours: $0) } ?? "—")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 24)

            Button {
                bleManager.stopAlarmIfRinging(reason: "wake_screen")
                onClose()
            } label: {
                Text("Stop alarm")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Colors.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Capsule().fill(DS.Colors.primaryFill))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            Button(action: onClose) {
                Text("Close")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Colors.label)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay(Capsule().stroke(DS.Colors.separator, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .background(DS.Colors.ground.ignoresSafeArea())
        .task {
            await store.refresh()
            if let s = engine.sleepStartTime, let f = fireDate, f > s {
                liveSegments = StageSegment.build(from: await SupabaseClient.shared.fetchSleepStages(start: s, end: f))
            }
        }
        .lucidRendered(.wake)
    }
}

// MARK: - Today

struct BoardTodayTop: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject private var store = BoardStore.shared
    @Environment(\.selectTab) private var selectTab

    private var engine: HealthEngine { bleManager.healthEngine }
    private var night: BoardNight { store.night }

    private var recovery: Double? {
        if night.loaded {
            guard !night.isFallback, engine.lastNightHasData else { return nil }
            return night.scores["recovery"] ?? (engine.recoveryScore > 0 ? engine.recoveryScore : nil)
        }
        return engine.lastNightHasData && engine.recoveryScore > 0 ? engine.recoveryScore : nil
    }

    private var strapDown: Bool {
        bleManager.connectionState == .disconnected || bleManager.connectionState == .scanning
    }

    private var todaysMeals: [FoodEntry] {
        store.meals.filter { Calendar.current.isDateInToday($0.capturedAt) }.sorted { $0.capturedAt > $1.capturedAt }
    }

    private var mealWord: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 4..<11: return "breakfast"
        case 11..<15: return "lunch"
        case 15..<21: return "dinner"
        default: return "a snack"
        }
    }

    private var trainingRow: (String, String) {
        guard let r = recovery else {
            return ("Go by feel today", "Recovery is still syncing from the strap")
        }
        switch r {
        case 67...: return ("A hard session fits today", "Recovery is green")
        case 34..<67: return ("Keep training moderate", "Recovery is yellow")
        default: return ("Make today an easy day", "Recovery is red")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardHeader(kicker: BoardFormat.dayMonth(Date()), title: BoardFormat.weekday(Date()), gear: true)
                .padding(.bottom, 16)

            if strapDown {
                BoardBanner(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    title: "Strap not connected",
                    subtitle: bleManager.lastSync.map { "Last reading \(BoardFormat.ago($0))" } ?? "No reading on this phone yet",
                    detail: "Check Bluetooth, keep the strap close.",
                    actionTitle: "Reconnect",
                    action: { NotificationCenter.default.post(name: .lucidReconnectBLE, object: nil) }
                )
                .padding(.bottom, 20)
            }

            HStack(alignment: .center, spacing: 20) {
                BoardRecoveryRing(
                    score: recovery,
                    size: 168,
                    footnote: night.isFallback ? night.positive("recovery").map { "\(night.dateLabel): \(BoardFormat.int($0))%" } : nil
                )
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recovery").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                        BandChip(text: recovery.map(BoardFormat.band) ?? "Syncing", score: recovery)
                    }
                    BoardStat(label: "HRV", value: night.positive("hrv_avg").map(BoardFormat.one) ?? "—", unit: "ms",
                              note: night.isFallback ? night.dateLabel : nil)
                    BoardStat(label: "Resting HR", value: night.positive("resting_hr").map(BoardFormat.int) ?? "—", unit: "bpm",
                              note: night.isFallback ? night.dateLabel : nil)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 20)

            BoardDivider()
            Button { selectTab(.health) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "moon").foregroundStyle(DS.Colors.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sleep").font(.system(size: 17)).foregroundStyle(DS.Colors.label)
                        if night.isFallback {
                            Text("Last full night, \(night.dateLabel)")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.secondaryLabel)
                        }
                    }
                    Spacer()
                    if let h = night.hours {
                        Text(BoardFormat.duration(hours: h))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.label)
                        if let s = night.start, let e = night.end {
                            Text("· \(BoardFormat.clock(s)) to \(BoardFormat.clock(e))")
                                .font(.system(size: 15))
                                .monospacedDigit()
                                .foregroundStyle(DS.Colors.secondaryLabel)
                                .lineLimit(1)
                        }
                    } else {
                        Text(store.loadedOnce ? "Still syncing" : "Loading")
                            .font(.system(size: 15))
                            .foregroundStyle(DS.Colors.secondaryLabel)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colors.dim)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            BoardDivider().padding(.bottom, 20)

            BoardSectionTitle(title: "For today").padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 18) {
                BoardActionRow(icon: "dumbbell", title: trainingRow.0, subtitle: trainingRow.1, action: { selectTab(.health) })
                if let last = todaysMeals.first {
                    BoardActionRow(icon: "fork.knife", title: "Log \(mealWord)",
                                   subtitle: "Last: \(BoardFormat.clock(last.capturedAt)), \(BoardMealRow.title(last))",
                                   action: { selectTab(.food) })
                } else {
                    BoardActionRow(icon: "fork.knife", title: "Log \(mealWord)", subtitle: "Nothing logged yet today",
                                   action: { selectTab(.food) })
                }
                if let s = night.start, let e = night.end {
                    BoardActionRow(icon: "moon", title: "Same bedtime as last night",
                                   subtitle: "Asleep \(BoardFormat.clock(s)), up \(BoardFormat.clock(e))")
                }
            }
            .padding(.bottom, 24)

            heartRateCard.padding(.bottom, 24)

            if !store.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Last 7 mornings").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Colors.label)
                        Spacer()
                        Text("Recovery").font(.system(size: 13)).foregroundStyle(DS.Colors.secondaryLabel)
                    }
                    BoardWeekStrip(days: store.lastDays(7))
                    if store.lastDays(7).contains(where: { $0.recovery == nil }) {
                        Text("Dotted days are still coming off the strap.")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.secondaryLabel)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(DS.Colors.raised))
            }
        }
        .task { await store.refresh() }
        .lucidRendered(.today, .todayLight)
    }

    private var heartRateCard: some View {
        let live = !strapDown && bleManager.heartRate > 0
        let bars = Array(engine.recentHR.suffix(28))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Heart rate").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(live ? DS.Colors.accent : DS.Colors.dim).frame(width: 7, height: 7)
                    Text(live ? "Live from strap" : "Strap offline")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.secondaryLabel)
                }
            }
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(live ? "\(bleManager.heartRate)" : "—")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.label)
                    Text("bpm").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                }
                Spacer(minLength: 16)
                if bars.count > 2, let lo = bars.min(), let hi = bars.max() {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                            Capsule()
                                .fill(i == bars.count - 1 ? DS.Colors.accent : DS.Colors.chartNeutral)
                                .frame(width: 3, height: 8 + 22 * CGFloat(hi > lo ? (v - lo) / (hi - lo) : 0.5))
                        }
                    }
                    .frame(height: 30, alignment: .bottom)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(DS.Colors.raised))
    }
}

// MARK: - Health

struct BoardHealthTop: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject private var store = BoardStore.shared
    var onAdjustSleep: () -> Void = {}

    private var engine: HealthEngine { bleManager.healthEngine }
    private var night: BoardNight { store.night }

    private var recovery: Double? {
        if night.loaded {
            guard !night.isFallback, engine.lastNightHasData else { return nil }
            return night.scores["recovery"] ?? (engine.recoveryScore > 0 ? engine.recoveryScore : nil)
        }
        return engine.lastNightHasData && engine.recoveryScore > 0 ? engine.recoveryScore : nil
    }

    private var week: [DailyMetric] { store.lastDays(7) }

    private var strainWeek: [Double] {
        let hist = (UserDefaults.standard.array(forKey: "lucid_daily_strain_history") as? [Double]) ?? []
        var v = Array(hist.suffix(6))
        if engine.strainScore > 0 { v.append(engine.strainScore) }
        return v
    }

    private func raw(_ key: String, _ label: String, _ unit: String = "", decimals: Int = 1) -> some View {
        let v = night.scores[key]
        let text = v.map { (decimals == 0 ? BoardFormat.int($0) : String(format: "%.\(decimals)f", $0)) + (unit.isEmpty ? "" : " \(unit)") } ?? "—"
        return BoardValueRow(label: label, value: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardHeader(kicker: BoardFormat.dayMonth(Date()), title: "Health").padding(.bottom, 20)

            HStack(alignment: .firstTextBaseline) {
                BoardSectionTitle(title: "Recovery")
                BandChip(text: recovery.map { "\(Int($0.rounded()))%" } ?? "Syncing", score: recovery)
            }
            Text(night.isFallback
                 ? "Today is still syncing. Values below are the last full night, \(night.dateLabel)."
                 : "Dot is last night. Line is the last 7 days, low to high.")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.secondaryLabel)
                .padding(.top, 2)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 16) {
                BoardRangeRow(label: "HRV", value: night.positive("hrv_avg"), unit: "ms",
                              history: week.compactMap { $0.hrv }.filter { $0 > 0 }, decimals: 1)
                BoardRangeRow(label: "Resting heart rate", value: night.positive("resting_hr"), unit: "bpm",
                              history: week.compactMap { $0.restingHr }.filter { $0 > 0 })
                HStack(alignment: .firstTextBaseline) {
                    Text("Respiratory rate").font(.system(size: 17)).foregroundStyle(DS.Colors.label)
                    Spacer()
                    Text(night.positive("respiratory_rate").map(BoardFormat.one) ?? "—")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.label)
                    Text("/min").font(.system(size: 13)).foregroundStyle(DS.Colors.secondaryLabel)
                }
                BoardExpandable(title: "Every input behind recovery") {
                    raw("sdnn", "SDNN", "ms")
                    raw("pnn50", "pNN50", "%")
                    raw("dfa_alpha1", "DFA alpha 1", decimals: 2)
                    raw("poincare_sd1", "Poincaré SD1", "ms")
                    raw("poincare_sd2", "Poincaré SD2", "ms")
                    raw("nocturnal_hr_dip", "Night heart rate dip", "%")
                    raw("skin_temp", "Skin temperature", "°C", decimals: 2)
                    raw("readiness_score", "Readiness", decimals: 0)
                    raw("illness_risk", "Illness risk", decimals: 0)
                    raw("alcohol_impact", "Alcohol impact", decimals: 0)
                    raw("body_battery", "Body battery", decimals: 0)
                    raw("cognitive", "Cognitive capacity", decimals: 0)
                }
            }
            .padding(.bottom, 20)

            BoardDivider().padding(.bottom, 20)

            BoardSectionTitle(title: "Sleep", trailing: night.hours.map { BoardFormat.duration(hours: $0) } ?? "—")
            Group {
                if let s = night.start, let e = night.end {
                    Text("\(BoardFormat.clock(s)) to \(BoardFormat.clock(e))"
                         + (night.efficiencyPct.map { " · \(Int($0.rounded()))% efficiency" } ?? "")
                         + (night.isFallback ? " · \(night.dateLabel)" : ""))
                } else {
                    Text(store.loadedOnce ? "Last night is still syncing from the strap." : "Loading")
                }
            }
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(DS.Colors.secondaryLabel)
            .padding(.top, 2)
            .padding(.bottom, 16)

            if let s = night.start, let e = night.end, !store.stages.isEmpty {
                BoardStageChart(segments: store.stages, start: s, end: e).padding(.bottom, 16)
            }
            BoardStageTotals(night: night).padding(.bottom, 16)
            BoardExpandable(title: "Stage minutes and sleep quality") {
                raw("deep_min", "Deep", "min", decimals: 0)
                raw("rem_min", "REM", "min", decimals: 0)
                raw("light_min", "Light", "min", decimals: 0)
                raw("awake_min", "Awake", "min", decimals: 0)
                raw("sleep_efficiency", "Efficiency", "%", decimals: 0)
                raw("sleep_score", "Sleep score", decimals: 0)
                raw("sleep_fragmentation", "Fragmentation", decimals: 2)
                raw("sleep_debt_hours", "Sleep debt", "h")
                Button("Adjust sleep times", action: onAdjustSleep)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Colors.accent)
                    .buttonStyle(.plain)
                    .padding(.top, 8)
            }
            .padding(.bottom, 20)

            BoardDivider().padding(.bottom, 20)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HRV, 7 days").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        let lastHRV = week.last { ($0.hrv ?? 0) > 0 }
                        Text(lastHRV?.hrv.map(BoardFormat.one) ?? "—")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(lastHRV.map { "ms · " + BoardFormat.weekdayShort($0.date) } ?? "ms")
                            .font(.system(size: 13)).foregroundStyle(DS.Colors.secondaryLabel)
                    }
                    .foregroundStyle(DS.Colors.label)
                    BoardSparkline(values: week.map { $0.hrv.flatMap { $0 > 0 ? $0 : nil } },
                                   labels: week.map { String(BoardFormat.weekdayShort($0.date).prefix(1)) })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Strain, 7 days").font(.system(size: 15)).foregroundStyle(DS.Colors.secondaryLabel)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(engine.strainScore > 0 ? BoardFormat.one(engine.strainScore) : "—")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("today").font(.system(size: 13)).foregroundStyle(DS.Colors.secondaryLabel)
                    }
                    .foregroundStyle(DS.Colors.label)
                    if strainWeek.count > 1 {
                        BoardMiniBars(values: strainWeek).frame(height: 64)
                    } else {
                        Text("Builds up on this phone, one day at a time.")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.secondaryLabel)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id("health-detail")
        }
        .task { await store.refresh() }
        .lucidRendered(.health, .healthDetail)
    }
}

// MARK: - Food

struct BoardMealRow: View {
    let entry: FoodEntry

    static func title(_ e: FoodEntry) -> String {
        if let c = e.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        let names = e.items.map { $0.name }.filter { !$0.isEmpty }
        return names.isEmpty ? "Meal" : names.prefix(3).joined(separator: ", ")
    }

    static func source(_ s: String) -> (String, String) {
        switch s {
        case "photo": return ("Photo", "camera")
        case "barcode": return ("Barcode", "barcode.viewfinder")
        case "manual": return ("Described", "text.bubble")
        case "quick_log": return ("Quick log", "bolt")
        case "favorite": return ("Favourite", "star")
        default: return (s.replacingOccurrences(of: "_", with: " ").capitalized, "square.and.pencil")
        }
    }

    var body: some View {
        let src = Self.source(entry.source)
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(BoardFormat.clock(entry.capturedAt))
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.secondaryLabel)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(entry))
                    .font(.system(size: 17))
                    .foregroundStyle(DS.Colors.label)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: src.1)
                    Text(src.0)
                }
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.secondaryLabel)
            }
            Spacer(minLength: 8)
            if let k = entry.totalKcal, k > 0 {
                Text("\(k) kcal")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.secondaryLabel)
            }
        }
        .padding(.vertical, 12)
    }
}

/// The day from waking to now, one dot per meal.
struct BoardDayTimeline: View {
    let meals: [FoodEntry]
    let wake: Date?

    var body: some View {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let firstMeal = meals.map { $0.capturedAt }.min()
        let candidate = wake.flatMap { $0 > startOfDay ? $0 : nil } ?? firstMeal ?? startOfDay.addingTimeInterval(7 * 3600)
        let start = min(candidate, firstMeal ?? candidate)
        let span = max(now.timeIntervalSince(start), 60)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(DS.Colors.separator).frame(height: 1)
                    Circle().fill(DS.Colors.chartNeutral).frame(width: 6, height: 6)
                    Circle().fill(DS.Colors.chartNeutral).frame(width: 6, height: 6).offset(x: w - 6)
                    ForEach(meals, id: \.capturedAt) { m in
                        let t = CGFloat(min(1, max(0, m.capturedAt.timeIntervalSince(start) / span)))
                        Circle().fill(DS.Colors.accent).frame(width: 10, height: 10).offset(x: t * (w - 10))
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            HStack {
                Text((wake != nil && start == candidate && wake! > startOfDay ? "Up " : "From ") + BoardFormat.clock(start))
                Spacer()
                Text("Now " + BoardFormat.clock(now))
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(DS.Colors.secondaryLabel)
        }
    }
}

struct BoardPillButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DS.Colors.label)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(Capsule().stroke(DS.Colors.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct BoardDescribeField: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble").foregroundStyle(DS.Colors.secondaryLabel)
                Text("Describe a meal").foregroundStyle(DS.Colors.secondaryLabel)
                Spacer()
            }
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(DS.Colors.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BoardFoodTop: View {
    let offline: Bool
    let onRetry: () -> Void
    let onDescribe: () -> Void
    let onPhoto: () -> Void
    let onBarcode: () -> Void
    let onBuild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardHeader(kicker: BoardFormat.dayMonth(Date()), title: "Food", gear: true)
                .padding(.bottom, 16)
            if offline {
                BoardBanner(
                    icon: "icloud.slash",
                    title: "Can't reach the server",
                    subtitle: "Pull down or tap to try again",
                    detail: "Strap readings wait on this phone and send when it answers. A meal needs the server to save.",
                    actionTitle: "Retry",
                    action: onRetry
                )
                .padding(.bottom, 16)
            }
            BoardDescribeField(action: onDescribe)
                .padding(.bottom, 12)
            HStack(spacing: 10) {
                BoardPillButton(title: "Photo", icon: "camera", action: onPhoto)
                BoardPillButton(title: "Barcode", icon: "barcode.viewfinder", action: onBarcode)
                BoardPillButton(title: "Build", icon: "square.stack", action: onBuild)
            }
        }
        .lucidRendered(.food, .offline)
    }
}

// MARK: - Insights

struct BoardInsightsTop: View {
    @ObservedObject private var store = BoardStore.shared

    private var days: [DailyMetric] { store.lastFullDays(7) }

    private var rangeLabel: String {
        guard let a = days.first.flatMap({ BoardFormat.metricDate($0.date) }),
              let b = days.last.flatMap({ BoardFormat.metricDate($0.date) }) else { return "Last 7 full nights" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d"
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_GB")
        g.timeZone = TimeZone(identifier: "UTC")
        g.dateFormat = "d MMMM"
        return "\(f.string(from: a)) to \(g.string(from: b))"
    }

    private var pairs: [(day: DailyMetric, hours: Double, recovery: Double)] {
        days.compactMap { d in
            guard let h = d.sleepHours, h > 0, let r = d.recovery else { return nil }
            return (d, h, r)
        }
    }

    private var correlation: Double? {
        let p = pairs
        guard p.count >= 3 else { return nil }
        let n = Double(p.count)
        let mx = p.map { $0.hours }.reduce(0, +) / n
        let my = p.map { $0.recovery }.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for q in p {
            sxy += (q.hours - mx) * (q.recovery - my)
            sxx += (q.hours - mx) * (q.hours - mx)
            syy += (q.recovery - my) * (q.recovery - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    private static let countWords = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BoardHeader(kicker: rangeLabel, title: "Insights").padding(.bottom, 4)
            if days.isEmpty {
                Text(store.loadedOnce ? "Insights appear once a few full nights have synced." : "Loading")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.secondaryLabel)
            } else {
                mornings
                scatter
            }
        }
        .task { await store.refresh() }
        .lucidRendered(.insights)
    }

    private var mornings: some View {
        let best = pairs.max { $0.recovery < $1.recovery }
        let worst = pairs.min { $0.recovery < $1.recovery }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sleep, then the next morning")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.Colors.label)
            if let best, let worst, best.day.date != worst.day.date {
                Text("Your best morning, \(BoardFormat.int(best.recovery)), followed \(BoardFormat.one(best.hours)) h of sleep. Your lowest, \(BoardFormat.int(worst.recovery)), followed \(BoardFormat.one(worst.hours)) h.")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Sleep")
                Spacer()
                Text("HRV")
                    .frame(width: 44, alignment: .trailing)
                Text("Recovery")
                    .frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundStyle(DS.Colors.secondaryLabel)
            ForEach(days.reversed(), id: \.date) { d in
                HStack(spacing: 10) {
                    Text(BoardFormat.weekdayShort(d.date))
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Colors.label)
                        .frame(width: 36, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Colors.chartTrack)
                            Capsule().fill(DS.Colors.secondaryLabel)
                                .frame(width: geo.size.width * CGFloat(min(1, (d.sleepHours ?? 0) / 10)))
                        }
                    }
                    .frame(height: 5)
                    Text(d.sleepHours.map { BoardFormat.one($0) + " h" } ?? "—")
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.label)
                        .frame(width: 48, alignment: .trailing)
                    Text(d.hrv.map(BoardFormat.int) ?? "—")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.secondaryLabel)
                        .frame(width: 30, alignment: .trailing)
                    BandChip(text: d.recovery.map(BoardFormat.int) ?? "—", score: d.recovery)
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(DS.Colors.raised))
    }

    @ViewBuilder
    private var scatter: some View {
        let p = pairs
        if p.count >= 3, let shortest = p.min(by: { $0.hours < $1.hours }), let longest = p.max(by: { $0.hours < $1.hours }) {
            let lo = floor(shortest.hours) - 0.5
            let hi = ceil(longest.hours) + 0.5
            let r = correlation ?? 0
            VStack(alignment: .leading, spacing: 12) {
                Text(r < 0.2 ? "More sleep did not mean more recovery" : "More sleep, better mornings")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DS.Colors.label)
                Text("Your shortest night, \(BoardFormat.one(shortest.hours)) h, came before a \(BoardFormat.int(shortest.recovery)). Your longest, \(BoardFormat.one(longest.hours)) h, came before a \(BoardFormat.int(longest.recovery)). \(p.count < Self.countWords.count ? Self.countWords[p.count] : "\(p.count)") nights, so this is the week, not a rule.")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Chart(p, id: \.day.date) { q in
                    let mark = q.day.date == shortest.day.date || q.day.date == longest.day.date
                    PointMark(x: .value("Sleep", q.hours), y: .value("Recovery", q.recovery))
                        .foregroundStyle(mark ? DS.Colors.label : DS.Colors.chartNeutral)
                        .symbolSize(mark ? 90 : 50)
                        .annotation(position: q.hours > (lo + hi) / 2 ? .leading : .trailing) {
                            if mark {
                                Text("\(BoardFormat.weekdayShort(q.day.date)), \(BoardFormat.one(q.hours)) h, \(BoardFormat.int(q.recovery))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.Colors.label)
                            }
                        }
                }
                .chartXScale(domain: lo...hi)
                .chartYScale(domain: 0...105)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                        AxisGridLine().foregroundStyle(DS.Colors.chartTrack)
                        AxisValueLabel().font(.system(size: 11)).foregroundStyle(DS.Colors.secondaryLabel)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: 1)) { v in
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text("\(Int(d)) h").font(.system(size: 11)).foregroundStyle(DS.Colors.secondaryLabel)
                            }
                        }
                    }
                }
                .frame(height: 150)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(DS.Colors.raised))
        }
    }
}
