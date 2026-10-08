import SwiftUI

// Block detail sheet (V3 board): one block of the strain day. Strain and battery here are modelled from 15-minute heart rate.

struct StrainBlockV3Sheet: View {
    let block: StrainDayBlock
    let day: StrainDayData
    let onChanged: () -> Void
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    init(block: StrainDayBlock, day: StrainDayData, onChanged: @escaping () -> Void = {}) {
        self.block = block
        self.day = day
        self.onChanged = onChanged
    }

    var body: some View {
        ZStack(alignment: .top) {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    Capsule().fill(V3.chrome).frame(width: 36, height: 5).padding(.top, 8)
                    V3Header(date: dateLine, title: block.name) {
                        V3IconButton(symbol: "xmark") { dismiss() }
                    }
                    kindRow
                    statRow
                    heartCard
                    batteryCard
                    footnote
                    V3Button(title: block.activity == nil ? "Name this block" : "Edit this block", symbol: "pencil", secondary: true) {
                        editing = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $editing) {
            ActivityEditSheet(
                mode: editMode,
                ble: bleManager,
                onSaved: {
                    onChanged()
                    dismiss()
                },
                onDeleted: {
                    onChanged()
                    dismiss()
                }
            )
        }
        .presentationDetents([.large])
        .presentationBackground(V3.sheet)
        .lucidRendered(.blockDetail)
    }

    // MARK: Data

    private var editMode: ActivityEditMode {
        if let a = block.activity { return .edit(a) }
        return .create(defaultStart: block.start)
    }

    private var dateLine: String {
        V3Format.shortDay(block.start) + " · " + V3Format.hhmm(block.start) + " to " + V3Format.hhmm(block.end)
    }

    private var slices: [BlockV3Slice] {
        var out: [BlockV3Slice] = []
        for p in day.hr.sorted(by: { $0.at < $1.at }) {
            let s: Date = max(p.at, block.start)
            let e: Date = min(p.at.addingTimeInterval(900), block.end)
            let m: Double = e.timeIntervalSince(s) / 60
            if m <= 0 { continue }
            out.append(BlockV3Slice(at: p.at, bpm: p.bpm, minutes: m, mid: s.addingTimeInterval(e.timeIntervalSince(s) / 2)))
        }
        return out
    }

    private var avgHR: Double? {
        if let a = block.hrAvg { return a }
        let list: [BlockV3Slice] = slices
        let mins: Double = list.reduce(0) { (acc: Double, s: BlockV3Slice) -> Double in acc + s.minutes }
        if mins <= 0 { return nil }
        let weighted: Double = list.reduce(0) { (acc: Double, s: BlockV3Slice) -> Double in acc + s.bpm * s.minutes }
        return weighted / mins
    }

    private var tickDates: [Date] {
        var out: [Date] = []
        let next: Date? = Calendar.current.nextDate(after: block.start, matching: DateComponents(minute: 0, second: 0),
                                                    matchingPolicy: .nextTime)
        guard var t = next else { return out }
        let step: Double = max(1, (block.minutes / 60 / 5).rounded(.up))
        while t < block.end && out.count < 12 {
            out.append(t)
            t = t.addingTimeInterval(step * 3600)
        }
        return out
    }

    private func zoneMinutes(_ list: [BlockV3Slice]) -> (below: Double, zone1: Double, zone2: Double) {
        let z1: Double = StrainDayBuilder.zoneStarts[0]
        let z2: Double = StrainDayBuilder.zoneStarts[1]
        var below: Double = 0
        var one: Double = 0
        var two: Double = 0
        for s in list {
            if s.bpm >= z2 { two += s.minutes } else if s.bpm >= z1 { one += s.minutes } else { below += s.minutes }
        }
        return (below, one, two)
    }

    // MARK: Sections

    private var kindRow: some View {
        HStack(spacing: 8) {
            BlockV3Chip(text: BlockV3Kind.label(block.kind), color: BlockV3Kind.chipColor(block.kind))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            if day.hasHR {
                BlockV3Stat(label: "Strain added", value: V3Format.signed(block.strainAdded, decimals: 1), color: V3.strain)
            } else {
                BlockV3Stat(label: "Strain added", value: "No data", small: true)
            }
            if let a = avgHR {
                BlockV3Stat(label: "Average HR", value: String(Int(a.rounded())), unit: "bpm")
            } else {
                BlockV3Stat(label: "Average HR", value: "No data", small: true)
            }
            if day.hasHR {
                BlockV3Stat(label: "Day's load", value: String(format: "%.0f", block.loadShare), unit: "%")
            } else {
                BlockV3Stat(label: "Day's load", value: "No data", small: true)
            }
        }
    }

    private var heartCard: some View {
        let list: [BlockV3Slice] = slices
        return V3Card {
            V3CardHeader(icon: "heart.fill", iconColor: V3.heart, title: "Heart rate", trailing: heartTrailing(list))
            if list.count >= 2 {
                BlockV3HRChart(slices: list, start: block.start, end: block.end, avg: avgHR ?? 0, ticks: tickDates)
                    .padding(.top, 14)
                zoneLegend(list)
            } else {
                V3EmptyLine(text: "Not enough heart rate in this window to draw a curve.")
                    .padding(.top, 14)
            }
        }
    }

    private func heartTrailing(_ list: [BlockV3Slice]) -> String? {
        guard let a = avgHR, let peak = list.map({ $0.bpm }).max() else { return nil }
        return "average " + String(Int(a.rounded())) + " · peak " + String(Int(peak.rounded()))
    }

    private func zoneLegend(_ list: [BlockV3Slice]) -> some View {
        let z: (below: Double, zone1: Double, zone2: Double) = zoneMinutes(list)
        return HStack(alignment: .top, spacing: 8) {
            V3LegendItem(label: "Below zone 1", value: V3Format.duration(minutes: z.below))
            V3LegendItem(label: "Zone 1", value: V3Format.duration(minutes: z.zone1))
            V3LegendItem(label: "Zone 2 and up", value: V3Format.duration(minutes: z.zone2))
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var batteryCard: some View {
        if let before = block.batteryStart, let after = block.batteryEnd {
            V3Card {
                V3CardHeader(icon: "bolt.fill", iconColor: V3.energy, title: "Body battery",
                             trailing: V3Format.hhmm(block.start) + " to " + V3Format.hhmm(block.end))
                BlockV3BatteryBar(before: before, after: after)
                    .padding(.top, 14)
                HStack(alignment: .top, spacing: 8) {
                    V3LegendItem(label: "Before", value: String(Int(before.rounded())))
                    V3LegendItem(label: "After", value: String(Int(after.rounded())))
                    V3LegendItem(label: "Used", value: String(Int(block.drained.rounded())), valueColor: V3.energy)
                }
                .padding(.top, 14)
            }
        }
    }

    private var footnote: some View {
        Text(day.batteryLive
             ? "Strain added is modelled from your heart rate in 15-minute steps."
             : "Strain added and body battery are modelled from your heart rate in 15-minute steps.")
            .font(V3Font.text(12)).foregroundStyle(V3.t2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - Models

private struct BlockV3Slice {
    let at: Date
    let bpm: Double
    let minutes: Double
    let mid: Date
}

private enum BlockV3Kind {
    static func label(_ k: StrainBlockKind) -> String {
        switch k {
        case .ride: return "Ride"
        case .work: return "Work"
        case .play: return "Play"
        case .rest: return "Rest"
        case .unknown: return "Unlabelled"
        }
    }

    static func chipColor(_ k: StrainBlockKind) -> Color {
        switch k {
        case .ride: return V3.ride
        case .work: return V3.work
        case .play: return V3.play
        case .rest: return V3.t2
        case .unknown: return V3.t2
        }
    }
}

// MARK: - Pieces

private struct BlockV3Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(V3Font.text(12, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct BlockV3Stat: View {
    let label: String
    let value: String
    var unit: String = ""
    var color: Color = V3.t1
    var small = false

    var body: some View {
        V3Card(padding: 14) {
            VStack(spacing: 6) {
                Text(label).font(V3Font.text(12, .semibold)).foregroundStyle(V3.t2).lineLimit(1).minimumScaleFactor(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(small ? V3Font.text(15, .semibold) : V3Font.num(26))
                        .tracking(small ? 0 : -0.78)
                        .foregroundStyle(small ? V3.t2 : color)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if !unit.isEmpty { Text(unit).font(V3Font.text(14)).foregroundStyle(V3.t2) }
                }
                .frame(minHeight: 32)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BlockV3HRChart: View {
    let slices: [BlockV3Slice]
    let start: Date
    let end: Date
    let avg: Double
    let ticks: [Date]

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = size.width
            let plotH: CGFloat = 120
            let top: CGFloat = 24
            let bottom: CGFloat = 8
            let span: Double = max(end.timeIntervalSince(start), 1)
            let zone: Double = StrainDayBuilder.zoneStarts[0]
            let bpms: [Double] = slices.map { $0.bpm }
            let dMin: Double = bpms.min() ?? 0
            let dMax: Double = bpms.max() ?? 1
            let lo: Double = max(0, (min(dMin, avg > 0 ? avg : dMin) - 6).rounded(.down))
            var hiGuess: Double = (dMax + 10).rounded(.up)
            if dMax >= zone - 20 { hiGuess = max(hiGuess, zone + 5) }
            let hi: Double = hiGuess
            let dom: Double = max(hi - lo, 1)
            func xOf(_ d: Date) -> CGFloat {
                let t: Double = min(max(d.timeIntervalSince(start) / span, 0), 1)
                return CGFloat(t) * w
            }
            func yOf(_ v: Double) -> CGFloat {
                top + CGFloat(1 - (v - lo) / dom) * (plotH - top - bottom)
            }
            let pts: [CGPoint] = slices.map { CGPoint(x: xOf($0.mid), y: yOf($0.bpm)) }

            if lo <= zone && zone <= hi {
                var zl = Path()
                zl.move(to: CGPoint(x: 0, y: yOf(zone)))
                zl.addLine(to: CGPoint(x: w, y: yOf(zone)))
                ctx.stroke(zl, with: .color(V3.heart.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            }
            if avg > 0 {
                var al = Path()
                al.move(to: CGPoint(x: 0, y: yOf(avg)))
                al.addLine(to: CGPoint(x: w, y: yOf(avg)))
                ctx.stroke(al, with: .color(V3.t3), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            if let a = pts.first, let z = pts.last {
                var area = v3SmoothPath(pts)
                area.addLine(to: CGPoint(x: z.x, y: plotH))
                area.addLine(to: CGPoint(x: a.x, y: plotH))
                area.closeSubpath()
                let fade = Gradient(colors: [V3.heart.opacity(0.28), V3.heart.opacity(0)])
                ctx.fill(area, with: .linearGradient(fade, startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: plotH)))
            }
            ctx.stroke(v3SmoothPath(pts), with: .color(V3.heart), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            if lo <= zone && zone <= hi {
                let zt = Text("zone 1 starts at " + String(Int(zone))).font(V3Font.text(12)).foregroundColor(V3.t2)
                let rz = ctx.resolve(zt)
                let sz: CGSize = rz.measure(in: CGSize(width: w, height: 40))
                // v115: the chip moves to the left when the peak dot sits on the right, so the dot never covers it.
                let peakX: CGFloat = slices.max(by: { $0.bpm < $1.bpm }).map { xOf($0.mid) } ?? 0
                let onRight: Bool = peakX < w * 0.5
                let chipX: CGFloat = onRight ? w - sz.width - 10 : 0
                let chip = CGRect(x: chipX, y: yOf(zone) - sz.height - 9, width: sz.width + 10, height: sz.height + 5)
                ctx.fill(Path(roundedRect: chip, cornerRadius: 6), with: .color(V3.card.opacity(0.9)))
                ctx.draw(rz, at: CGPoint(x: onRight ? w - 5 : 5, y: yOf(zone) - 6.5),
                         anchor: onRight ? .bottomTrailing : .bottomLeading)
            }

            if let peak = slices.max(by: { $0.bpm < $1.bpm }) {
                let p = CGPoint(x: xOf(peak.mid), y: yOf(peak.bpm))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7.5, y: p.y - 7.5, width: 15, height: 15)), with: .color(V3.card))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(V3.heart))
                let text = String(Int(peak.bpm.rounded())) + " bpm · " + V3Format.hhmm(peak.at)
                let label = Text(text).font(V3Font.text(12, .semibold)).foregroundColor(V3.t1)
                let lx: CGFloat = min(max(p.x, 56), w - 56)
                ctx.draw(label, at: CGPoint(x: lx, y: p.y - 11), anchor: .bottom)
            }

            let startLabel = Text(V3Format.hhmm(start)).font(V3Font.text(11)).foregroundColor(V3.t3)
            ctx.draw(startLabel, at: CGPoint(x: 0, y: plotH + 12), anchor: .leading)
            for t in ticks {
                let x: CGFloat = xOf(t)
                if x < 64 || x > w - 22 { continue }   // v115: 44 let "06:00" overlap the start label
                let tl = Text(V3Format.hhmm(t)).font(V3Font.text(11)).foregroundColor(V3.t3)
                ctx.draw(tl, at: CGPoint(x: x, y: plotH + 12), anchor: .center)
            }
        }
        .frame(height: 142)
    }
}

private struct BlockV3BatteryBar: View {
    let before: Double
    let after: Double

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = size.width
            func xOf(_ v: Double) -> CGFloat {
                CGFloat(min(max(v, 0), 100) / 100) * w
            }
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 1, width: w, height: 12), cornerRadius: 6), with: .color(V3.track))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 1, width: xOf(after), height: 12), cornerRadius: 6),
                     with: .color(V3.energy.opacity(0.35)))
            let used: CGFloat = xOf(before) - xOf(after) - 2
            if used > 0.5 {
                ctx.fill(Path(roundedRect: CGRect(x: xOf(after) + 2, y: 1, width: used, height: 12), cornerRadius: 4),
                         with: .color(V3.energy))
            }
        }
        .frame(height: 14)
    }
}
