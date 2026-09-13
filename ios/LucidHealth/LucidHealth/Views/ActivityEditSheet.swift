import SwiftUI

// ════════════════════════════════════════════════════════════
// ActivityEditSheet — edit existing OR create from scratch
//
// Two modes:
//   .edit(activity) — tap timeline row, correct auto-detection
//   .create(defaultStart) — fresh manual log, optionally via backtrack
//
// What Fabi can do:
//   • Custom free-text type (Health understands semantically, no picker prison)
//   • Suggestion chips for common types (one-tap fill)
//   • Adjust start/end with DatePicker
//   • Open physiology backtrack scrubber with zoom/pan + spike clustering
//     to snap boundaries to real HR events
//   • Notes, delete (edit mode only), vitals readout (edit mode only)
//
// The backtrack scrubber supports:
//   • Pinch-to-zoom + horizontal drag pan
//   • 5 discrete zoom presets (Full / 1h / 30m / 10m / 5m) as buttons
//   • Auto-suggestion: largest spike cluster auto-snaps handles on load
//   • Minute-level precision when zoomed in
// ════════════════════════════════════════════════════════════

enum ActivityEditMode {
    case edit(ActivityEvent)
    case create(defaultStart: Date)
}

struct ActivityEditSheet: View {
    let mode: ActivityEditMode
    let ble: BLEManager
    let onSaved: () -> Void
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var activityType: String
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var notes: String
    @State private var isSaving: Bool = false
    @State private var showBacktrack: Bool = false

    /// Suggestion chips — tap to fill the TextField. Fabi can also type anything
    /// freeform since Health resolves semantic meaning on the backend.
    private let typeSuggestions: [String] = [
        "deep_work", "ee_work", "exercise", "meditation", "reading", "creative",
        "social", "nap", "sauna", "cold_plunge", "anxiety", "meal", "coffee", "walk"
    ]

    init(mode: ActivityEditMode, ble: BLEManager, onSaved: @escaping () -> Void, onDeleted: @escaping () -> Void) {
        self.mode = mode
        self.ble = ble
        self.onSaved = onSaved
        self.onDeleted = onDeleted

        switch mode {
        case .edit(let activity):
            _activityType = State(initialValue: activity.activityType)
            _startedAt = State(initialValue: activity.startedAt)
            _endedAt = State(initialValue: activity.endedAt ?? activity.startedAt.addingTimeInterval(30 * 60))
            _notes = State(initialValue: activity.notes ?? "")
        case .create(let defaultStart):
            _activityType = State(initialValue: "")
            _startedAt = State(initialValue: defaultStart)
            _endedAt = State(initialValue: defaultStart.addingTimeInterval(30 * 60))
            _notes = State(initialValue: "")
        }
    }

    private var isCreateMode: Bool {
        if case .create = mode { return true }
        return false
    }

    private var editingActivity: ActivityEvent? {
        if case .edit(let a) = mode { return a }
        return nil
    }

    private var navigationTitle: String {
        isCreateMode ? "Log activity" : "Edit activity"
    }

