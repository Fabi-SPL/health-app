import SwiftUI

// MARK: - InsightsView
// 2026-07 redesign: "what patterns move my body, shown as evidence."
// Every claim is carried by a chart; prose is caption-length only.
// Page order: featured discovery → effect bars → evidence scatter → recovery
// heatmap → discoveries feed → spiral alerts → Hermes (freshness-gated) →
// data gate → Labs row. Tool launchers and status readouts moved to Today.

struct InsightsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @State private var patterns: [FoodPattern] = []
    @State private var isLoading = false
    @State private var entryCount = 0
    @State private var appeared = false
    @State private var showBiostate = false
    @State private var biostateInitialCorrect: BiostateDetector? = nil
    @State private var dailyMetrics: [DailyMetric] = []
    @State private var crossDomain: [FoodPattern] = []

    private static let minimumEntries = 14

    /// Featured = strongest pattern; the feed shows the rest.
    private var featured: FoodPattern? { patterns.first }
    private var remaining: [FoodPattern] { Array(patterns.dropFirst()) }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: DS.Spacing.md) {
                    headerSpacer

                    if isLoading {
                        LoadingState(label: "Analyzing patterns…")
                    } else {
                        // 1 — Featured discovery: the screen's ONE accent card.
                        if let top = featured {
                            FeaturedDiscoveryCard(pattern: top)
                                .padding(.horizontal, DS.Spacing.md)
                                .offset(y: appeared ? 0 : 20)
                                .opacity(appeared ? 1 : 0)
                                .animation(DS.Anim.stagger(index: 0), value: appeared)
                        }

                        // 2 — What moves your body: diverging effect-magnitude bars.
                        if patterns.count >= 3 {
                            PatternImpactBars(patterns: patterns)
                                .padding(.horizontal, DS.Spacing.md)
                                .offset(y: appeared ? 0 : 20)
                                .opacity(appeared ? 1 : 0)
                                .animation(DS.Anim.stagger(index: 1), value: appeared)
                        }

                        // 3 — Evidence scatter (sleep ↔ recovery).
                        if dailyMetrics.filter({ $0.recovery != nil && ($0.sleepHours ?? 0) > 0 }).count >= 4 {
                            SleepRecoveryScatter(metrics: dailyMetrics)
                                .padding(.horizontal, DS.Spacing.md)
                                .offset(y: appeared ? 0 : 20)
                                .opacity(appeared ? 1 : 0)
                                .animation(DS.Anim.stagger(index: 2), value: appeared)
                        }

                        // 4 — Recovery heatmap (5 weeks).
                        if dailyMetrics.contains(where: { $0.recovery != nil }) {
                            RecoveryHeatmap(metrics: dailyMetrics)
                                .padding(.horizontal, DS.Spacing.md)
                                .offset(y: appeared ? 0 : 20)
                                .opacity(appeared ? 1 : 0)
                                .animation(DS.Anim.stagger(index: 3), value: appeared)
                        }

                        // 5 — Discoveries feed: nightly AI insights, capped w/ show-all.
                        DailyInsightsStrip()
                            .offset(y: appeared ? 0 : 20)
                            .opacity(appeared ? 1 : 0)
                            .animation(DS.Anim.stagger(index: 4), value: appeared)

                        // 5b — Cross-domain connections (Health computed + Gemini).
                        if !crossDomain.isEmpty {
                            sectionLabel("ACROSS DOMAINS")
                            ForEach(Array(crossDomain.enumerated()), id: \.element.id) { i, p in
                                InsightCard(pattern: p)
                                    .padding(.horizontal, DS.Spacing.md)
                                    .offset(y: appeared ? 0 : 20)
                                    .opacity(appeared ? 1 : 0)
                                    .animation(DS.Anim.stagger(index: min(i + 5, 9)), value: appeared)
                            }
                        }

                        // 5c — Remaining computed patterns.
                        if !remaining.isEmpty {
                            sectionLabel("YOUR PATTERNS")
                            ForEach(Array(remaining.enumerated()), id: \.element.id) { i, pattern in
                                InsightCard(pattern: pattern)
                                    .padding(.horizontal, DS.Spacing.md)
                                    .offset(y: appeared ? 0 : 20)
                                    .opacity(appeared ? 1 : 0)
                                    .animation(DS.Anim.stagger(index: min(i + 6, 9)), value: appeared)
                            }
                        }

                        if patterns.isEmpty && crossDomain.isEmpty {
                            EmptyGlassState(
                                icon: "lightbulb",
                                title: "No pattern found yet",
                                detail: "Analysis improves as more days accumulate."
                            )
                            .padding(.horizontal, DS.Spacing.md)
                        }

                        // 6 — Spiral alerts (event log — moved in from Settings Labs).
                        SpiralAlertsLogCard()
                            .padding(.horizontal, DS.Spacing.md)
                            .offset(y: appeared ? 0 : 20)
                            .opacity(appeared ? 1 : 0)
                            .animation(DS.Anim.stagger(index: 7), value: appeared)

                        // 7 — Hermes: interpretation surface (freshness-gated inside).
                        HermesCard()
                            .padding(.horizontal, DS.Spacing.md)
                            .offset(y: appeared ? 0 : 20)
                            .opacity(appeared ? 1 : 0)
                            .animation(DS.Anim.stagger(index: 8), value: appeared)

                        // 8 — Data gate: only while food logging is thin.
                        if entryCount < Self.minimumEntries {
                            DataGateCard(entriesLogged: entryCount, required: Self.minimumEntries)
                                .padding(.horizontal, DS.Spacing.md)
                                .offset(y: appeared ? 0 : 20)
                                .opacity(appeared ? 1 : 0)
                                .animation(DS.Anim.stagger(index: 9), value: appeared)
                        }

                        // 9 — Labs: the experimental biostate surface, finally labeled.
                        LabsBiostateRow { showBiostate = true }
                            .padding(.horizontal, DS.Spacing.md)
                            .offset(y: appeared ? 0 : 20)
                            .opacity(appeared ? 1 : 0)
                            .animation(DS.Anim.stagger(index: 9), value: appeared)
                    }

                    bottomSpacer
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TwoToneHeadline(primary: "Insights", secondary: " · Patterns", font: .system(size: 17, weight: .bold, design: .rounded))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                SettingsGearButton()
            }
        }
        .task {
            await loadInsights()
            withAnimation { appeared = true }
        }
        .refreshable { await loadInsights() }
        .fullScreenCover(isPresented: $showBiostate) {
            BiostateDashboardView(initialCorrect: biostateInitialCorrect)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lucidOpenBiostate)) { note in
            biostateInitialCorrect = (note.object as? String).flatMap { BiostateDetector(rawValue: $0) }
            showBiostate = true
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(DS.Colors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.md + 4)
            .padding(.top, DS.Spacing.sm)
    }

    private var headerSpacer: some View { Color.clear.frame(height: DS.Spacing.sm) }
    private var bottomSpacer: some View { Color.clear.frame(height: 100) }

    private func loadInsights() async {
        isLoading = patterns.isEmpty   // refreshes stay non-destructive
        // Health-metric correlations don't need food data — fetch both, always compute.
        let metrics = await SupabaseClient.shared.fetchDailyMetrics(days: 120)
        dailyMetrics = metrics
        var entries: [FoodEntry] = []
        do { entries = try await SupabaseClient.shared.fetchRecentFoodEntries(limit: 90) } catch { }
        entryCount = entries.count
        patterns = InsightEngine.compute(entries: entries, metrics: metrics)
        crossDomain = await SupabaseClient.shared.fetchCrossDomainInsights()
        isLoading = false
    }
}

