import WidgetKit
import SwiftUI
import AppIntents

struct HealthDataProvider: TimelineProvider {
    func placeholder(in context: Context) -> HealthDataEntry {
        HealthDataEntry(date: Date(), data: SharedHealthData())
    }

    func getSnapshot(in context: Context, completion: @escaping (HealthDataEntry) -> Void) {
        completion(HealthDataEntry(date: Date(), data: SharedHealthData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthDataEntry>) -> Void) {
        // 2026-04-27 — tightened from 12×1min to 3×5min after research.
        // iOS rate-limits widget reloads to ~40-70/day across the whole
        // bundle. The 12-entry timeline burned budget on entries iOS rarely
        // displayed. 3 entries × 5 min covers a 15-min horizon — wide enough
        // that iOS doesn't immediately re-poll, narrow enough that the
        // displayed snapshot is never more than 15 min stale when budget is
        // available. .atEnd policy lets iOS opportunistically refresh
        // sooner if the user opens / unlocks the device.
        let now = Date()
        let snapshot = SharedHealthData.load()
        // Diagnostic — lands in Console.app when device plugged into Mac.
        // Filter for "LucidWidget" to confirm what the widget process is
        // actually reading. If values are zero AND save/load logged a
        // "sharedURL nil" message, the App Group entitlement was stripped
        // by AltStore re-sign — see SharedHealthData.swift comment.
        LucidLog.log("LucidWidget", "getTimeline rec=\(snapshot.recoveryScore) bb=\(snapshot.bodyBattery) hr=\(snapshot.heartRate) updated=\(snapshot.lastUpdated)")
        let entries: [HealthDataEntry] = [
            HealthDataEntry(date: now, data: snapshot),
            HealthDataEntry(date: now.addingTimeInterval(5 * 60), data: snapshot),
            HealthDataEntry(date: now.addingTimeInterval(10 * 60), data: snapshot),
        ]
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct HealthDataEntry: TimelineEntry {
    let date: Date
    let data: SharedHealthData
}

private enum WidgetPalette {
    static let violet = Color(red: 0.545, green: 0.486, blue: 0.965)
    static let teal = Color(red: 0.310, green: 0.820, blue: 0.773)
    static let green = Color(red: 0.063, green: 0.725, blue: 0.506)
    static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let red = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let bgTop = Color(red: 0.08, green: 0.07, blue: 0.15)
    static let bgBottom = Color(red: 0.03, green: 0.03, blue: 0.06)
}

private func recoveryColor(_ score: Double) -> Color {
    if score >= 67 { return WidgetPalette.green }
    if score >= 34 { return WidgetPalette.amber }
    return WidgetPalette.red
}

private func batteryColor(_ value: Double) -> Color {
    if value >= 60 { return WidgetPalette.green }
    if value >= 30 { return WidgetPalette.amber }
    return WidgetPalette.red
}

private func strainColor(_ value: Double) -> Color {
    if value < 8 { return WidgetPalette.teal }
    if value < 14 { return WidgetPalette.amber }
    return WidgetPalette.red
}

private func readinessColor(_ value: String) -> Color {
    switch value {
    case "green": return WidgetPalette.green
    case "yellow": return WidgetPalette.amber
    case "red": return WidgetPalette.red
    default: return Color.secondary
    }
}

private func recoveryLabel(_ score: Double) -> String {
    if score >= 67 { return "Push window" }
    if score >= 34 { return "Steady state" }
    return "Protect day"
}

private func energyEmoji(_ data: SharedHealthData) -> String {
    if data.sleepDetected { return "🌙" }
    if data.illnessAlert != nil { return "🛟" }
    if data.recoveryScore >= 67 { return "⚡" }
    if data.recoveryScore >= 34 { return "🎯" }
    return "🫧"
}

private func coachLine(_ data: SharedHealthData) -> String {
    if data.sleepDetected {
        return "Sleep still looks active."
    }
    if data.illnessAlert != nil {
        return "Recovery first today."
    }
    if data.recoveryScore >= 67 && data.readiness == "green" {
        return "Good day to push."
    }
    if data.recoveryScore >= 34 {
        return "Stay narrow and steady."
    }
    return "Keep the day gentle."
}

private func modeLabel(_ data: SharedHealthData) -> String {
    if data.activeActivityType != nil {
        return "Experiment"
    }

    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<9: return "Morning"
    case 9..<18: return "Work"
    case 18..<21: return "Evening"
    default: return "Night"
    }
}

private func nextMoveLine(_ data: SharedHealthData) -> String {
    if data.illnessAlert != nil { return "Recovery first" }
    if data.sleepDetected { return "Sleep still active" }
    if data.activeActivityType != nil {
        let name = data.activeActivityType?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Session"
        return "\(name) live"
    }

    let hour = Calendar.current.component(.hour, from: Date())
    let push = data.recoveryScore >= 67 && data.readiness == "green"

    switch hour {
    case 5..<9:
        return push ? "Read body, pick one" : "Start simple, stay quiet"
    case 9..<18:
        return push ? "Depth time — go deep" : "Stay narrow, avoid scatter"
    case 18..<21:
        return "Reflect and close out"
    default:
        return "Reduce stimulation"
    }
}

private func readinessWord(_ data: SharedHealthData) -> String {
    if data.illnessAlert != nil { return "PROTECT" }
    switch data.readiness.lowercased() {
    case "green": return "READY"
    case "yellow": return "STEADY"
    case "red": return "PROTECT"
    // Fallback used to be "LIVE" — collided with the "BRIDGE LIVE/OFFLINE"
    // pill on the same row, producing the visually contradictory render
    // "BRIDGE OFFLINE   LIVE". Em-dash is unambiguous as "no data yet".
    default: return "—"
    }
}

private func backgroundGradient(accent: Color) -> some View {
    LinearGradient(
        colors: [WidgetPalette.bgTop, WidgetPalette.bgBottom, accent.opacity(0.18)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private struct WidgetTag: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct WidgetRing: View {
    let value: Double
    let maxValue: Double
    let color: Color
    let label: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0, min(value / maxValue, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(Int(value))")
                    .font(.system(size: size * 0.24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: size * 0.08, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .tracking(0.8)
            }
        }
        .frame(width: size, height: size)
    }
}

struct SmallWidgetView: View {
    let entry: HealthDataEntry

    var body: some View {
        let accent = recoveryColor(entry.data.recoveryScore)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(energyEmoji(entry.data)) Health")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(coachLine(entry.data))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer()
                Circle()
                    .fill(entry.data.isConnected ? WidgetPalette.green : WidgetPalette.red)
                    .frame(width: 10, height: 10)
            }

            HStack(spacing: 12) {
                WidgetRing(
                    value: entry.data.recoveryScore,
                    maxValue: 100,
                    color: accent,
                    label: "REC",
                    size: 76
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(recoveryLabel(entry.data.recoveryScore))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)

                    WidgetTag(icon: "battery.75", text: "\(Int(entry.data.bodyBattery))%", color: batteryColor(entry.data.bodyBattery))

                    if entry.data.heartRate > 0 {
                        WidgetTag(icon: "heart.fill", text: "\(entry.data.heartRate) bpm", color: WidgetPalette.red)
                    } else {
                        WidgetTag(icon: entry.data.isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash", text: entry.data.isConnected ? "Live" : "Offline", color: entry.data.isConnected ? WidgetPalette.green : WidgetPalette.red)
                    }
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            backgroundGradient(accent: accent)
        }
    }
}

struct MediumWidgetView: View {
    let entry: HealthDataEntry

    var body: some View {
        let accent = recoveryColor(entry.data.recoveryScore)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(energyEmoji(entry.data)) \(coachLine(entry.data))")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(modeLabel(entry.data)) canvas")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Spacer()
                WidgetTag(icon: "brain.head.profile", text: entry.data.readiness.capitalized, color: readinessColor(entry.data.readiness))
            }

            HStack(spacing: 14) {
                WidgetRing(
                    value: entry.data.recoveryScore,
                    maxValue: 100,
                    color: accent,
                    label: "REC",
                    size: 72
                )

                VStack(alignment: .leading, spacing: 8) {
                    widgetRow(icon: "battery.75", label: "Battery", value: "\(Int(entry.data.bodyBattery))%", color: batteryColor(entry.data.bodyBattery))
                    widgetRow(icon: "moon.fill", label: "Sleep", value: "\(Int(entry.data.sleepScore))", color: recoveryColor(entry.data.sleepScore))
                    widgetRow(icon: "flame.fill", label: "Strain", value: String(format: "%.1f", entry.data.strainScore), color: strainColor(entry.data.strainScore))
                    if entry.data.currentRMSSD > 0 {
                        widgetRow(icon: "waveform.path.ecg", label: "HRV", value: "\(Int(entry.data.currentRMSSD)) ms", color: readinessColor(entry.data.readiness))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shape")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))

                    HStack(alignment: .bottom, spacing: 6) {
                        miniBar(height: CGFloat(max(12, entry.data.recoveryScore * 0.38)), color: accent)
                        miniBar(height: CGFloat(max(12, entry.data.bodyBattery * 0.38)), color: batteryColor(entry.data.bodyBattery))
                        miniBar(height: CGFloat(max(12, entry.data.sleepScore * 0.38)), color: recoveryColor(entry.data.sleepScore))
                        miniBar(height: CGFloat(max(12, entry.data.strainScore / 21 * 42)), color: strainColor(entry.data.strainScore))
                    }
                    .frame(height: 44, alignment: .bottom)

                    if let activity = entry.data.activeActivityType {
                        WidgetTag(icon: "sparkles", text: activity.replacingOccurrences(of: "_", with: " ").capitalized, color: WidgetPalette.violet)
                    } else {
                        WidgetTag(icon: entry.data.isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash", text: entry.data.isConnected ? "Bridge live" : "Bridge quiet", color: entry.data.isConnected ? WidgetPalette.green : WidgetPalette.red)
                    }
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            backgroundGradient(accent: accent)
        }
    }

    private func widgetRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private func miniBar(height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(width: 12, height: height)
    }
}

// MARK: - Lock Screen: Capacity Ring (circular)

struct CapacityRingView: View {
    let entry: HealthDataEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 4)
                .padding(3)
            Circle()
                .trim(from: 0, to: max(0, min(entry.data.recoveryScore / 100, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            VStack(spacing: 0) {
                Text("\(Int(entry.data.recoveryScore))")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                Text("CAP")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Lock Screen: Next Move chip (inline)

struct NextMoveChipView: View {
    let entry: HealthDataEntry

    var body: some View {
        Text("\(energyEmoji(entry.data)) \(modeLabel(entry.data)) · \(nextMoveLine(entry.data))")
            .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Lock Screen: Readiness Word (inline)

struct ReadinessWordView: View {
    let entry: HealthDataEntry

    var body: some View {
        Text("\(energyEmoji(entry.data)) \(readinessWord(entry.data)) · cap \(Int(entry.data.recoveryScore))")
            .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Lock Screen: Live HR · HRV · Strain (rectangular)

struct LiveMetricsView: View {
    let entry: HealthDataEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: entry.data.isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text(entry.data.isConnected ? "BRIDGE LIVE" : "BRIDGE OFFLINE")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
                Spacer()
                Text(readinessWord(entry.data))
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                metric(icon: "heart.fill", value: entry.data.heartRate > 0 ? "\(entry.data.heartRate)" : "—", label: "BPM")
                metric(icon: "waveform.path.ecg", value: entry.data.currentRMSSD > 0 ? "\(Int(entry.data.currentRMSSD))" : "—", label: "HRV")
                metric(icon: "flame.fill", value: String(format: "%.1f", entry.data.strainScore), label: "STR")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private func metric(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
                Text(label)
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
    }
}

struct LucidSmallWidget: Widget {
    let kind = "LucidSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            SmallWidgetView(entry: entry)
        }
        .configurationDisplayName("Recovery")
        .description("Strong-glance recovery, battery, and live bridge state.")
        .supportedFamilies([.systemSmall])
    }
}

struct LucidMediumWidget: Widget {
    let kind = "LucidMediumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            MediumWidgetView(entry: entry)
        }
        .configurationDisplayName("Canvas")
        .description("A one-glance body canvas for recovery, load, and focus state.")
        .supportedFamilies([.systemMedium])
    }
}

struct LucidCapacityRingWidget: Widget {
    let kind = "LucidCapacityRingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            CapacityRingView(entry: entry)
        }
        .configurationDisplayName("Capacity Ring")
        .description("Recovery score at a glance — can you push?")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LucidNextMoveWidget: Widget {
    let kind = "LucidNextMoveWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            NextMoveChipView(entry: entry)
        }
        .configurationDisplayName("Next Move")
        .description("Chapter-aware one-line nudge on the lock screen.")
        .supportedFamilies([.accessoryInline])
    }
}

struct LucidReadinessWordWidget: Widget {
    let kind = "LucidReadinessWordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            ReadinessWordView(entry: entry)
        }
        .configurationDisplayName("Readiness Word")
        .description("One word: READY, STEADY, or PROTECT.")
        .supportedFamilies([.accessoryInline])
    }
}

struct LucidLiveMetricsWidget: Widget {
    let kind = "LucidLiveMetricsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            LiveMetricsView(entry: entry)
        }
        .configurationDisplayName("Live HR · HRV · Strain")
        .description("Three live physiology metrics while the bridge streams.")
        .supportedFamilies([.accessoryRectangular])
    }
}

// ════════════════════════════════════════════════════════════
// NEW (2026-04-25) — DayState awareness, Body Battery, Live HR,
// Bridge control. Combines Apr 15 brainstorm gaps + today's research.
// ════════════════════════════════════════════════════════════

private func dayStateIcon(_ state: String) -> String {
    switch state {
    case "hangover":  return "drop.triangle.fill"
    case "sick":      return "cross.circle.fill"
    case "soft":      return "leaf.fill"
    case "sleepDebt": return "moon.zzz.fill"
    case "push":      return "flame.fill"
    case "wired":     return "bolt.heart.fill"
    default:          return "circle.dashed"
    }
}

private func dayStateLabel(_ state: String) -> String {
    switch state {
    case "hangover":  return "Hangover"
    case "sick":      return "Sick day"
    case "soft":      return "Soft day"
    case "sleepDebt": return "Sleep debt"
    case "push":      return "Push day"
    case "wired":     return "Wired"
    default:          return "Normal"
    }
}

private func dayStateColor(_ state: String) -> Color {
    switch state {
    case "hangover":  return WidgetPalette.violet
    case "sick":      return WidgetPalette.red
    case "soft":      return WidgetPalette.green
    case "sleepDebt": return WidgetPalette.amber
    case "push":      return WidgetPalette.green
    case "wired":     return WidgetPalette.red
    default:          return Color.secondary
    }
}

private func batteryStateLabel(_ value: Double) -> String {
    if value >= 75 { return "Reserve looks healthy" }
    if value >= 45 { return "Spend it carefully" }
    if value >= 20 { return "Protect capacity" }
    return "Reset needed"
}

// MARK: - Lock Screen: DayState Face (rectangular)

/// Rectangular lock-screen widget combining DayState awareness with the
/// recovery score gauge and a one-line coach nudge. The brainstorm flagged
/// "AppMode dedicated widget" as a gap — this generalizes that to DayState
/// since DayState now drives the whole app's layout.
struct DayStateFaceView: View {
    let entry: HealthDataEntry

    var body: some View {
        let rec = entry.data.recoveryScore
        let state = entry.data.dayState

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: dayStateIcon(state))
                    .font(.system(size: 9, weight: .semibold))
                Text(dayStateLabel(state).uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                Spacer()
                Text(readinessWord(entry.data))
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ProgressView(value: rec / 100.0)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                Text("\(Int(rec))")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }

            Text(coachLine(entry.data))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct LucidDayStateFaceWidget: Widget {
    let kind = "LucidDayStateFaceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            DayStateFaceView(entry: entry)
        }
        .configurationDisplayName("Day Face")
        .description("DayState + recovery gauge + coach nudge.")
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - Home Screen: Body Battery (systemSmall)

/// Dedicated body-battery home-screen widget. Apr 15 brainstorm proposed this
/// but it was never built — body battery only ever appeared as a sub-element.
/// This gives it the real estate it deserves: huge percentage, state label,
/// recovery context.
struct BodyBatteryView: View {
    let entry: HealthDataEntry

    var body: some View {
        let bb = entry.data.bodyBattery
        let color = batteryColor(bb)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "battery.75")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("BODY BATTERY")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Circle()
                    .fill(entry.data.isConnected ? WidgetPalette.green : WidgetPalette.red)
                    .frame(width: 8, height: 8)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(bb))")
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(color.opacity(0.7))
            }

            Text(batteryStateLabel(bb))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            HStack(spacing: 6) {
                Text("REC")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.55))
                Text("\(Int(entry.data.recoveryScore))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(recoveryColor(entry.data.recoveryScore))
                if entry.data.dayState != "normal" {
                    Text("·")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(dayStateLabel(entry.data.dayState).uppercased())
                        .font(.system(size: 8, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(dayStateColor(entry.data.dayState))
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            backgroundGradient(accent: color)
        }
    }
}

struct LucidBodyBatteryWidget: Widget {
    let kind = "LucidBodyBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            BodyBatteryView(entry: entry)
        }
        .configurationDisplayName("Body Battery")
        .description("Body battery percentage with recovery + day state context.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Lock Screen: Live HR Gauge (circular)

/// Live HR ring on the lock screen — complements the static recovery
/// CapacityRing widget. While Capacity Ring is "what's your reserve today,"
/// this is "what's your pulse RIGHT NOW." Useful during exercise, useful as
/// a quick "is the bridge alive" check.
struct LiveHRGaugeView: View {
    let entry: HealthDataEntry

    var body: some View {
        let hr = entry.data.heartRate
        let zone = entry.data.currentHRZone
        let displayHR = hr > 0 ? hr : 0
        let progress = max(0, min(Double(displayHR) / 180.0, 1.0))

        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 4)
                .padding(3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            VStack(spacing: 0) {
                Text(hr > 0 ? "\(hr)" : "—")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                Text(zone > 0 ? "Z\(zone)" : "BPM")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct LucidLiveHRWidget: Widget {
    let kind = "LucidLiveHRWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthDataProvider()) { entry in
            LiveHRGaugeView(entry: entry)
        }
        .configurationDisplayName("Live HR")
        .description("Live heart rate ring with zone.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Control Center: Bridge Open (iOS 18+)

/// Control Center / Lock Screen / Action Button widget. Tapping it opens the
/// Bridge app directly to the Bridge (Console) tab so Fabi can check
/// connection state with one tap. Not a true reconnect toggle (BLE start/stop
/// from a Control intent has background/entitlement constraints) — but the
/// Action Button assignment is the killer use.
@available(iOS 18.0, *)
struct LucidBridgeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LucidBridgeControl") {
            ControlWidgetButton(action: OpenBridgeIntent()) {
                Label("Bridge", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .displayName("Bridge")
        .description("One-tap open Bridge — assign to Action Button or Control Center.")
    }
}

@available(iOS 18.0, *)
struct OpenBridgeIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Bridge"
    static var description = IntentDescription("Opens the Bridge app to the connection page.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
