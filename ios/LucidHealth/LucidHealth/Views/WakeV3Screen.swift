import SwiftUI

// MARK: - Wake screen on the approved V3 board (minerva/jobs/lh3-full, "Wake").
// Real numbers only. No wake score exists in the app, so that ring is drawn the board's empty way.

struct WakeV3Screen: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject private var store = BoardStore.shared
    let fireDate: Date?
    let onClose: () -> Void
    @State private var liveSegments: [StageSegment] = []

    private var engine: HealthEngine { bleManager.healthEngine }
    private var night: BoardNight { store.night }

    private var segments: [StageSegment] { liveSegments.isEmpty ? store.stages : liveSegments }
    private var wakeTime: Date? { fireDate ?? night.end }

    private var wakeStage: String? {
        guard let t = wakeTime else { return nil }
        return StageSegment.stage(at: t, in: segments)
    }

    private var reason: String {
        guard let stage = wakeStage else { return "Your smart alarm went off." }
        switch stage {
        case "light": return "You were in light sleep, so this is a good moment to get up."
        case "rem": return "You were in REM, close to the surface, so this is a good moment to get up."
        case "awake": return "You were already stirring, so this is a good moment to get up."
        default: return "The alarm reached its latest time, so it woke you from deep sleep."
        }
    }

    private var stageChip: (text: String, color: Color)? {
        guard let stage = wakeStage else { return nil }
        switch stage {
        case "light": return ("Light sleep", V3.green)
        case "rem": return ("REM", V3.green)
        case "awake": return ("Awake", V3.green)
        default: return ("Deep sleep", V3.amber)
        }
    }

    private var greeting: String {
        guard let t = wakeTime else { return "Good morning" }
        let h: Int = Calendar.current.component(.hour, from: t)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
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

    // MARK: Alarm window (server labels from the smart-wake status)

    private static func hours(_ label: String) -> Double? {
        let parts: [Substring] = label.split(separator: ":")
        guard parts.count == 2, let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
        return h + m / 60
    }

    private var alarmWindow: WakeWindow? {
        guard let st = bleManager.smartWakeStatus,
              let floorLabel = st.earliestWakeLabel, let targetLabel = st.targetWakeLabel,
              let floorHour = Self.hours(floorLabel), let targetHour = Self.hours(targetLabel),
              targetHour > floorHour else { return nil }
        return WakeWindow(floorHour: floorHour, targetHour: targetHour, floorLabel: floorLabel, targetLabel: targetLabel)
    }

    private var fireHour: Double? {
        guard let f = fireDate else { return nil }
        return V3Format.hourOfDay(f, relativeTo: f)
    }

    private var windowCaption: String? {
        var parts: [String] = []
        if let w = alarmWindow { parts.append("target \(w.targetLabel)") }
        if let f = fireDate { parts.append("fired \(V3Format.hhmm(f))") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Body

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        topRow
                        clockBlock
                        heroBlock
                        windowCard
                        recoveryCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                footer
            }
        }
        .task {
            await store.refresh()
            if let s = engine.sleepStartTime, let f = fireDate, f > s {
                liveSegments = StageSegment.build(from: await SupabaseClient.shared.fetchSleepStages(start: s, end: f))
            }
        }
        .lucidRendered(.wake)
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            V3IconWell(symbol: "alarm", color: V3.amber)
            Text("Smart alarm").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2)
            Spacer(minLength: 8)
            if let chip = stageChip { WakeChip(text: chip.text, color: chip.color) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }

    private var clockBlock: some View {
        VStack(spacing: 0) {
            Text(wakeTime.map(V3Format.hhmm) ?? "Syncing")
                .font(V3Font.num(wakeTime == nil ? 40 : 72))
                .tracking(wakeTime == nil ? 0 : -3.6)
                .foregroundStyle(wakeTime == nil ? V3.t2 : V3.t1)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(greeting)
                .font(V3Font.text(17, .semibold))
                .foregroundStyle(V3.t1)
                .padding(.top, 8)
            Text(reason)
                .font(V3Font.text(14))
                .foregroundStyle(V3.t2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.horizontal, 12)
            if bleManager.heartRate > 0 {
                V3Pill(dot: V3.heart, text: "\(bleManager.heartRate) bpm").padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var heroBlock: some View {
        WakeScoreRing()
            .background(alignment: .center) { V3Glow(color: V3.sleep) }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.bottom, 4)
    }

    private var windowCard: some View {
        V3Card {
            V3CardHeader(title: "Alarm window", trailing: windowCaption)
            if let w = alarmWindow {
                WakeRangeStrip(
                    lo: min(w.floorHour, fireHour ?? w.floorHour) - 0.25,
                    hi: max(w.targetHour, fireHour ?? w.targetHour) + 0.25,
                    band: (w.floorHour, w.targetHour),
                    value: fireHour,
                    color: V3.amber,
                    ticks: [WakeTick(at: w.floorHour, label: w.floorLabel), WakeTick(at: w.targetHour, label: w.targetLabel)]
                )
            } else {
                V3EmptyLine(text: "No window recorded")
            }
        }
        .padding(.top, 16)
    }

    private var recoveryCard: some View {
        V3Card {
            HStack(spacing: 14) {
                ZStack {
                    if let r = recovery {
                        V3Ring(progress: r / 100, color: V3.recovery(r), lineWidth: 6)
                        Text("\(Int(r.rounded()))").font(V3Font.num(17))
                            .foregroundStyle(V3.t1)
                    } else {
                        V3Ring(progress: 0, color: V3.t3, lineWidth: 6, dashed: true)
                    }
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recovery").font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
                    Text(recovery.map { V3.recoveryWord($0) } ?? "Syncing")
                        .font(V3Font.text(20, .bold)).tracking(-0.6)
                        .foregroundStyle(recovery.map { V3.recovery($0) } ?? V3.t2)
                    Text(sleepHours.map { "Slept \(V3Format.duration(hours: $0))" } ?? "Sleep syncing")
                        .font(V3Font.text(13)).foregroundStyle(V3.t2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 10)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            V3Button(title: "Stop alarm") {
                bleManager.stopAlarmIfRinging(reason: "wake_screen")
                onClose()
            }
            V3Button(title: "Close", secondary: true, action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Private pieces

private struct WakeWindow {
    let floorHour: Double
    let targetHour: Double
    let floorLabel: String
    let targetLabel: String
}

private struct WakeTick {
    let at: Double
    let label: String
}

private struct WakeChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(V3Font.text(12, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct WakeScoreRing: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                V3Ring(progress: 0, color: V3.sleep, lineWidth: 15, dashed: true)
                Text("No data").font(V3Font.text(24, .semibold)).foregroundStyle(V3.t3)
            }
            .frame(width: 172, height: 172)
            Text("Wake score").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1).padding(.top, 10)
            Text("Not scored yet").font(V3Font.text(12, .semibold)).foregroundStyle(V3.t2).padding(.top, 2)
        }
        .fixedSize()
    }
}

private struct WakeRangeStrip: View {
    let lo: Double
    let hi: Double
    let band: (Double, Double)
    let value: Double?
    let color: Color
    let ticks: [WakeTick]

    private func x(_ v: Double, _ w: CGFloat) -> CGFloat {
        let span: Double = max(hi - lo, 0.0001)
        let f: Double = min(max((v - lo) / span, 0), 1)
        return 8 + CGFloat(f) * (w - 16)
    }

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let x0: CGFloat = x(band.0, w)
            let x1: CGFloat = x(band.1, w)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(V3.track).frame(width: w, height: 2).position(x: w / 2, y: 14)
                Capsule().fill(color.opacity(0.16))
                    .frame(width: max(12, x1 - x0), height: 12)
                    .position(x: x0 + max(12, x1 - x0) / 2, y: 14)
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                    Text(t.label).font(V3Font.text(11)).foregroundStyle(V3.t2).monospacedDigit()
                        .fixedSize()
                        .position(x: min(max(x(t.at, w), 18), w - 18), y: 41)
                }
                if let v = value {
                    Circle().fill(color)
                        .overlay(Circle().stroke(V3.card, lineWidth: 2.5))
                        .frame(width: 14, height: 14)
                        .position(x: x(v, w), y: 14)
                }
            }
        }
        .frame(height: 50)
    }
}