    private var canSave: Bool {
        !activityType.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    TextField("Custom name or pick below", text: $activityType)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(typeSuggestions, id: \.self) { suggestion in
                                Button {
                                    activityType = suggestion
                                } label: {
                                    Text(activityLabel(suggestion))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(activityType == suggestion ? .white : DS.Colors.textSecondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule()
                                                .fill(activityType == suggestion ? DS.Colors.violet : DS.Colors.surfaceElevated)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                    if let act = editingActivity {
                        LabeledContent("Source") {
                            Text(act.source.capitalized)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                }

                Section("Time") {
                    DatePicker("Start", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $endedAt, in: startedAt..., displayedComponents: [.date, .hourAndMinute])

                    LabeledContent("Duration") {
                        Text(durationLabel)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .monospacedDigit()
                    }

                    Button {
                        showBacktrack = true
                    } label: {
                        Label(isCreateMode ? "Backtrack from physiology" : "Backtrack with physiology", systemImage: "waveform.path.ecg")
                            .foregroundStyle(DS.Colors.teal)
                    }
                }

                Section("Notes") {
                    TextField("What was happening?", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let act = editingActivity, let hr = act.hrAvg {
                    Section("Captured vitals") {
                        LabeledContent("Avg HR") { Text("\(hr) bpm") }
                        if let hrv = act.hrvAvg, hrv > 0 {
                            LabeledContent("Avg HRV") { Text("\(Int(hrv)) ms") }
                        }
                    }
                }

                if editingActivity != nil {
                    Section {
                        Button(role: .destructive) {
                            delete()
                        } label: {
                            Label("Delete activity", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showBacktrack) {
                PhysiologyBacktrackView(
                    ble: ble,
                    initialStart: startedAt,
                    initialEnd: endedAt,
                    onConfirm: { newStart, newEnd in
                        startedAt = newStart
                        endedAt = newEnd
                    }
                )
                .presentationDetents([.large])
            }
        }
    }

    private var durationLabel: String {
        let minutes = max(Int(endedAt.timeIntervalSince(startedAt) / 60), 0)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func save() {
        let cleanType = activityType.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
        guard !cleanType.isEmpty else { return }

        isSaving = true

        switch mode {
        case .edit(let act):
            let typeChanged = cleanType != act.activityType
            let startChanged = startedAt != act.startedAt
            let endChanged = endedAt != (act.endedAt ?? act.startedAt)
            let notesChanged = notes != (act.notes ?? "")

            Task {
                let ok = await ble.supabase.updateActivity(
                    id: act.id,
                    activityType: typeChanged ? cleanType : nil,
                    startedAt: startChanged ? startedAt : nil,
                    endedAt: endChanged ? endedAt : nil,
                    notes: notesChanged ? notes : nil
                )
                await MainActor.run {
                    isSaving = false
                    if ok { onSaved(); dismiss() }
                }
            }

        case .create:
            // Fresh manual log — pushActivity with source="manual"
            let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
            Task {
                ble.supabase.pushActivity(
                    type: cleanType,
                    source: "manual",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    hrAvg: nil,
                    hrPeak: nil,
                    hrvAvg: nil,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    category: "physical",
                    metadata: nil
                )
                // pushActivity is fire-and-forget (no async return) — give it a beat,
                // then refresh the timeline
                try? await Task.sleep(nanoseconds: 400_000_000)
                await MainActor.run {
                    isSaving = false
                    onSaved()
                    dismiss()
                }
            }
        }
    }

    private func delete() {
        guard let act = editingActivity else { return }
        isSaving = true
        Task {
            let ok = await ble.supabase.deleteActivity(id: act.id)
            await MainActor.run {
                isSaving = false
                if ok { onDeleted(); dismiss() }
            }
        }
    }

    private func activityLabel(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// ════════════════════════════════════════════════════════════
// PhysiologyBacktrackView — zoom, pan, cluster-aware scrubber
//
// Opens with a 3-hour window fetched from realtime_health. The *visible*
// window is a sub-range that can shrink to 5 minutes for minute-level
// precision. Zoom presets are discrete buttons (ADHD-friendly, no fussy
// pinch), plus a horizontal drag gesture for panning.
//
// Spike detection runs once on load. Detected spikes are clustered by
// time proximity (within 5 min of each other). The largest cluster is
// auto-snapped to handles on open, and the "Suggest" button re-snaps to
// the largest cluster from the current visible window.
// ════════════════════════════════════════════════════════════

struct PhysiologyBacktrackView: View {
    let ble: BLEManager
    let initialStart: Date
    let initialEnd: Date
    let onConfirm: (Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var samples: [PhysioSample] = []
    @State private var isLoading: Bool = true

    // Full data window (what we fetched)
    @State private var windowStart: Date
    @State private var windowEnd: Date

    // Visible window (what's rendered) — can zoom in to 5 min
    @State private var visibleStart: Date
    @State private var visibleEnd: Date

    // Activity boundary handles
    @State private var handleStart: Date
    @State private var handleEnd: Date

    // Detected spikes + clusters
    @State private var spikes: [PhysioSample] = []
    @State private var suggestedCluster: (start: Date, end: Date, count: Int)? = nil

    // Pan tracking
    @State private var panBase: Date? = nil

    init(ble: BLEManager, initialStart: Date, initialEnd: Date, onConfirm: @escaping (Date, Date) -> Void) {
        self.ble = ble
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.onConfirm = onConfirm
        let pad: TimeInterval = 60 * 60
        let wStart = initialStart.addingTimeInterval(-pad)
        let wEnd = initialEnd.addingTimeInterval(pad)
        _windowStart = State(initialValue: wStart)
        _windowEnd = State(initialValue: wEnd)
        _visibleStart = State(initialValue: wStart)
        _visibleEnd = State(initialValue: wEnd)
        _handleStart = State(initialValue: initialStart)
        _handleEnd = State(initialValue: initialEnd)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.md) {
                if isLoading {
                    ProgressView("Loading physiology stream…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if samples.isEmpty {
                    emptyState
                } else {
                    scrubberCard
                    zoomBar
                    legend
                    if let cluster = suggestedCluster {
                        suggestionBanner(cluster)
                    }
                    handleReadouts
                    Spacer()
                }
            }
            .padding(DS.Spacing.md)
            .navigationTitle("Backtrack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        onConfirm(handleStart, handleEnd)
                        dismiss()
                    }
                    .disabled(samples.isEmpty)
                }
            }
            .task { await loadSamples() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 32))
                .foregroundStyle(DS.Colors.textMuted)
            Text("No physiology readings in this window")
                .font(DS.Font.body)
                .foregroundStyle(DS.Colors.textSecondary)
            Text("The bridge had no stream between \(timeLabel(windowStart)) and \(timeLabel(windowEnd)).")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Colors.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scrubberCard: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let hrRange = hrMinMax
            let hrvRange = hrvMinMax
            let startX = xPos(for: handleStart, width: w)
            let endX = xPos(for: handleEnd, width: w)

            ZStack(alignment: .topLeading) {
                // Background card — receives pan gesture
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(DS.Colors.surface)
                    .contentShape(Rectangle())
                    .gesture(panGesture(width: w))

                // Time gridlines — adapt to zoom level
                ForEach(gridTicks, id: \.self) { tick in
                    let x = xPos(for: tick, width: w)
                    if x >= 0 && x <= w {
                        Rectangle()
                            .fill(DS.Colors.border.opacity(0.3))
                            .frame(width: 0.5, height: h)
                            .offset(x: x)
                        Text(gridTickLabel(tick))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(DS.Colors.textMuted)
                            .offset(x: x + 2, y: h - 14)
                    }
                }

                // Selected band (between handles) — clipped to visible window
                if endX > 0 && startX < w {
                    let bandStart = max(0, min(startX, endX))
                    let bandWidth = max(0, min(endX - startX, w))
                    Rectangle()
                        .fill(DS.Colors.violet.opacity(0.14))
                        .frame(width: bandWidth, height: h)
                        .offset(x: bandStart, y: 0)
                        .allowsHitTesting(false)
                }

                // HR line — only samples within visible window
                Path { path in
                    var started = false
                    for sample in visibleSamples {
                        let x = xPos(for: sample.time, width: w)
                        let y = yPos(value: Double(sample.hr), minV: hrRange.lo, maxV: hrRange.hi, height: h)
                        if !started { path.move(to: CGPoint(x: x, y: y)); started = true }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(DS.Colors.danger, lineWidth: 1.6)
                .allowsHitTesting(false)

                // HRV line
                if hrvRange.hi > 0 {
                    Path { path in
                        var started = false
                        for sample in visibleSamples where sample.hrv > 0 {
                            let x = xPos(for: sample.time, width: w)
                            let y = yPos(value: sample.hrv, minV: hrvRange.lo, maxV: hrvRange.hi, height: h)
                            if !started { path.move(to: CGPoint(x: x, y: y)); started = true }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(DS.Colors.teal.opacity(0.8), lineWidth: 1.2)
                    .allowsHitTesting(false)
                }

                // Spike dots — tap to snap
                ForEach(visibleSpikes) { spike in
                    let x = xPos(for: spike.time, width: w)
                    let y = yPos(value: Double(spike.hr), minV: hrRange.lo, maxV: hrRange.hi, height: h)
                    Circle()
                        .fill(DS.Colors.warning)
                        .frame(width: 10, height: 10)
                        .position(x: x, y: y)
                        .onTapGesture {
                            snapNearestHandle(to: spike.time)
                        }
                }

                // Handles
                if startX >= 0 && startX <= w {
                    handleView(color: DS.Colors.teal, label: "A", height: h)
                        .position(x: startX, y: h / 2)
                        .gesture(handleDrag(isStart: true, width: w))
                }
                if endX >= 0 && endX <= w {
                    handleView(color: DS.Colors.violet, label: "B", height: h)
                        .position(x: endX, y: h / 2)
                        .gesture(handleDrag(isStart: false, width: w))
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }

    private func handleView(color: Color, label: String, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    Text(label)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                )
            Rectangle()
                .fill(color)
                .frame(width: 2, height: height)
                .offset(y: -10)
        }
    }

    private func handleDrag(isStart: Bool, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let clamped = max(0, min(value.location.x, width))
                let newDate = timeAtX(clamped, width: width)
                if isStart {
                    handleStart = min(newDate, handleEnd.addingTimeInterval(-30))
                } else {
                    handleEnd = max(newDate, handleStart.addingTimeInterval(30))
                }
            }
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                let visibleSpan = visibleEnd.timeIntervalSince(visibleStart)
                let deltaPx = value.translation.width
                let deltaTime = -Double(deltaPx / width) * visibleSpan
                if panBase == nil {
                    panBase = visibleStart
                }
                guard let base = panBase else { return }
                let proposedStart = base.addingTimeInterval(deltaTime)
                let clampedStart = max(windowStart, min(proposedStart, windowEnd.addingTimeInterval(-visibleSpan)))
                visibleStart = clampedStart
                visibleEnd = clampedStart.addingTimeInterval(visibleSpan)
            }
            .onEnded { _ in
                panBase = nil
            }
    }

    private var zoomBar: some View {
        HStack(spacing: 6) {
            ForEach(zoomPresets, id: \.label) { preset in
                Button {
                    applyZoom(span: preset.span)
                } label: {
                    Text(preset.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(currentZoomLabel == preset.label ? .white : DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(currentZoomLabel == preset.label ? DS.Colors.violet : DS.Colors.surface)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var zoomPresets: [(label: String, span: TimeInterval)] {
        [
            ("Full", windowEnd.timeIntervalSince(windowStart)),
            ("1h", 60 * 60),
            ("30m", 30 * 60),
            ("10m", 10 * 60),
            ("5m", 5 * 60)
        ]
    }

    private var currentZoomLabel: String {
        let currentSpan = visibleEnd.timeIntervalSince(visibleStart)
        // Match to closest preset by label
        if currentSpan >= windowEnd.timeIntervalSince(windowStart) - 1 { return "Full" }
        if abs(currentSpan - 3600) < 30 { return "1h" }
        if abs(currentSpan - 1800) < 30 { return "30m" }
        if abs(currentSpan - 600) < 30 { return "10m" }
        if abs(currentSpan - 300) < 30 { return "5m" }
        return ""
    }

    private func applyZoom(span: TimeInterval) {
        let fullSpan = windowEnd.timeIntervalSince(windowStart)
        let clampedSpan = min(span, fullSpan)

        // Center the new visible window on the current handle midpoint when zooming in,
        // otherwise on the current visible midpoint
        let centerTime: Date
        if clampedSpan < visibleEnd.timeIntervalSince(visibleStart) {
            centerTime = handleStart.addingTimeInterval(handleEnd.timeIntervalSince(handleStart) / 2)
        } else {
            centerTime = visibleStart.addingTimeInterval(visibleEnd.timeIntervalSince(visibleStart) / 2)
        }

        var newStart = centerTime.addingTimeInterval(-clampedSpan / 2)
        var newEnd = centerTime.addingTimeInterval(clampedSpan / 2)

        // Clamp inside the full window
        if newStart < windowStart {
            newStart = windowStart
            newEnd = windowStart.addingTimeInterval(clampedSpan)
        }
        if newEnd > windowEnd {
            newEnd = windowEnd
            newStart = windowEnd.addingTimeInterval(-clampedSpan)
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            visibleStart = newStart
            visibleEnd = newEnd
        }
    }

    private func suggestionBanner(_ cluster: (start: Date, end: Date, count: Int)) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                handleStart = cluster.start
                handleEnd = cluster.end
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(DS.Colors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(cluster.count) HR spikes clustered")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("\(timeLabel(cluster.start)) → \(timeLabel(cluster.end)) · tap to snap")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(DS.Colors.violet)
            }
            .padding(12)
            .background(DS.Colors.warning.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(color: DS.Colors.danger, label: "HR")
            legendDot(color: DS.Colors.teal, label: "HRV")
            legendDot(color: DS.Colors.warning, label: "Spike")
            Spacer()
            Text("Drag to pan · tap spike to snap")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Colors.textMuted)
        }
        .font(.system(size: 11, weight: .semibold))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var handleReadouts: some View {
        HStack(spacing: DS.Spacing.sm) {
            readout(label: "START", color: DS.Colors.teal, date: handleStart)
            readout(label: "END", color: DS.Colors.violet, date: handleEnd)
            readout(label: "DURATION", color: DS.Colors.warning, text: durationLabel)
        }
    }

    private func readout(label: String, color: Color, date: Date? = nil, text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(DS.Colors.textMuted)
            Text(text ?? (date.map(preciseTimeLabel) ?? "—"))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }

    private var durationLabel: String {
        let minutes = max(Int(handleEnd.timeIntervalSince(handleStart) / 60), 0)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: - Data

    private func loadSamples() async {
        let fetched = await ble.supabase.fetchReadingsInRange(start: windowStart, end: windowEnd)
        await MainActor.run {
            samples = fetched
            spikes = detectSpikes(fetched)
            suggestedCluster = clusterSpikes(spikes)

            // Auto-snap handles to the biggest cluster if one exists AND the
            // initial range looks like a default (user hadn't manually set it)
            if let cluster = suggestedCluster {
                let initialSpan = initialEnd.timeIntervalSince(initialStart)
                // Only auto-snap if the initial span is exactly 30 min (the default)
                // OR the initial range doesn't overlap any spikes at all
                if abs(initialSpan - 30 * 60) < 1 || !overlapsAnySpike(initialStart: initialStart, initialEnd: initialEnd) {
                    handleStart = cluster.start
                    handleEnd = cluster.end
                }
            }

            isLoading = false
        }
    }

    private func overlapsAnySpike(initialStart: Date, initialEnd: Date) -> Bool {
        for spike in spikes {
            if spike.time >= initialStart && spike.time <= initialEnd { return true }
        }
        return false
    }

    /// Mean + 1.2σ spike detector with a minimum delta floor of 15 bpm above mean.
    /// Tuned up from earlier 1.0σ + 5 bpm floor because quiet days were producing
    /// too many false spikes on background HR noise.
    private func detectSpikes(_ data: [PhysioSample]) -> [PhysioSample] {
        guard data.count >= 5 else { return [] }
        let hrValues = data.map { Double($0.hr) }.filter { $0 > 0 }
        guard !hrValues.isEmpty else { return [] }

        let hrMean = hrValues.reduce(0, +) / Double(hrValues.count)
        let hrVariance = hrValues.map { ($0 - hrMean) * ($0 - hrMean) }.reduce(0, +) / Double(hrValues.count)
        let hrSD = sqrt(hrVariance)
        let hrThreshold = hrMean + max(hrSD * 1.2, 15)

        var result: [PhysioSample] = []
        var lastSpikeTime: Date? = nil
        for sample in data {
            guard Double(sample.hr) > hrThreshold else { continue }
            if let last = lastSpikeTime, sample.time.timeIntervalSince(last) < 180 { continue }
            result.append(sample)
            lastSpikeTime = sample.time
        }
        return result
    }

    /// Group spikes into clusters (spikes within 5 min of each other belong to
    /// the same cluster) and return the largest cluster's time envelope.
    private func clusterSpikes(_ spikes: [PhysioSample]) -> (start: Date, end: Date, count: Int)? {
        guard !spikes.isEmpty else { return nil }
        let sorted = spikes.sorted { $0.time < $1.time }

        var clusters: [[PhysioSample]] = []
        var current: [PhysioSample] = [sorted[0]]

        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let cur = sorted[i]
            if cur.time.timeIntervalSince(prev.time) <= 5 * 60 {
                current.append(cur)
            } else {
                clusters.append(current)
                current = [cur]
            }
        }
        clusters.append(current)

        guard let biggest = clusters.max(by: { $0.count < $1.count }) else { return nil }
        guard biggest.count >= 2 else { return nil }

        // Pad the envelope by 2 min on each side
        let padded = 2 * 60.0
        let start = biggest.first!.time.addingTimeInterval(-padded)
        let end = biggest.last!.time.addingTimeInterval(padded)
        return (start, end, biggest.count)
    }

    // MARK: - Visible subsets

    private var visibleSamples: [PhysioSample] {
        samples.filter { $0.time >= visibleStart && $0.time <= visibleEnd }
    }

    private var visibleSpikes: [PhysioSample] {
        spikes.filter { $0.time >= visibleStart && $0.time <= visibleEnd }
    }

    // MARK: - Gridlines

    private var gridTicks: [Date] {
        let span = visibleEnd.timeIntervalSince(visibleStart)
        let stepSeconds: TimeInterval
        if span >= 2 * 3600 { stepSeconds = 30 * 60 }
        else if span >= 3600 { stepSeconds = 15 * 60 }
        else if span >= 1800 { stepSeconds = 5 * 60 }
        else if span >= 600 { stepSeconds = 2 * 60 }
        else { stepSeconds = 60 }

        var ticks: [Date] = []
        let cal = Calendar.current
        var t = cal.date(bySetting: .second, value: 0, of: visibleStart) ?? visibleStart
        // Snap to a round interval
        let stepMin = Int(stepSeconds / 60)
        let minute = cal.component(.minute, from: t)
        let snapBack = minute % stepMin
        if snapBack > 0 {
            t = t.addingTimeInterval(TimeInterval(-snapBack * 60))
        }
        while t <= visibleEnd {
            if t >= visibleStart { ticks.append(t) }
            t = t.addingTimeInterval(stepSeconds)
        }
        return ticks
    }

    private func gridTickLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Geometry helpers

    private var hrMinMax: (lo: Double, hi: Double) {
        let hrs = visibleSamples.map { Double($0.hr) }.filter { $0 > 0 }
        guard let lo = hrs.min(), let hi = hrs.max(), hi > lo else { return (40, 120) }
        let pad = (hi - lo) * 0.1
        return (lo - pad, hi + pad)
    }

    private var hrvMinMax: (lo: Double, hi: Double) {
        let hrvs = visibleSamples.map { $0.hrv }.filter { $0 > 0 }
        guard let lo = hrvs.min(), let hi = hrvs.max(), hi > lo else { return (0, 0) }
        let pad = (hi - lo) * 0.15
        return (lo - pad, hi + pad)
    }

    private func xPos(for date: Date, width: CGFloat) -> CGFloat {
        let total = visibleEnd.timeIntervalSince(visibleStart)
        guard total > 0 else { return 0 }
        let t = date.timeIntervalSince(visibleStart) / total
        return CGFloat(t) * width
    }

    private func timeAtX(_ x: CGFloat, width: CGFloat) -> Date {
        guard width > 0 else { return visibleStart }
        let t = Double(x / width)
        return visibleStart.addingTimeInterval(t * visibleEnd.timeIntervalSince(visibleStart))
    }

    private func yPos(value: Double, minV: Double, maxV: Double, height: CGFloat) -> CGFloat {
        guard maxV > minV else { return height / 2 }
        let t = (value - minV) / (maxV - minV)
        let inset: CGFloat = 24
        return inset + CGFloat(1 - t) * (height - 2 * inset)
    }

    private func snapNearestHandle(to time: Date) {
        let distStart = abs(handleStart.timeIntervalSince(time))
        let distEnd = abs(handleEnd.timeIntervalSince(time))
        withAnimation(.easeOut(duration: 0.15)) {
            if distStart <= distEnd {
                handleStart = min(time, handleEnd.addingTimeInterval(-30))
            } else {
                handleEnd = max(time, handleStart.addingTimeInterval(30))
            }
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// HH:mm:ss when zoomed in tight (< 10 min visible), HH:mm otherwise.
    private func preciseTimeLabel(_ date: Date) -> String {
        let span = visibleEnd.timeIntervalSince(visibleStart)
        let f = DateFormatter()
        f.dateFormat = span < 600 ? "HH:mm:ss" : "HH:mm"
        return f.string(from: date)
    }
}
