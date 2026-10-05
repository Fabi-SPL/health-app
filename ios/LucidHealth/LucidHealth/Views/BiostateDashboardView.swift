import SwiftUI
import Charts

// MARK: - BiostateDashboardView
//
// EXPERIMENTAL biostate engine (server v141-v146) surfaced in the app:
//   • Live state — arousal / drunk / respiration, with confidence.
//   • Week graph — the 15-min cron samples (biostate_history).
//   • Train it — tap any card to correct a wrong read → log_state_correction.
//   • Timeline — recent corrections you've made.
//
// Everything is flagged experimental. Nothing here feeds recovery / sleep / mood.
// Read-only on the detectors; the ONLY write is a ground-truth correction.

enum BiostateDetector: String, Identifiable {
    case arousal, drunk, respiration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .arousal: return "Arousal"
        case .drunk: return "Intoxication"
        case .respiration: return "Breathing"
        }
    }
    var icon: String {
        switch self {
        case .arousal: return "bolt.heart.fill"
        case .drunk: return "wineglass"
        case .respiration: return "lungs.fill"
        }
    }
    var tint: Color {
        switch self {
        case .arousal: return DS.Colors.pink
        case .drunk: return DS.Colors.amber
        case .respiration: return DS.Colors.teal
        }
    }
}

struct BiostateDashboardView: View {
    /// When set (e.g. opened from a change-notification's "Open & fix"), the
    /// matching correction sheet auto-presents once data loads.
    var initialCorrect: BiostateDetector? = nil

    @Environment(\.dismiss) private var dismiss
    private let svc = ExperimentalFeaturesService.shared

    @State private var now: ExperimentalFeaturesService.BiostateNow?
    @State private var history: [ExperimentalFeaturesService.BiostateHistoryPoint] = []
    @State private var truth: [ExperimentalFeaturesService.TruthLogEntry] = []
    @State private var loading = true
    @State private var appeared = false
    @State private var refreshing = false
    @State private var correcting: BiostateDetector?
    @State private var toast: String?
    @State private var graphMetric: GraphMetric = .arousal

