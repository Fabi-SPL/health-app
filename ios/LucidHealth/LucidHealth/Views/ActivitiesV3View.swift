import SwiftUI
import Charts
import MapKit

// MARK: - Activities tab: recent workouts, a detail sheet per workout, and the shared start sheet.

struct ActivitiesV3View: View {
    let isSelected: Bool
    @EnvironmentObject private var bleManager: BLEManager
    @State private var workouts: [SupabaseClient.WorkoutRecord] = []
    @State private var types: [SupabaseClient.WorkoutType] = []
    @State private var loaded = false
    @State private var openSession: SupabaseClient.WorkoutSession? = nil
    @State private var liveSession: SupabaseClient.WorkoutSession? = nil
    @State private var detailTarget: SupabaseClient.WorkoutRecord? = nil
    @State private var showStart = false
    @State private var autoOpened = false

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    V3Header(date: "Your workouts", title: "Activities") {
                        V3IconButton(symbol: "plus") {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showStart = true
                        }
                    }
                    if let o = openSession { resumeCard(o) }
                    ActivityWeekCard(workouts: workouts)
                    listCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
        .task(id: isSelected) {
            guard isSelected else { return }
            await load()
            await autoOpenForScreenshot()
        }
        .sheet(item: $detailTarget) { (w: SupabaseClient.WorkoutRecord) in
            ActivityDetailSheet(record: w) { Task { await load() } }
        }
        .sheet(isPresented: $showStart) {
            WorkoutStartSheet(types: types) { (s: SupabaseClient.WorkoutSession) in
                showStart = false
                openSession = s
                liveSession = s
            }
        }
        .fullScreenCover(item: $liveSession, onDismiss: { Task { await load() } }) { (s: SupabaseClient.WorkoutSession) in
            LiveRideV3View(session: s) { liveSession = nil }
                .environmentObject(bleManager)
        }
        .lucidRendered(.activities)
    }

    private func load() async {
        if ActivityMock.active {
            workouts = ActivityMock.records()
            loaded = true
            return
        }
        async let recent = SupabaseClient.shared.workoutRecent(limit: 30)
        async let typeList = SupabaseClient.shared.fetchWorkoutTypes()
        async let openNow = SupabaseClient.shared.workoutOpen()
        let r = await recent
        let t = await typeList
        let o = await openNow
        if Task.isCancelled { return }
        workouts = r.sorted { $0.startedAt > $1.startedAt }
        if !t.isEmpty { types = t }
        openSession = o
        loaded = true
    }

    private func autoOpenForScreenshot() async {
        guard ActivityMock.active, !autoOpened else { return }
        autoOpened = true
        try? await Task.sleep(for: .seconds(1.2))
        switch LucidScreen.current {
        case .activityRoute, .activityRouteLow: detailTarget = workouts.first { $0.id == ActivityMock.walkId }
        case .activityIndoor: detailTarget = workouts.first { $0.id == ActivityMock.bikeId }
        case .workoutStart: showStart = true
        default: break
        }
    }

    private func resumeCard(_ o: SupabaseClient.WorkoutSession) -> some View {
        Button { liveSession = o } label: {
            V3Card {
                HStack(spacing: 12) {
                    V3IconWell(symbol: "play.fill", color: V3.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(o.label) in progress").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1).lineLimit(1)
                        Text("Started \(V3Format.hhmm(o.startedAt))").font(V3Font.text(12)).foregroundStyle(V3.t2)
                    }
                    Spacer(minLength: 8)
                    Text("Resume").font(V3Font.text(13, .semibold)).foregroundStyle(V3.green)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var listCard: some View {
        V3Card {
            V3CardHeader(icon: "list.bullet", iconColor: V3.t2, title: "Recent", trailing: workouts.isEmpty ? nil : "\(workouts.count)")
            if workouts.isEmpty {
                V3EmptyLine(text: loaded ? "No workouts yet" : "Loading")
            } else {
                ForEach(workouts.indices, id: \.self) { (i: Int) in
                    Button { detailTarget = workouts[i] } label: { ActivityRow(w: workouts[i], first: i == 0) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Formatting and zones

enum ActivityFormat {
    static func duration(_ sec: Int) -> String { V3Format.duration(minutes: Double(max(sec, 60)) / 60) }

    static func km(_ v: Double) -> String { String(format: v >= 100 ? "%.0f" : "%.2f", v) }

    static func source(_ s: String?) -> String {
        switch s {
        case "gps": return "GPS"
        case "pedometer": return "Steps"
        case "manual": return "Manual"
        default: return ""
        }
    }

    static func pace(_ minPerKm: Double) -> String {
        let total = Int((minPerKm * 60).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func steps(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func usesPace(_ typeKey: String) -> Bool { typeKey == "walk" || typeKey == "run" }

    static func span(_ a: Date, _ b: Date) -> String { V3Format.hhmm(a) + " to " + V3Format.hhmm(b) }
}

/// Karvonen cut points, the same ones the server uses for zones_min (0.35 / 0.55 / 0.70 / 0.85 of reserve).
struct ActivityZones {
    let rest: Double
    let max: Double

    static let colors: [Color] = [V3.t2, V3.energy, V3.strain, V3.amber, V3.red]

    func index(_ hr: Int) -> Int {
        let p: Double = (Double(hr) - rest) / Swift.max(max - rest, 1)
        if p < 0.35 { return 0 }
        if p < 0.55 { return 1 }
        if p < 0.70 { return 2 }
        if p < 0.85 { return 3 }
        return 4
    }
}

// MARK: - List pieces

private struct ActivityEnvChip: View {
    let outdoor: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: outdoor ? "sun.max.fill" : "house.fill").font(.system(size: 9, weight: .bold))
            Text(outdoor ? "Outside" : "Indoor").font(V3Font.text(11, .semibold))
        }
        .foregroundStyle(outdoor ? V3.green : V3.t2)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(outdoor ? V3.green.opacity(0.14) : V3.card2, in: Capsule())
    }
}

private struct ActivityRow: View {
    let w: SupabaseClient.WorkoutRecord
    let first: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(V3.line).frame(height: 1) }
            HStack(alignment: .top, spacing: 12) {
                Text(w.emoji)
                    .font(.system(size: 18))
                    .frame(width: 38, height: 38)
                    .background(V3.strain.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(w.label).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1).lineLimit(1)
                        Spacer(minLength: 6)
                        if let env = w.environment { ActivityEnvChip(outdoor: env == "outdoor") }
                    }
                    Text(V3Format.shortDay(w.startedAt) + " · " + V3Format.hhmm(w.startedAt))
                        .font(V3Font.text(12)).foregroundStyle(V3.t2).monospacedDigit()
                    HStack(spacing: 14) {
                        stat(ActivityFormat.duration(w.durationSec), "")
                        if let d = w.distanceKm, d > 0 { stat(ActivityFormat.km(d), "km " + ActivityFormat.source(w.distanceSource)) }
                        if w.kcal > 0 { stat("\(w.kcal)", "kcal") }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.top, first ? 2 : 12)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
        }
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(V3Font.num(14, .semibold)).foregroundStyle(V3.t1)
            if !unit.isEmpty { Text(unit.trimmingCharacters(in: .whitespaces)).font(V3Font.text(12)).foregroundStyle(V3.t2) }
        }
        .lineLimit(1)
    }
}

private struct ActivityDay: Identifiable {
    let day: Date
    let label: String
    let minutes: Double
    var id: Date { day }
    var key: String { "\(Int(day.timeIntervalSince1970))" }
}

private struct ActivityWeekCard: View {
    let workouts: [SupabaseClient.WorkoutRecord]

    private var weekStart: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())
    }

    private var thisWeek: [SupabaseClient.WorkoutRecord] {
        let s = weekStart
        return workouts.filter { $0.startedAt >= s }
    }

    private var days: [ActivityDay] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEEE"
        return (0..<7).compactMap { (i: Int) -> ActivityDay? in
            guard let d = cal.date(byAdding: .day, value: i, to: weekStart) else { return nil }
            let mins: Double = thisWeek.filter { cal.isDate($0.startedAt, inSameDayAs: d) }
                .reduce(0) { $0 + Double($1.durationSec) / 60 }
            return ActivityDay(day: d, label: f.string(from: d), minutes: mins)
        }
    }

    var body: some View {
        let list = thisWeek
        let minutes: Double = list.reduce(0) { $0 + Double($1.durationSec) / 60 }
        let km: Double = list.reduce(0) { $0 + ($1.distanceKm ?? 0) }
        let kcal: Int = list.reduce(0) { $0 + $1.kcal }
        let rows: [ActivityDay] = days
        return V3Card {
            V3CardHeader(icon: "figure.run", iconColor: V3.strain, title: "This week", trailing: "\(list.count) workouts")
            HStack(alignment: .top, spacing: 8) {
                V3LegendItem(dot: V3.strain, label: "Time", value: V3Format.duration(minutes: minutes))
                V3LegendItem(dot: V3.energy, label: "Distance", value: km > 0 ? ActivityFormat.km(km) + " km" : "–")
                V3LegendItem(dot: V3.kcal, label: "Energy", value: kcal > 0 ? "\(kcal) kcal" : "–")
            }
            Chart(rows) { (d: ActivityDay) in
                BarMark(x: .value("Day", d.key), y: .value("Minutes", max(d.minutes, 1)), width: .ratio(0.5))
                    .foregroundStyle(d.minutes > 0 ? V3.strain : V3.track)
                    .cornerRadius(4)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: rows.map { $0.key }) { (value: AxisValue) in
                    AxisValueLabel {
                        Text(rows.first { $0.key == value.as(String.self) }?.label ?? "")
                            .font(V3Font.text(11)).foregroundStyle(V3.t2)
                    }
                }
            }
            .chartYScale(domain: 0...max(30, (rows.map { $0.minutes }.max() ?? 0) * 1.1))
            .frame(height: 96)
            .padding(.top, 14)
        }
    }
}

// MARK: - Detail

struct ActivityDetailSheet: View {
    let record: SupabaseClient.WorkoutRecord
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detail: SupabaseClient.WorkoutDetail? = nil
    @State private var zones: ActivityZones? = nil
    @State private var loading = true
    @State private var busy = false
    @State private var place = "Indoor"
    @State private var confirmIndoor = false
    @State private var confirmDelete = false

    private static var cachedZones: ActivityZones? = nil

    var body: some View {
        ZStack(alignment: .top) {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    Capsule().fill(V3.chrome).frame(width: 36, height: 5).padding(.top, 8)
                    V3Header(date: dateLine, title: record.emoji + " " + record.label) {
                        V3IconButton(symbol: "xmark") { dismiss() }
                    }
                    if let d = detail {
                        if showsRealTimes(d) { realTimesCard(d) }
                        if d.hasRoute { routeCard(d) }
                        ActivityStatsGrid(d: d)
                        heartCard(d)
                        zonesCard(d)
                        placeCard(d)
                    } else {
                        V3Card { V3EmptyLine(text: loading ? "Loading" : "No data") }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(LucidScreen.current == .activityRouteLow ? .bottom : nil)
        }
        .presentationDetents([.large])
        .presentationBackground(V3.sheet)
        .task { await load() }
        .onChange(of: place) { _, new in placeChanged(new) }
        .confirmationDialog("Indoor deletes the route", isPresented: $confirmIndoor, titleVisibility: .visible) {
            Button("Make it indoor", role: .destructive) { Task { await setEnvironment("indoor") } }
            Button("Keep outside", role: .cancel) { place = "Outside" }
        }
        .confirmationDialog("Delete the route?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete route", role: .destructive) { Task { await deleteRoute() } }
            Button("Keep", role: .cancel) {}
        }
        .lucidRendered(.activityRoute, .activityRouteLow, .activityIndoor)
    }

    private var dateLine: String {
        let start: Date = detail?.startedAt ?? record.startedAt
        let end: Date = detail?.endedAt ?? start.addingTimeInterval(TimeInterval(detail?.durationSec ?? record.durationSec))
        return V3Format.shortDay(start) + " · " + ActivityFormat.span(start, end)
    }

    // MARK: Loading and actions

    private func load() async {
        if ActivityMock.active {
            apply(ActivityMock.detail(record.id))
            zones = ActivityMock.zones
            loading = false
            return
        }
        async let d = SupabaseClient.shared.workoutDetail(id: record.id)
        if Self.cachedZones == nil, let ref = await SupabaseClient.shared.workoutHRRef() {
            Self.cachedZones = ActivityZones(rest: ref.rest, max: ref.max)
        }
        zones = Self.cachedZones
        if let got = await d { apply(got) }
        loading = false
    }

    private func apply(_ d: SupabaseClient.WorkoutDetail) {
        detail = d
        place = d.isOutdoor ? "Outside" : "Indoor"
    }

    private func placeChanged(_ new: String) {
        guard let d = detail else { return }
        let outdoor = new == "Outside"
        if outdoor == d.isOutdoor { return }
        if !outdoor && d.hasRoute {
            confirmIndoor = true
            return
        }
        Task { await setEnvironment(outdoor ? "outdoor" : "indoor") }
    }

    private func setEnvironment(_ env: String) async {
        guard !ActivityMock.active else { return }
        busy = true
        await SupabaseClient.shared.workoutSetEnvironment(id: record.id, environment: env)
        if let d = await SupabaseClient.shared.workoutDetail(id: record.id) { apply(d) }
        busy = false
        onChanged()
    }

    private func deleteRoute() async {
        guard !ActivityMock.active else { return }
        busy = true
        await SupabaseClient.shared.workoutDeleteRoute(id: record.id)
        if let d = await SupabaseClient.shared.workoutDetail(id: record.id) { apply(d) }
        busy = false
        onChanged()
    }

    private func moveTimes(_ toDetected: Bool) async {
        guard !ActivityMock.active else { return }
        busy = true
        var d: SupabaseClient.WorkoutDetail? = nil
        if toDetected {
            d = await SupabaseClient.shared.workoutApplyDetected(id: record.id)
        } else {
            d = await SupabaseClient.shared.workoutRevertLogged(id: record.id)
        }
        if let d {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            apply(d)
            onChanged()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        busy = false
    }

    // MARK: Cards

    private func routeCard(_ d: SupabaseClient.WorkoutDetail) -> some View {
        V3Card(padding: 12) {
            ActivityRouteMap(route: d.route)
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                Circle().fill(V3.green).frame(width: 7, height: 7)
                Text("Start").font(V3Font.text(12)).foregroundStyle(V3.t2)
                Circle().fill(V3.red).frame(width: 7, height: 7).padding(.leading, 6)
                Text("Finish").font(V3Font.text(12)).foregroundStyle(V3.t2)
                Spacer(minLength: 8)
                if let km = d.distanceKm {
                    Text(ActivityFormat.km(km) + " km").font(V3Font.num(13, .semibold)).foregroundStyle(V3.t1)
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 4)
        }
    }

    private func loggedWindow(_ d: SupabaseClient.WorkoutDetail) -> (Date, Date) {
        let s: Date = d.loggedStart ?? d.startedAt
        let e: Date = d.loggedEnd ?? d.endedAt ?? s.addingTimeInterval(TimeInterval(d.durationSec))
        return (s, e)
    }

    private func showsRealTimes(_ d: SupabaseClient.WorkoutDetail) -> Bool {
        if d.timesMoved { return true }
        guard let ds = d.detectedStart, let de = d.detectedEnd else { return false }
        let (ls, le) = loggedWindow(d)
        return abs(ds.timeIntervalSince(ls)) >= 180 || abs(de.timeIntervalSince(le)) >= 180
    }

    private func realTimesCard(_ d: SupabaseClient.WorkoutDetail) -> some View {
        let (ls, le) = loggedWindow(d)
        let ds: Date = d.detectedStart ?? ls
        let de: Date = d.detectedEnd ?? le
        return V3Card {
            V3CardHeader(icon: "clock.arrow.circlepath", iconColor: V3.green, title: "Real start and end",
                         trailing: d.timesMoved ? "Applied" : nil)
            Text("Your heart rate says you started at \(V3Format.hhmm(ds)) and stopped at \(V3Format.hhmm(de))")
                .font(V3Font.text(15, .semibold))
                .foregroundStyle(V3.t1)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                V3LegendItem(dot: V3.t3, label: "Logged", value: ActivityFormat.span(ls, le))
                V3LegendItem(dot: V3.green, label: "Heart rate", value: ActivityFormat.span(ds, de))
            }
            .padding(.top, 12)
            Group {
                if d.timesMoved {
                    V3Button(title: busy ? "Working" : "Undo", symbol: "arrow.uturn.backward", secondary: true) {
                        Task { await moveTimes(false) }
                    }
                } else {
                    V3Button(title: busy ? "Working" : "Use these times", symbol: "checkmark") {
                        Task { await moveTimes(true) }
                    }
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
            .padding(.top, 14)
        }
    }

    private func heartCard(_ d: SupabaseClient.WorkoutDetail) -> some View {
        let trailing: String? = d.hrAvg.map { a in "average \(a)" + (d.hrPeak.map { " · peak \($0)" } ?? "") }
        let (ls, le) = loggedWindow(d)
        return V3Card {
            V3CardHeader(icon: "heart.fill", iconColor: V3.heart, title: "Heart rate", trailing: trailing)
            if d.hrSeries.count >= 2 {
                ActivityHRChart(series: d.hrSeries, zones: zones, logged: (ls, le),
                                detected: d.detectedStart.flatMap { s in d.detectedEnd.map { (s, $0) } })
                    .frame(height: 170)
                    .padding(.top, 6)
                HStack(spacing: 14) {
                    legendSwatch(V3.t1.opacity(0.10), "Logged", dashed: false)
                    if d.detectedStart != nil { legendSwatch(V3.green, "Heart rate start and end", dashed: true) }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            } else {
                V3EmptyLine(text: "No heart rate")
            }
        }
    }

    private func legendSwatch(_ color: Color, _ text: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            if dashed {
                Rectangle().fill(color).frame(width: 2, height: 12)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 12)
            }
            Text(text).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(1)
        }
    }

    private func zonesCard(_ d: SupabaseClient.WorkoutDetail) -> some View {
        let total: Int = d.zonesMin.reduce(0, +)
        return V3Card {
            V3CardHeader(icon: "chart.bar.fill", iconColor: V3.strain, title: "Zones", trailing: total > 0 ? "\(total) min" : nil)
            if total > 0 {
                ActivityZoneBar(minutes: d.zonesMin).frame(height: 14)
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<5, id: \.self) { (i: Int) in
                        V3LegendItem(dot: ActivityZones.colors[i], label: "Z\(i + 1)", value: "\(d.zonesMin[i])m")
                    }
                }
                .padding(.top, 12)
            } else {
                V3EmptyLine(text: "No heart rate")
            }
        }
    }

    private func placeCard(_ d: SupabaseClient.WorkoutDetail) -> some View {
        V3Card {
            V3CardHeader(icon: place == "Outside" ? "sun.max.fill" : "house.fill",
                         iconColor: place == "Outside" ? V3.green : V3.t2, title: "Where")
            V3Segmented(options: ["Indoor", "Outside"], selection: $place)
                .disabled(busy)
            if d.hasRoute {
                V3Button(title: "Delete route", symbol: "trash", secondary: true) { confirmDelete = true }
                    .disabled(busy)
                    .padding(.top, 12)
            }
        }
    }
}

