import SwiftUI

struct FoodV3Sheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var all: [FoodEntry] = []
    @State private var cut: SupabaseClient.CutStatus? = nil
    @State private var weights: [SupabaseClient.WeightPoint] = []
    @State private var comp: FoodV3Comp? = nil
    @State private var selected: FoodEntry? = nil
    @State private var now: Date = Date()
    @State private var loaded = false

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init() {}

    var body: some View {
        ZStack {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    header
                    heroRow
                    sinceLast
                    todayCard
                    bodyCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(V3.sheet)
        .onReceive(ticker) { now = $0 }
        .task { await load() }
        .sheet(item: $selected) { entry in
            MealV3Sheet(entry: entry)
        }
        .lucidRendered(.foodList)
    }

    @MainActor private func load() async {
        let client = SupabaseClient.shared
        async let entriesResult = try? client.fetchRecentFoodEntries(limit: 60)
        async let cutResult = try? client.cutStatus()
        async let weightResult = client.fetchWeightSeries(days: 30)
        async let compResult = FoodV3Net.bodyComp()
        if let list = await entriesResult { all = list.sorted { $0.capturedAt > $1.capturedAt } }
        if let c = await cutResult { cut = c }
        weights = await weightResult
        comp = await compResult
        loaded = true
        if LucidScreen.current == .mealDetail {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            selected = all.first
        }
    }

    // MARK: - Derived data

    private var todayEntries: [FoodEntry] {
        all.filter { Calendar.current.isDateInToday($0.capturedAt) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    private var todayKcal: Int {
        todayEntries.reduce(0) { $0 + FoodV3Text.kcal($1) }
    }

    private var todayMacros: FoodV3Macros {
        let ms: [FoodV3Macros] = todayEntries.map { FoodV3Text.macros($0) }
        return FoodV3Macros(
            protein: FoodV3Text.sum(ms.map { $0.protein }),
            carbs: FoodV3Text.sum(ms.map { $0.carbs }),
            fat: FoodV3Text.sum(ms.map { $0.fat })
        )
    }

    private var lastMealAt: Date? {
        all.first(where: { $0.capturedAt <= now })?.capturedAt
    }

    private var weekDelta: Double? {
        guard let last = weights.last else { return nil }
        guard let base = weights.last(where: { last.date.timeIntervalSince($0.date) >= 6 * 86_400 }) else { return nil }
        return last.kg - base.kg
    }

    private var weekText: String? {
        guard let d = weekDelta else { return nil }
        if abs(d) < 0.3 { return "flat this week" }
        let amount = String(format: "%.1f", abs(d))
        return d < 0 ? "down \(amount) kg this week" : "up \(amount) kg this week"
    }

    private var paceText: String? {
        let recent: [SupabaseClient.WeightPoint] = weights.filter { $0.date.timeIntervalSinceNow > -21 * 86_400 }
        guard recent.count >= 3, let first = recent.first, let last = recent.last else { return nil }
        guard last.date.timeIntervalSince(first.date) >= 5 * 86_400 else { return nil }
        let xs: [Double] = recent.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let ys: [Double] = recent.map { $0.kg }
        let n = Double(recent.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for i in 0..<recent.count {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        guard den > 0 else { return nil }
        let perWeek = num / den * 7
        if abs(perWeek) < 0.15 { return "Holding" }
        return V3Format.signed(perWeek, decimals: 1) + " kg/wk"
    }

    // MARK: - Header and hero

    private var header: some View {
        V3Header(date: V3Format.dayTitle(now), title: "Food") {
            if let c = cut {
                V3Pill(dot: V3.kcal, text: "Cut · " + FoodV3Text.int(c.targetIntake))
            }
            V3IconButton(symbol: "xmark") { dismiss() }
        }
    }

    private var heroRow: some View {
        HStack(spacing: 20) {
            heroRing
            VStack(alignment: .leading, spacing: 14) {
                V3MacroBar(label: "Calories", value: calValue, unit: calUnit, fraction: cut?.intakePct ?? 0, color: V3.kcal)
                V3MacroBar(label: "Protein", value: proteinValue, unit: proteinUnit, fraction: cut?.proteinPct ?? 0, color: V3.protein)
                carbFatBar
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 4)
    }

    private var heroRing: some View {
        ZStack {
            V3Ring(progress: cut?.intakePct ?? 0, color: V3.kcal, lineWidth: 13)
            V3Ring(progress: cut?.proteinPct ?? 0, color: V3.protein, lineWidth: 10).padding(17)
            VStack(spacing: 0) {
                Text(ringNumber)
                    .font(V3Font.num(28))
                    .tracking(-0.84)
                    .foregroundStyle(V3.t1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(ringCaption).font(V3Font.text(12)).foregroundStyle(V3.t2)
            }
        }
        .frame(width: 132, height: 132)
    }

    private var ringNumber: String {
        if let c = cut { return FoodV3Text.int(abs(c.remaining)) }
        return FoodV3Text.int(todayKcal)
    }

    private var ringCaption: String {
        if let c = cut { return c.isOver ? "kcal over" : "kcal left" }
        return "kcal today"
    }

    private var calValue: String {
        if let c = cut { return FoodV3Text.int(c.consumed) + " / " + FoodV3Text.int(c.targetIntake) }
        return FoodV3Text.int(todayKcal)
    }

    private var calUnit: String { cut == nil ? "kcal today" : "kcal" }

    private var proteinValue: String {
        if let c = cut { return "\(Int(c.proteinG.rounded())) / \(c.proteinTarget)" }
        return FoodV3Text.grams(todayMacros.protein)
    }

    private var proteinUnit: String {
        if cut == nil && todayMacros.protein == nil { return "" }
        return "g"
    }

    private var carbFatBar: some View {
        let m = todayMacros
        let c: Double = m.carbs ?? 0
        let f: Double = m.fat ?? 0
        let carbShare: CGFloat = (c + f) > 0 ? CGFloat(c / (c + f)) : 0
        let carbText: String = m.carbs == nil ? "\u{2013}" : FoodV3Text.grams(m.carbs) + " g"
        let fatText: String = m.fat == nil ? "\u{2013}" : FoodV3Text.grams(m.fat) + " g"
        return VStack(alignment: .leading, spacing: 0) {
            Text("Carbs · Fat").font(V3Font.text(12, .semibold)).foregroundStyle(V3.t2)
            Text(carbText + " · " + fatText)
                .font(V3Font.num(17))
                .tracking(-0.34)
                .foregroundStyle(V3.t1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 3)
            GeometryReader { g in
                HStack(spacing: 2) {
                    if c + f > 0 {
                        Capsule().fill(V3.carbs).frame(width: max(6, (g.size.width - 2) * carbShare))
                        Capsule().fill(V3.fat).frame(maxWidth: .infinity)
                    } else {
                        Capsule().fill(V3.track)
                    }
                }
            }
            .frame(height: 6)
            .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var sinceLast: some View {
        if let at = lastMealAt, now.timeIntervalSince(at) < 24 * 3600 {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(V3.t2)
                (Text(V3Format.duration(minutes: max(0, now.timeIntervalSince(at) / 60)))
                    .font(V3Font.text(14, .semibold)).foregroundColor(V3.t1)
                 + Text(" since your last meal").font(V3Font.text(14)).foregroundColor(V3.t2))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    // MARK: - Today

    private var todayCard: some View {
        let rows: [FoodEntry] = todayEntries
        return V3Card {
            V3CardHeader(title: "Today", trailing: "\(rows.count) logged")
            if rows.isEmpty {
                V3EmptyLine(text: loaded ? "Nothing logged today" : "Loading meals")
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        Button { selected = rows[i] } label: { todayRow(rows[i]) }
                            .buttonStyle(.plain)
                        if i < rows.count - 1 {
                            Rectangle().fill(V3.line).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func todayRow(_ e: FoodEntry) -> some View {
        let name: String = FoodV3Text.name(e)
        return HStack(alignment: .top, spacing: 12) {
            Text(V3Format.hhmm(e.capturedAt))
                .font(V3Font.num(13, .medium))
                .foregroundStyle(V3.t2)
                .frame(width: 42, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1).lineLimit(1)
                rowDetail(e, name: name)
                novaPill(e.novaAvg)
            }
            Spacer(minLength: 8)
            rowTrailing(e)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func rowDetail(_ e: FoodEntry, name: String) -> some View {
        if let d = FoodV3Text.detail(e, name: name) {
            Text(d).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(1)
        }
    }

    @ViewBuilder private func novaPill(_ avg: Double?) -> some View {
        if let a = avg {
            let cls = min(4, max(1, Int(a.rounded())))
            let tint: Color = cls <= 2 ? V3.green : V3.amber
            Text(FoodV3Text.novaLabel(cls))
                .font(V3Font.text(11, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.14), in: Capsule())
                .padding(.top, 6)
        }
    }

    private func rowTrailing(_ e: FoodEntry) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            (Text("\(FoodV3Text.kcal(e))").font(V3Font.num(15, .semibold)).foregroundColor(V3.t1)
             + Text(" kcal").font(V3Font.text(11)).foregroundColor(V3.t2))
            if let p = FoodV3Text.macros(e).protein, p >= 10 {
                Text("\(Int(p.rounded())) g P").font(V3Font.num(12, .medium)).foregroundStyle(V3.protein)
            }
        }
    }

    // MARK: - Body

    @ViewBuilder private var bodyCard: some View {
        if let last = weights.last {
            V3Card {
                V3CardHeader(icon: "scalemass", iconColor: V3.fat, title: "Body", trailing: weekText)
                weightRow(last)
                compositionBlock(last)
            }
        }
    }

    private func weightRow(_ last: SupabaseClient.WeightPoint) -> some View {
        let series: [Double] = weights.suffix(14).map { $0.kg }
        return HStack(alignment: .center) {
            V3BigNumber(value: String(format: "%.1f", last.kg), unit: "kg", size: 30)
            Spacer(minLength: 12)
            if series.count > 1 {
                V3Sparkline(values: series, color: V3.fat, lo: (series.min() ?? 0) - 0.4, hi: (series.max() ?? 0) + 0.4)
                    .frame(width: 150, height: 48)
            }
        }
    }

    @ViewBuilder private func compositionBlock(_ last: SupabaseClient.WeightPoint) -> some View {
        let fatPct: Double? = comp?.fatPct
        let leanKg: Double? = comp?.leanKg ?? fatPct.map { last.kg * (1 - $0 / 100) }
        VStack(alignment: .leading, spacing: 0) {
            if let fp = fatPct {
                let fatMass = last.kg * fp / 100
                let leanMass = max(last.kg - fatMass, 0)
                GeometryReader { g in
                    HStack(spacing: 2) {
                        Capsule().fill(V3.t1.opacity(0.22)).frame(width: max(8, (g.size.width - 2) * CGFloat(leanMass / max(last.kg, 1))))
                        Capsule().fill(V3.fat).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 10)
                .padding(.top, 16)
            }
            legendRow(leanKg: leanKg, fatPct: fatPct)
        }
    }

    @ViewBuilder private func legendRow(leanKg: Double?, fatPct: Double?) -> some View {
        let pace: String? = paceText
        if leanKg != nil || fatPct != nil || pace != nil {
            HStack(alignment: .top, spacing: 12) {
                if let l = leanKg {
                    V3LegendItem(label: "Lean mass", value: String(format: "%.1f kg", l))
                }
                if let f = fatPct {
                    V3LegendItem(dot: V3.fat, label: "Body fat", value: String(format: "%.1f%%", f))
                }
                if let p = pace {
                    V3LegendItem(label: "Cut pace", value: p)
                }
            }
            .padding(.top, 14)
        }
    }
}

// MARK: - Support types

private struct FoodV3Macros {
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

private struct FoodV3Comp {
    let fatPct: Double?
    let leanKg: Double?
}

private enum FoodV3Text {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 0
        return f
    }()

    static func int(_ n: Int) -> String {
        grouped.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func grams(_ v: Double?) -> String {
        guard let v = v else { return "\u{2013}" }
        return String(format: "%.0f", v)
    }

    static func sum(_ xs: [Double?]) -> Double? {
        let vals: [Double] = xs.compactMap { $0 }
        return vals.isEmpty ? nil : vals.reduce(0, +)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func itemName(_ i: DetectedItem) -> String {
        if let l = i.nameLocal, !l.isEmpty { return l }
        return i.name
    }

    static func kcal(_ e: FoodEntry) -> Int {
        e.totalKcal ?? e.items.reduce(0) { $0 + $1.kcal }
    }

    static func name(_ e: FoodEntry) -> String {
        let cap = (e.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cap.isEmpty && cap.count <= 40 { return cap }
        let names: [String] = e.items.map { itemName($0) }.filter { !$0.isEmpty }
        if !names.isEmpty { return clip(names.joined(separator: ", "), 40) }
        if !cap.isEmpty { return clip(cap, 40) }
        return "Meal"
    }

    static func detail(_ e: FoodEntry, name: String) -> String? {
        let joined = e.items.map { itemName($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
        if !joined.isEmpty && joined != name && clip(joined, 40) != name { return clip(joined, 48) }
        return sourceLabel(e.source)
    }

    static func sourceLabel(_ source: String) -> String? {
        switch source {
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

    static func novaLabel(_ cls: Int) -> String {
        switch cls {
        case 1: return "Unprocessed"
        case 2: return "Lightly processed"
        case 3: return "Processed"
        default: return "Ultra-processed"
        }
    }

    static func macros(_ e: FoodEntry) -> FoodV3Macros {
        var totals: [String: Any]? = nil
        if let s = e.geminiRawJson, let d = s.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            totals = obj["meal_totals"] as? [String: Any]
        }
        func pick(_ key: String, _ field: (DetectedItem) -> Double?) -> Double? {
            if let v = FoodV3Net.number(totals?[key]) { return v }
            return sum(e.items.map { field($0) })
        }
        return FoodV3Macros(
            protein: pick("protein_g_estimate") { $0.proteinG },
            carbs: pick("carbs_g_estimate") { $0.carbsG },
            fat: pick("fat_g_estimate") { $0.fatG }
        )
    }
}

private enum FoodV3Net {
    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func fatValue(_ r: [String: Any]) -> Double? {
        for (k, raw) in r {
            let key = k.lowercased()
            if key.contains("lean") || key.contains("free") { continue }
            let isFat = key == "body_fat" || (key.contains("fat") && (key.contains("pct") || key.contains("percent")))
            if isFat, let v = number(raw), v > 0 { return v < 1 ? v * 100 : v }
        }
        return nil
    }

    static func leanValue(_ r: [String: Any]) -> Double? {
        for (k, raw) in r {
            let key = k.lowercased()
            if key.contains("pct") || key.contains("percent") { continue }
            if key.contains("lean") || key.contains("fat_free"), let v = number(raw), v > 0 { return v }
        }
        return nil
    }

    static func bodyComp() async -> FoodV3Comp? {
        let client = SupabaseClient.shared
        do { try await client.ensureAuth() } catch { return nil }
        guard let token = client.accessToken else { return nil }
        guard var comps = URLComponents(string: "\(client.baseURL)/rest/v1/body_composition_log") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_id", value: "eq.\(client.userId)"),
            URLQueryItem(name: "order", value: "measured_at.desc"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(client.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let result = try? await URLSession.shared.data(for: req) else { return nil }
        guard let rows = (try? JSONSerialization.jsonObject(with: result.0)) as? [[String: Any]] else { return nil }
        for row in rows {
            let fat = fatValue(row)
            var lean = leanValue(row)
            if lean == nil, let f = fat, let w = number(row["weight_kg"]) { lean = w * (1 - f / 100) }
            if fat != nil || lean != nil { return FoodV3Comp(fatPct: fat, leanKg: lean) }
        }
        return nil
    }
}