    enum GraphMetric: String, CaseIterable, Identifiable {
        case arousal = "Arousal", drunk = "Intoxication", respiration = "Breath"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AuroraBackground().ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.md) {
                        Color.clear.frame(height: DS.Spacing.xs)

                        liveSection
                        graphSection
                        timelineSection
                        disclaimer

                        Color.clear.frame(height: 40)
                    }
                    .padding(.horizontal, DS.Spacing.md)
                }

                if let t = toast { toastView(t) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { titleBar }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { DS.Haptic.tap(); dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(DS.Colors.textMuted)
                    }
                }
            }
        }
        .task {
            await loadAll()
            if let d = initialCorrect { correcting = d }
        }
        .sheet(item: $correcting) { det in
            BiostateCorrectionSheet(detector: det, now: now) { state, value, note in
                await submitCorrection(det, state: state, value: value, note: note)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.Colors.violet)
            Text("Biostate")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            ExperimentalPill()
        }
    }

    // MARK: Live section

    private var liveSection: some View {
        VStack(spacing: DS.Spacing.sm) {
            sectionHeader("LIVE", trailing: refreshing ? "refreshing…" : relativeTime(now?.ts) , systemTrailing: refreshing ? nil : "arrow.clockwise") {
                Task { await refresh() }
            }

            if loading {
                ProgressView().tint(DS.Colors.violet).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                LiveStateCard(
                    detector: .arousal,
                    headline: arousalHeadline,
                    sub: arousalSub,
                    confidence: now?.arousal?.confidence,
                    warn: now?.arousal?.signals_disagree == true ? "signals disagree" : nil,
                    onTap: { correcting = .arousal }
                )
                LiveStateCard(
                    detector: .drunk,
                    headline: drunkHeadline,
                    sub: drunkSub,
                    confidence: (now?.drunk?.gated == true) ? nil : now?.drunk?.confidence,
                    warn: nil,
                    onTap: { correcting = .drunk }
                )
                LiveStateCard(
                    detector: .respiration,
                    headline: respHeadline,
                    sub: respSub,
                    confidence: now?.respiration?.confidence,
                    warn: nil,
                    onTap: { correcting = .respiration }
                )
            }
        }
    }

    // headline / sub builders -------------------------------------------------

    private var arousalHeadline: String {
        guard let a = now?.arousal, let v = a.arousal else { return "—" }
        let emoji = a.emoji ?? ""
        return "\(emoji) \(String(format: "%.1f", v))"
    }
    private var arousalSub: String {
        guard let a = now?.arousal else { return "no reading" }
        if a.arousal == nil { return a.reason == "low_quality_window" ? "low-quality window" : "no reading" }
        var parts: [String] = []
        if let band = a.band { parts.append(band.replacingOccurrences(of: "_", with: " ")) }
        if let r = a.rmssd { parts.append("RMSSD \(Int(r))") }
        if let h = a.hr { parts.append("HR \(Int(h))") }
        if let act = a.activity_state { parts.append(act) }
        return parts.joined(separator: " · ")
    }

    private var drunkHeadline: String {
        guard let d = now?.drunk else { return "—" }
        if d.gated == true { return "Sober" }
        guard let label = d.label, d.stage != nil else { return "Unknown" }
        return label.capitalized
    }
    private var drunkSub: String {
        guard let d = now?.drunk else { return "no reading" }
        if d.gated == true { return "alcohol mode off · forced sober" }
        if d.stage == nil { return d.reason == "low_quality_window" ? "low-quality window" : "no reading" }
        var parts: [String] = []
        if let ratio = d.rmssd_ratio { parts.append("ratio \(String(format: "%.2f", ratio))") }
        if let r = d.rmssd { parts.append("RMSSD \(Int(r))") }
        if d.hr_corroborated == true { parts.append("HR-corrob") }
        return parts.joined(separator: " · ")
    }

    private var respHeadline: String {
        guard let r = now?.respiration, let v = r.resp_rate else { return "—" }
        return "\(String(format: "%.0f", v)) bpm"
    }
    private var respSub: String {
        guard let r = now?.respiration else { return "no reading" }
        if r.resp_rate == nil { return "no usable source" }
        var parts: [String] = []
        if let e = r.error_bpm { parts.append("±\(String(format: "%.0f", e))") }
        if let m = r.method { parts.append(m.replacingOccurrences(of: "_", with: " ")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Graph section

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionHeader("LAST 7 DAYS", trailing: "\(graphPoints.count) samples", systemTrailing: nil, action: nil)

            metricPicker

            if graphPoints.count < 2 {
                Text("Filling up — a sample lands every 15 min. Keep the strap on to build history.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 30)
            } else {
                // Day-bucketed band — one min–max range bar + a mean dot per day
                // instead of ~670 raw 15-min samples drawn as spaghetti.
                Chart {
                    if graphMetric == .arousal, let f = dayBuckets.first?.day, let l = dayBuckets.last?.day {
                        RectangleMark(
                            xStart: .value("s", f), xEnd: .value("e", Calendar.current.date(byAdding: .day, value: 1, to: l) ?? l),
                            yStart: .value("lo", 4.0), yEnd: .value("hi", 6.0)
                        )
                        .foregroundStyle(DS.Colors.violet.opacity(0.06))
                    }
                    ForEach(dayBuckets) { b in
                        BarMark(
                            x: .value("day", b.day, unit: .day),
                            yStart: .value("min", b.min),
                            yEnd: .value("max", max(b.max, b.min + yNudge)),
                            width: .ratio(0.45)
                        )
                        .foregroundStyle(graphTint.opacity(0.22))
                        .cornerRadius(4)
                        PointMark(
                            x: .value("day", b.day, unit: .day),
                            y: .value("mean", b.mean)
                        )
                        .symbolSize(42)
                        .foregroundStyle(graphTint)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.weekday(.narrow))
                } }
                .frame(height: 180)
                .padding(.top, DS.Spacing.xs)
                .accessibilityLabel("Last 7 days of \(graphMetric.rawValue): daily range bands with mean dots")
            }
        }
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    private var metricPicker: some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(GraphMetric.allCases) { m in
                let sel = graphMetric == m
                Button {
                    DS.Haptic.select()
                    withAnimation(DS.Anim.quick) { graphMetric = m }
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 12, weight: sel ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(sel ? graphTint : DS.Colors.textFaint)
                        .padding(.horizontal, DS.Spacing.md).padding(.vertical, 6)
                        .background(
                            Capsule().fill(sel ? graphTint.opacity(0.14) : DS.Colors.surface)
                                .overlay(Capsule().stroke(sel ? graphTint.opacity(0.3) : DS.Colors.border, lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var graphTint: Color {
        switch graphMetric {
        case .arousal: return DS.Colors.pink
        case .drunk: return DS.Colors.amber
        case .respiration: return DS.Colors.teal
        }
    }

    private struct GraphPoint: Identifiable {
        let id: Int        // biostate_history primary key — unique even if two rows share a ts
        let date: Date
        let value: Double
    }

    private var graphPoints: [GraphPoint] {
        history.compactMap { p in
            guard let d = parseDate(p.ts) else { return nil }
            let v: Double?
            switch graphMetric {
            case .arousal: v = p.arousal
            case .drunk: v = p.drunk_stage.map(Double.init)
            case .respiration: v = p.resp_rate
            }
            guard let vv = v else { return nil }
            return GraphPoint(id: p.id, date: d, value: vv)
        }
    }

    private struct DayBucket: Identifiable {
        let day: Date
        let min: Double
        let max: Double
        let mean: Double
        var id: Date { day }
    }

    /// Minimum band height so a flat day still draws a visible pill.
    private var yNudge: Double {
        (yDomain.upperBound - yDomain.lowerBound) * 0.02
    }

    private var dayBuckets: [DayBucket] {
        let grouped = Dictionary(grouping: graphPoints) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { day, pts in
            let vals = pts.map(\.value)
            return DayBucket(
                day: day,
                min: vals.min() ?? 0,
                max: vals.max() ?? 0,
                mean: vals.reduce(0, +) / Double(vals.count)
            )
        }
        .sorted { $0.day < $1.day }
    }

    private var yDomain: ClosedRange<Double> {
        switch graphMetric {
        case .arousal: return 0...10
        case .drunk: return 0...4
        case .respiration:
            let vals = graphPoints.map(\.value)
            let lo = max((vals.min() ?? 8) - 2, 0)
            let hi = (vals.max() ?? 24) + 2
            return lo...hi
        }
    }

    // MARK: Timeline section

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionHeader("YOUR CORRECTIONS", trailing: truth.isEmpty ? nil : "\(truth.count)", systemTrailing: nil, action: nil)

            if truth.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 18)).foregroundStyle(DS.Colors.violet.opacity(0.7))
                    Text("No corrections yet. When a reading above is wrong, tap it and tell it the truth — that's how it learns your body.")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassDefault()
            } else {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(truth) { row in TruthRow(row: row, relative: relativeTime(row.ts)) }
                }
            }
        }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("🧪")
            Text("Experimental. These detectors are still learning and are **not** medical readings. Nothing here feeds your recovery, sleep, or mood scores.")
                .font(.system(size: 11)).foregroundStyle(DS.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Colors.surface.opacity(0.5)))
    }

    // MARK: Shared bits

    private func sectionHeader(_ title: String, trailing: String?, systemTrailing: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(DS.Font.label).tracking(1.0).foregroundStyle(DS.Colors.textFaint)
            Spacer()
            if let t = trailing, !t.isEmpty {
                Text(t).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Colors.textFaint)
            }
            if let sys = systemTrailing {
                Button { action?() } label: {
                    Image(systemName: sys).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.violet)
                }.buttonStyle(.plain)
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(DS.Colors.success)
            Text(text).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(DS.Colors.raised).overlay(Capsule().stroke(DS.Colors.success.opacity(0.3), lineWidth: 0.5)))
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Data

    private func loadAll() async {
        loading = true
        now = await svc.fetchBiostateNow()
        loading = false
        async let h = svc.fetchBiostateHistory(hours: 168)
        async let t = svc.fetchTruthLog(limit: 25)
        history = await h
        truth = await t
        withAnimation { appeared = true }
    }

    private func refresh() async {
        refreshing = true
        now = await svc.fetchBiostateNow()
        refreshing = false
    }

    private func submitCorrection(_ det: BiostateDetector, state: String?, value: Double?, note: String?) async {
        let ok = await svc.logStateCorrection(detector: det.rawValue, correctedState: state, correctedValue: value, note: note)
        if ok {
            DS.Haptic.success()
            showToast("Logged — \(det.title.lowercased()) trained")
            truth = await svc.fetchTruthLog(limit: 25)
        } else {
            DS.Haptic.error()
            showToast("Couldn't save — try again")
        }
    }

    private func showToast(_ s: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }

    // MARK: Time helpers

    private func parseDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: iso) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: iso)
    }

    private func relativeTime(_ iso: String?) -> String {
        guard let d = parseDate(iso) else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }
}

