import SwiftUI

/// Full-screen voice capture overlay. Triggered via the CaptureVoiceIntent
/// (Action Button / Siri / Apple Intelligence) or from the in-app FAB.
///
/// Records on-device, transcribes via Apple Speech, POSTs the final transcript
/// to the Hetzner /voice-route endpoint, and shows the returned summary.
struct VoiceCaptureView: View {

    @StateObject private var recorder = VoiceRecorder()
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .ready
    @State private var resultSummary: String = ""

    enum Phase { case ready, recording, routing, done, error }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 24)

                // Animated halo + mic glyph
                ZStack {
                    Circle()
                        .fill(haloColor.opacity(0.16))
                        .frame(
                            width: 160 + CGFloat(recorder.audioLevel * 90),
                            height: 160 + CGFloat(recorder.audioLevel * 90)
                        )
                        .animation(.easeOut(duration: 0.12), value: recorder.audioLevel)

                    Circle()
                        .fill(haloColor.opacity(0.08))
                        .frame(width: 220, height: 220)

                    Image(systemName: phase == .recording ? "waveform" : "mic.fill")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(haloColor)
                        .symbolEffect(.pulse, isActive: phase == .recording)
                }

                // Transcript live preview
                ScrollView {
                    Text(displayText)
                        .font(.title3)
                        .foregroundStyle(recorder.transcript.isEmpty && phase != .done ? .secondary : .primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 200)

                if phase == .done || phase == .error {
                    Text(resultSummary)
                        .font(.body.weight(.medium))
                        .foregroundStyle(phase == .error ? .red : .green)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }

                Spacer()

                Button(action: handleTap) {
                    Text(buttonLabel)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(buttonColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 24)
                .disabled(phase == .routing)

                Button("Cancel") { dismiss() }
                    .foregroundColor(.secondary)
                    .padding(.bottom, 16)
            }
        }
        .task {
            let ok = await recorder.requestAuthorization()
            if !ok {
                resultSummary = "⚠️ Microphone or Speech permission denied. Enable in Settings."
                phase = .error
                return
            }
            startRecording()
        }
        .onDisappear { recorder.stop() }
    }

    // MARK: - Derived state

    private var haloColor: Color {
        switch phase {
        case .recording: return .red
        case .routing:   return .blue
        case .done:      return .green
        case .error:     return .orange
        case .ready:     return .blue
        }
    }

    private var displayText: String {
        switch phase {
        case .ready, .recording:
            return recorder.transcript.isEmpty ? "Listening…" : recorder.transcript
        case .routing:
            return recorder.transcript
        case .done, .error:
            return recorder.transcript.isEmpty ? "" : recorder.transcript
        }
    }

    private var buttonLabel: String {
        switch phase {
        case .ready:     return "Start"
        case .recording: return "Done"
        case .routing:   return "Routing…"
        case .done:      return "Capture another"
        case .error:     return "Try again"
        }
    }

    private var buttonColor: Color {
        switch phase {
        case .recording: return .red
        case .routing:   return .gray
        case .error:     return .orange
        default:         return .blue
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch phase {
        case .ready:
            startRecording()
        case .recording:
            Task { await finishRecording() }
        case .routing:
            break
        case .done, .error:
            phase = .ready
            resultSummary = ""
            startRecording()
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
            phase = .recording
        } catch {
            resultSummary = "⚠️ \(error.localizedDescription)"
            phase = .error
        }
    }

    private func finishRecording() async {
        recorder.stop()
        let text = recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            resultSummary = "⚠️ Nothing captured"
            phase = .error
            return
        }
        phase = .routing
        let result = await VoiceRouterClient.shared.route(transcript: text)
        resultSummary = result.summary
        phase = result.success ? .done : .error

        // Auto-dismiss on success after a brief read window
        if result.success {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            dismiss()
        }
    }
}

#Preview {
    VoiceCaptureView()
}
