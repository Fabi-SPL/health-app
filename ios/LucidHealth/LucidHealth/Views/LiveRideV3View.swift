import SwiftUI

// MARK: - Live workout on the approved V3 board (minerva/jobs/lh3-full, "Live ride").
// Speed, distance and the route map have no source, so the tiles are what the server does measure.

struct LiveRideV3View: View {
    let session: SupabaseClient.WorkoutSession
    let onClosed: () -> Void

    @State private var live: SupabaseClient.WorkoutLive? = nil
    @State private var showFinish = false
    @State private var showDiscard = false
    @State private var summary: SupabaseClient.WorkoutSummary? = nil
    @State private var finishing = false

    var body: some View {
        ZStack {
            V3.bg.ignoresSafeArea()
            if let summary {
                finishedBody(summary)
            } else {
                liveBody
            }
        }
        .task {
            while !Task.isCancelled && summary == nil {
                if let l = await SupabaseClient.shared.workoutLive(id: session.id) {
                    await MainActor.run { live = l }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .sheet(isPresented: $showFinish) {
            LiveRideFinishSheet(session: session, busy: $finishing) { km, load, rpe in
                Task {
                    await MainActor.run { finishing = true }
                    let s = await SupabaseClient.shared.workoutFinish(
                        id: session.id, distanceKm: km, load: load, rpe: rpe
                    )
                    await MainActor.run {
                        finishing = false
                        showFinish = false
                        if let s {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            summary = s
                        } else {
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                        }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationBackground(V3.sheet)
        }
        .confirmationDialog("Discard this workout?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep going", role: .cancel) {}
        }
    }

    // MARK: Live

    private var zoneIndex: Int {
        switch live?.zone ?? "" {
        case let z where z.hasPrefix("zone 5"): return 4
        case let z where z.hasPrefix("zone 4"): return 3
        case let z where z.hasPrefix("zone 3"): return 2
        case let z where z.hasPrefix("zone 2"): return 1
        default: return 0
        }
    }

    private var zoneColor: Color {
        switch zoneIndex {
        case 4: return V3.red
        case 3: return V3.amber
        case 2: return V3.strain
        case 1: return V3.energy
        default: return V3.t2
        }
    }

    private var zoneText: String {
        let z: String = live?.zone ?? "warm-up"
        guard let first = z.first else { return "Warm-up" }
        return first.uppercased() + z.dropFirst()
    }

    private var liveBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    topRow
                    clockBlock
                    heroBlock
                    statRow
                    zoneCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            footer
        }
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            Text(session.emoji)
                .font(.system(size: 15))
                .frame(width: 26, height: 26)
                .background(V3.strain.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(session.label).font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2).lineLimit(1)
            Spacer(minLength: 8)
            V3Pill(dot: V3.heart, text: "Live")
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }

    private var clockBlock: some View {
        VStack(spacing: 0) {
            Text("Elapsed").font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
            TimelineView(.periodic(from: session.startedAt, by: 1)) { ctx in
                Text(Self.clock(ctx.date.timeIntervalSince(session.startedAt)))
                    .font(V3Font.num(56))
                    .tracking(-2.8)
                    .foregroundStyle(V3.t1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var heroBlock: some View {
        LiveRideHeartRing(hr: live?.hrNow, zoneIndex: zoneIndex, zoneText: zoneText, zoneColor: zoneColor, hasLive: live != nil)
            .background(alignment: .center) { V3Glow(color: V3.strain) }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            LiveRideStat(label: "Energy", value: live.map { "\($0.kcal)" }, unit: "kcal", color: V3.kcal)
            LiveRideStat(label: "Average", value: live?.hrAvg.map { "\($0)" }, unit: "bpm", color: V3.t1)
            LiveRideStat(label: "Peak", value: live?.hrPeak.map { "\($0)" }, unit: "bpm", color: V3.heart)
        }
        .padding(.top, 16)
    }

    private var zoneCard: some View {
        V3Card {
            V3CardHeader(title: "Heart rate zone", trailing: live == nil ? nil : zoneText)
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(live != nil && i == zoneIndex ? zoneColor : V3.track)
                        .frame(height: live != nil && i == zoneIndex ? 8 : 5)
                }
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.25), value: zoneIndex)
        }
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            V3Button(title: "Discard", secondary: true) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showDiscard = true
            }
            V3Button(title: "Finish", symbol: "stop.fill") {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showFinish = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func discard() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await SupabaseClient.shared.workoutCancel(id: session.id)
            await MainActor.run { onClosed() }
        }
    }

    // MARK: Finished

    private func finishedBody(_ s: SupabaseClient.WorkoutSummary) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Text(session.emoji).font(.system(size: 44))
                Text(s.headline)
                    .font(V3Font.text(22, .bold))
                    .tracking(-0.66)
                    .foregroundStyle(V3.t1)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.horizontal, 12)
                if s.kcalSource != "hr" {
                    Text("Estimated from resistance, strap was off")
                        .font(V3Font.text(13))
                        .foregroundStyle(V3.t2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            }
            HStack(spacing: 10) {
                LiveRideStat(label: "Time", value: Self.clock(TimeInterval(s.durationSec)), unit: "", color: V3.t1)
                LiveRideStat(label: "Energy", value: "\(s.kcal)", unit: "kcal", color: V3.kcal)
                if let d = s.distanceKm {
                    LiveRideStat(label: "Distance", value: String(format: "%.1f", d), unit: "km", color: V3.t1)
                } else {
                    LiveRideStat(label: "Average", value: s.hrAvg.map { "\($0)" }, unit: "bpm", color: V3.heart)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            Spacer(minLength: 0)
            V3Button(title: "Done") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onClosed()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private static func clock(_ secs: TimeInterval) -> String {
        let t: Int = max(0, Int(secs))
        let h: Int = t / 3600, m: Int = (t % 3600) / 60, s: Int = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Private pieces

private struct LiveRideHeartRing: View {
    let hr: Int?
    let zoneIndex: Int
    let zoneText: String
    let zoneColor: Color
    let hasLive: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let hr {
                    V3Ring(progress: Double(zoneIndex + 1) / 5.0, color: V3.heart, lineWidth: 15)
                    VStack(spacing: 4) {
                        Text("\(hr)").font(V3Font.num(58)).tracking(-2.6).foregroundStyle(V3.t1)
                        Text("bpm").font(V3Font.text(13)).foregroundStyle(V3.t2)
                    }
                } else {
                    V3Ring(progress: 0, color: V3.heart, lineWidth: 15, dashed: true)
                    Text(hasLive ? "No data" : "Syncing")
                        .font(V3Font.text(24, .semibold))
                        .foregroundStyle(V3.t3)
                }
            }
            .frame(width: 172, height: 172)
            Text("Heart rate").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1).padding(.top, 10)
            Text(hr == nil ? "Waiting for the strap" : zoneText)
                .font(V3Font.text(12, .semibold))
                .foregroundStyle(hr == nil ? V3.t2 : zoneColor)
                .padding(.top, 2)
        }
        .fixedSize()
    }
}

private struct LiveRideStat: View {
    let label: String
    let value: String?
    let unit: String
    let color: Color

    var body: some View {
        V3Card(padding: 12) {
            VStack(spacing: 6) {
                Text(label).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2).lineLimit(1)
                if let value {
                    Text(value)
                        .font(V3Font.num(26))
                        .tracking(-0.78)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Text("No data").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t3).lineLimit(1)
                }
                Text(unit.isEmpty ? " " : unit).font(V3Font.text(12)).foregroundStyle(V3.t2)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Finish sheet (distance / resistance / effort)

private struct LiveRideFinishSheet: View {
    let session: SupabaseClient.WorkoutSession
    @Binding var busy: Bool
    let onSave: (Double?, Int?, Int?) -> Void

    @State private var kmText = ""
    @State private var load: Int? = nil
    @State private var rpe: Int? = nil
    @FocusState private var kmFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How was it?")
                .font(V3Font.text(22, .bold))
                .tracking(-0.66)
                .foregroundStyle(V3.t1)
                .padding(.top, 22)

            if session.tracksDistance { distanceField }

            if session.tracksLoad {
                scale(title: "Resistance", value: $load, tint: V3.strain)
            }

            scale(title: "Effort (RPE)", value: $rpe, tint: V3.amber)

            Spacer(minLength: 0)

            V3Button(title: busy ? "Saving" : "Save") {
                let km: Double? = Double(kmText.replacingOccurrences(of: ",", with: "."))
                onSave(km, load, rpe)
            }
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .background(V3.sheet.ignoresSafeArea())
    }

    private var distanceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Distance").font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
            HStack(spacing: 8) {
                TextField("0.0", text: $kmText)
                    .keyboardType(.decimalPad)
                    .focused($kmFocused)
                    .font(V3Font.num(17, .semibold))
                    .foregroundStyle(V3.t1)
                    .padding(.horizontal, 14)
                    .frame(width: 120, height: 44)
                    .background(V3.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("km").font(V3Font.text(14, .semibold)).foregroundStyle(V3.t2)
            }
        }
    }

    @ViewBuilder
    private func scale(title: String, value: Binding<Int?>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2)
                Spacer(minLength: 8)
                if let v = value.wrappedValue {
                    Text("\(v)").font(V3Font.num(13, .semibold)).foregroundStyle(tint)
                }
            }
            HStack(spacing: 4) {
                ForEach(1...10, id: \.self) { n in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        value.wrappedValue = (value.wrappedValue == n) ? nil : n
                    } label: {
                        Text("\(n)")
                            .font(V3Font.num(12))
                            .foregroundStyle(value.wrappedValue == n ? V3.ink : V3.t2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(value.wrappedValue == n ? tint : V3.card2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
