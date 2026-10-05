import SwiftUI
import Charts

/// One point on the 24h body-battery curve (server-reconstructed from realtime HR).
struct BodyBatteryPoint: Identifiable {
    let at: Date
    let value: Double
    var id: Date { at }
}

/// Body Battery hero — the MAIN metric on Today. A horizontal battery that fills
/// with the carry-over tank level (green/amber/red), a big number, a plain-language
/// status, and a demoted secondary row (recovery / sleep / stress).
///
/// Body Battery answers "how much can I actually push today" — it carries over
/// day-to-day and refills slowly, unlike recovery which is a memoryless
/// single-night charge. (Why "92% recovery but I feel like shit" happens.)
struct BodyBatteryHero: View {
    let level: Double          // 0..100 — the tank
    let recovery: Double       // demoted to secondary
    let sleepHours: Double
    let strain: Double         // 0..21
    var hasNightData: Bool = true   // false = strap recorded no night; show "—", not 0
    var trend: [BodyBatteryPoint] = []   // 24h curve (server) — empty = hide chart
    var overlay: RecoveryOverlay = .neutral   // replaces the status chip when active

    private var lvl: Int { Int(level.rounded()) }
    private var color: Color { DS.Colors.bodyBatteryColor(level) }

    // The ONE interpretive slot on Today. 2–3 words — the bar + color + number
    // already encode the rest. RecoveryOverlay REPLACES this in-place when
    // active (illness/alcohol/red days); voices never stack.
    private var chipText: String {
        if overlay.shouldShow { return overlay.title }
        switch level {
        case 75...:    return "Full tank"
        case 55..<75:  return "Good charge"
        case 35..<55:  return "Half tank"
        case 20..<35:  return "Protect it"
        default:       return "On fumes"
        }
    }
    private var chipIcon: String {
        overlay.shouldShow ? overlay.icon : "bolt.fill"
    }
    private var chipColor: Color {
        overlay.shouldShow ? overlay.accent : color
    }
    private var stressLabel: String {
        if strain >= 14 { return "high" }
        if strain >= 7  { return "med" }
        return "low"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                Text("Body battery")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Colors.textFaint)
                Spacer()
                Text("in the tank")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.textFaint)
            }

            // Big number
            Text("\(lvl)")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.4), value: lvl)

            // Battery gauge
            BatteryBar(level: level, color: color)
                .frame(height: 30)

            // 24h curve — the smooth glide over the day (server-reconstructed)
            if trend.count >= 3 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Today")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.Colors.textFaint)
                        Spacer()
                        if let lo = trend.map(\.value).min(), let hi = trend.map(\.value).max() {
                            Text("\(Int(lo)) – \(Int(hi))")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DS.Colors.textFaint)
                        }
                    }
                    BodyBatteryTrend(points: trend, color: color)
                        .frame(height: 60)
                }
                .padding(.top, 2)
            }

            // ONE interpretive slot — chip, not sentence. Overlay swaps the
            // content in-place (never a second banner).
            HStack(spacing: 6) {
                Image(systemName: chipIcon)
                    .font(.system(size: 10, weight: .bold))
                Text(chipText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(chipColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(chipColor.opacity(0.12)))
            .overlay(Capsule().stroke(chipColor.opacity(0.28), lineWidth: 0.5))
            .animation(DS.Anim.quick, value: chipText)
            .accessibilityLabel("Status: \(chipText)")

            Divider().background(DS.Colors.border)

            // Secondary row — recovery DEMOTED here (still visible, not the
            // headline), with the live "vs your normal" percentile beside it.
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    secondaryStat("recovery", hasNightData ? "\(Int(recovery))" : "—",
                                  hasNightData ? DS.Colors.recoveryColor(recovery) : DS.Colors.textFaint)
                    if hasNightData && recovery > 0 {
                        PersonalPercentileChip(metric: "recovery_score", value: recovery)
                    }
                }
                .frame(maxWidth: .infinity)
                statDivider
                secondaryStat("sleep", hasNightData ? String(format: "%.1fh", sleepHours) : "—", DS.Colors.textSecondary)
                statDivider
                secondaryStat("stress", stressLabel, DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.lg)
        .heroCard()
    }

    @ViewBuilder
    private func secondaryStat(_ label: String, _ value: String, _ valueColor: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(valueColor)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(DS.Colors.textFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(DS.Colors.border)
            .frame(width: 0.5, height: 24)
    }
}

/// 24h body-battery curve — the smooth glide over the day. Area + line, faint hour ticks.
/// Endpoint equals the big number (same server formula), so the chart and the gauge agree.
private struct BodyBatteryTrend: View {
    let points: [BodyBatteryPoint]
    let color: Color

    private var maxY: Double {
        let hi = points.map(\.value).max() ?? 100
        return max(10, (ceil((hi + 4) / 10) * 10))   // round up to nearest 10 + headroom
    }

    var body: some View {
        Chart {
            ForEach(points) { pt in
                AreaMark(x: .value("time", pt.at), y: .value("battery", pt.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            ForEach(points) { pt in
                LineMark(x: .value("time", pt.at), y: .value("battery", pt.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(color)
            }
            if let last = points.last {
                PointMark(x: .value("time", last.at), y: .value("battery", last.value))
                    .symbolSize(34)
                    .foregroundStyle(color)
            }
        }
        .chartYScale(domain: 0...maxY)
        .chartYAxis {
            AxisMarks(values: [0, maxY]) { _ in
                AxisGridLine().foregroundStyle(DS.Colors.border.opacity(0.4))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                AxisGridLine().foregroundStyle(DS.Colors.border.opacity(0.25))
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colors.textFaint)
            }
        }
    }
}

/// Horizontal battery: rounded body + terminal nub, fill width = level, animated.
private struct BatteryBar: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let termW: CGFloat = 6
            let gap: CGFloat = 4
            let inset: CGFloat = 3
            let bodyW = w - termW - gap
            let fillMax = bodyW - inset * 2
            let pct = CGFloat(max(0.03, min(1, level / 100)))

            HStack(spacing: gap) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DS.Colors.surfaceElevated)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(DS.Colors.border, lineWidth: 1)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [color.opacity(0.82), color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, fillMax * pct), height: h - inset * 2)
                        .padding(.leading, inset)
                        .animation(.easeInOut(duration: 0.5), value: level)
                }
                .frame(width: bodyW, height: h)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(DS.Colors.border)
                    .frame(width: termW, height: h * 0.42)
            }
        }
    }
}
