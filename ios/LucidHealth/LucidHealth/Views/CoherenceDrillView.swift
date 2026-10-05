import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// Coherence Drill — 5-min HRV biofeedback session
//
// Pattern stolen from HeartMath's Inner Balance (200+ peer-reviewed studies).
// At 6 breaths per minute (resonance frequency), HR oscillation peaks —
// this is the parasympathetic sweet spot. Score = 0.1 Hz spectral power
// ratio (real coherence) from the live RR tachogram, 0 to 1.
//
// Real-time coherence visualization: the bouncing sphere paces breath.
// User syncs breath with sphere → HRV climbs → score climbs.
// ════════════════════════════════════════════════════════════════════════

struct CoherenceDrillView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss

    // Session state
    @State private var phase: SessionPhase = .ready
    @State private var elapsedSec: Int = 0
    @State private var targetSec: Int = 300  // 5 min default
    @State private var breathInhale: Bool = true   // true = inhaling

    // Live metrics
    @State private var sessionStartRMSSD: Double = 0
    @State private var sessionStartBaevsky: Double = 0
    @State private var sessionRMSSDSamples: [Double] = []
    @State private var sessionHRSamples: [Double] = []
    @State private var liveCoherence: Double = 0
    @State private var peakCoherence: Double = 0

    // Animation
    @State private var sphereScale: CGFloat = 0.4
    @State private var pulse: CGFloat = 1.0

    // Timers
    @State private var sessionTimer: Timer?
    @State private var breathTimer: Timer?
    @State private var sampleTimer: Timer?

    // Persistence
    @State private var saved: Bool = false

    enum SessionPhase {
        case ready, running, complete
    }

    private let breathInhaleDuration: TimeInterval = 5.0  // 5s in
    private let breathExhaleDuration: TimeInterval = 5.0  // 5s out → 6 BPM

    var body: some View {
        ZStack {
            AuroraBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.lg) {

                    // Header
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(DS.Colors.textMuted)
                        }
                        Spacer()
                        Text("COHERENCE DRILL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.Colors.violet)
                            .tracking(1.2)
                        Spacer()
                        Color.clear.frame(width: 22, height: 22)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.sm)

                    // Breath pacer sphere
                    breathSphere
                        .padding(.top, DS.Spacing.md)

                    // Phase-specific content
                    switch phase {
                    case .ready:
                        readyContent
                    case .running:
                        runningContent
                    case .complete:
                        completeContent
                    }

                    Color.clear.frame(height: 60)
                }
            }
        }
        .onDisappear { stopAllTimers() }
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Breath sphere
    // ════════════════════════════════════════════════════════════════════

    private var breathSphere: some View {
        ZStack {
            // Outer rings
            ForEach(0..<3) { i in
                Circle()
                    .stroke(DS.Colors.violet.opacity(0.2 - Double(i) * 0.06), lineWidth: 1)
                    .frame(width: 220 + CGFloat(i * 30), height: 220 + CGFloat(i * 30))
                    .scaleEffect(pulse)
            }

            // Main sphere
            ZStack {
                Circle()
                    .stroke(DS.Colors.separator, lineWidth: 1)
                    .frame(width: 200, height: 200)
                Circle()
                    .fill(DS.Colors.accent.opacity(0.85))
                    .frame(width: 180, height: 180)
                    .overlay(
                        VStack(spacing: 4) {
                            if phase == .running {
                                Text(breathInhale ? "breathe in" : "breathe out")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .transition(.opacity)
                                    .id(breathInhale)
                                Text(formatTime(elapsedSec))
                                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                            } else if phase == .ready {
                                Text("ready")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("5 min")
                                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                            } else {
                                Text(String(format: "%.2f", liveCoherence))
                                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                Text("coherence")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    )
            }
            .scaleEffect(sphereScale)
            .animation(.easeInOut(duration: phase == .running ? breathInhaleDuration : 0.4),
                       value: sphereScale)
        }
        .frame(height: 260)
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Phase contents
    // ════════════════════════════════════════════════════════════════════

    private var readyContent: some View {
        VStack(spacing: DS.Spacing.md) {
            Text("breathe with the sphere")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("5s in · 5s out · 6 breaths per minute")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DS.Colors.textMuted)

            // Duration picker
            HStack(spacing: 8) {
                ForEach([180, 300, 600], id: \.self) { sec in
                    Button { targetSec = sec } label: {
                        Text("\(sec / 60) min")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .foregroundStyle(targetSec == sec ? .white : DS.Colors.violet)
                            .background(targetSec == sec ? DS.Colors.violet : DS.Colors.violet.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.top, 4)

            // Pre-session vitals
            if bleManager.healthEngine.currentRMSSD > 0 {
                HStack(spacing: DS.Spacing.lg) {
                    statTile("hrv", value: "\(Int(bleManager.healthEngine.currentRMSSD))", unit: "ms", color: DS.Colors.teal)
                    if bleManager.healthEngine.baevskyStress > 0 {
                        statTile("stress", value: "\(Int(bleManager.healthEngine.baevskyStress))", unit: bleManager.healthEngine.baevskyStressLabel, color: DS.Colors.amber)
                    }
                    if bleManager.heartRate > 0 {
                        statTile("hr", value: "\(bleManager.heartRate)", unit: "bpm", color: DS.Colors.danger)
                    }
                }
                .padding(.top, 8)
            }

            // Start button
            Button {
                startSession()
            } label: {
                Label("start", systemImage: "play.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(DS.Colors.accent)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.md)
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    private var runningContent: some View {
        VStack(spacing: DS.Spacing.md) {
            // Live metrics row
            HStack(spacing: DS.Spacing.lg) {
                statTile("hrv", value: "\(Int(bleManager.healthEngine.currentRMSSD))", unit: "ms", color: DS.Colors.teal)
                statTile("hr", value: "\(bleManager.heartRate)", unit: "bpm", color: DS.Colors.danger)
                statTile("peak", value: String(format: "%.2f", peakCoherence), unit: "coherence", color: DS.Colors.violet)
            }
            .padding(.top, 4)

            // Progress bar
            ProgressView(value: Double(elapsedSec), total: Double(targetSec))
                .tint(DS.Colors.violet)
                .padding(.horizontal, DS.Spacing.lg)

            // Stop button
            Button {
                completeSession()
            } label: {
                Label("end early", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textMuted)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(DS.Colors.surface)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    private var completeContent: some View {
        VStack(spacing: DS.Spacing.lg) {
            // Score breakdown
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("session results")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.Colors.textMuted)
                    .tracking(1.0)

                resultRow("duration", "\(elapsedSec / 60)m \(elapsedSec % 60)s")
                resultRow("avg HRV", "\(Int(avgRMSSD)) ms")
                resultRow("avg HR", "\(Int(avgHR)) bpm")
                resultRow("peak coherence", String(format: "%.2f", peakCoherence))

                if sessionStartBaevsky > 0 && bleManager.healthEngine.baevskyStress > 0 {
                    let drop = sessionStartBaevsky - bleManager.healthEngine.baevskyStress
                    resultRow("stress change", "\(drop > 0 ? "↓" : "↑")\(abs(Int(drop)))")
                }
            }
            .padding(DS.Spacing.lg)
            .glassDefault()

            HStack(spacing: DS.Spacing.md) {
                Button {
                    resetSession()
                } label: {
                    Text("again")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.violet)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(DS.Colors.violet.opacity(0.12))
                        .clipShape(Capsule())
                }
                Button {
                    dismiss()
                } label: {
                    Text(saved ? "saved · close" : "close")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(DS.Colors.accent)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ════════════════════════════════════════════════════════════════════

    @ViewBuilder
    private func statTile(_ label: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DS.Colors.textMuted)
                .tracking(1.0)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DS.Colors.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.Colors.textPrimary)
        }
    }

    private var avgRMSSD: Double {
        sessionRMSSDSamples.isEmpty ? 0 :
            sessionRMSSDSamples.reduce(0, +) / Double(sessionRMSSDSamples.count)
    }
    private var avgHR: Double {
        sessionHRSamples.isEmpty ? 0 :
            sessionHRSamples.reduce(0, +) / Double(sessionHRSamples.count)
    }

    private func formatTime(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%d:%02d", m, s)
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Session lifecycle
    // ════════════════════════════════════════════════════════════════════

    private func startSession() {
        sessionStartRMSSD = bleManager.healthEngine.currentRMSSD
        sessionStartBaevsky = bleManager.healthEngine.baevskyStress
        sessionRMSSDSamples = []
        sessionHRSamples = []
        liveCoherence = 0
        peakCoherence = 0
        elapsedSec = 0
        phase = .running
        breathInhale = true
        sphereScale = 0.4

        // Breath cycle timer (10s loop = 6 BPM)
        startBreathCycle()

        // Sample timer (every 5s)
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            sampleVitals()
        }

        // Session timer
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedSec += 1
            if elapsedSec >= targetSec {
                completeSession()
            }
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func startBreathCycle() {
        // Initial inhale
        sphereScale = 1.0
        breathInhale = true

        breathTimer = Timer.scheduledTimer(withTimeInterval: breathInhaleDuration, repeats: true) { _ in
            withAnimation(.easeInOut(duration: breathInhaleDuration)) {
                breathInhale.toggle()
                sphereScale = breathInhale ? 1.0 : 0.4
            }
        }
    }

    private func sampleVitals() {
        let rmssd = bleManager.healthEngine.currentRMSSD
        let hr = Double(bleManager.heartRate)
        if rmssd > 0 { sessionRMSSDSamples.append(rmssd) }
        if hr > 0 { sessionHRSamples.append(hr) }

        // Real coherence: 0.1 Hz spectral power ratio from the live RR tachogram
        // (HealthEngine.computeCoherenceScore → currentCoherence). Replaces the
        // old RMSSD-ratio proxy. Climbs as the user locks onto the 6/min pace.
        let coh = bleManager.healthEngine.currentCoherence
        if coh > 0 {
            liveCoherence = coh
            if coh > peakCoherence { peakCoherence = coh }
        }
    }

    private func completeSession() {
        stopAllTimers()
        phase = .complete
        sphereScale = 0.7
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Save session to Supabase
        Task { await saveSession() }
    }

    private func resetSession() {
        elapsedSec = 0
        sessionRMSSDSamples = []
        sessionHRSamples = []
        liveCoherence = 0
        peakCoherence = 0
        saved = false
        phase = .ready
        sphereScale = 0.4
    }

    private func stopAllTimers() {
        sessionTimer?.invalidate()
        breathTimer?.invalidate()
        sampleTimer?.invalidate()
        sessionTimer = nil
        breathTimer = nil
        sampleTimer = nil
    }

    private func saveSession() async {
        let postBaevsky = bleManager.healthEngine.baevskyStress
        let session = ExperimentalFeaturesService.CoherenceSession(
            duration_sec: elapsedSec,
            coherence_score: liveCoherence,
            avg_rmssd: avgRMSSD,
            avg_hr: avgHR,
            peak_coherence: peakCoherence,
            pre_session_baevsky: sessionStartBaevsky > 0 ? sessionStartBaevsky : nil,
            post_session_baevsky: postBaevsky > 0 ? postBaevsky : nil,
            target_breath_per_min: 6.0
        )
        let ok = await ExperimentalFeaturesService.shared.saveCoherenceSession(session)
        await MainActor.run { saved = ok }
    }
}
