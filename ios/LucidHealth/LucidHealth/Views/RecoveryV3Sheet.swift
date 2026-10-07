import SwiftUI

// Recovery sheet (V3 board): last night's inputs against your own normal; the score itself comes from the server.

struct RecoveryV3Sheet: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss

    init() {}

    var body: some View {
        RecoveryV3Content(engine: bleManager.healthEngine, onClose: { dismiss() })
            .presentationDetents([.large])
            .presentationBackground(V3.sheet)
            .lucidRendered(.recovery)
    }
}

// MARK: - Models

private struct RecoveryV3Night {
    let date: String
    let hours: Double?
    let hrv: Double?
    let rhr: Double?
    let resp: Double?
}

private struct RecoveryV3Range {
    let lo: Double
    let hi: Double
}

private enum RecoveryV3Status {
    case inside
    case above
    case below
}

private struct RecoveryV3Factor: Identifiable {
    let id: String
    let name: String
    let value: Double
    let valueText: String
    let color: Color
    let band: Color
    let higherIsBetter: Bool
    let range: RecoveryV3Range?
    let rangeText: String?

    var status: RecoveryV3Status? {
        guard let r = range else { return nil }
        if value > r.hi { return .above }
        if value < r.lo { return .below }
        return .inside
    }

    var chipText: String? {
        guard let s = status else { return nil }
        switch s {
        case .inside: return "In range"
        case .above: return "Above normal"
        case .below: return "Below normal"
        }
    }

    var isWarn: Bool {
        guard let s = status else { return false }
        switch s {
        case .inside: return false
        case .above: return !higherIsBetter
        case .below: return higherIsBetter
        }
    }

    var chipColor: Color {
        status == nil ? V3.t2 : (isWarn ? V3.amber : V3.green)
    }

    var dotColor: Color {
        isWarn ? V3.amber : color
    }
}

private enum RecoveryV3Math {
    static func range(_ values: [Double]) -> RecoveryV3Range? {
        let v: [Double] = values.filter { $0 > 0 }
        guard v.count >= 7 else { return nil }
        let mean: Double = v.reduce(0, +) / Double(v.count)
        let sq: Double = v.reduce(0) { (acc: Double, x: Double) -> Double in acc + (x - mean) * (x - mean) }
        let sd: Double = (sq / Double(v.count)).squareRoot()
        return RecoveryV3Range(lo: mean - sd, hi: mean + sd)
    }

    static func colorWord(_ v: Double) -> String {
        v >= 67 ? "green" : v >= 34 ? "yellow" : "red"
    }

    static func advice(_ v: Double) -> String {
        v >= 67 ? "Good day to train." : v >= 34 ? "Keep it moderate." : "Go easy and recover."
    }
}

// MARK: - Content

private struct RecoveryV3Content: View {
    @ObservedObject var engine: HealthEngine
    let onClose: () -> Void
    @ObservedObject private var store = BoardStore.shared
    @State private var history: [RecoveryV3Night] = []

