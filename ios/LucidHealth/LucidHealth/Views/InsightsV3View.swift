import SwiftUI

// MARK: - Insights tab on the approved V3 board (minerva/jobs/lh3-full, "Insights").
// Real numbers only. Dead or thin sources are drawn the board's way: "No data", "Not yet", or no card.

struct InsightsV3View: View {
    @State private var range: String = "7 days"
    @State private var days: [InsightsDay] = []
    @State private var alerts: [ExperimentalFeaturesService.SpiralAlert] = []
    @State private var plan: TonightPlan? = nil
    @State private var loaded = false
    @State private var showAlerts = false
    @Environment(\.scenePhase) private var scenePhase

    private static let ranges: [String] = ["7 days", "30 days", "90 days"]

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    V3Header(date: "Your patterns", title: "Insights") { V3KeledButton() }
                    V3Segmented(options: Self.ranges, selection: $range)
                        .padding(.bottom, 4)
                    if loaded {
                        recoveryCard
                        movesCard
                        hrvCard
                        alcoholCard
                        spiralCard
                        tonightCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .sheet(isPresented: $showAlerts) {
            InsightsAlertsSheet(alerts: alerts)
        }
        .lucidRendered(.insights)
    }

    // MARK: Loading

    @MainActor
    private func load() async {
        async let metrics = InsightsLoader.fetchDays(limit: 130)
        async let spirals = ExperimentalFeaturesService.shared.fetchSpiralAlerts(limit: 50)
        async let tonightPlan = SupabaseClient.shared.fetchTonightPlan()
        let m = await metrics
        let s = await spirals
        let t = await tonightPlan
        days = m
        alerts = s
        plan = t
        loaded = true
    }

    // MARK: Derived data

    private var rangeDays: Int { range == "30 days" ? 30 : (range == "90 days" ? 90 : 7) }

    private var endDay: Int? { days.last(where: { (d: InsightsDay) -> Bool in d.recovery != nil })?.dayNumber }

    private func window(_ n: Int) -> [InsightsDay] {
        guard let end = endDay else { return [] }
        return days.filter { (d: InsightsDay) -> Bool in d.dayNumber > end - n && d.dayNumber <= end }
    }

    private var recoveryPoints: [InsightsPoint] {
        guard let end = endDay else { return [] }
        var byDay: [Int: Double] = [:]
        for d in days {
            if let r = d.recovery { byDay[d.dayNumber] = r }
        }
        let n = rangeDays
        var out: [InsightsPoint] = []
        for i in 0..<n {
            let day = end - (n - 1) + i
            out.append(InsightsPoint(id: i, value: byDay[day], letter: InsightsCal.letter(day)))
        }
        return out
    }

    private var recoveryAxis: [String] {
        guard let end = endDay, rangeDays > 7 else { return [] }
        let start = end - (rangeDays - 1)
        return [InsightsCal.label(start), InsightsCal.label(start + (rangeDays - 1) / 2), InsightsCal.label(end)]
    }

    private var alcoholNights: [InsightsAlcoholNight] {
        guard let end = endDay else { return [] }
        var byDay: [Int: InsightsDay] = [:]
        for d in days { byDay[d.dayNumber] = d }
        var out: [InsightsAlcoholNight] = []
        for i in 0..<7 {
            let day = end - 6 + i
            let row = byDay[day]
            out.append(InsightsAlcoholNight(id: i, letter: InsightsCal.letter(day),
                                            drinks: row?.drinks,
                                            confidence: InsightsMath.confidence(row?.confidence)))
        }
        return out
    }

    private var spiralLine: InsightsLine {
        let now = Date()
        var dates: [Date] = []
        for a in alerts {
            if let d = InsightsLoader.parseStamp(a.fired_at) { dates.append(d) }
        }
        let thisMonth = dates.filter { (d: Date) -> Bool in
            Calendar.current.isDate(d, equalTo: now, toGranularity: .month)
        }.count
        let title = thisMonth == 0 ? "None this month" : "\(thisMonth) this month"
        var sub = "Nothing detected so far"
        if let last = dates.max() { sub = "Last one on " + InsightsCal.shortDate(last) }
        return InsightsLine(title: title, sub: sub)
    }