// MARK: - Labs · Biostate row (labeled entry to the experimental surface)

private struct LabsBiostateRow: View {
    let action: () -> Void

    var body: some View {
        Button {
            DS.Haptic.tap()
            action()
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.Colors.violet)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DS.Colors.violet.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Labs · Biostate")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Experimental detectors — read loosely")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DS.Colors.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textFaint)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassSubtle()
    }
}

// MARK: - Recovery Heatmap + Sleep↔Recovery Scatter (v6 mockup)

private struct RecoveryHeatmap: View {
    let metrics: [DailyMetric]

    private var cells: [DailyMetric?] {
        let sorted = metrics.sorted { $0.date < $1.date }
        let last = Array(sorted.suffix(35))
        let pad: [DailyMetric?] = Array(repeating: nil, count: max(0, 35 - last.count))
        return pad + last.map { Optional($0) }
    }

    private func color(_ v: Double?) -> Color {
        guard let v = v else { return DS.Colors.track }
        if v >= 67 { return DS.Colors.success }
        if v >= 34 { return DS.Colors.amber }
        return DS.Colors.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recovery · 5 weeks")
                    .font(.system(size: 10, weight: .bold)).tracking(1.4).textCase(.uppercase)
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                HStack(spacing: 4) {
                    Text("Low").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.textMuted)
                    RoundedRectangle(cornerRadius: 2).fill(DS.Colors.danger).frame(width: 10, height: 10)
                    RoundedRectangle(cornerRadius: 2).fill(DS.Colors.amber).frame(width: 10, height: 10)
                    RoundedRectangle(cornerRadius: 2).fill(DS.Colors.success).frame(width: 10, height: 10)
                    Text("High").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.textMuted)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(0..<cells.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color(cells[i]?.recovery))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
    }
}

