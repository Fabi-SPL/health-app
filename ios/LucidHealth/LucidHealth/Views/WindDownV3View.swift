import SwiftUI

// MARK: - Wind-down on the approved V3 board (minerva/jobs/lh3-full, "Wind-down").
// The board's readiness percent, bpm-above-floor and descent chart have no stored source, so they are not drawn.
// The breathing ring takes the hero slot; the smart-wake plan takes the descent card's slot.

struct WindDownV3View: View {
    @ObservedObject var bleManager: BLEManager
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var showDrill = false

    private var isAlcohol: Bool { bleManager.tonightPlanMode == "alcohol" }
    private var accent: Color { isAlcohol ? V3.amber : V3.sleep }
    private var planNote: String {
        bleManager.tonightPlanNote.isEmpty
            ? "Lights low, screens away. Let your heart rate settle."
            : bleManager.tonightPlanNote
    }

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topRow
                ScrollView {
                    VStack(spacing: 0) {
                        breathingBlock
                        titleBlock
                        WindDownSmartWake(bleManager: bleManager).padding(.top, 18)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                footer
            }
            .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { appeared = true } }
        .fullScreenCover(isPresented: $showDrill) {
            CoherenceDrillView().environmentObject(bleManager)
        }
    }

    // MARK: Pieces

    private var topRow: some View {
        HStack(spacing: 8) {
            V3IconWell(symbol: "moon", color: V3.sleep)
            Text("Wind-down").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2)
            Spacer(minLength: 8)
            V3IconButton(symbol: "xmark", action: finish)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var breathingBlock: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 86400 : 1.0 / 30.0)) { context in
            let t: Double = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let cycle: Double = (sin(t * .pi / 4) + 1) / 2
            let inhaling: Bool = cos(t * .pi / 4) >= 0

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(V3.line, lineWidth: 1)
                        .frame(width: 236, height: 236)
                        .scaleEffect(CGFloat(0.80 + 0.20 * cycle))
                    ZStack {
                        V3Ring(progress: cycle, color: accent, lineWidth: 15)
                        Image(systemName: "moon.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(accent)
                            .scaleEffect(CGFloat(0.92 + 0.08 * cycle))
                    }
                    .frame(width: 172, height: 172)
                    .scaleEffect(CGFloat(0.92 + 0.08 * cycle))
                }
                .frame(height: 240)
                .background(alignment: .center) { V3Glow(color: accent) }

                Text(reduceMotion ? "Slow your breathing" : (inhaling ? "Breathe in" : "Breathe out"))
                    .font(V3Font.text(15, .semibold))
                    .foregroundStyle(V3.t1)
                    .contentTransition(.opacity)
                if bleManager.heartRate > 0 {
                    Text("Heart rate \(bleManager.heartRate) bpm")
                        .font(V3Font.text(12, .semibold))
                        .foregroundStyle(V3.t2)
                        .monospacedDigit()
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    private var titleBlock: some View {
        VStack(spacing: 0) {
            if isAlcohol { V3Pill(dot: V3.amber, text: "Alcohol mode").padding(.bottom, 10) }
            Text(isAlcohol ? "Recovery night" : "Time to wind down")
                .font(V3Font.text(26, .bold))
                .tracking(-0.78)
                .foregroundStyle(V3.t1)
            Text(planNote)
                .font(V3Font.text(14))
                .foregroundStyle(V3.t2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var drinkingBinding: Binding<Bool> {
        Binding<Bool>(
            get: { bleManager.tonightPlanMode == "alcohol" },
            set: { isOn in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    _ = await bleManager.supabase.setDrinkingTonight(isOn)
                    await bleManager.syncTonightPlan()
                }
            }
        )
    }

    private var drinkingCard: some View {
        V3Card(padding: 14) {
            HStack(spacing: 14) {
                V3IconWell(symbol: "wineglass", color: V3.kcal, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drinking tonight").font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                    Text("Tells recovery to expect it").font(V3Font.text(12)).foregroundStyle(V3.t2)
                }
                Spacer(minLength: 8)
                V3Toggle(isOn: drinkingBinding)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            drinkingCard
            V3Button(title: "Breathe", symbol: "wind") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showDrill = true
            }
            Text("Coherence drill with live heart rate variability.")
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
            V3Button(title: isAlcohol ? "Got it, goodnight" : "I'm winding down", secondary: true, action: finish)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func finish() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onDismiss()
    }
}

// MARK: - Smart wake (arms the server-side engine, shows the plan once armed)

private struct WindDownSmartWake: View {
    @ObservedObject var bleManager: BLEManager

    @State private var useDeadline = false
    @State private var deadline: Date =
        Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var busy = false
    @AppStorage("lucid_backup_nudge_date") private var backupNudgeDate: String = ""

    private var armed: Bool { bleManager.smartWakeArmed }
    private var status: SmartWakeStatus? { bleManager.smartWakeStatus }
    private var plan: SmartWakePlan? { bleManager.smartWakePlan }
    private var targetH: Double? { plan?.targetH ?? status?.targetH }

    private var backupNudgeSeenToday: Bool { backupNudgeDate == Self.dayStamp() }
    private static func dayStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var floorFromStatus: Double? {
        guard let asleep = status?.asleepH, let inMin = status?.earliestInMin else { return nil }
        return asleep + Double(inMin) / 60.0
    }

    private var armedNote: String? {
        if let s = status?.note, !s.isEmpty, status?.armed == true { return s }
        return plan?.note
    }

    var body: some View {
        V3Card {
            if armed { armedView } else { idleView }
        }
        .task { await bleManager.refreshSmartWakeStatus() }
    }

    // MARK: Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            V3CardHeader(icon: "sunrise.fill", iconColor: V3.sleep, title: "Smart wake")
                .padding(.bottom, -4)
            Text("Finds a light-sleep moment to wake you, after your sleep floor.")
                .font(V3Font.text(13)).foregroundStyle(V3.t2)
                .fixedSize(horizontal: false, vertical: true)
            V3Button(title: busy ? "Arming" : "Wake me at the perfect time", symbol: "sunrise.fill") { arm() }
                .disabled(busy)
            HStack {
                Text("Set a hard \u{201C}up by\u{201D} time").font(V3Font.text(14, .semibold)).foregroundStyle(V3.t1)
                Spacer(minLength: 8)
                V3Toggle(isOn: $useDeadline)
            }
            if useDeadline {
                DatePicker("", selection: $deadline, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(V3.sleep)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("I'll aim to wake you before this. If it's sooner than your sleep floor, I'll tell you to set a normal alarm too.")
                    .font(V3Font.text(12)).foregroundStyle(V3.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Armed

    private var armedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            V3CardHeader(icon: "sunrise.fill", iconColor: V3.sleep, title: "Smart wake armed",
                         trailing: status?.strapStreaming == true ? "Live" : nil)
                .padding(.bottom, -4)

            armedChart

            if let backstop = status?.backstopLabel, !backstop.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "alarm.waves.left.and.right.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(V3.amber)
                    Text("Hard wake \(backstop), the latest I'll let you sleep.")
                        .font(V3Font.text(13, .semibold)).foregroundStyle(V3.t1)
                }
            }

            if let note = armedNote, !note.isEmpty {
                Text(note)
                    .font(V3Font.text(13)).foregroundStyle(V3.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan?.deadlineBelowFloor == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(V3.amber)
                    Text("Your \u{201C}up by\u{201D} time is earlier than your sleep floor. Set a normal alarm too, just in case.")
                        .font(V3Font.text(12, .semibold)).foregroundStyle(V3.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !backupNudgeSeenToday {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "alarm").font(.system(size: 12)).foregroundStyle(V3.t2)
                    Text("Keep a normal alarm as a backup.")
                        .font(V3Font.text(12, .semibold)).foregroundStyle(V3.t2)
                }
                .onAppear { backupNudgeDate = Self.dayStamp() }
            }

            V3Button(title: busy ? "Cancelling" : "Cancel smart wake", secondary: true) { cancel() }
                .disabled(busy)
        }
    }

    @ViewBuilder
    private var armedChart: some View {
        if let t = targetH, let f = plan?.safetyFloorH ?? floorFromStatus {
            WindDownNightBar(
                targetH: t,
                floorH: f,
                asleepH: status?.asleepH,
                floorLabel: status?.earliestWakeLabel,
                targetLabel: status?.targetWakeLabel,
                accent: V3.sleep
            )
        } else if let win = status?.projectedWindow {
            V3LegendItem(label: "Window", value: win)
        } else if let inMin = status?.earliestInMin, inMin > 0 {
            V3LegendItem(label: "Earliest in", value: "\(inMin) m")
        }
    }

    // MARK: Actions

    private func arm() {
        guard !busy else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let target: Date? = useDeadline ? nextOccurrence(of: deadline) : nil
        Task {
            _ = await bleManager.armSmartWake(latestWake: target)
            await MainActor.run { busy = false }
        }
    }

    private func nextOccurrence(of picked: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: picked)
        return cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) ?? picked
    }

    private func cancel() {
        guard !busy else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await bleManager.cancelSmartWake()
            await MainActor.run { busy = false }
        }
    }
}

// MARK: - Night bar (hours since onset: floor to target window, ticks, now dot)

private struct WindDownNightBar: View {
    let targetH: Double
    let floorH: Double
    var asleepH: Double? = nil
    var floorLabel: String? = nil
    var targetLabel: String? = nil
    var accent: Color = V3.sleep

    private var domain: Double { max(targetH, floorH, asleepH ?? 0) + 0.4 }
    private func x(_ h: Double, _ w: CGFloat) -> CGFloat {
        w * CGFloat(max(0, min(1, h / domain)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let w: CGFloat = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(V3.track).frame(height: 8)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(accent.opacity(0.5))
                        .frame(width: max(6, x(targetH, w) - x(floorH, w)), height: 8)
                        .offset(x: x(floorH, w))

                    Image(systemName: "moon.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(V3.t3)
                        .offset(x: -2, y: -14)

                    tick(at: x(floorH, w), color: V3.amber)
                    tick(at: x(targetH, w), color: accent)

                    if let now = asleepH, now > 0 {
                        Circle()
                            .fill(V3.energy)
                            .frame(width: 9, height: 9)
                            .offset(x: max(0, x(now, w) - 4.5))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 26)
            .padding(.top, 12)

            HStack {
                barLabel("Floor", floorLabel ?? String(format: "%.1fh", floorH), V3.amber)
                Spacer()
                if let now = asleepH, now > 0 {
                    barLabel("Asleep", String(format: "%.1fh", now), V3.energy)
                    Spacer()
                }
                barLabel("Target", targetLabel ?? String(format: "%.1fh", targetH), accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wake window from \(floorLabel ?? String(format: "%.1f hours", floorH)) to \(targetLabel ?? String(format: "%.1f hours", targetH)) of sleep")
    }

    private func tick(at xPos: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color)
            .frame(width: 3, height: 16)
            .offset(x: max(0, xPos - 1.5))
    }

    private func barLabel(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(V3Font.text(11)).foregroundStyle(V3.t2)
            Text(value).font(V3Font.num(12, .semibold)).foregroundStyle(color)
        }
    }
}