    private var tonightLine: InsightsLine? {
        guard let p = plan, let target = p.targetSleepH, target > 0, p.windowEndMinutes > 0 else { return nil }
        let need = Int((target * 60).rounded())
        let bed = ((p.windowEndMinutes - need) % 1440 + 1440) % 1440
        let hours = abs(target - target.rounded()) < 0.05 ? "\(Int(target.rounded()))h" : V3Format.duration(hours: target)
        return InsightsLine(title: "In bed by " + String(format: "%02d:%02d", bed / 60, bed % 60),
                            sub: "Gets you \(hours) before the alarm")
    }

    private func alcoholRight(_ nights: [InsightsAlcoholNight]) -> String? {
        guard let last = nights.last, let d = last.drinks else { return nil }
        return InsightsMath.drinksText(d) + " last night"
    }

    // MARK: Cards

    @ViewBuilder
    private var recoveryCard: some View {
        let pts = recoveryPoints
        let vals = pts.compactMap { (p: InsightsPoint) -> Double? in p.value }
        let avgText: String? = vals.isEmpty ? nil : "avg \(Int(InsightsMath.mean(vals).rounded()))"
        V3Card {
            V3CardHeader(title: "Recovery", trailing: avgText)
            if vals.isEmpty {
                V3EmptyLine(text: "No data")
            } else {
                InsightsRecoveryBars(points: pts, axis: recoveryAxis)
            }
        }
    }

    @ViewBuilder
    private var movesCard: some View {
        let n = max(14, rangeDays)
        let win = window(n)
        let bed = InsightsMath.bedtimeSplit(win)
        let pinned = InsightsMath.strainSaturated(win)
        let hard: InsightsPair? = pinned ? nil : InsightsMath.strainSplit(win, all: days)
        let strainEmpty = pinned ? "Not yet. Day strain sits at its ceiling too often to compare." : "Not yet. Needs 3 days on each side."
        if bed != nil || hard != nil {
            V3Card {
                V3CardHeader(title: "What moves your recovery", trailing: "\(n) nights")
                InsightsCompare(question: "Asleep before 01:00", topName: "Before 01:00", bottomName: "After 01:00",
                                pair: bed, topMinusBottom: true, unit: "nights",
                                emptyText: "Not yet. Needs 3 nights on each side.")
                    .padding(.top, 4)
                Rectangle().fill(V3.line).frame(height: 1).padding(.top, 16)
                InsightsCompare(question: "Day after strain 18+", topName: "Normal day", bottomName: "After 18+",
                                pair: hard, topMinusBottom: false, unit: "days",
                                emptyText: strainEmpty)
                    .padding(.top, 14)
            }
        }
    }