private struct ActivityStatsGrid: View {
    let d: SupabaseClient.WorkoutDetail

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let value: String
        let unit: String
        let sub: String?
    }

    private var items: [Item] {
        var out: [Item] = [Item(id: "Time", icon: "timer", color: V3.strain, value: ActivityFormat.duration(d.durationSec), unit: "", sub: nil)]
        if let km = d.distanceKm, km > 0 {
            out.append(Item(id: "Distance", icon: "point.topleft.down.to.point.bottomright.curvepath", color: V3.energy,
                            value: ActivityFormat.km(km), unit: "km", sub: ActivityFormat.source(d.distanceSource)))
        }
        if ActivityFormat.usesPace(d.typeKey), let p = d.paceMinPerKm, p > 0 {
            out.append(Item(id: "Pace", icon: "speedometer", color: V3.rem, value: ActivityFormat.pace(p), unit: "/km", sub: nil))
        } else if let v = d.kmh, v > 0 {
            out.append(Item(id: "Speed", icon: "speedometer", color: V3.rem, value: String(format: "%.1f", v), unit: "km/h", sub: nil))
        }
        out.append(Item(id: "Energy", icon: "flame.fill", color: V3.kcal, value: "\(d.kcal)", unit: "kcal",
                        sub: d.kcalActive.map { "\($0) active" }))
        if let a = d.hrAvg {
            out.append(Item(id: "Heart rate", icon: "heart.fill", color: V3.heart, value: "\(a)", unit: "avg",
                            sub: d.hrPeak.map { "peak \($0)" }))
        }
        if let s = d.steps, s > 0 {
            out.append(Item(id: "Steps", icon: "shoeprints.fill", color: V3.green, value: ActivityFormat.steps(s), unit: "", sub: nil))
        }
        if d.isOutdoor, let g = d.elevationGainM, g > 0 {
            out.append(Item(id: "Climb", icon: "mountain.2.fill", color: V3.sleep, value: "\(Int(g.rounded()))", unit: "m", sub: nil))
        }
        return out
    }

    var body: some View {
        V3Card(padding: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: 3),
                      alignment: .leading, spacing: 18) {
                ForEach(items) { (it: Item) in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Image(systemName: it.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(it.color)
                            Text(it.id).font(V3Font.text(12, .semibold)).foregroundStyle(V3.t2).lineLimit(1)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(it.value).font(V3Font.num(22)).tracking(-0.5).foregroundStyle(V3.t1)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            if !it.unit.isEmpty { Text(it.unit).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(1) }
                        }
                        .padding(.top, 6)
                        Text(it.sub ?? " ").font(V3Font.text(11, .semibold)).foregroundStyle(V3.t3).lineLimit(1)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ActivityHRBar: Identifiable {
    let t: Date
    let hr: Double
    let zone: Int
    let inside: Bool
    var id: Date { t }
}

private struct ActivityHRChart: View {
    let series: [SupabaseClient.WorkoutHRPoint]
    let zones: ActivityZones?
    let logged: (Date, Date)
    let detected: (Date, Date)?

    var body: some View {
        let bars: [ActivityHRBar] = series.map { p in
            ActivityHRBar(t: p.t, hr: Double(p.hr), zone: zones?.index(p.hr) ?? -1,
                          inside: p.t >= logged.0.addingTimeInterval(-60) && p.t <= logged.1)
        }
        let hrs: [Double] = bars.map { $0.hr }
        let lo: Double = ((hrs.min() ?? 60) - 8).rounded(.down)
        let hi: Double = ((hrs.max() ?? 180) + 6).rounded(.up)
        let first: Date = bars.first?.t ?? logged.0
        let last: Date = (bars.last?.t ?? logged.1).addingTimeInterval(60)
        let spanMin: Double = last.timeIntervalSince(first) / 60
        let tickEvery: Int = spanMin > 150 ? 60 : spanMin > 75 ? 30 : 15
        return Chart {
            RectangleMark(xStart: .value("Logged start", logged.0), xEnd: .value("Logged end", logged.1),
                          yStart: .value("Low", lo), yEnd: .value("High", hi))
                .foregroundStyle(V3.t1.opacity(0.07))
            ForEach(bars) { (b: ActivityHRBar) in
                BarMark(x: .value("Minute", b.t, unit: .minute), yStart: .value("Low", lo), yEnd: .value("HR", b.hr))
                    .foregroundStyle(barColor(b))
            }
            if let det = detected {
                RuleMark(x: .value("Start", det.0))
                    .foregroundStyle(V3.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                RuleMark(x: .value("End", det.1))
                    .foregroundStyle(V3.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .chartXScale(domain: first...last)
        .chartYScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: tickEvery)) { (value: AxisValue) in
                AxisGridLine().foregroundStyle(V3.grid)
                AxisValueLabel {
                    if let t = value.as(Date.self) {
                        Text(V3Format.hhmm(t)).font(V3Font.text(11)).foregroundStyle(V3.t2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(V3.grid)
                AxisValueLabel().font(V3Font.text(11)).foregroundStyle(V3.t2)
            }
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private func barColor(_ b: ActivityHRBar) -> Color {
        let base: Color = b.zone >= 0 ? ActivityZones.colors[b.zone] : V3.heart
        return b.inside ? base : base.opacity(0.35)
    }
}

private struct ActivityZoneBar: View {
    let minutes: [Int]

    var body: some View {
        GeometryReader { g in
            let total: Double = Double(max(minutes.reduce(0, +), 1))
            let shown: [Int] = (0..<5).filter { minutes[$0] > 0 }
            let gaps: CGFloat = CGFloat(max(shown.count - 1, 0)) * 3
            HStack(spacing: 3) {
                ForEach(shown, id: \.self) { (i: Int) in
                    Capsule()
                        .fill(ActivityZones.colors[i])
                        .frame(width: max(6, (g.size.width - gaps) * CGFloat(Double(minutes[i]) / total)))
                }
            }
        }
    }
}

private struct ActivityRouteMap: View {
    let route: [[Double]]

    var body: some View {
        let coords: [CLLocationCoordinate2D] = route.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        Map(initialPosition: .rect(Self.rect(coords)), interactionModes: []) {
            MapPolyline(coordinates: coords)
                .stroke(V3.strain, lineWidth: 4)
            if let a = coords.first {
                Annotation("Start", coordinate: a) { Self.dot(V3.green) }
                    .annotationTitles(.hidden)
            }
            if let z = coords.last {
                Annotation("Finish", coordinate: z) { Self.dot(V3.red) }
                    .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    private static func dot(_ c: Color) -> some View {
        Circle().fill(c).frame(width: 12, height: 12).overlay(Circle().stroke(Color.white, lineWidth: 2))
    }

    private static func rect(_ coords: [CLLocationCoordinate2D]) -> MKMapRect {
        let pts: [MKMapPoint] = coords.map { MKMapPoint($0) }
        guard let f = pts.first else { return .world }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let w = max(maxX - minX, 400), h = max(maxY - minY, 400)
        return MKMapRect(x: minX - w * 0.15, y: minY - h * 0.25, width: w * 1.3, height: h * 1.5)
    }
}

// MARK: - Start sheet (shared with the Strain tab)

struct WorkoutStartSheet: View {
    let types: [SupabaseClient.WorkoutType]
    var initialKey: String? = nil
    let onStarted: (SupabaseClient.WorkoutSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var place = "Indoor"
    @State private var busy = false
    @State private var failed = false

    /// The server list, or the same six types when it cannot be reached.
    static let fallback: [SupabaseClient.WorkoutType] = [
        .init(id: "cardio_bike", label: "Cardio Bike", emoji: "\u{1F6B4}", category: "cardio", tracksDistance: true, tracksLoad: true, defaultEnvironment: "indoor"),
        .init(id: "bike_outdoor", label: "Bike (outside)", emoji: "\u{1F6B2}", category: "cardio", tracksDistance: true, tracksLoad: false, defaultEnvironment: "outdoor"),
        .init(id: "walk", label: "Walk", emoji: "\u{1F6B6}", category: "cardio", tracksDistance: true, tracksLoad: false, defaultEnvironment: "outdoor"),
        .init(id: "run", label: "Run", emoji: "\u{1F3C3}", category: "cardio", tracksDistance: true, tracksLoad: false, defaultEnvironment: "outdoor"),
        .init(id: "strength", label: "Gym", emoji: "\u{1F3CB}\u{FE0F}", category: "strength", tracksDistance: false, tracksLoad: false, defaultEnvironment: "indoor"),
        .init(id: "rowing", label: "Rowing", emoji: "\u{1F6A3}", category: "cardio", tracksDistance: true, tracksLoad: true, defaultEnvironment: "indoor"),
    ]

    private var list: [SupabaseClient.WorkoutType] { types.isEmpty ? Self.fallback : types }
    private var current: SupabaseClient.WorkoutType? { list.first { $0.id == selected } }

    var body: some View {
        ZStack(alignment: .top) {
            V3.sheet.ignoresSafeArea()
            VStack(spacing: 14) {
                Capsule().fill(V3.chrome).frame(width: 36, height: 5).padding(.top, 8)
                V3Header(date: "New workout", title: "Start") {
                    V3IconButton(symbol: "xmark") { dismiss() }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(list) { (t: SupabaseClient.WorkoutType) in typeCell(t) }
                }
                .sensoryFeedback(.selection, trigger: selected)
                V3Segmented(options: ["Indoor", "Outside"], selection: $place)
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    Image(systemName: place == "Outside" ? "location.fill" : "location.slash")
                        .font(.system(size: 11, weight: .semibold))
                    Text(place == "Outside" ? "Route by GPS" : "No GPS")
                        .font(V3Font.text(12, .semibold))
                }
                .foregroundStyle(place == "Outside" ? V3.green : V3.t2)
                Spacer(minLength: 0)
                if failed {
                    Text("Could not start. Check the connection.").font(V3Font.text(12)).foregroundStyle(V3.red)
                }
                V3Button(title: busy ? "Starting" : "Start", symbol: "play.fill") { start() }
                    .disabled(busy || current == nil)
                    .opacity(busy || current == nil ? 0.5 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .presentationDetents([.height(500)])
        .presentationBackground(V3.sheet)
        .onAppear {
            if selected.isEmpty { select(initialKey ?? list.first?.id ?? "") }
        }
        .lucidRendered(.workoutStart)
    }

    private func typeCell(_ t: SupabaseClient.WorkoutType) -> some View {
        let on: Bool = t.id == selected
        return Button { select(t.id) } label: {
            VStack(spacing: 6) {
                Text(t.emoji).font(.system(size: 24))
                Text(t.label).font(V3Font.text(12, .semibold)).foregroundStyle(on ? V3.t1 : V3.t2)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(V3.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? V3.strain : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func select(_ key: String) {
        selected = key
        if let t = list.first(where: { $0.id == key }) { place = t.isOutdoorByDefault ? "Outside" : "Indoor" }
    }

    private func start() {
        guard let t = current, !busy else { return }
        busy = true
        failed = false
        let outdoor: Bool = place == "Outside"
        Task {
            guard let s = await SupabaseClient.shared.workoutStart(type: t.id) else {
                busy = false
                failed = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            if outdoor != t.isOutdoorByDefault {
                await SupabaseClient.shared.workoutSetEnvironment(id: s.id, environment: outdoor ? "outdoor" : "indoor")
            }
            WorkoutTracker.shared.begin(session: s, outdoor: outdoor)
            busy = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onStarted(s)
        }
    }
}

// MARK: - Screenshot mock (CI only; a made-up week around the Tiergarten, no real data)

enum ActivityMock {
    static let walkId = "mock-walk"
    static let bikeId = "mock-bike"
    static let zones = ActivityZones(rest: 55, max: 195)

    static var active: Bool {
        switch LucidScreen.current {
        case .activities, .activityRoute, .activityIndoor, .workoutStart: return true
        default: return false
        }
    }

    private static func at(daysAgo: Int, _ h: Int, _ m: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return day.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
    }

    static func records() -> [SupabaseClient.WorkoutRecord] {
        func rec(_ id: String, _ key: String, _ label: String, _ emoji: String, _ start: Date, min: Int,
                 km: Double?, source: String?, kcal: Int, outdoor: Bool, route: Bool) -> SupabaseClient.WorkoutRecord {
            SupabaseClient.WorkoutRecord(
                id: id, label: label, emoji: emoji, startedAt: start, durationSec: min * 60, distanceKm: km,
                loadLevel: nil, rpe: nil, hrAvg: 120, kcal: kcal, kcalSource: "hr", kmh: nil,
                typeKey: key, environment: outdoor ? "outdoor" : "indoor", distanceSource: source,
                steps: nil, kcalActive: nil, kcalMethod: "hr", detectedStart: nil, detectedEnd: nil, hasRoute: route
            )
        }
        return [
            rec(walkId, "walk", "Walk", "\u{1F6B6}", at(daysAgo: 0, 10, 45), min: 57, km: 6.0, source: "gps", kcal: 400, outdoor: true, route: true),
            rec(bikeId, "cardio_bike", "Cardio Bike", "\u{1F6B4}", at(daysAgo: 1, 18, 0), min: 45, km: 18.0, source: "manual", kcal: 450, outdoor: false, route: false),
            rec("mock-gym", "strength", "Gym", "\u{1F3CB}\u{FE0F}", at(daysAgo: 2, 17, 30), min: 60, km: nil, source: nil, kcal: 300, outdoor: false, route: false),
            rec("mock-run", "run", "Run", "\u{1F3C3}", at(daysAgo: 3, 8, 0), min: 30, km: 5.0, source: "gps", kcal: 350, outdoor: true, route: true),
            rec("mock-row", "rowing", "Rowing", "\u{1F6A3}", at(daysAgo: 5, 19, 0), min: 25, km: 5.0, source: "manual", kcal: 250, outdoor: false, route: false),
            rec("mock-walk2", "walk", "Walk", "\u{1F6B6}", at(daysAgo: 8, 12, 0), min: 40, km: 3.0, source: "pedometer", kcal: 200, outdoor: true, route: false),
        ]
    }

    static func detail(_ id: String) -> SupabaseClient.WorkoutDetail {
        if id == walkId {
            let ls = at(daysAgo: 0, 10, 45), le = at(daysAgo: 0, 11, 42)
            let ds = at(daysAgo: 0, 10, 20)
            let series = hr(from: ds.addingTimeInterval(-900), to: le.addingTimeInterval(900), active: (ds, le), base: 72, work: 122)
            return make(id: id, key: "walk", label: "Walk", emoji: "\u{1F6B6}", outdoor: true, start: ls, end: le,
                        detected: (ds, le), series: series, km: 6.0, source: "gps", pace: 9.5, kmh: nil, steps: 8000,
                        climb: 20, kcal: 400, active: 300, route: tiergartenLoop())
        }
        let ls = at(daysAgo: 1, 18, 0), le = at(daysAgo: 1, 18, 45)
        let series = hr(from: ls.addingTimeInterval(-900), to: le.addingTimeInterval(900), active: (ls, le), base: 70, work: 150)
        return make(id: id, key: "cardio_bike", label: "Cardio Bike", emoji: "\u{1F6B4}", outdoor: false, start: ls, end: le,
                    detected: (ls.addingTimeInterval(60), le), series: series, km: 18.0, source: "manual", pace: nil, kmh: 24.0,
                    steps: nil, climb: nil, kcal: 450, active: 380, route: [])
    }

    private static func make(id: String, key: String, label: String, emoji: String, outdoor: Bool, start: Date, end: Date,
                             detected: (Date, Date), series: [SupabaseClient.WorkoutHRPoint], km: Double, source: String,
                             pace: Double?, kmh: Double?, steps: Int?, climb: Double?, kcal: Int, active: Int,
                             route: [[Double]]) -> SupabaseClient.WorkoutDetail {
        var mins: [Int] = [0, 0, 0, 0, 0]
        for p in series where p.t >= start && p.t < end { mins[zones.index(p.hr)] += 1 }
        let inside = series.filter { $0.t >= start && $0.t < end }.map { $0.hr }
        return SupabaseClient.WorkoutDetail(
            id: id, typeKey: key, label: label, emoji: emoji, environment: outdoor ? "outdoor" : "indoor",
            startedAt: start, endedAt: end, loggedStart: start, loggedEnd: end,
            detectedStart: detected.0, detectedEnd: detected.1, timesMoved: false,
            durationSec: Int(end.timeIntervalSince(start)), distanceKm: km, distanceSource: source,
            paceMinPerKm: pace, kmh: kmh, steps: steps, elevationGainM: climb,
            hrAvg: inside.isEmpty ? nil : inside.reduce(0, +) / inside.count, hrPeak: inside.max(),
            zonesMin: mins, hrSeries: series, kcal: kcal, kcalActive: active, kcalMethod: "hr",
            hasRoute: !route.isEmpty, route: route
        )
    }

    private static func hr(from a: Date, to b: Date, active: (Date, Date), base: Double, work: Double) -> [SupabaseClient.WorkoutHRPoint] {
        var out: [SupabaseClient.WorkoutHRPoint] = []
        var t = a
        var i = 0.0
        while t <= b {
            let since: Double = t.timeIntervalSince(active.0)
            let after: Double = t.timeIntervalSince(active.1)
            var level: Double = 0
            if since >= 0 && after <= 0 { level = min(1, since / 480) }
            else if after > 0 { level = max(0, 1 - after / 360) }
            let wobble: Double = sin(i * 0.7) * 4 + sin(i * 0.23) * 7
            let v: Double = base + (work - base) * level + wobble * (0.3 + 0.7 * level)
            out.append(SupabaseClient.WorkoutHRPoint(t: t, hr: Int(v.rounded())))
            t = t.addingTimeInterval(60)
            i += 1
        }
        return out
    }

    /// A made-up loop through the Tiergarten in Berlin.
    private static func tiergartenLoop() -> [[Double]] {
        (0...120).map { (k: Int) -> [Double] in
            let a: Double = Double(k) / 120 * 2 * .pi
            let lat: Double = 52.5142 + 0.0040 * sin(a) + 0.0006 * sin(3 * a)
            let lon: Double = 13.3560 + 0.0150 * cos(a) + 0.0012 * cos(2 * a + 0.6)
            return [lat, lon]
        }
    }
}