// MARK: - Live State Card

private struct LiveStateCard: View {
    let detector: BiostateDetector
    let headline: String
    let sub: String
    let confidence: Double?
    let warn: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: { DS.Haptic.tap(); onTap() }) {
            HStack(spacing: DS.Spacing.md) {
                ZStack {
                    Circle().fill(detector.tint.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: detector.icon)
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(detector.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(detector.title)
                            .font(.system(size: 11, weight: .bold)).tracking(0.5)
                            .foregroundStyle(DS.Colors.textFaint)
                        if let w = warn {
                            Text("⚠︎ \(w)").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DS.Colors.warning)
                        }
                    }
                    Text(headline)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .monospacedDigit()
                    Text(sub)
                        .font(.system(size: 11)).foregroundStyle(DS.Colors.textMuted)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let c = confidence {
                        ConfidenceBar(value: c, tint: detector.tint).padding(.top, 2)
                    }
                }
                Spacer()
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(detector.tint.opacity(0.5))
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassDefault()
        .pressableCard()
    }
}

private struct ConfidenceBar: View {
    let value: Double
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.surfaceElevated).frame(height: 4)
                    Capsule().fill(tint).frame(width: max(0, min(1, value)) * geo.size.width, height: 4)
                }
            }
            .frame(height: 4)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.Colors.textFaint)
        }
    }
}