    var body: some View {
        ZStack(alignment: .top) {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    Capsule().fill(V3.chrome).frame(width: 36, height: 5).padding(.top, 8)
                    V3Header(date: V3Format.dayTitle(Date()), title: "Recovery") {
                        V3IconButton(symbol: "xmark") { onClose() }
                    }
                    hero
                    calloutRow
                    factorsCard
                    trendCard
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .task { await store.refresh() }
        .task { await loadHistory() }
    }

    // MARK: Data

    private var freshNight: BoardNight? {
        let n: BoardNight = store.night
        if n.loaded && !n.isFallback { return n }
        return nil
    }

    private var recovery: Double? {
        if engine.recoveryScore > 0 { return engine.recoveryScore }
        if !engine.lastNightHasData { return nil }
        if let n = freshNight, let r = n.scores["recovery"] { return r }
        return nil
    }

    private var priorNights: [RecoveryV3Night] {
        Array(history.dropFirst())
    }

    private func makeFactor(_ id: String, _ name: String, value: Double, unit: String, color: Color, band: Color,
                            higherIsBetter: Bool, past: [Double], fmt: (Double) -> String) -> RecoveryV3Factor {
        let r: RecoveryV3Range? = RecoveryV3Math.range(past)
        var text: String? = nil
        if let r { text = "normal " + fmt(r.lo) + " to " + fmt(r.hi) }
        return RecoveryV3Factor(id: id, name: name, value: value, valueText: fmt(value) + unit, color: color, band: band,
                                higherIsBetter: higherIsBetter, range: r, rangeText: text)
    }

    private var factors: [RecoveryV3Factor] {
        guard let n = freshNight else { return [] }
        let prior: [RecoveryV3Night] = priorNights
        var out: [RecoveryV3Factor] = []
        if let v = n.positive("hrv_avg") {
            out.append(makeFactor("hrv", "HRV", value: v, unit: " ms", color: V3.energy, band: V3.green.opacity(0.16),
                                  higherIsBetter: true, past: prior.compactMap { $0.hrv },
                                  fmt: { (x: Double) -> String in String(format: "%.0f", x) }))
        }
        if let v = n.positive("resting_hr") {
            out.append(makeFactor("rhr", "Resting heart rate", value: v, unit: " bpm", color: V3.heart, band: V3.green.opacity(0.16),
                                  higherIsBetter: false, past: prior.compactMap { $0.rhr },
                                  fmt: { (x: Double) -> String in String(format: "%.0f", x) }))
        }
        if let v = n.hours {
            out.append(makeFactor("sleep", "Sleep", value: v, unit: "", color: V3.sleep, band: V3.sleep.opacity(0.16),
                                  higherIsBetter: true, past: prior.compactMap { $0.hours },
                                  fmt: { (x: Double) -> String in V3Format.duration(hours: x) }))
        }
        if let v = n.positive("respiratory_rate") {
            out.append(makeFactor("resp", "Breathing", value: v, unit: " /min", color: V3.rem, band: V3.green.opacity(0.16),
                                  higherIsBetter: false, past: prior.compactMap { $0.resp },
                                  fmt: { (x: Double) -> String in String(format: "%.1f", x) }))
        }
        return out
    }

    private var trendDays: [DailyMetric] {
        store.lastFullDays(7)
    }

    private func loadHistory() async {
        let uid: String = SupabaseClient.shared.userId
        let items: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "metric_date,sleep_hours,hrv_avg,resting_hr,respiratory_rate"),
            URLQueryItem(name: "user_id", value: "eq." + uid),
            URLQueryItem(name: "sleep_hours", value: "gt.0"),
            URLQueryItem(name: "order", value: "metric_date.desc"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        let rows: [[String: Any]] = await StrainDayAPI.rows("health_metrics", items)
        var parsed: [RecoveryV3Night] = []
        for r in rows {
            guard let d = r["metric_date"] as? String else { continue }
            parsed.append(RecoveryV3Night(date: d,
                                          hours: StrainParse.num(r["sleep_hours"]),
                                          hrv: StrainParse.num(r["hrv_avg"]),
                                          rhr: StrainParse.num(r["resting_hr"]),
                                          resp: StrainParse.num(r["respiratory_rate"])))
        }
        history = parsed
    }

    // MARK: Sections

    @ViewBuilder
    private var hero: some View {
        if let r = recovery {
            HStack {
                Spacer(minLength: 0)
                V3HeroRing(value: String(Int(r.rounded())), unit: "%", progress: r / 100, color: V3.recovery(r),
                           label: "Readiness, " + RecoveryV3Math.colorWord(r), sub: V3.recoveryWord(r),
                           subColor: V3.recovery(r))
                Spacer(minLength: 0)
            }
            .padding(.top, 26)
            .padding(.bottom, 4)
            .background(alignment: .top) { V3Glow(color: V3.recovery(r)).padding(.top, 2) }
        } else {
            emptyHero
        }
    }

    private var emptyHero: some View {
        VStack(spacing: 0) {
            ZStack {
                V3Ring(progress: 0, color: V3.t3, lineWidth: 15, dashed: true)
                Text("No score yet").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2)
            }
            .frame(width: 172, height: 172)
            Text("Recovery arrives once a night is recorded on the strap.")
                .font(V3Font.text(12)).foregroundStyle(V3.t2)
                .multilineTextAlignment(.center).padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
    }

    @ViewBuilder
    private var calloutRow: some View {
        if let r = recovery {
            V3Callout(color: V3.recovery(r), bold: calloutBold(r), rest: RecoveryV3Math.advice(r))
        }
    }

    private func calloutBold(_ r: Double) -> String {
        guard let hrv = factors.first(where: { $0.id == "hrv" }), let s = hrv.status else {
            return V3.recoveryWord(r) + "."
        }
        switch s {
        case .inside: return "HRV in your normal range."
        case .above: return "HRV above your normal range."
        case .below: return "HRV below your normal range."
        }
    }

    private var factorsCard: some View {
        V3Card {
            V3CardHeader(title: "What made it", trailing: "vs your normal")
            if factors.isEmpty {
                V3EmptyLine(text: "Last night's readings have not synced yet.")
            } else {
                ForEach(factors) { (f: RecoveryV3Factor) in
                    RecoveryV3FactorRow(factor: f, first: f.id == factors.first?.id)
                }
            }
        }
    }

    @ViewBuilder
    private var trendCard: some View {
        let days: [DailyMetric] = trendDays
        if days.count >= 2 {
            V3Card {
                V3CardHeader(title: "Last " + String(days.count) + " days", trailing: trendTrailing(days))
                RecoveryV3Bars(days: days)
            }
        }
    }

    private func trendTrailing(_ days: [DailyMetric]) -> String? {
        let vals: [Double] = days.compactMap { $0.recovery }
        guard vals.count >= 3 else { return nil }
        let avg: Double = vals.reduce(0, +) / Double(vals.count)
        return "average " + String(format: "%.0f", avg)
    }

    @ViewBuilder
    private var footnote: some View {
        if factors.contains(where: { $0.range != nil }) {
            Text("Normal is your own average, give or take one standard deviation, across your previous nights.")
                .font(V3Font.text(12)).foregroundStyle(V3.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - Pieces

private struct RecoveryV3FactorRow: View {
    let factor: RecoveryV3Factor
    let first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(factor.name).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                Spacer(minLength: 8)
                Text(factor.valueText).font(V3Font.num(15, .semibold)).foregroundStyle(V3.t1)
            }
            noteRow
            strip
        }
        .padding(.top, first ? 2 : 14)
    }

    @ViewBuilder
    private var noteRow: some View {
        if let note = factor.rangeText, let chip = factor.chipText {
            HStack(alignment: .center) {
                Text(note).font(V3Font.text(12)).foregroundStyle(V3.t2).monospacedDigit()
                Spacer(minLength: 8)
                Text(chip)
                    .font(V3Font.text(12, .bold))
                    .foregroundStyle(factor.chipColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(factor.chipColor.opacity(0.14), in: Capsule())
            }
            .padding(.top, 2)
            .padding(.bottom, 6)
        } else {
            Text("Not enough nights yet for your normal.")
                .font(V3Font.text(12)).foregroundStyle(V3.t2)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var strip: some View {
        if let r = factor.range {
            let span: Double = max(r.hi - r.lo, 0.0001)
            let lo: Double = max(0, min(r.lo - span * 1.5, factor.value - span * 0.5))
            let hi: Double = max(r.hi + span * 1.5, factor.value + span * 0.5)
            RecoveryV3RangeStrip(lo: lo, hi: hi, bandLo: r.lo, bandHi: r.hi, bandColor: factor.band,
                                 value: factor.value, color: factor.dotColor)
        }
    }
}

private struct RecoveryV3RangeStrip: View {
    let lo: Double
    let hi: Double
    let bandLo: Double
    let bandHi: Double
    let bandColor: Color
    let value: Double
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = size.width
            let cy: CGFloat = 14
            let rangeSpan: Double = max(hi - lo, 0.0001)
            func xOf(_ v: Double) -> CGFloat {
                let t: Double = (min(max(v, lo), hi) - lo) / rangeSpan
                return 8 + CGFloat(t) * (w - 16)
            }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: cy))
            line.addLine(to: CGPoint(x: w, y: cy))
            ctx.stroke(line, with: .color(V3.track), lineWidth: 2)
            let bx0: CGFloat = xOf(bandLo)
            let bx1: CGFloat = xOf(bandHi)
            let band = Path(roundedRect: CGRect(x: bx0, y: cy - 6, width: max(bx1 - bx0, 0), height: 12), cornerRadius: 6)
            ctx.fill(band, with: .color(bandColor))
            let x: CGFloat = xOf(value)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 9.5, y: cy - 9.5, width: 19, height: 19)), with: .color(V3.card))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 7, y: cy - 7, width: 14, height: 14)), with: .color(color))
        }
        .frame(height: 28)
    }
}

private struct RecoveryV3Bars: View {
    let days: [DailyMetric]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.date) { (d: DailyMetric) in
                column(d)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func column(_ d: DailyMetric) -> some View {
        let v: Double = d.recovery ?? 0
        let h: CGFloat = max(4, CGFloat(v / 100) * 72)
        return VStack(spacing: 6) {
            Text(String(Int(v.rounded()))).font(V3Font.num(12, .semibold)).foregroundStyle(V3.t2)
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(V3.recovery(v)).frame(height: h)
            Text(BoardFormat.weekdayShort(d.date)).font(V3Font.text(11)).foregroundStyle(V3.t3)
        }
        .frame(maxWidth: .infinity)
    }
}