private struct SleepRecoveryScatter: View {
    let metrics: [DailyMetric]

    private var points: [(x: Double, y: Double)] {
        metrics.compactMap { m in
            guard let s = m.sleepHours, let r = m.recovery, s > 0 else { return nil }
            return (s, r)
        }
    }

    private func recColor(_ v: Double) -> Color {
        if v >= 67 { return DS.Colors.success }
        if v >= 34 { return DS.Colors.amber }
        return DS.Colors.danger
    }

    var body: some View {
        let pts = points
        let xs = pts.map { $0.x }
        let ys = pts.map { $0.y }
        let xMin = max((xs.min() ?? 4) - 0.3, 0)
        let xMax = (xs.max() ?? 9) + 0.3
        let xSpan = max(xMax - xMin, 1)
        let n = Double(pts.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = xs.reduce(0) { $0 + $1 * $1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let denom = n * sxx - sx * sx
        let slope = denom != 0 ? (n * sxy - sx * sy) / denom : 0
        let intercept = n != 0 ? (sy - slope * sx) / n : 0

        return VStack(alignment: .leading, spacing: 12) {
            Text("Sleep vs recovery")
                .font(.system(size: 10, weight: .bold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(DS.Colors.textMuted)
            HStack(spacing: 6) {
                VStack {
                    Text("100").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.textMuted)
                    Spacer()
                    Text("0").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.textMuted)
                }
                .frame(height: 128)
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let px: (Double) -> CGFloat = { CGFloat(($0 - xMin) / xSpan) * w }
                    let py: (Double) -> CGFloat = { h - CGFloat(min(max($0, 0), 100) / 100) * h }
                    ZStack {
                        Path { p in
                            p.move(to: CGPoint(x: px(xMin), y: py(slope * xMin + intercept)))
                            p.addLine(to: CGPoint(x: px(xMax), y: py(slope * xMax + intercept)))
                        }
                        .stroke(DS.Colors.violet.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        ForEach(0..<pts.count, id: \.self) { i in
                            Circle().fill(recColor(pts[i].y))
                                .frame(width: 7, height: 7)
                                .position(x: px(pts[i].x), y: py(pts[i].y))
                        }
                    }
                }
                .frame(height: 128)
            }
            HStack {
                Text("\(Int(xMin.rounded()))h").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.textMuted)
                Spacer()
                Text("sleep duration").font(.system(size: 9, weight: .medium)).foregroundStyle(DS.Colors.textMuted)
                Spacer()
                Text("\(Int(xMax.rounded()))h").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.textMuted)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
    }
}

// MARK: - Featured Discovery (the ONE accent card on the screen)

private struct FeaturedDiscoveryCard: View {
    let pattern: FoodPattern
    private var accent: Color { pattern.effectPositive ? DS.Colors.teal : DS.Colors.danger }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Colors.violet)
                Text("Strongest pattern")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                if let badge = pattern.badgeText {
                    DeltaBadge(text: badge, positive: pattern.effectPositive)
                }
            }
            Text(pattern.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let eff = pattern.effectDescription, !eff.isEmpty {
                Text(eff)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The evidence — drawn, not narrated.
            if let comp = pattern.comparison {
                MiniComparisonBars(comparison: comp, accent: accent)
                    .padding(.top, 2)
            } else if let r = pattern.rValue {
                StrengthMeter(r: r, positive: pattern.effectPositive, sampleN: pattern.sampleN)
                    .padding(.top, 2)
            }

            Text(caption)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.violet)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.violet.opacity(0.12)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(DS.Colors.violet.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DS.Colors.violet.opacity(0.28), lineWidth: 1))
    }

    private var caption: String {
        var parts = ["\(Int((pattern.confidenceValue * 100).rounded()))% confidence"]
        if let n = pattern.sampleN, n > 0 { parts.append("\(n) days") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Diverging Impact Bars — effect magnitude, hurts ←→ helps

private struct PatternImpactBars: View {
    let patterns: [FoodPattern]
    private var rows: [FoodPattern] { Array(patterns.prefix(6)) }

    /// Comparable 0–100 impact per pattern: comparison delta (score points /
    /// pct) where present, |r|×100 for correlations. Honest per-bar labels
    /// (badgeText) carry the real units.
    private func magnitude(_ p: FoodPattern) -> Double {
        if let c = p.comparison { return abs(c.after - c.before) }
        if let r = p.rValue { return abs(r) * 100 }
        return p.confidenceValue * 40   // speculative rows render short
    }

    var body: some View {
        let maxMag = max(rows.map(magnitude).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What moves your body")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                HStack(spacing: 4) {
                    Text("hurts").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.danger)
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DS.Colors.textFaint)
                    Text("helps").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.teal)
                }
            }
            VStack(spacing: 10) {
                ForEach(rows) { p in
                    DivergingRow(pattern: p, frac: CGFloat(min(max(magnitude(p) / maxMag, 0.08), 1.0)))
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
    }
}

