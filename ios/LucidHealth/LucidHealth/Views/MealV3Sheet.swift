import SwiftUI
import Charts

struct MealV3Sheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current: FoodEntry
    @State private var cut: SupabaseClient.CutStatus? = nil
    @State private var hr: MealV3HRSummary? = nil
    @State private var showEdit = false

    init(entry: FoodEntry) {
        _current = State(initialValue: entry)
    }

    var body: some View {
        ZStack {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    header
                    heroRing
                    macrosCard
                    scoreRow
                    heartCard
                    itemsCard
                    V3Button(title: "Edit meal", symbol: "pencil") { showEdit = true }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(V3.sheet)
        .task(id: current.capturedAt) { await load() }
        .sheet(isPresented: $showEdit) {
            EditFoodEntrySheet(
                entry: current,
                onSaved: { updated in
                    current = updated
                    showEdit = false
                },
                onCancel: { showEdit = false }
            )
            .presentationDetents([.large])
        }
        .lucidRendered(.mealDetail)
    }

    @MainActor private func load() async {
        if let c = try? await SupabaseClient.shared.cutStatus() { cut = c }
        let at = current.capturedAt
        let readings = await MealV3Net.readings(from: at.addingTimeInterval(-20 * 60), to: at.addingTimeInterval(80 * 60))
        hr = MealV3Net.summary(readings, mealAt: at)
    }

    // MARK: - Derived data

    private var raw: [String: Any]? {
        guard let s = current.geminiRawJson, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private var kcal: Int? {
        if let k = current.totalKcal { return k }
        if current.items.isEmpty { return nil }
        return current.items.reduce(0) { $0 + $1.kcal }
    }

    private var macros: MealV3Macros? {
        let totals = raw?["meal_totals"] as? [String: Any]
        func pick(_ key: String, _ field: (DetectedItem) -> Double?) -> Double? {
            if let v = MealV3Net.number(totals?[key]) { return v }
            let vals: [Double] = current.items.compactMap { field($0) }
            return vals.isEmpty ? nil : vals.reduce(0, +)
        }
        let p: Double? = pick("protein_g_estimate") { $0.proteinG }
        let c: Double? = pick("carbs_g_estimate") { $0.carbsG }
        let f: Double? = pick("fat_g_estimate") { $0.fatG }
        if p == nil && c == nil && f == nil { return nil }
        return MealV3Macros(protein: p, carbs: c, fat: f)
    }

    private var brainScore: Int? {
        var s: Int? = current.mindScore
        if s == nil, let b = raw?["brain_score"] as? [String: Any], let t = MealV3Net.number(b["total"]) {
            s = Int(t.rounded())
        }
        guard let v = s else { return nil }
        return min(15, max(0, v))
    }

    private var novaClass: Int? {
        guard let avg = current.novaAvg else { return nil }
        return min(4, max(1, Int(avg.rounded())))
    }

    private var noteText: String? {
        guard let s = current.geminiRawJson?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let n = raw?["notes"] as? String {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if s.hasPrefix("{") || s.hasPrefix("[") { return nil }
        return s
    }

    private var sourceLabel: String? {
        switch current.source {
        case "photo": return "Photo + AI"
        case "text": return "Described · AI"
        case "manual": return "Typed · AI"
        case "barcode": return "Barcode · label data"
        case "quick_tag", "quick_log": return "Quick log"
        case "favorite": return "Saved meal"
        case "combined": return "Combined"
        default: return nil
        }
    }

    private var titleText: String {
        let cap = (current.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cap.isEmpty && cap.count <= 32 { return cap }
        let names: [String] = current.items.map { MealV3Text.itemName($0) }.filter { !$0.isEmpty }
        if names.count == 1 { return MealV3Text.clip(names[0], 32) }
        if !names.isEmpty { return MealV3Text.clip(names.joined(separator: ", "), 32) }
        if !cap.isEmpty { return MealV3Text.clip(cap, 32) }
        return "Meal"
    }

    private var outerProgress: Double {
        guard let c = cut, c.targetIntake > 0, let k = kcal else { return 0 }
        return min(Double(k) / Double(c.targetIntake), 1)
    }

    private var innerProgress: Double {
        guard let c = cut, c.proteinTarget > 0, let p = macros?.protein else { return 0 }
        return min(p / Double(c.proteinTarget), 1)
    }

    // MARK: - Header and ring

    private var header: some View {
        V3Header(
            date: V3Format.dayTitle(current.capturedAt) + " · " + V3Format.hhmm(current.capturedAt),
            title: titleText
        ) {
            V3IconButton(symbol: "xmark") { dismiss() }
        }
    }

    private var heroRing: some View {
        VStack(spacing: 14) {
            ZStack {
                V3Ring(progress: outerProgress, color: V3.kcal, lineWidth: 15)
                V3Ring(progress: innerProgress, color: V3.protein, lineWidth: 11).padding(20)
                VStack(spacing: 0) {
                    Text(kcal.map { "\($0)" } ?? "n/a")
                        .font(V3Font.num(40))
                        .tracking(-1.2)
                        .foregroundStyle(V3.t1)
                    Text("kcal").font(V3Font.text(13)).foregroundStyle(V3.t2)
                }
            }
            .frame(width: 170, height: 170)
            heroCaption
            sourceLine
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder private var heroCaption: some View {
        if let c = cut, c.targetIntake > 0 {
            HStack(spacing: 12) {
                V3LegendItem(dot: V3.kcal, label: "Calories", value: MealV3Text.percent(kcal.map { Double($0) / Double(c.targetIntake) }))
                V3LegendItem(dot: V3.protein, label: "Protein", value: MealV3Text.percent(macros?.protein.map { $0 / Double(max(c.proteinTarget, 1)) }))
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder private var sourceLine: some View {
        if let s = sourceLabel {
            Text(s).font(V3Font.text(13)).foregroundStyle(V3.t2)
        }
    }

    // MARK: - Macros

    @ViewBuilder private var macrosCard: some View {
        if let m = macros {
            let s = MealV3Text.shares(m)
            V3Card {
                HStack(alignment: .top, spacing: 14) {
                    V3MacroBar(label: "Protein", value: MealV3Text.grams(m.protein), unit: m.protein == nil ? "" : "g", fraction: s.protein, color: V3.protein)
                    V3MacroBar(label: "Carbs", value: MealV3Text.grams(m.carbs), unit: m.carbs == nil ? "" : "g", fraction: s.carbs, color: V3.carbs)
                    V3MacroBar(label: "Fat", value: MealV3Text.grams(m.fat), unit: m.fat == nil ? "" : "g", fraction: s.fat, color: V3.fat)
                }
                Text("Bars show each macro's share of this meal's calories")
                    .font(V3Font.text(12))
                    .foregroundStyle(V3.t2)
                    .padding(.top, 14)
            }
        } else {
            V3Card { V3EmptyLine(text: "No macros recorded for this meal") }
        }
    }

    // MARK: - Brain food and processing

    @ViewBuilder private var scoreRow: some View {
        if brainScore != nil || novaClass != nil {
            HStack(alignment: .top, spacing: 12) {
                if let b = brainScore { brainTile(b) }
                if let n = novaClass { novaTile(n) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func brainTile(_ score: Int) -> some View {
        MealV3Tile {
            V3CardHeader(icon: "brain", iconColor: V3.sleep, title: "Brain food")
            HStack(spacing: 12) {
                ZStack {
                    V3Ring(progress: Double(score) / 15, color: V3.sleep, lineWidth: 6)
                    Text("\(score)").font(V3Font.num(17)).foregroundStyle(V3.t1)
                }
                .frame(width: 52, height: 52)
                Text("out of 15").font(V3Font.text(13)).foregroundStyle(V3.t2)
            }
        }
    }

    private func novaTile(_ cls: Int) -> some View {
        let tint: Color = cls <= 2 ? V3.green : V3.amber
        return MealV3Tile {
            V3CardHeader(icon: "leaf.fill", iconColor: V3.green, title: "Processing")
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(i < cls ? tint : V3.track)
                        .frame(height: 10)
                }
            }
            Text("NOVA \(cls), \(MealV3Text.novaWord(cls))")
                .font(V3Font.text(13))
                .foregroundStyle(V3.t2)
                .padding(.top, 12)
        }
    }

    // MARK: - Heart rate

    private var heartCard: some View {
        V3Card {
            V3CardHeader(icon: "heart.fill", iconColor: V3.heart, title: "Heart rate after it", trailing: "vs before the meal")
            heartBody
        }
    }

    @ViewBuilder private var heartBody: some View {
        if let h = hr {
            if h.points.filter({ $0.minute >= 0 }).count >= 3 {
                heartChartBlock(h)
            } else {
                V3EmptyLine(text: current.capturedAt.timeIntervalSinceNow > -600
                            ? "Not enough heart rate around this meal yet"
                            : "No heart rate recorded around this meal")
            }
        } else {
            V3EmptyLine(text: "Loading heart rate")
        }
    }

    private func heartChartBlock(_ h: MealV3HRSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heartBump(h)
            heartChart(h)
            heartLegend(h)
        }
    }

    @ViewBuilder private func heartBump(_ h: MealV3HRSummary) -> some View {
        if let b = h.baseline, let p = h.postMean {
            (Text(V3Format.signed(p - b, decimals: 0) + " bpm").font(V3Font.text(15, .semibold)).foregroundColor(V3.heart)
             + Text(" in the first 40 min").font(V3Font.text(15)).foregroundColor(V3.t2))
        } else if h.baseline == nil {
            V3EmptyLine(text: "No heart rate before the meal to compare")
        }
    }

    private func heartChart(_ h: MealV3HRSummary) -> some View {
        let values: [Double] = h.points.map { $0.bpm } + (h.baseline.map { [$0] } ?? [])
        let lo: Double = (values.min() ?? 50) - 4
        let hi: Double = (values.max() ?? 90) + 6
        let atMeal: Double = h.points.min(by: { abs($0.minute) < abs($1.minute) })?.bpm ?? (h.baseline ?? lo)
        return Chart {
            RectangleMark(
                xStart: .value("From", 0.0),
                xEnd: .value("To", 40.0),
                yStart: .value("Low", lo),
                yEnd: .value("High", hi)
            )
            .foregroundStyle(V3.heart.opacity(0.07))
            if let b = h.baseline {
                RuleMark(y: .value("Before the meal", b))
                    .foregroundStyle(V3.t3)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            }
            ForEach(h.points) { p in
                LineMark(x: .value("Minute", p.minute), y: .value("BPM", p.bpm))
                    .foregroundStyle(V3.heart)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            PointMark(x: .value("Minute", 0.0), y: .value("BPM", atMeal))
                .foregroundStyle(V3.kcal)
                .symbolSize(70)
        }
        .chartXScale(domain: -20.0...80.0)
        .chartYScale(domain: lo...hi)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [-20.0, 0.0, 40.0, 80.0]) { value in
                AxisValueLabel {
                    if let m = value.as(Double.self) {
                        Text(V3Format.hhmm(current.capturedAt.addingTimeInterval(m * 60)))
                            .font(V3Font.num(11, .medium))
                            .foregroundStyle(V3.t2)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 150)
    }

    @ViewBuilder private func heartLegend(_ h: MealV3HRSummary) -> some View {
        if let b = h.baseline, let p = h.postMean {
            HStack(spacing: 12) {
                V3LegendItem(dot: V3.t3, label: "Before the meal", value: "\(Int(b.rounded())) bpm")
                V3LegendItem(dot: V3.heart, label: "First 40 min", value: "\(Int(p.rounded())) bpm")
            }
        }
    }

    // MARK: - Items

    @ViewBuilder private var itemsCard: some View {
        if !current.items.isEmpty {
            V3Card {
                V3CardHeader(title: "Items", trailing: "\(current.items.count) found")
                MealV3Flow(spacing: 8) {
                    ForEach(current.items) { item in
                        Text(MealV3Text.chip(item))
                            .font(V3Font.text(13, .semibold))
                            .foregroundStyle(V3.t1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(V3.card2, in: Capsule())
                    }
                }
                itemsNote
            }
        }
    }

    @ViewBuilder private var itemsNote: some View {
        if let n = noteText {
            Text(n)
                .font(V3Font.text(14))
                .foregroundStyle(V3.t2)
                .lineSpacing(3)
                .padding(.top, 14)
        }
    }
}

// MARK: - Support types

private struct MealV3Macros {
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

private struct MealV3HRPoint: Identifiable {
    let id: Int
    let minute: Double
    let bpm: Double
}

private struct MealV3HRSummary {
    let points: [MealV3HRPoint]
    let baseline: Double?
    let postMean: Double?
}

private struct MealV3Reading {
    let at: Date
    let bpm: Double
}

private struct MealV3Tile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(V3.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private enum MealV3Text {
    static func itemName(_ i: DetectedItem) -> String {
        if let l = i.nameLocal, !l.isEmpty { return l }
        return i.name
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func chip(_ i: DetectedItem) -> String {
        let n = itemName(i)
        return i.grams > 0 ? n + " · \(i.grams) g" : n
    }

    static func grams(_ v: Double?) -> String {
        guard let v = v else { return "n/a" }
        return String(format: "%.0f", v)
    }

    static func percent(_ v: Double?) -> String {
        guard let v = v else { return "n/a" }
        return "\(Int((v * 100).rounded()))% of target"
    }

    static func shares(_ m: MealV3Macros) -> (protein: Double, carbs: Double, fat: Double) {
        let p = (m.protein ?? 0) * 4
        let c = (m.carbs ?? 0) * 4
        let f = (m.fat ?? 0) * 9
        let t = p + c + f
        guard t > 0 else { return (0, 0, 0) }
        return (p / t, c / t, f / t)
    }

    static func novaWord(_ cls: Int) -> String {
        switch cls {
        case 1: return "unprocessed"
        case 2: return "lightly processed"
        case 3: return "processed"
        default: return "ultra-processed"
        }
    }
}

private enum MealV3Net {
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

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func readings(from: Date, to: Date) async -> [MealV3Reading] {
        let client = SupabaseClient.shared
        do { try await client.ensureAuth() } catch { return [] }
        guard let token = client.accessToken else { return [] }
        let page = 1000
        var out: [MealV3Reading] = []
        for pageIndex in 0..<6 {
            guard var comps = URLComponents(string: "\(client.baseURL)/rest/v1/realtime_health") else { return out }
            comps.queryItems = [
                URLQueryItem(name: "select", value: "heart_rate,recorded_at"),
                URLQueryItem(name: "user_id", value: "eq.\(client.userId)"),
                URLQueryItem(name: "recorded_at", value: "gte.\(isoPlain.string(from: from))"),
                URLQueryItem(name: "recorded_at", value: "lte.\(isoPlain.string(from: to))"),
                URLQueryItem(name: "order", value: "recorded_at.asc"),
                URLQueryItem(name: "limit", value: "\(page)"),
                URLQueryItem(name: "offset", value: "\(pageIndex * page)")
            ]
            guard let url = comps.url else { return out }
            var req = URLRequest(url: url)
            req.setValue(client.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let result = try? await URLSession.shared.data(for: req) else { return out }
            guard let rows = (try? JSONSerialization.jsonObject(with: result.0)) as? [[String: Any]] else { return out }
            for row in rows {
                guard let ts = row["recorded_at"] as? String, let at = date(ts) else { continue }
                guard let bpm = number(row["heart_rate"]), bpm > 30 else { continue }
                out.append(MealV3Reading(at: at, bpm: bpm))
            }
            if rows.count < page { break }
        }
        return out
    }

    static func summary(_ readings: [MealV3Reading], mealAt: Date) -> MealV3HRSummary {
        var pre: [Double] = []
        var post: [Double] = []
        var sums = [Double](repeating: 0, count: 20)
        var counts = [Int](repeating: 0, count: 20)
        for r in readings {
            let m = r.at.timeIntervalSince(mealAt) / 60
            if m < -20 || m > 80 { continue }
            if m < 0 { pre.append(r.bpm) }
            if m >= 0 && m <= 40 { post.append(r.bpm) }
            let idx = min(19, max(0, Int(((m + 20) / 5).rounded(.down))))
            sums[idx] += r.bpm
            counts[idx] += 1
        }
        var points: [MealV3HRPoint] = []
        for i in 0..<20 where counts[i] > 0 {
            points.append(MealV3HRPoint(id: i, minute: -17.5 + Double(i) * 5, bpm: sums[i] / Double(counts[i])))
        }
        let baseline: Double? = pre.count >= 5 ? pre.reduce(0, +) / Double(pre.count) : nil
        let postMean: Double? = post.count >= 5 ? post.reduce(0, +) / Double(post.count) : nil
        return MealV3HRSummary(points: points, baseline: baseline, postMean: postMean)
    }
}

private struct MealV3Flow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW: CGFloat = proposal.width ?? .infinity
        let limit: CGFloat? = maxW.isFinite ? maxW : nil
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var usedW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            if x > 0 && x + sz.width > maxW {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            usedW = max(usedW, x - spacing)
        }
        return CGSize(width: usedW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + sz.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sz.width, height: sz.height))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
