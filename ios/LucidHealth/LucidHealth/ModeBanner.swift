import SwiftUI

/// Thin banner that sits above the dashboard showing the current AppMode.
/// In Morning mode it surfaces the big "I'm awake" CTA.
/// In other modes it's a minimal status pill.
struct ModeBanner: View {
    let mode: AppMode
    @ObservedObject var modeStore: AppModeStore
    /// Runs the real wake-up (closes the sleep session + server recompute).
    var onWake: () -> Void = {}

    var body: some View {
        switch mode {
        case .morning:
            morningBanner
        case .justWokeUp:
            simpleBanner(tint: DS.Colors.warning, tag: "Just woke up")
        case .day, .evening, .windDown:
            // Per Fabi: gray status pill is visual noise — hide it for day-band modes.
            // Mode tint is implicit in the rest of the UI (recovery ring, accents).
            EmptyView()
        case .lateNight:
            EmptyView() // Late-Night fully replaces dashboard, no banner needed
        }
    }

    /// Morning = the big "I'm awake" card at the top of the dashboard.
    private var morningBanner: some View {
        VStack(spacing: 12) {
            Text("Still asleep?")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Colors.textMuted)
                .textCase(.uppercase)
                .kerning(1.2)

            Button(action: { DS.Haptic.commit(); modeStore.tapImAwake(); onWake() }) {
                HStack(spacing: 12) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 22, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I'm awake")
                            .font(DS.Font.title2)
                            .fontWeight(.bold)
                        Text("Runs overnight analysis")
                            .font(DS.Font.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(
                        colors: [DS.Colors.violet, DS.Colors.teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                .shadow(color: DS.Colors.violet.opacity(0.35), radius: 16, y: 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, 12)
    }

    /// Non-morning modes — thin status pill, collapsible.
    private func simpleBanner(tint: Color, tag: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint.opacity(0.6), radius: 4)
            Text(tag)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            Text(mode.subtitle)
                .font(DS.Font.micro)
                .foregroundStyle(DS.Colors.textMuted)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 8)
        .background(DS.Colors.cardFill)
        .overlay(
            Rectangle()
                .fill(DS.Colors.border)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: Date())
    }
}