    @ViewBuilder
    private var hrvCard: some View {
        if let end = endDay {
            let startDay = end - 13
            let recent = days.filter { (d: InsightsDay) -> Bool in
                d.dayNumber >= startDay && d.dayNumber <= end && d.hrv != nil
            }
            if recent.count >= 3 {
                let values = recent.compactMap { (d: InsightsDay) -> Double? in d.hrv }
                let band = InsightsMath.band(days.compactMap { (d: InsightsDay) -> Double? in d.hrv })
                let dots = recent.map { (d: InsightsDay) -> InsightsHRVDot in
                    InsightsHRVDot(x: Double(d.dayNumber - startDay) / 13, v: d.hrv ?? 0)
                }
                let lo = floor(min(values.min() ?? 0, band?.lo ?? Double.greatestFiniteMagnitude) - 3)
                let hi = ceil(max(values.max() ?? 0, band?.hi ?? -Double.greatestFiniteMagnitude) + 3)
                let right: String? = band.map { (b: InsightsBand) -> String in
                    "normal \(Int(b.lo.rounded()))\u{2013}\(Int(b.hi.rounded()))"
                }
                V3Card {
                    V3CardHeader(icon: "waveform.path.ecg", iconColor: V3.energy, title: "HRV, 14 days", trailing: right)
                    InsightsHRVChart(dots: dots, band: band, lo: lo, hi: hi)
                        .frame(height: 110)
                    HStack {
                        Text(InsightsCal.label(startDay))
                        Spacer(minLength: 0)
                        Text(InsightsCal.label(end - 7))
                        Spacer(minLength: 0)
                        Text(InsightsCal.label(end))
                    }
                    .font(V3Font.text(11))
                    .foregroundStyle(V3.t3)
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var alcoholCard: some View {
        let nights = alcoholNights
        let anyKnown = nights.contains { (n: InsightsAlcoholNight) -> Bool in n.drinks != nil }
        let right: String? = alcoholRight(nights)
        V3Card {
            V3CardHeader(icon: "wineglass", iconColor: V3.kcal, title: "Alcohol, per night", trailing: right)
            if anyKnown {
                InsightsAlcoholRow(nights: nights)
                Text("Bigger is more drinks, brighter is more sure.")
                    .font(V3Font.text(12))
                    .foregroundStyle(V3.t2)
                    .padding(.top, 8)
            } else {
                V3EmptyLine(text: "Tap Drinking tonight to log")
            }
        }
    }

    @ViewBuilder
    private var spiralCard: some View {
        let line = spiralLine
        if alerts.isEmpty {
            V3Card {
                InsightsStatusRow(icon: "waveform.path.ecg", color: V3.red, label: "Spiral alerts",
                                  title: line.title, sub: line.sub, chevron: false)
            }
        } else {
            Button { showAlerts = true } label: {
                V3Card {
                    InsightsStatusRow(icon: "waveform.path.ecg", color: V3.red, label: "Spiral alerts",
                                      title: line.title, sub: line.sub, chevron: true)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var tonightCard: some View {
        if let line = tonightLine {
            V3Card {
                InsightsStatusRow(icon: "moon", color: V3.sleep, label: "Tonight",
                                  title: line.title, sub: line.sub, chevron: false)
            }
        }
    }
}

// MARK: - Model

private struct InsightsDay {
    let dayNumber: Int
    let recovery: Double?
    let hrv: Double?
    let strain: Double?
    let sleepStart: Date?
    let drinks: Double?
    let confidence: String?
}

private struct InsightsPoint: Identifiable {
    let id: Int
    let value: Double?
    let letter: String
}

private struct InsightsPair {
    let nTop: Int
    let nBottom: Int
    let avgTop: Double
    let avgBottom: Double
}

private struct InsightsBand {
    let lo: Double
    let hi: Double
    let mean: Double
}

private struct InsightsHRVDot {
    let x: Double
    let v: Double
}

private struct InsightsAlcoholNight: Identifiable {
    let id: Int
    let letter: String
    let drinks: Double?
    let confidence: Double
}

private struct InsightsLine {
    let title: String
    let sub: String
}

// MARK: - Math

private enum InsightsMath {
    static let minGroup = 3

    static func mean(_ values: [Double]) -> Double {
        if values.isEmpty { return 0 }
        var sum = 0.0
        for v in values { sum += v }
        return sum / Double(values.count)
    }

    static func pair(_ top: [Double], _ bottom: [Double]) -> InsightsPair? {
        guard top.count >= minGroup, bottom.count >= minGroup else { return nil }
        return InsightsPair(nTop: top.count, nBottom: bottom.count, avgTop: mean(top), avgBottom: mean(bottom))
    }

    /// Recovery on nights that started before 01:00 against nights that started after it.
    static func bedtimeSplit(_ window: [InsightsDay]) -> InsightsPair? {
        var early: [Double] = []
        var late: [Double] = []
        for d in window {
            guard let rec = d.recovery, let start = d.sleepStart else { continue }
            let c = Calendar.current.dateComponents([.hour, .minute], from: start)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if m >= 300 && m < 1080 { continue }
            let night = m >= 1080 ? m - 1440 : m
            if night < 60 { early.append(rec) } else { late.append(rec) }
        }
        return pair(early, late)
    }

    /// Next-day recovery after a normal day against after a day at strain 18 or more.
    static func strainSplit(_ window: [InsightsDay], all: [InsightsDay]) -> InsightsPair? {
        var recByDay: [Int: Double] = [:]
        for d in all {
            if let r = d.recovery { recByDay[d.dayNumber] = r }
        }
        var normal: [Double] = []
        var hard: [Double] = []
        for d in window {
            guard let s = d.strain, let next = recByDay[d.dayNumber + 1] else { continue }
            if s >= 18 { hard.append(next) } else { normal.append(next) }
        }
        return pair(normal, hard)
    }

    /// The strain score pins at 21 on a large share of days, so an 18+ split says nothing.
    static func strainSaturated(_ window: [InsightsDay]) -> Bool {
        var total = 0
        var pinned = 0
        for d in window {
            guard let s = d.strain else { continue }
            total += 1
            if s >= 20.9 { pinned += 1 }
        }
        return total >= 5 && Double(pinned) / Double(total) > 0.25
    }

    /// Personal normal: mean plus or minus one standard deviation of every fetched night.
    static func band(_ values: [Double]) -> InsightsBand? {
        guard values.count >= 7 else { return nil }
        let m = mean(values)
        var acc = 0.0
        for v in values { acc += (v - m) * (v - m) }
        let sd = (acc / Double(values.count)).squareRoot()
        return InsightsBand(lo: m - sd, hi: m + sd, mean: m)
    }

    static func confidence(_ label: String?) -> Double {
        switch label ?? "" {
        case "high": return 1.0
        case "medium": return 0.8
        case "low": return 0.55
        default: return 0.7
        }
    }

    static func drinksText(_ v: Double) -> String {
        v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

// MARK: - Calendar helpers

private enum InsightsCal {
    static let letters: [String] = ["S", "M", "T", "W", "T", "F", "S"]

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        return c
    }()

    static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM"
        return f
    }()

    static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    static let localStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    static func date(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86400) }
    static func letter(_ day: Int) -> String { letters[utc.component(.weekday, from: date(day)) - 1] }
    static func label(_ day: Int) -> String { dayLabel.string(from: date(day)) }
    static func shortDate(_ d: Date) -> String { localDay.string(from: d) }
    static func stamp(_ d: Date) -> String { localStamp.string(from: d) }
}

// MARK: - Loader

private enum InsightsLoader {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let stampFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let stampPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseStamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return stampFraction.date(from: s) ?? stampPlain.date(from: s)
    }

    static func num(_ row: [String: Any], _ key: String) -> Double? {
        if let n = row[key] as? NSNumber { return n.doubleValue }
        if let s = row[key] as? String { return Double(s) }
        return nil
    }

    static func positive(_ v: Double?) -> Double? {
        guard let x = v, x > 0 else { return nil }
        return x
    }

    static func fetchRows(select: String, limit: Int, token: String) async -> [[String: Any]]? {
        let client = SupabaseClient.shared
        let urlStr = "\(client.baseURL)/rest/v1/health_metrics?user_id=eq.\(client.userId)&select=\(select)&order=metric_date.desc&limit=\(limit)"
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            return nil
        }
    }

    /// Newest `limit` days, oldest first. Falls back to the columns every row has if a newer column is missing.
    static func fetchDays(limit: Int) async -> [InsightsDay] {
        let client = SupabaseClient.shared
        do { try await client.ensureAuth() } catch { return [] }
        guard let token = client.accessToken else { return [] }
        let full = "metric_date,recovery_score,hrv_avg,strain_score,sleep_start,alcohol_drinks_est,alcohol_confidence"
        var fetched = await fetchRows(select: full, limit: limit, token: token)
        if fetched == nil {
            fetched = await fetchRows(select: "metric_date,recovery_score,hrv_avg", limit: limit, token: token)
        }
        guard let rows = fetched else { return [] }
        var out: [InsightsDay] = []
        for row in rows {
            guard let ds = row["metric_date"] as? String, let date = dayFormatter.date(from: ds) else { continue }
            out.append(InsightsDay(
                dayNumber: Int((date.timeIntervalSince1970 / 86400).rounded()),
                recovery: num(row, "recovery_score"),
                hrv: positive(num(row, "hrv_avg")),
                strain: positive(num(row, "strain_score")),
                sleepStart: parseStamp(row["sleep_start"] as? String),
                drinks: num(row, "alcohol_drinks_est"),
                confidence: row["alcohol_confidence"] as? String
            ))
        }
        out.sort { (a: InsightsDay, b: InsightsDay) -> Bool in a.dayNumber < b.dayNumber }
        return out
    }
}

// MARK: - Recovery bars

private struct InsightsRecoveryBars: View {
    let points: [InsightsPoint]
    let axis: [String]

    private var barArea: CGFloat { 120 }
    private var labelled: Bool { points.count <= 7 }
    private var gap: CGFloat { points.count <= 7 ? 12 : (points.count <= 30 ? 3 : 1) }
    private var radius: CGFloat { points.count <= 7 ? 7 : (points.count <= 30 ? 3 : 1.5) }

    private var scaleMax: Double {
        var m = 1.0
        for p in points {
            if let v = p.value, v > m { m = v }
        }
        return m * 1.08
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(points) { (p: InsightsPoint) in
                    column(p)
                }
            }
            if axis.count == 3 {
                HStack {
                    Text(axis[0])
                    Spacer(minLength: 0)
                    Text(axis[1])
                    Spacer(minLength: 0)
                    Text(axis[2])
                }
                .font(V3Font.text(11))
                .foregroundStyle(V3.t3)
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func column(_ p: InsightsPoint) -> some View {
        let isLast = p.id == points.count - 1
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let v = p.value {
                if labelled {
                    Text("\(Int(v.rounded()))")
                        .font(V3Font.text(12, .semibold))
                        .foregroundStyle(isLast ? V3.t1 : V3.t2)
                        .padding(.bottom, 6)
                }
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(V3.recovery(v))
                    .opacity(isLast ? 1 : 0.85)
                    .frame(height: max(3, barArea * CGFloat(v / scaleMax)))
            } else {
                Capsule().fill(V3.track).frame(height: 4)
            }
            if labelled {
                Text(p.letter)
                    .font(V3Font.text(11))
                    .foregroundStyle(V3.t3)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: labelled ? 160 : 120)
    }
}

// MARK: - Comparison rows

private struct InsightsCompare: View {
    let question: String
    let topName: String
    let bottomName: String
    let pair: InsightsPair?
    let topMinusBottom: Bool
    let unit: String
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(question)
                    .font(V3Font.text(15, .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(V3.t1)
                    .lineLimit(1)
                if let p = pair {
                    InsightsDiffPill(value: topMinusBottom ? p.avgTop - p.avgBottom : p.avgBottom - p.avgTop)
                }
            }
            if let p = pair {
                InsightsHBar(name: topName, value: p.avgTop)
                    .padding(.top, 8)
                InsightsHBar(name: bottomName, value: p.avgBottom)
                    .padding(.top, 8)
                Text("\(p.nTop) vs \(p.nBottom) \(unit)")
                    .font(V3Font.text(12))
                    .foregroundStyle(V3.t3)
                    .padding(.top, 8)
            } else {
                V3EmptyLine(text: emptyText)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InsightsDiffPill: View {
    let value: Double

    private var tint: Color {
        let r = value.rounded()
        return r > 0 ? V3.green : (r < 0 ? V3.red : V3.t2)
    }

    var body: some View {
        Text(value.rounded() == 0 ? "0" : V3Format.signed(value))
            .font(V3Font.num(12))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct InsightsHBar: View {
    let name: String
    let value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
                .lineLimit(1)
                .frame(width: 86, alignment: .leading)
            GeometryReader { g in
                let frac = CGFloat(min(max(value, 0), 100) / 100)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(V3.recovery(value))
                    .frame(width: max(34, g.size.width * frac), height: 22)
                    .overlay(alignment: .trailing) {
                        Text("\(Int(value.rounded()))")
                            .font(V3Font.num(12))
                            .foregroundStyle(Color.black)
                            .padding(.trailing, 8)
                    }
            }
            .frame(height: 22)
            .background(V3.trackSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

// MARK: - HRV chart

private struct InsightsHRVChart: View {
    let dots: [InsightsHRVDot]
    let band: InsightsBand?
    let lo: Double
    let hi: Double

    private func yFor(_ v: Double, _ h: CGFloat) -> CGFloat {
        let span = max(hi - lo, 1)
        return 6 + CGFloat(1 - (v - lo) / span) * (h - 12)
    }

    var body: some View {
        GeometryReader { g in
            let w: CGFloat = g.size.width
            let h: CGFloat = g.size.height
            let pts: [CGPoint] = dots.map { (d: InsightsHRVDot) -> CGPoint in
                CGPoint(x: 6 + CGFloat(d.x) * (w - 12), y: yFor(d.v, h))
            }
            ZStack {
                if let b = band {
                    let top = yFor(b.hi, h)
                    let bottom = yFor(b.lo, h)
                    let mid = yFor(b.mean, h)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(V3.energy.opacity(0.09))
                        .frame(width: w, height: max(bottom - top, 2))
                        .position(x: w / 2, y: (top + bottom) / 2)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: mid))
                        p.addLine(to: CGPoint(x: w, y: mid))
                    }
                    .stroke(V3.energy.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                v3SmoothPath(pts)
                    .stroke(V3.energy, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                ForEach(0..<pts.count, id: \.self) { (i: Int) in
                    let isLast = i == pts.count - 1
                    Circle()
                        .fill(isLast ? V3.energy : V3.card)
                        .overlay(Circle().stroke(V3.energy, lineWidth: isLast ? 0 : 1.5))
                        .frame(width: isLast ? 10 : 5, height: isLast ? 10 : 5)
                        .position(pts[i])
                }
            }
            .frame(width: w, height: h)
        }
    }
}

// MARK: - Alcohol dots

private struct InsightsAlcoholRow: View {
    let nights: [InsightsAlcoholNight]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(nights) { (n: InsightsAlcoholNight) in
                VStack(spacing: 6) {
                    mark(n)
                        .frame(height: 44)
                    Text(n.letter)
                        .font(V3Font.text(11))
                        .foregroundStyle(V3.t3)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func mark(_ n: InsightsAlcoholNight) -> some View {
        if let d = n.drinks {
            if d > 0 {
                let size = min(40, 16 + CGFloat(d) * 8)
                Circle()
                    .fill(V3.kcal.opacity(n.confidence))
                    .frame(width: size, height: size)
                    .overlay(
                        Text(InsightsMath.drinksText(d))
                            .font(V3Font.num(12))
                            .foregroundStyle(Color.black)
                    )
            } else {
                Circle()
                    .stroke(V3.kcal.opacity(n.confidence * 0.7), lineWidth: 2)
                    .frame(width: 14, height: 14)
            }
        } else {
            Circle()
                .fill(V3.track)
                .frame(width: 5, height: 5)
        }
    }
}

// MARK: - Status rows and sheet

private struct InsightsStatusRow: View {
    let icon: String
    let color: Color
    let label: String
    let title: String
    let sub: String
    let chevron: Bool

    var body: some View {
        HStack(spacing: 14) {
            V3IconWell(symbol: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(V3Font.text(13, .semibold))
                    .foregroundStyle(V3.t2)
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(V3.t1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(sub)
                    .font(V3Font.text(13))
                    .foregroundStyle(V3.t2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(V3.t3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InsightsAlertsSheet: View {
    let alerts: [ExperimentalFeaturesService.SpiralAlert]

    var body: some View {
        ZStack {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Spiral alerts")
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.84)
                        .foregroundStyle(V3.t1)
                        .padding(.top, 28)
                        .padding(.horizontal, 4)
                    V3Card {
                        ForEach(0..<alerts.count, id: \.self) { (i: Int) in
                            row(alerts[i], first: i == 0)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(_ a: ExperimentalFeaturesService.SpiralAlert, first: Bool) -> some View {
        V3ListRow(icon: "waveform.path.ecg", iconColor: V3.red, title: title(a), detail: detail(a),
                  value: (a.user_response ?? "").capitalized, first: first)
    }

    private func title(_ a: ExperimentalFeaturesService.SpiralAlert) -> String {
        if let d = InsightsLoader.parseStamp(a.fired_at) { return InsightsCal.stamp(d) }
        return a.fired_at
    }

    private func detail(_ a: ExperimentalFeaturesService.SpiralAlert) -> String {
        var parts: [String] = []
        if let d = a.hrv_drop_pct { parts.append("HRV down \(Int(d.rounded()))%") }
        if let r = a.hr_rise_pct { parts.append("HR up \(Int(r.rounded()))%") }
        return parts.joined(separator: ", ")
    }
}