private struct DivergingRow: View {
    let pattern: FoodPattern
    let frac: CGFloat
    private var color: Color { pattern.effectPositive ? DS.Colors.teal : DS.Colors.danger }

    var body: some View {
        HStack(spacing: 10) {
            Text(pattern.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            GeometryReader { geo in
                let half = geo.size.width / 2
                let barW = half * frac
                ZStack(alignment: .center) {
                    Rectangle()
                        .fill(DS.Colors.track)
                        .frame(width: 1.5)
                    Capsule()
                        .fill(color)
                        .frame(width: barW, height: 13)
                        .offset(x: pattern.effectPositive ? barW / 2 : -barW / 2)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            Text(pattern.badgeText ?? "")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Data Gate Card

private struct DataGateCard: View {
    let entriesLogged: Int
    let required: Int

    private var progress: Double { Double(entriesLogged) / Double(required) }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 40))
                .foregroundStyle(DS.Colors.violet.opacity(0.6))

            TwoToneHeadline(
                primary: "Almost there",
                secondary: " — \(required - entriesLogged) entries to go",
                font: .system(size: 22, weight: .heavy, design: .rounded)
            )

            Text("With \(required) entries LucidHealth starts surfacing patterns between your food and your recovery.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DS.Colors.surfaceElevated)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [DS.Colors.violet, DS.Colors.teal],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progress, height: 6)
                }
            }
            .frame(height: 6)

            Text("\(entriesLogged) / \(required)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.Colors.textFaint)
        }
        .padding(DS.Spacing.xl)
        .heroCard()
    }
}

// MARK: - Insight Engine (real correlations)
//
// REWRITE (2026-06-01): the old engine multiplied the CURRENT recovery score
// by arbitrary constants (e.g. (1 - recoveryScore/100)*15) and called it a
// "correlation" — pure theater. This computes real day-over-day relationships:
//   • Recovery predictors (HRV / RHR / sleep → recovery) from health_metrics —
//     hundreds of real days, live TODAY.
//   • Food / alcohol → next-day recovery, food → sleep — real once food
//     logging accumulates; honestly gated until then (no fake numbers).
// 2026-07: same math, now also emits the numbers (sampleN, rValue, comparison,
// badgeText) so the cards can draw evidence instead of narrating it.

enum InsightEngine {

    private static let utc: TimeZone = TimeZone(identifier: "UTC") ?? .current

    /// Pearson correlation; nil if too few points or zero variance.
    private static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        let n = Double(xs.count)
        guard xs.count == ys.count, xs.count >= 5 else { return nil }
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0, dx = 0.0, dy = 0.0
        for i in xs.indices {
            let a = xs[i] - mx, b = ys[i] - my
            num += a * b; dx += a * a; dy += b * b
        }
        guard dx > 0, dy > 0 else { return nil }
        return num / (dx.squareRoot() * dy.squareRoot())
    }

    private static func tier(n: Int, r: Double) -> FoodPattern.ConfidenceTier {
        let a = abs(r)
        if n >= 30 && a >= 0.45 { return .high }
        if n >= 14 && a >= 0.28 { return .medium }
        return .low
    }

    private static func strength(_ r: Double) -> String {
        switch abs(r) {
        case 0.6...:    return "strong"
        case 0.4..<0.6: return "clear"
        case 0.25..<0.4: return "mild"
        default:        return "weak"
        }
    }

    static func compute(entries: [FoodEntry], metrics: [DailyMetric]) -> [FoodPattern] {
        var out: [FoodPattern] = []

        // ── Recovery predictors (real, from health_metrics) ──────────────
        func paired(_ sel: (DailyMetric) -> Double?) -> ([Double], [Double]) {
            var xs = [Double](), ys = [Double]()
            for m in metrics {
                if let x = sel(m), let r = m.recovery, r > 0 { xs.append(x); ys.append(r) }
            }
            return (xs, ys)
        }

        let hrvPair = paired { $0.hrv }
        if let r = pearson(hrvPair.0, hrvPair.1) {
            out.append(FoodPattern(
                title: "HRV drives your recovery",
                subtitle: "Across \(hrvPair.0.count) days, higher morning HRV preceded higher recovery.",
                confidenceTier: tier(n: hrvPair.0.count, r: r),
                confidenceValue: min(abs(r), 1.0),
                effectDescription: "\(strength(r)) link",
                effectPositive: r > 0,
                sampleN: hrvPair.0.count,
                rValue: r,
                badgeText: String(format: "r %.2f", r)))
        }

        let rhrPair = paired { $0.restingHr }
        if let r = pearson(rhrPair.0, rhrPair.1) {
            out.append(FoodPattern(
                title: "Resting HR vs recovery",
                subtitle: "Lower resting heart rate nights tend to precede stronger recovery.",
                confidenceTier: tier(n: rhrPair.0.count, r: r),
                confidenceValue: min(abs(r), 1.0),
                effectDescription: "\(strength(r))\(r < 0 ? " inverse" : "") link",
                effectPositive: r < 0,
                sampleN: rhrPair.0.count,
                rValue: r,
                badgeText: String(format: "r %.2f", r)))
        }

        let slpPair = paired { $0.sleepHours }
        if slpPair.0.count >= 8, let r = pearson(slpPair.0, slpPair.1) {
            out.append(FoodPattern(
                title: "Sleep duration → recovery",
                subtitle: "Recovery measured against sleep length over \(slpPair.0.count) nights.",
                confidenceTier: tier(n: slpPair.0.count, r: r),
                confidenceValue: min(abs(r), 1.0),
                effectDescription: "\(strength(r)) link",
                effectPositive: r > 0,
                sampleN: slpPair.0.count,
                rValue: r,
                badgeText: String(format: "r %.2f", r)))
        }

        // ── Food-dependent (real once logging accumulates) ───────────────
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = utc
        let cal = Calendar.current

        var foodByDay: [String: [FoodEntry]] = [:]
        for e in entries { foodByDay[fmt.string(from: e.capturedAt), default: []].append(e) }
        var metByDay: [String: DailyMetric] = [:]
        for m in metrics { metByDay[m.date] = m }

        // Alcohol → NEXT-day recovery
        var alcRecov = [Double](), soberRecov = [Double]()
        for (day, es) in foodByDay {
            guard let d = fmt.date(from: day),
                  let next = cal.date(byAdding: .day, value: 1, to: d) else { continue }
            guard let r = metByDay[fmt.string(from: next)]?.recovery, r > 0 else { continue }
            if es.contains(where: { $0.items.contains { $0.isAlcohol == true } }) {
                alcRecov.append(r)
            } else {
                soberRecov.append(r)
            }
        }
        if alcRecov.count >= 3 && soberRecov.count >= 3 {
            let a = alcRecov.reduce(0, +) / Double(alcRecov.count)
            let s = soberRecov.reduce(0, +) / Double(soberRecov.count)
            let pct = s > 0 ? ((a - s) / s) * 100 : 0
            out.append(FoodPattern(
                title: "Alcohol → next-day recovery",
                subtitle: "Morning-after recovery vs sober nights, over \(alcRecov.count) drinking days.",
                confidenceTier: alcRecov.count >= 8 ? .high : .medium,
                confidenceValue: min(Double(alcRecov.count) / 12.0, 1.0),
                effectDescription: String(format: "%+.0f%% recovery the morning after", pct),
                effectPositive: (a - s) >= 0,
                sampleN: alcRecov.count + soberRecov.count,
                comparison: PatternComparison(
                    beforeLabel: "sober nights", afterLabel: "after drinking",
                    before: s, after: a, unit: "recovery"),
                badgeText: String(format: "%+.0f%%", pct)))
        }

        // High-NOVA day → that night's sleep score
        var novaSleep = [Double](), cleanSleep = [Double]()
        for (day, es) in foodByDay {
            guard let ss = metByDay[day]?.sleepScore, ss > 0 else { continue }
            let avgNova = es.compactMap { $0.novaAvg }.reduce(0, +) / Double(max(es.count, 1))
            if avgNova >= 3.0 { novaSleep.append(ss) } else { cleanSleep.append(ss) }
        }
        if novaSleep.count >= 4 && cleanSleep.count >= 4 {
            let hi = novaSleep.reduce(0, +) / Double(novaSleep.count)
            let lo = cleanSleep.reduce(0, +) / Double(cleanSleep.count)
            out.append(FoodPattern(
                title: "Processed food → sleep",
                subtitle: "Sleep score on heavy ultra-processed days vs cleaner days, \(novaSleep.count) days each.",
                confidenceTier: novaSleep.count >= 10 ? .high : .medium,
                confidenceValue: min(Double(novaSleep.count) / 14.0, 1.0),
                effectDescription: String(format: "%+.0f sleep score on processed days", hi - lo),
                effectPositive: (hi - lo) >= 0,
                sampleN: novaSleep.count + cleanSleep.count,
                comparison: PatternComparison(
                    beforeLabel: "cleaner days", afterLabel: "processed days",
                    before: lo, after: hi, unit: "sleep score"),
                badgeText: String(format: "%+.0f", hi - lo)))
        }

        return out.sorted { $0.confidenceValue > $1.confidenceValue }
    }
}