// MARK: - Truth Row

private struct TruthRow: View {
    let row: ExperimentalFeaturesService.TruthLogEntry
    let relative: String

    private var emoji: String {
        switch row.detector {
        case "arousal": return "⚡"
        case "drunk": return "🍷"
        case "respiration": return "🫁"
        default: return "•"
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(emoji).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text("You: \(row.corrected_state ?? valueStr(row.corrected_value))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("read \(row.detected_state ?? valueStr(row.detected_value))")
                    .font(.system(size: 10)).foregroundStyle(DS.Colors.textMuted)
            }
            Spacer()
            Text(relative).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Colors.textFaint)
        }
        .padding(.horizontal, DS.Spacing.md).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Colors.surface.opacity(0.6)))
    }

    private func valueStr(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }
}

// MARK: - Experimental pill

private struct ExperimentalPill: View {
    var body: some View {
        Text("EXP")
            .font(.system(size: 8, weight: .heavy)).tracking(0.5)
            .foregroundStyle(DS.Colors.violet)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(DS.Colors.raised2))
    }
}

// MARK: - Correction Sheet

struct BiostateCorrectionSheet: View {
    let detector: BiostateDetector
    let now: ExperimentalFeaturesService.BiostateNow?
    let onSubmit: (String?, Double?, String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var respValue: Double = 14
    @State private var submitting = false

    private struct Preset { let label: String; let emoji: String; let state: String; let value: Double }

    private var presets: [Preset] {
        switch detector {
        case .arousal:
            return [
                .init(label: "Deep calm", emoji: "😴", state: "deep_calm", value: 1),
                .init(label: "Relaxed", emoji: "🌊", state: "relaxed", value: 3),
                .init(label: "Neutral", emoji: "⚪", state: "neutral", value: 5),
                .init(label: "Elevated", emoji: "⚡", state: "elevated", value: 7),
                .init(label: "High", emoji: "🔥", state: "high_arousal", value: 9),
            ]
        case .drunk:
            return [
                .init(label: "Sober", emoji: "✅", state: "sober", value: 0),
                .init(label: "Buzzed", emoji: "🍺", state: "buzzed", value: 1),
                .init(label: "Tipsy", emoji: "🍷", state: "tipsy", value: 2),
                .init(label: "Drunk", emoji: "🥴", state: "drunk", value: 3),
                .init(label: "Wasted", emoji: "💀", state: "wasted", value: 4),
            ]
        case .respiration: return []
        }
    }

    private var detectedLine: String {
        switch detector {
        case .arousal:
            guard let a = now?.arousal, let v = a.arousal else { return "no current reading" }
            return "reads \(a.band?.replacingOccurrences(of: "_", with: " ") ?? "—") (\(String(format: "%.1f", v)))"
        case .drunk:
            guard let d = now?.drunk else { return "no current reading" }
            if d.gated == true { return "reads sober (alcohol mode off)" }
            return "reads \(d.label ?? "—")"
        case .respiration:
            guard let r = now?.respiration, let v = r.resp_rate else { return "no current reading" }
            return "reads \(String(format: "%.0f", v)) bpm"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: detector.icon).foregroundStyle(detector.tint)
                                Text("What was the truth?")
                                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                                    .foregroundStyle(DS.Colors.textPrimary)
                            }
                            Text("It \(detectedLine). Set what was actually true — it trains on clean windows only.")
                                .font(.system(size: 12)).foregroundStyle(DS.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if detector == .respiration {
                            respControl
                        } else {
                            presetGrid
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTE (OPTIONAL)").font(DS.Font.label).tracking(1).foregroundStyle(DS.Colors.textFaint)
                            TextField("e.g. awake, just sat down…", text: $note)
                                .font(.system(size: 14))
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(DS.Colors.surfaceElevated).clipShape(Capsule())
                                .foregroundStyle(DS.Colors.textPrimary)
                        }

                        Color.clear.frame(height: 20)
                    }
                    .padding(DS.Spacing.lg)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("Train \(detector.title)").font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.Colors.textPrimary)
                        ExperimentalPill()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { DS.Haptic.tap(); dismiss() }.foregroundStyle(DS.Colors.textMuted)
                }
            }
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 3), spacing: DS.Spacing.sm) {
            ForEach(presets, id: \.state) { p in
                Button {
                    submit(state: p.state, value: p.value)
                } label: {
                    VStack(spacing: 6) {
                        Text(p.emoji).font(.system(size: 26))
                        Text(p.label).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Colors.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(DS.Colors.surface)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(detector.tint.opacity(0.18), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
                .disabled(submitting)
            }
        }
    }

    private var respControl: some View {
        VStack(spacing: DS.Spacing.md) {
            Text("\(String(format: "%.0f", respValue)) bpm")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.teal).monospacedDigit()
            Slider(value: $respValue, in: 6...30, step: 1).tint(DS.Colors.teal)
            HStack {
                Text("6").font(.system(size: 10)).foregroundStyle(DS.Colors.textFaint)
                Spacer()
                Text("30").font(.system(size: 10)).foregroundStyle(DS.Colors.textFaint)
            }
            Button {
                submit(state: nil, value: respValue)
            } label: {
                Text(submitting ? "Saving…" : "Save reading")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Capsule().fill(DS.Colors.teal))
            }
            .buttonStyle(.plain).disabled(submitting)
        }
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    private func submit(state: String?, value: Double?) {
        guard !submitting else { return }
        submitting = true
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await onSubmit(state, value, trimmedNote.isEmpty ? nil : trimmedNote)
            dismiss()
        }
    }
}
