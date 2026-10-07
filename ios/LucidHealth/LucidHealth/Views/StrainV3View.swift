import SwiftUI

// Strain tab (V3 board: Rings and River); the day model lives in StrainDayModel.swift.

struct StrainV3View: View {
    @EnvironmentObject private var bleManager: BLEManager
    @StateObject private var model = StrainDayModel()
    @AppStorage("strainView") private var mode: String = "Rings"
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var nameTarget: StrainDayBlock? = nil
    @State private var blockTarget: StrainDayBlock? = nil
    @State private var autoOpened = false
    @State private var liveSession: SupabaseClient.WorkoutSession? = nil
    @State private var openSession: SupabaseClient.WorkoutSession? = nil
    @State private var workoutNote: String? = nil
    @State private var starting = false
    @Environment(\.scenePhase) private var scenePhase

    private static let modes: [String] = ["Rings", "River"]

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    V3Header(date: "Your day", title: "Strain") { dayStepper }
                    V3Segmented(options: Self.modes, selection: $mode)
                        .padding(.bottom, 4)
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }
            .sheet(item: $blockTarget) { (b: StrainDayBlock) in
                if let d = model.data {
                    StrainBlockV3Sheet(block: b, day: d, onChanged: { Task { await reload() } })
                        .environmentObject(bleManager)
                }
            }
        }
        .task(id: selectedDay) {
            await model.load(day: selectedDay, engine: bleManager.healthEngine)
            autoOpenBlock()
        }
        .onChange(of: model.data?.topBlock?.id) { _, _ in autoOpenBlock() }
        .task { await refreshWorkouts() }
        .onAppear {
            if LucidScreen.current == .strainRiver {
                mode = "River"
            } else if LucidScreen.current == .strain {
                mode = "Rings"
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && Calendar.current.isDateInToday(selectedDay) {
                Task { await reload() }
            }
        }
        .sheet(item: $nameTarget) { (b: StrainDayBlock) in
            ActivityEditSheet(
                mode: .create(defaultStart: b.start),
                ble: bleManager,
                onSaved: { Task { await reload() } },
                onDeleted: {}
            )
        }
        .fullScreenCover(item: $liveSession, onDismiss: { Task { await refreshWorkouts() } }) { (s: SupabaseClient.WorkoutSession) in
            LiveRideV3View(session: s) { liveSession = nil }
                .environmentObject(bleManager)
        }
        .lucidRendered(.strain, .strainRiver)
    }

    // MARK: Loading

    private func autoOpenBlock() {
        guard LucidScreen.current == .blockDetail, !autoOpened, let top = model.data?.topBlock else { return }
        autoOpened = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            blockTarget = top
        }
    }

    private func reload() async {
        await model.load(day: selectedDay, engine: bleManager.healthEngine)
        await refreshWorkouts()
    }

    private func refreshWorkouts() async {
        await model.loadWorkouts()
        openSession = await SupabaseClient.shared.workoutOpen()
    }

    // MARK: Day stepper

    private var canStepForward: Bool {
        selectedDay < Calendar.current.startOfDay(for: Date())
    }

    private func stepDay(_ delta: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        let start = cal.startOfDay(for: next)
        if start > Date() { return }
        selectedDay = start
    }

    private var dayStepper: some View {
        HStack(spacing: 0) {
            Button { stepDay(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(V3.t2)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(V3Format.shortDay(selectedDay))
                .font(V3Font.text(13, .semibold))
                .foregroundStyle(V3.t1)
                .monospacedDigit()
            Button { stepDay(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canStepForward ? V3.t2 : V3.t3)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canStepForward)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(V3.card2, in: Capsule())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let d = model.data, Calendar.current.isDate(d.day, inSameDayAs: selectedDay) {
            if mode == "River" {
                riverContent(d)
            } else {
                ringsContent(d)
            }
        } else {
            loadingCard
        }
    }

    private var loadingCard: some View {
        V3Card {
            HStack(spacing: 10) {
                ProgressView().tint(V3.t2)
                Text("Loading your day")
                    .font(V3Font.text(15, .semibold))
                    .foregroundStyle(V3.t2)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func emptyText(_ d: StrainDayData) -> String {
        d.isToday ? "Not enough heart rate yet today." : "No heart rate recorded for this day."
    }

    @ViewBuilder
    private func ringsContent(_ d: StrainDayData) -> some View {
        StrainHeroTrio(d: d)
        if d.hasHR {
            if d.partsVisible { StrainPartsRow(d: d, top: 8) }
            loadCallout(d)
            StrainDayCard(d: d)
            StrainBlocksCard(d: d, onName: { (b: StrainDayBlock) in nameTarget = b },
                             onOpen: { (b: StrainDayBlock) in blockTarget = b })
            if d.hasBattery { StrainDrainCard(d: d) }
            StrainHRCard(d: d)
        } else {
            StrainEmptyCard(text: emptyText(d))
        }
        StrainTrainingCard(d: d)
        StrainRidesCard(rides: model.rides, selectedDay: selectedDay)
        workoutCard
    }

    @ViewBuilder
    private func riverContent(_ d: StrainDayData) -> some View {
        StrainRiverBigPair(d: d)
        if d.hasHR {
            if d.partsVisible { StrainPartsRow(d: d, top: 2) }
            StrainRiverCard(d: d, onName: { (b: StrainDayBlock) in nameTarget = b })
                .padding(.top, 6)
            StrainZonesCard(d: d)
        } else {
            StrainEmptyCard(text: emptyText(d))
        }
        StrainTrainingCard(d: d)
        StrainRidesCard(rides: model.rides, selectedDay: selectedDay)
        workoutCard
    }

    @ViewBuilder
    private func loadCallout(_ d: StrainDayData) -> some View {
        if let top = d.topBlock, (d.dayTrimp ?? 0) > 0, top.loadShare >= 1 {
            V3Callout(
                color: V3.strain,
                bold: "The \(StrainStyle.lowerFirst(top.short)) did \(Int(top.loadShare.rounded()))% of the load."
            )
        }
    }

    private var workoutCard: some View {
        StrainWorkoutCard(
            last: model.lastWorkout,
            running: openSession,
            starting: starting,
            note: workoutNote,
            onStart: { (chip: String) in startWorkout(chip) },
            onResume: { liveSession = openSession }
        )
    }

    private func startWorkout(_ chip: String) {
        if starting { return }
        guard let t = model.workoutType(for: chip) else {
            workoutNote = "No \(chip.lowercased()) workout type is set up yet."
            return
        }
        workoutNote = nil
        starting = true
        Task {
            let s = await SupabaseClient.shared.workoutStart(type: t.id)
            starting = false
            if let s = s {
                openSession = s
                liveSession = s
            } else {
                workoutNote = "Could not start the workout. Check the connection."
            }
        }
    }
}

// MARK: - Shared style helpers

private enum StrainStyle {
    static func color(_ k: StrainBlockKind) -> Color {
        switch k {
        case .ride: return V3.ride
        case .work: return V3.work
        case .play: return V3.play
        case .rest: return V3.rest
        case .unknown: return V3.t2
        }
    }

    static func iconColor(_ k: StrainBlockKind) -> Color {
        k == .rest ? V3.t2 : color(k)
    }

    static func zoneColor(_ bpm: Double) -> Color {
        if bpm >= 115 { return V3.heart }
        if bpm >= 95 { return V3.heart.opacity(0.55) }
        return V3.heart.opacity(0.24)
    }

    static func one(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    static func lowerFirst(_ s: String) -> String {
        let chars = Array(s)
        if chars.count >= 2 && chars[0].isUppercase && chars[1].isUppercase { return s }
        guard let f = chars.first else { return s }
        return String(f).lowercased() + String(chars.dropFirst())
    }

    static func dayMonth(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    static func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE"
        return f.string(from: d)
    }
}

private enum StrainCurve {
    // Continues the current subpath through pts, Catmull-Rom at tension 0.18 like v3SmoothPath.
    static func add(_ p: inout Path, _ pts: [CGPoint]) {
        if pts.count < 2 { return }
        let t: CGFloat = 0.18
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * t, y: p1.y + (p2.y - p0.y) * t)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * t, y: p2.y - (p3.y - p1.y) * t)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
    }
}

// MARK: - Hero and parts

private struct StrainHeroTrio: View {
    let d: StrainDayData

    var body: some View {
        V3HeroTrio(glow: V3.strain) {
            recoveryRing
        } middle: {
            strainRing
        } right: {
            nextRing
        }
    }

    @ViewBuilder
    private var recoveryRing: some View {
        if let r = d.recovery {
            V3SmallRing(value: "\(Int(r.rounded()))", progress: r / 100, color: V3.recovery(r), label: "Recovery", sub: "that morning")
        } else {
            V3SmallRing(value: "–", progress: 0, color: V3.t3, label: "Recovery", sub: "not scored", dashed: true)
        }
    }

    @ViewBuilder
    private var strainRing: some View {
        if d.hasHR, let s = d.dayStrain {
            V3HeroRing(
                value: StrainStyle.one(s),
                unit: "",
                progress: s / 21,
                color: V3.strain,
                label: "Day strain",
                sub: "\(V3.strainWord(s)) · of 21",
                subColor: V3.strain
            )
        } else {
            V3HeroRing(value: "–", unit: "", progress: 0, color: V3.t3, label: "Day strain", sub: "No heart rate yet")
        }
    }

    @ViewBuilder
    private var nextRing: some View {
        if let r = d.recoveryNext {
            V3SmallRing(value: "\(Int(r.rounded()))", progress: r / 100, color: V3.recovery(r), label: "Next day", sub: "recovery")
        } else {
            V3SmallRing(value: "–", progress: 0, color: V3.t3, label: "Next day", sub: d.isToday ? "tomorrow" : "not scored", dashed: true)
        }
    }
}

private struct StrainPartsRow: View {
    let d: StrainDayData
    var top: CGFloat = 8

    var body: some View {
        let p = d.physical ?? 0
        let s = d.stress ?? 0
        let a = d.autonomic ?? 0
        HStack(alignment: .top, spacing: 14) {
            V3MacroBar(label: "Physical", value: StrainStyle.one(p), fraction: p / 21, color: V3.strain)
            V3MacroBar(label: "Stress", value: StrainStyle.one(s), fraction: s / 21, color: V3.heart)
            V3MacroBar(label: "Autonomic", value: StrainStyle.one(a), fraction: a / 21, color: V3.energy)
        }
        .padding(.horizontal, 4)
        .padding(.top, top)
    }
}

private struct StrainEmptyCard: View {
    let text: String

    var body: some View {
        V3Card {
            V3CardHeader(title: "Your day")
            V3EmptyLine(text: text)
        }
    }
}

// MARK: - Axis and legend

private struct StrainTick: Identifiable {
    let id: Int
    let f: Double
    let label: String
}

private struct StrainAxis: View {
    let wake: Date
    let end: Date

    private var ticks: [StrainTick] {
        let cal = Calendar.current
        let t0 = wake.timeIntervalSince1970
        let span = end.timeIntervalSince1970 - t0
        if span <= 0 { return [] }
        var out: [StrainTick] = []
        let base = cal.startOfDay(for: wake)
        for dayOffset in 0..<3 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: base) else { continue }
            for h in [0, 3, 6, 9, 12, 15, 18, 21] {
                guard let t = cal.date(bySettingHour: h, minute: 0, second: 0, of: day) else { continue }
                let f = (t.timeIntervalSince1970 - t0) / span
                if f >= 0.12 && f <= 0.88 {
                    out.append(StrainTick(id: out.count, f: f, label: String(format: "%02d", h)))
                }
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                HStack {
                    Text(V3Format.hhmm(wake))
                    Spacer(minLength: 0)
                    Text(V3Format.hhmm(end))
                }
                ForEach(ticks) { t in
                    Text(t.label)
                        .position(x: g.size.width * CGFloat(t.f), y: g.size.height / 2)
                }
            }
            .font(V3Font.text(11, .medium))
            .foregroundStyle(V3.t3)
        }
        .frame(height: 16)
        .padding(.top, 6)
    }
}

private enum StrainSwatchStyle {
    case bar, dot, dashed
}

private struct StrainLegendCell: View {
    let label: String
    let color: Color
    let style: StrainSwatchStyle

    var body: some View {
        HStack(spacing: 6) {
            swatch
            Text(label)
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var swatch: some View {
        switch style {
        case .bar:
            Capsule().fill(color).frame(width: 14, height: 3)
        case .dot:
            Circle().fill(color).frame(width: 7, height: 7)
        case .dashed:
            Circle()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .frame(width: 8, height: 8)
        }
    }
}

private struct StrainKindLegend: View {
    let battery: Bool

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: 3),
            alignment: .leading,
            spacing: 8
        ) {
            if battery {
                StrainLegendCell(label: "Battery", color: V3.energy, style: .bar)
            }
            StrainLegendCell(label: "Ride", color: V3.ride, style: .dot)
            StrainLegendCell(label: "Work", color: V3.work, style: .dot)
            StrainLegendCell(label: "Play", color: V3.play, style: .dot)
            StrainLegendCell(label: "Rest", color: V3.rest, style: .dot)
            StrainLegendCell(label: "Not labelled", color: V3.t2, style: .dashed)
        }
        .padding(.top, 14)
    }
}

// MARK: - Your day (battery over blocks)

private struct StrainDayCard: View {
    let d: StrainDayData

    var body: some View {
        V3Card {
            V3CardHeader(title: "Your day", trailing: d.hasBattery ? (d.batteryLive ? "battery over blocks" : "estimated battery") : "blocks")
            StrainDayChart(d: d)
            StrainAxis(wake: d.wake, end: d.end)
            StrainKindLegend(battery: d.hasBattery)
        }
    }
}

private struct StrainDayChart: View {
    let d: StrainDayData

    private let plotH: CGFloat = 96
    private let barH: CGFloat = 18
    private var barY: CGFloat { d.hasBattery ? plotH + 10 : 0 }

    var body: some View {
        Canvas { ctx, size in
            draw(&ctx, size)
        }
        .frame(height: barY + barH)
    }

    private func thinned(_ a: [StrainBatteryPoint]) -> [StrainBatteryPoint] {
        let maxN = 90
        if a.count <= maxN { return a }
        let step = Int((Double(a.count) / Double(maxN)).rounded(.up))
        var out: [StrainBatteryPoint] = []
        var i = 0
        while i < a.count {
            out.append(a[i])
            i += step
        }
        if let last = a.last, out.last?.at != last.at { out.append(last) }
        return out
    }

    private func dot(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ ring: CGFloat) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let path = Path(ellipseIn: rect)
        ctx.fill(path, with: .color(V3.energy))
        ctx.stroke(path, with: .color(V3.card), lineWidth: ring)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width
        let t0 = d.wake.timeIntervalSince1970
        let span = max(1, d.end.timeIntervalSince1970 - t0)
        let h = plotH

        func xOf(_ t: Date) -> CGFloat {
            CGFloat((t.timeIntervalSince1970 - t0) / span) * w
        }
        func yOf(_ v: Double) -> CGFloat {
            12 + CGFloat(1 - min(max(v, 0), 100) / 100) * (h - 16)
        }

        let sepTop: CGFloat = d.hasBattery ? yOf(100) : 0
        let sepBottom = barY + barH

        if d.hasBattery {
            for v in [25.0, 50.0, 75.0] {
                var g = Path()
                g.move(to: CGPoint(x: 0, y: yOf(v)))
                g.addLine(to: CGPoint(x: w, y: yOf(v)))
                ctx.stroke(g, with: .color(V3.grid), lineWidth: 1)
            }
        }

        for b in d.blocks.dropFirst() {
            var sep = Path()
            sep.move(to: CGPoint(x: xOf(b.start), y: sepTop))
            sep.addLine(to: CGPoint(x: xOf(b.start), y: sepBottom))
            ctx.stroke(sep, with: .color(V3.t3.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        if d.hasBattery {
            let pts: [CGPoint] = thinned(d.battery).map { (p: StrainBatteryPoint) -> CGPoint in
                CGPoint(x: xOf(p.at), y: yOf(p.value))
            }
            if let first = pts.first, let last = pts.last, pts.count > 1 {
                var area = v3SmoothPath(pts)
                area.addLine(to: CGPoint(x: last.x, y: h))
                area.addLine(to: CGPoint(x: first.x, y: h))
                area.closeSubpath()
                let grad = Gradient(colors: [V3.energy.opacity(0.3), V3.energy.opacity(0)])
                ctx.fill(area, with: .linearGradient(grad, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
                ctx.stroke(
                    v3SmoothPath(pts),
                    with: .color(V3.energy),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )

                dot(&ctx, CGPoint(x: first.x + 2, y: first.y), 3.5, 2)
                if let a = d.batteryAtWake {
                    let label = Text("\(Int(a.rounded()))").font(V3Font.num(12, .semibold)).foregroundStyle(V3.t1)
                    ctx.draw(label, at: CGPoint(x: first.x + 10, y: max(7, first.y - 10)), anchor: .leading)
                }

                dot(&ctx, CGPoint(x: last.x - 2, y: last.y), 5, 2.5)
                if let z = d.batteryAtEnd {
                    let label = Text("\(Int(z.rounded()))").font(V3Font.num(12, .semibold)).foregroundStyle(V3.t1)
                    ctx.draw(label, at: CGPoint(x: min(last.x - 2, w - 10), y: max(7, last.y - 15)), anchor: .center)
                }
            }
        }

        for b in d.blocks {
            let x = xOf(b.start) + 1
            let bw = max(2, xOf(b.end) - xOf(b.start) - 2)
            if b.kind == .unknown {
                let r = CGRect(x: x + 0.75, y: barY + 0.75, width: max(1, bw - 1.5), height: barH - 1.5)
                let path = RoundedRectangle(cornerRadius: 5, style: .continuous).path(in: r)
                ctx.stroke(path, with: .color(V3.t2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            } else {
                let r = CGRect(x: x, y: barY, width: bw, height: barH)
                let path = RoundedRectangle(cornerRadius: 5, style: .continuous).path(in: r)
                ctx.fill(path, with: .color(StrainStyle.color(b.kind)))
            }
        }
    }
}

// MARK: - What did it

private struct StrainBlocksCard: View {
    let d: StrainDayData
    let onName: (StrainDayBlock) -> Void
    var onOpen: (StrainDayBlock) -> Void = { _ in }

    var body: some View {
        V3Card {
            V3CardHeader(title: "What did it", trailing: d.blocks.count == 1 ? "1 block" : "\(d.blocks.count) blocks")
            ForEach(d.blocks) { b in
                row(b)
            }
        }
    }

    private func detail(_ b: StrainDayBlock) -> String {
        var s = "\(V3Format.hhmm(b.start))–\(V3Format.hhmm(b.end)) · \(V3Format.duration(minutes: b.minutes))"
        if let h = b.hrAvg { s += " · \(Int(h.rounded())) bpm" }
        return s
    }

    @ViewBuilder
    private func row(_ b: StrainDayBlock) -> some View {
        let isFirst = b.id == d.blocks.first?.id
        V3ListRow(
            icon: b.icon,
            iconColor: StrainStyle.iconColor(b.kind),
            title: b.name,
            detail: detail(b),
            value: "+" + StrainStyle.one(b.strainAdded),
            valueColor: V3.strain,
            valueSub: "\(Int(b.loadShare.rounded()))% of load",
            first: isFirst,
            dashedIcon: b.kind == .unknown
        ) {
            if b.kind == .unknown {
                Button { onName(b) } label: { nameChip }
                    .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(b)
        }
    }

    private var nameChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.system(size: 12, weight: .semibold))
            Text("Name it").font(V3Font.text(13, .semibold))
        }
        .foregroundStyle(V3.t1)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(V3.card2, in: Capsule())
        .padding(.top, 8)
    }
}

// MARK: - Where the battery went

private struct StrainDrainCard: View {
    let d: StrainDayData

    private var rows: [StrainDayBlock] {
        var pairs: [(Int, StrainDayBlock)] = []
        for (i, b) in d.blocks.enumerated() where b.drained >= 0.5 {
            pairs.append((i, b))
        }
        pairs.sort { (x: (Int, StrainDayBlock), y: (Int, StrainDayBlock)) -> Bool in
            if x.1.drained != y.1.drained { return x.1.drained > y.1.drained }
            return x.0 < y.0
        }
        return pairs.map { (p: (Int, StrainDayBlock)) -> StrainDayBlock in p.1 }
    }

    private var maxDrain: Double {
        rows.map { (b: StrainDayBlock) -> Double in b.drained }.max() ?? 0
    }

    private var trailing: String? {
        guard let a = d.batteryAtWake, let z = d.batteryAtEnd else { return nil }
        return "\(Int(a.rounded())) to \(Int(z.rounded()))"
    }

    var body: some View {
        V3Card {
            V3CardHeader(icon: "bolt.fill", iconColor: V3.energy, title: "Where the battery went", trailing: trailing)
            ForEach(rows) { b in
                V3BarRow(
                    name: b.drainName,
                    fraction: maxDrain > 0 ? b.drained / maxDrain : 0,
                    color: StrainStyle.color(b.kind),
                    value: V3Format.signed(-b.drained.rounded(), decimals: 0),
                    dashed: b.kind == .unknown
                )
            }
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let z = d.batteryAtEnd {
            let level = Int(z.rounded())
            let bold = d.isToday ? "\(level) so far" : "\(level) carried into \(V3Format.shortDay(d.nextDay))"
            HStack(spacing: 8) {
                Circle().fill(V3.energy).frame(width: 7, height: 7)
                HStack(spacing: 0) {
                    Text(bold)
                        .font(V3Font.text(13, .semibold))
                        .foregroundStyle(V3.t1)
                    Text(" at " + V3Format.hhmm(d.end))
                        .font(V3Font.text(13))
                        .foregroundStyle(V3.t2)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(.top, 14)
        }
    }
}

// MARK: - Heart rate and zones

private struct StrainHRCard: View {
    let d: StrainDayData

    private let plotH: CGFloat = 104
    private let topPad: CGFloat = 16

    private func zoneDot(_ i: Int) -> Color? {
        if i == 0 { return V3.heart.opacity(0.55) }
        if i == 1 { return V3.heart }
        return nil
    }

    private func zoneMinutes(_ i: Int) -> Double {
        i < d.zoneMinutes.count ? d.zoneMinutes[i] : 0
    }

    var body: some View {
        V3Card {
            V3CardHeader(icon: "heart.fill", iconColor: V3.heart, title: "Heart rate and zones", trailing: "every 15 min")
            Canvas { ctx, size in
                draw(&ctx, size)
            }
            .frame(height: topPad + plotH)
            StrainAxis(wake: d.wake, end: d.end)
            HStack(alignment: .top, spacing: 6) {
                ForEach(0..<5, id: \.self) { i in
                    V3LegendItem(dot: zoneDot(i), label: "Zone \(i + 1)", value: V3Format.duration(minutes: zoneMinutes(i)))
                }
            }
            .padding(.top, 14)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width
        let t0 = d.wake.timeIntervalSince1970
        let span = max(1, d.end.timeIntervalSince1970 - t0)
        let hours = span / 3600
        let bw = max(1, w / CGFloat(hours * 4) - 1.6)
        let top = topPad
        let ph = plotH

        func yOf(_ v: Double) -> CGFloat {
            top + CGFloat(1 - (min(max(v, 50), 136) - 50) / 86) * ph
        }

        let zones: [(Double, String)] = [(95, "Zone 1"), (115, "Zone 2")]
        for z in zones {
            let y = yOf(z.0)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(line, with: .color(V3.t3), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            let label = Text(z.1).font(V3Font.text(12, .medium)).foregroundStyle(V3.t2)
            ctx.draw(label, at: CGPoint(x: 0, y: y - 4), anchor: .bottomLeading)
        }

        var peakX: CGFloat = 0
        for p in d.hr {
            let s = max(p.at, d.wake)
            let x = CGFloat((s.timeIntervalSince1970 - t0) / span) * w + 0.8
            let y = yOf(p.bpm)
            let r = CGRect(x: x, y: y, width: bw, height: top + ph - y)
            let path = RoundedRectangle(cornerRadius: 1.5, style: .continuous).path(in: r)
            ctx.fill(path, with: .color(StrainStyle.zoneColor(p.bpm)))
            if let pk = d.peak, pk.at == p.at { peakX = x }
        }

        if let pk = d.peak {
            let text = "\(Int(pk.bpm.rounded())) · \(V3Format.hhmm(pk.at))"
            let label = Text(text).font(V3Font.text(12, .semibold)).foregroundStyle(V3.t1)
            let x = min(max(peakX + 2, 34), w - 34)
            ctx.draw(label, at: CGPoint(x: x, y: yOf(pk.bpm) - 8), anchor: .center)
        }
    }
}

// MARK: - Time in zones (River)

private struct StrainBarSegment: Identifiable {
    let id: Int
    let minutes: Double
    let color: Color
}

private struct StrainZonesCard: View {
    let d: StrainDayData

    private func zone(_ i: Int) -> Double {
        i < d.zoneMinutes.count ? d.zoneMinutes[i] : 0
    }

    private var segments: [StrainBarSegment] {
        var out: [StrainBarSegment] = []
        if d.belowZoneMinutes > 0 { out.append(StrainBarSegment(id: 0, minutes: d.belowZoneMinutes, color: V3.heart.opacity(0.24))) }
        if zone(0) > 0 { out.append(StrainBarSegment(id: 1, minutes: zone(0), color: V3.heart.opacity(0.55))) }
        let high = zone(1) + zone(2) + zone(3) + zone(4)
        if high > 0 { out.append(StrainBarSegment(id: 2, minutes: high, color: V3.heart)) }
        return out
    }

    var body: some View {
        let segs = segments
        let total = max(1, segs.reduce(0) { (acc: Double, s: StrainBarSegment) -> Double in acc + s.minutes })
        let gaps = CGFloat(max(0, segs.count - 1)) * 2
        V3Card {
            V3CardHeader(
                icon: "heart.fill",
                iconColor: V3.heart,
                title: "Time in zones",
                trailing: "awake " + V3Format.duration(minutes: d.windowMinutes)
            )
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(segs) { s in
                        Rectangle()
                            .fill(s.color)
                            .frame(width: max(0, (g.size.width - gaps) * CGFloat(s.minutes / total)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            HStack(alignment: .top, spacing: 6) {
                V3LegendItem(label: "Below zone 1", value: V3Format.duration(minutes: d.belowZoneMinutes))
                V3LegendItem(label: "Zone 1", value: V3Format.duration(minutes: zone(0)))
                V3LegendItem(label: "Zone 2", value: V3Format.duration(minutes: zone(1)))
                V3LegendItem(label: "Zones 3 to 5", value: V3Format.duration(minutes: zone(2) + zone(3) + zone(4)))
            }
            .padding(.top, 14)
        }
    }
}

// MARK: - Training load

private struct StrainTrainingCard: View {
    let d: StrainDayData

    private func status(_ a: Double) -> (String, Color) {
        if a < 0.8 { return ("Low", V3.t2) }
        if a <= 1.3 { return ("Steady", V3.green) }
        if a <= 1.5 { return ("Rising", V3.amber) }
        return ("High", V3.red)
    }

    var body: some View {
        V3Card {
            V3CardHeader(icon: "waveform.path.ecg", iconColor: V3.strain, title: "Training load", trailing: "acute to chronic")
            if let a = d.acwr {
                let st = status(a)
                HStack(spacing: 10) {
                    V3BigNumber(value: String(format: "%.2f", a))
                    Text(st.0)
                        .font(V3Font.text(12, .bold))
                        .foregroundStyle(st.1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(st.1.opacity(0.14), in: Capsule())
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 12)
                StrainRangeStrip(value: a, color: st.1)
            } else {
                V3EmptyLine(text: "No training load for this day")
            }
            VStack(spacing: 0) {
                Rectangle().fill(V3.line).frame(height: 1)
                HStack(alignment: .top, spacing: 6) {
                    legendItem("Monotony", d.monotony, "%.2f")
                    legendItem("VO2max", d.vo2, "%.1f")
                    V3LegendItem(label: "Steps", value: "Not synced", valueColor: V3.t2)
                }
                .padding(.top, 12)
            }
            .padding(.top, 12)
        }
    }

    private func legendItem(_ label: String, _ v: Double?, _ fmt: String) -> some View {
        V3LegendItem(
            label: label,
            value: v.map { (x: Double) -> String in String(format: fmt, x) } ?? "No data",
            valueColor: v == nil ? V3.t2 : V3.t1
        )
    }
}

private struct StrainRangeStrip: View {
    let value: Double
    let color: Color

    private let lo = 0.5
    private let hi = 2.0

    var body: some View {
        Canvas { ctx, size in
            draw(&ctx, size)
        }
        .frame(height: 46)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width
        let lo = self.lo
        let hi = self.hi
        let y: CGFloat = 14

        func xOf(_ v: Double) -> CGFloat {
            8 + CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)) * (w - 16)
        }

        var track = Path()
        track.move(to: CGPoint(x: 0, y: y))
        track.addLine(to: CGPoint(x: w, y: y))
        ctx.stroke(track, with: .color(V3.track), lineWidth: 2)

        let bands: [(Double, Double, Color)] = [
            (0.8, 1.3, V3.green.opacity(0.16)),
            (1.3, 1.5, V3.amber.opacity(0.16))
        ]
        for b in bands {
            let r = CGRect(x: xOf(b.0), y: y - 6, width: xOf(b.1) - xOf(b.0), height: 12)
            ctx.fill(RoundedRectangle(cornerRadius: 6, style: .continuous).path(in: r), with: .color(b.2))
        }

        let dotRect = CGRect(x: xOf(value) - 7, y: y - 7, width: 14, height: 14)
        let dotPath = Path(ellipseIn: dotRect)
        ctx.fill(dotPath, with: .color(color))
        ctx.stroke(dotPath, with: .color(V3.card), lineWidth: 2.5)

        let ticks: [(Double, String)] = [(0.5, "0.5"), (0.8, "0.8"), (1.3, "1.3"), (1.5, "1.5"), (2.0, "2.0")]
        for t in ticks {
            let label = Text(t.1).font(V3Font.text(11, .medium)).foregroundStyle(V3.t3)
            ctx.draw(label, at: CGPoint(x: xOf(t.0), y: y + 23), anchor: .center)
        }
    }
}

// MARK: - Rides and workouts

private struct StrainRidesCard: View {
    let rides: [SupabaseClient.WorkoutRecord]
    let selectedDay: Date

    var body: some View {
        V3Card {
            V3CardHeader(icon: "bicycle", iconColor: V3.strain, title: "Rides", trailing: "last five")
            if rides.isEmpty {
                V3EmptyLine(text: "No rides recorded yet")
            } else {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(rides) { r in
                        cell(r)
                    }
                    ForEach(0..<max(0, 5 - rides.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func cell(_ r: SupabaseClient.WorkoutRecord) -> some View {
        let km: String = r.distanceKm.map { (x: Double) -> String in String(format: "%.1f", x) } ?? "–"
        let highlight = Calendar.current.isDate(r.startedAt, inSameDayAs: selectedDay)
        return VStack(spacing: 0) {
            Text(StrainStyle.dayMonth(r.startedAt))
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
            Text(km)
                .font(V3Font.num(17))
                .foregroundStyle(V3.t1)
                .padding(.top, 5)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            Text("km")
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
            Text("\(r.minutes) min")
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(highlight ? V3.card2 : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StrainWorkoutCard: View {
    let last: SupabaseClient.WorkoutRecord?
    let running: SupabaseClient.WorkoutSession?
    let starting: Bool
    let note: String?
    let onStart: (String) -> Void
    let onResume: () -> Void

    private static let chips: [String] = ["Gym", "Run", "Bike", "Walk", "Ride"]

    var body: some View {
        V3Card {
            V3CardHeader(title: "Start a workout", trailing: "goes live")
            if let o = running { resumeRow(o) }
            HStack(spacing: 0) {
                ForEach(Self.chips, id: \.self) { name in
                    chip(name)
                    if name != Self.chips.last { Spacer(minLength: 6) }
                }
            }
            if let n = note {
                Text(n)
                    .font(V3Font.text(12))
                    .foregroundStyle(V3.t2)
                    .padding(.top, 10)
            }
            if let w = last { lastRow(w) }
        }
    }

    private func chip(_ name: String) -> some View {
        Button { onStart(name) } label: {
            Text(name)
                .font(V3Font.text(13, .semibold))
                .foregroundStyle(V3.t1)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(V3.card2, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(starting)
    }

    private func resumeRow(_ o: SupabaseClient.WorkoutSession) -> some View {
        Button(action: onResume) {
            HStack(spacing: 12) {
                V3IconWell(symbol: "play.fill", color: V3.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(o.label) in progress")
                        .font(V3Font.text(15, .semibold))
                        .foregroundStyle(V3.t1)
                        .lineLimit(1)
                    Text("Started \(V3Format.hhmm(o.startedAt))")
                        .font(V3Font.text(12))
                        .foregroundStyle(V3.t2)
                }
                Spacer(minLength: 8)
                Text("Resume")
                    .font(V3Font.text(13, .semibold))
                    .foregroundStyle(V3.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)
    }

    private func lastRow(_ w: SupabaseClient.WorkoutRecord) -> some View {
        HStack(spacing: 12) {
            V3IconWell(symbol: "gauge.with.needle", color: V3.heart)
            VStack(alignment: .leading, spacing: 1) {
                Text("Last workout")
                    .font(V3Font.text(12))
                    .foregroundStyle(V3.t2)
                Text(w.label)
                    .font(V3Font.text(15, .semibold))
                    .foregroundStyle(V3.t1)
                    .lineLimit(1)
                Text("\(V3Format.shortDay(w.startedAt)) · \(w.minutes) min")
                    .font(V3Font.text(12))
                    .foregroundStyle(V3.t2)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if let h = w.hrAvg {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(h)")
                        .font(V3Font.text(15, .semibold))
                        .foregroundStyle(V3.heart)
                        .monospacedDigit()
                    Text("avg")
                        .font(V3Font.text(12))
                        .foregroundStyle(V3.t2)
                }
            }
        }
        .padding(.top, 14)
    }
}

private struct StrainWorkoutSheet: View {
    let session: SupabaseClient.WorkoutSession
    @Environment(\.dismiss) private var dismiss
    @State private var live: SupabaseClient.WorkoutLive? = nil
    @State private var distance: String = ""
    @State private var busy = false
    @State private var summary: SupabaseClient.WorkoutSummary? = nil
    @State private var failed = false

    var body: some View {
        ZStack {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    titleRow
                    if let s = summary {
                        summaryCard(s)
                    } else {
                        clockCard
                        liveCard
                        if session.tracksDistance { distanceField }
                        if failed {
                            V3EmptyLine(text: "That did not save. Try again.")
                        }
                        V3Button(title: busy ? "Saving" : "Finish", symbol: "checkmark") { finish() }
                        V3Button(title: "Discard", secondary: true) { discard() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .task { await poll() }
        .presentationDetents([.medium, .large])
        .presentationBackground(V3.sheet)
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text(session.emoji).font(.system(size: 24))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.label)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(V3.t1)
                Text("Started \(V3Format.hhmm(session.startedAt))")
                    .font(V3Font.text(13))
                    .foregroundStyle(V3.t2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func clock(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(session.startedAt)))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private var clockCard: some View {
        V3Card {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(clock(context.date))
                    .font(V3Font.num(52))
                    .foregroundStyle(V3.t1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var liveCard: some View {
        V3Card {
            if let l = live {
                HStack(alignment: .top, spacing: 6) {
                    V3LegendItem(dot: V3.heart, label: "Heart rate", value: l.hrNow.map { (x: Int) -> String in "\(x)" } ?? "–")
                    V3LegendItem(label: "Average", value: l.hrAvg.map { (x: Int) -> String in "\(x)" } ?? "–")
                    V3LegendItem(label: "Peak", value: l.hrPeak.map { (x: Int) -> String in "\(x)" } ?? "–")
                    V3LegendItem(label: "kcal", value: "\(l.kcal)")
                }
                if !l.zone.isEmpty {
                    Text(l.zone)
                        .font(V3Font.text(12))
                        .foregroundStyle(V3.t2)
                        .padding(.top, 12)
                }
            } else {
                V3EmptyLine(text: "Waiting for the first reading")
            }
        }
    }

    private var distanceField: some View {
        HStack(spacing: 10) {
            Text("Distance")
                .font(V3Font.text(15, .semibold))
                .foregroundStyle(V3.t1)
            Spacer(minLength: 8)
            TextField("0.0", text: $distance)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(V3Font.num(17))
                .foregroundStyle(V3.t1)
                .frame(width: 90)
            Text("km")
                .font(V3Font.text(14))
                .foregroundStyle(V3.t2)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(V3.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func summaryCard(_ s: SupabaseClient.WorkoutSummary) -> some View {
        VStack(spacing: 14) {
            V3Card {
                Text(s.headline)
                    .font(V3Font.text(15, .semibold))
                    .foregroundStyle(V3.t1)
                    .padding(.bottom, 14)
                HStack(alignment: .top, spacing: 6) {
                    V3LegendItem(label: "Time", value: V3Format.duration(minutes: Double(s.durationSec) / 60))
                    V3LegendItem(label: s.kcalSource == "hr" ? "kcal from heart rate" : "kcal estimated", value: "\(s.kcal)")
                    V3LegendItem(label: "Average", value: s.hrAvg.map { (x: Int) -> String in "\(x)" } ?? "–")
                }
                if let km = s.distanceKm {
                    Text(String(format: "%.1f km", km))
                        .font(V3Font.text(13))
                        .foregroundStyle(V3.t2)
                        .padding(.top, 12)
                }
            }
            V3Button(title: "Done") { dismiss() }
        }
    }

    private func poll() async {
        while !Task.isCancelled && summary == nil {
            if let l = await SupabaseClient.shared.workoutLive(id: session.id) { live = l }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func finish() {
        if busy { return }
        busy = true
        failed = false
        let km = Double(distance.replacingOccurrences(of: ",", with: "."))
        Task {
            let result = await SupabaseClient.shared.workoutFinish(id: session.id, distanceKm: km, load: nil, rpe: nil)
            busy = false
            if let r = result {
                summary = r
            } else {
                failed = true
            }
        }
    }

    private func discard() {
        if busy { return }
        busy = true
        Task {
            await SupabaseClient.shared.workoutCancel(id: session.id)
            busy = false
            dismiss()
        }
    }
}

// MARK: - River

private struct StrainRiverBigPair: View {
    let d: StrainDayData

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Day strain")
                    .font(V3Font.text(13, .semibold))
                    .foregroundStyle(V3.t2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(strainText)
                        .font(V3Font.num(46))
                        .tracking(-2.07)
                        .foregroundStyle(d.hasHR ? V3.strain : V3.t3)
                    Text("of 21")
                        .font(V3Font.text(16))
                        .foregroundStyle(V3.t2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("Next day")
                    .font(V3Font.text(13, .semibold))
                    .foregroundStyle(V3.t2)
                Text(nextText)
                    .font(V3Font.num(46))
                    .tracking(-2.07)
                    .foregroundStyle(nextColor)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private var strainText: String {
        if d.hasHR, let s = d.dayStrain { return StrainStyle.one(s) }
        return "–"
    }

    private var nextText: String {
        if let r = d.recoveryNext { return "\(Int(r.rounded()))" }
        return "–"
    }

    private var nextColor: Color {
        if let r = d.recoveryNext { return V3.recovery(r) }
        return V3.t3
    }
}

private struct StrainRiverCard: View {
    let d: StrainDayData
    let onName: (StrainDayBlock) -> Void

    var body: some View {
        V3Card {
            V3CardHeader(title: "Your day as a river", trailing: "width is heart rate")
            HStack {
                if d.hasBattery {
                    Text("Battery")
                        .font(V3Font.text(12, .semibold))
                        .foregroundStyle(V3.energy)
                }
                Spacer(minLength: 0)
                Text("Strain added")
                    .font(V3Font.text(12, .semibold))
                    .foregroundStyle(V3.strain)
            }
            .padding(.bottom, 8)
            StrainRiverCanvas(d: d, onName: onName)
            StrainKindLegend(battery: false)
            if let a = d.batteryAtWake, let z = d.batteryAtEnd {
                VStack(spacing: 0) {
                    Rectangle().fill(V3.line).frame(height: 1)
                    HStack(alignment: .top, spacing: 6) {
                        V3LegendItem(label: "At wake, \(V3Format.hhmm(d.wake))", value: "\(Int(a.rounded()))", valueColor: V3.energy)
                        V3LegendItem(label: "Used by the day", value: "\(Int(max(0, a - z).rounded()))")
                        V3LegendItem(
                            label: d.isToday ? "Right now" : "Carried into \(StrainStyle.weekday(d.nextDay))",
                            value: "\(Int(z.rounded()))",
                            valueColor: V3.energy
                        )
                    }
                    .padding(.top, 12)
                }
                .padding(.top, 14)
            }
        }
    }
}

private struct StrainRiverCanvas: View {
    let d: StrainDayData
    let onName: (StrainDayBlock) -> Void

    private struct Sample {
        let t: Date
        let bpm: Double
    }

    private struct LabelSlot: Identifiable {
        let id: String
        let y: CGFloat
        let block: StrainDayBlock
    }

    private let pxPerHour: CGFloat = 30
    private let topPad: CGFloat = 10
    private let cx: CGFloat = 86
    private let labelX: CGFloat = 150

    private func yOf(_ t: Date) -> CGFloat {
        topPad + CGFloat(t.timeIntervalSince(d.wake) / 3600) * pxPerHour
    }

    private func widthOf(_ bpm: Double) -> CGFloat {
        let v = min(max(bpm, 55), 130)
        return 12 + CGFloat((v - 55) / 75) * 84
    }

    private var samples: [Sample] {
        var out: [Sample] = []
        let sorted = d.hr.sorted { (a: StrainHRPoint, b: StrainHRPoint) -> Bool in a.at < b.at }
        guard let first = sorted.first, let last = sorted.last else { return out }
        out.append(Sample(t: d.wake, bpm: first.bpm))
        for p in sorted {
            let c = p.at.addingTimeInterval(450)
            if c > d.wake && c < d.end { out.append(Sample(t: c, bpm: p.bpm)) }
        }
        out.append(Sample(t: d.end, bpm: last.bpm))
        return out
    }

    private var slots: [LabelSlot] {
        var out: [LabelSlot] = []
        var lastY: CGFloat = -99
        var gap: CGFloat = 46
        for b in d.blocks {
            let mid = (yOf(b.start) + yOf(b.end)) / 2
            let y = max(mid + 4, lastY + gap)
            lastY = y
            gap = b.kind == .unknown ? 74 : 46
            out.append(LabelSlot(id: b.id, y: y, block: b))
        }
        return out
    }

    private var canvasHeight: CGFloat {
        let riverBottom = yOf(d.end) + 10
        var labelBottom: CGFloat = 0
        if let last = slots.last {
            labelBottom = last.y + (last.block.kind == .unknown ? 56 : 20)
        }
        return max(riverBottom, labelBottom)
    }

    var body: some View {
        let chipSlots: [LabelSlot] = slots.filter { (s: LabelSlot) -> Bool in s.block.kind == .unknown }
        Canvas { ctx, size in
            draw(&ctx, size)
        }
        .frame(maxWidth: .infinity)
        .frame(height: canvasHeight)
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(chipSlots) { slot in
                    Button { onName(slot.block) } label: { nameChip }
                        .buttonStyle(.plain)
                        .padding(.leading, labelX)
                        .padding(.top, slot.y + 24)
                }
            }
        }
    }

    private var nameChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.system(size: 12, weight: .semibold))
            Text("Name it").font(V3Font.text(12, .semibold))
        }
        .foregroundStyle(V3.t1)
        .frame(width: 78, height: 28)
        .background(V3.card2, in: Capsule())
    }

    private func riverPath(_ s: [Sample]) -> Path {
        let left: [CGPoint] = s.map { (p: Sample) -> CGPoint in
            CGPoint(x: cx - widthOf(p.bpm) / 2, y: yOf(p.t))
        }
        let right: [CGPoint] = s.reversed().map { (p: Sample) -> CGPoint in
            CGPoint(x: cx + widthOf(p.bpm) / 2, y: yOf(p.t))
        }
        var path = v3SmoothPath(left)
        if let r0 = right.first { path.addLine(to: r0) }
        StrainCurve.add(&path, right)
        path.closeSubpath()
        return path
    }

    private func halfWidth(near t: Date, _ s: [Sample]) -> CGFloat {
        guard var best = s.first else { return 0 }
        var bestDist = abs(best.t.timeIntervalSince(t))
        for x in s {
            let dist = abs(x.t.timeIntervalSince(t))
            if dist < bestDist {
                best = x
                bestDist = dist
            }
        }
        return widthOf(best.bpm) / 2
    }

    private func batteryMark(_ ctx: inout GraphicsContext, _ v: Double, _ y: CGFloat) {
        let label = Text("\(Int(v.rounded()))").font(V3Font.num(12, .semibold)).foregroundStyle(V3.energy)
        ctx.draw(label, at: CGPoint(x: 22, y: y), anchor: .trailing)
        var line = Path()
        line.move(to: CGPoint(x: 28, y: y))
        line.addLine(to: CGPoint(x: cx - 52, y: y))
        ctx.stroke(line, with: .color(V3.energy.opacity(0.3)), lineWidth: 1)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width
        let s = samples
        if s.count < 2 { return }
        let river = riverPath(s)

        for b in d.blocks {
            let y0 = yOf(b.start) + 1
            let y1 = yOf(b.end) - 1
            if y1 <= y0 { continue }
            var c = ctx
            c.clip(to: Path(CGRect(x: 0, y: y0, width: w, height: y1 - y0)))
            if b.kind == .unknown {
                c.stroke(river, with: .color(V3.t2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            } else {
                c.fill(river, with: .color(StrainStyle.color(b.kind)))
            }
        }

        for b in d.blocks where b.kind == .unknown {
            for k in 0..<2 {
                let t = k == 0 ? b.start : b.end
                let y = yOf(t) + (k == 0 ? 1.75 : -1.75)
                let half = halfWidth(near: t, s)
                var cap = Path()
                cap.move(to: CGPoint(x: cx - half, y: y))
                cap.addLine(to: CGPoint(x: cx + half, y: y))
                ctx.stroke(cap, with: .color(V3.t2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }

        if d.hasBattery {
            var lastB: CGFloat = -99
            for b in d.blocks {
                guard let v = b.batteryStart else { continue }
                let y = yOf(b.start)
                if y - lastB < 20 { continue }
                lastB = y
                batteryMark(&ctx, v, y)
            }
            if let z = d.batteryAtEnd {
                let y = yOf(d.end)
                if y - lastB >= 14 { batteryMark(&ctx, z, y) }
            }
        }

        for slot in slots {
            let b = slot.block
            let name = Text(b.short).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t1)
            ctx.draw(name, at: CGPoint(x: labelX, y: slot.y - 8), anchor: .leading)
            let added = Text("+" + StrainStyle.one(b.strainAdded)).font(V3Font.text(13, .semibold)).foregroundStyle(V3.strain)
            ctx.draw(added, at: CGPoint(x: w, y: slot.y - 8), anchor: .trailing)
            let when = Text("\(V3Format.hhmm(b.start)) · \(V3Format.duration(minutes: b.minutes))")
                .font(V3Font.text(12, .medium))
                .foregroundStyle(V3.t2)
            ctx.draw(when, at: CGPoint(x: labelX, y: slot.y + 8), anchor: .leading)
        }
    }
}
