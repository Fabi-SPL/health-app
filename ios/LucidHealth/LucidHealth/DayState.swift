import Foundation
import SwiftUI

// ════════════════════════════════════════════════════════════
// DayState — third dimension of UI state in LucidBridge.
//
//   AppMode         — time/sleep state (justWokeUp / morning / day / evening
//                     / windDown / lateNight). Drives WHICH home view renders.
//   RecoveryOverlay — current real-time physiological tone. Drives banner
//                     copy and accent on the active home view.
//   DayState        — "what kind of day is today, all of it." Cuts across
//                     all AppModes and lasts the whole day. Auto-detected
//                     from accumulated signals OR manually toggled. When
//                     active, the home view LAYOUT TRANSFORMS (different
//                     cards, different copy, different priorities) — not
//                     just a banner swap.
//
// All three layers stack: a Hangover Day in JustWokeUp AppMode with an
// alcohol RecoveryOverlay is a different screen than a Push Day in JustWokeUp
// with a green overlay. The home view reads all three to decide what to show.
// ════════════════════════════════════════════════════════════

enum DayState: String, CaseIterable, Identifiable {
    case normal
    case hangover
    case sick
    case soft
    case sleepDebt
    case push
    case wired

    var id: String { rawValue }

    /// Display title for the state, used in the Day State pill / banner.
    var title: String {
        switch self {
        case .normal:    return "Normal day"
        case .hangover:  return "Hangover day"
        case .sick:      return "Sick day"
        case .soft:      return "Soft day"
        case .sleepDebt: return "Sleep-debt day"
        case .push:      return "Push day"
        case .wired:     return "Wired day"
        }
    }

    /// One-sentence framing — why the state is active and what the day is for.
    var subtitle: String {
        switch self {
        case .normal:    return "No special signal — run the day on AppMode alone."
        case .hangover:  return "Yesterday cost you. Hydrate, eat, walk. No metrics push."
        case .sick:      return "Immunity is the priority. Training and focus pressure are off the table."
        case .soft:      return "Multi-day deficit. Half output, gentle wins, streak is protected."
        case .sleepDebt: return "You owe the body sleep. Move bedtime earlier and protect tomorrow."
        case .push:      return "All signals primed. Spend the window — this is your top day."
        case .wired:     return "Body is exhausted but the mind won't slow. Calm before push."
        }
    }

    /// SF Symbol icon — used in pills, banners, and any state-aware chrome.
    var icon: String {
        switch self {
        case .normal:    return "circle.dashed"
        case .hangover:  return "drop.triangle.fill"
        case .sick:      return "cross.circle.fill"
        case .soft:      return "leaf.fill"
        case .sleepDebt: return "moon.zzz.fill"
        case .push:      return "flame.fill"
        case .wired:     return "bolt.heart.fill"
        }
    }

    /// Accent color from DS — used for tints, borders, hero-card glow.
    var accent: Color {
        switch self {
        case .normal:    return DS.Colors.textMuted
        case .hangover:  return DS.Colors.violet
        case .sick:      return DS.Colors.danger
        case .soft:      return DS.Colors.success
        case .sleepDebt: return DS.Colors.warning
        case .push:      return DS.Colors.success
        case .wired:     return DS.Colors.danger
        }
    }

    /// Whether the home view should LAYOUT-TRANSFORM for this state. `.normal`
    /// keeps the AppMode-default layout; everything else replaces or reorders
    /// cards, hides perf metrics, swaps copy.
    var transformsLayout: Bool { self != .normal }

    /// Whether to BLOCK any "push window" / training recommendations regardless
    /// of recovery score. Sick + Hangover + Sleep Debt + Soft = no push CTAs.
    var blocksPushCTAs: Bool {
        switch self {
        case .sick, .hangover, .soft, .sleepDebt, .wired: return true
        case .normal, .push: return false
        }
    }

    /// Whether perf metrics (live HR, HRV ms, body battery %) should be hidden
    /// on this day. Recovery-first states drop the numbers in favor of vibes.
    var hidesPerfMetrics: Bool {
        switch self {
        case .sick, .hangover, .soft: return true
        case .sleepDebt, .wired, .push, .normal: return false
        }
    }
}

// ════════════════════════════════════════════════════════════
// DayStateResolver — signal pipeline → DayState
//
// Priority order matters. First match wins. Manual override beats everything.
// Sick > Hangover > Sleep Debt > Soft > Wired > Push > Normal.
// ════════════════════════════════════════════════════════════

struct DayStateResolver {
    /// Resolve the current DayState given live engine readings and an optional
    /// manual override (set by the user via "Feel like shit" or similar action).
    /// Override always wins — there are days you know are off even if the
    /// numbers don't show it yet.
    static func resolve(engine: HealthEngine, manualOverride: DayState? = nil) -> DayState {
        if let override = manualOverride { return override }

        // 1. Sick — sentinel pattern (resp up + HR up + HRV down) trumps everything.
        if engine.illnessRisk >= 2 || engine.illnessAlert != nil {
            return .sick
        }

        // 2. Hangover — overnight alcohol depressed RMSSD by >= 10% vs baseline.
        if engine.lastAlcoholImpact >= 10 {
            return .hangover
        }

        // 3. Sleep debt — > 6 hours of cumulative debt over the rolling window.
        if engine.sleepDebtHours > 6 {
            return .sleepDebt
        }

        // 4. Soft — 3+ consecutive days of low HRV signals long-term deficit.
        //    Manual toggle (the web app's Soft Day) also lands here via override.
        if engine.consecutiveLowHRVDays >= 3 {
            return .soft
        }

        // 5. Wired — currently auto-disabled. Will trigger on low HRV + high
        //    arousal markers once an anxiety detector exists. Manual-only for now.

        // 6. Push — top day. High recovery + slept well + clean strain ledger.
        if engine.recoveryScore >= 75
            && engine.sleepScore >= 75
            && engine.strainScore < 8 {
            return .push
        }

        // 7. Default — let AppMode drive the day on its own.
        return .normal
    }
}

// ════════════════════════════════════════════════════════════
// DayStateStore — observable, mirrors AppModeStore pattern.
//
// Recomputes every 5 minutes (DayState changes much slower than AppMode).
// Persists manual override in UserDefaults with 24h expiry — the day ends,
// the override clears.
// ════════════════════════════════════════════════════════════

@MainActor
final class DayStateStore: ObservableObject {
    @Published private(set) var current: DayState = .normal

    private weak var engine: HealthEngine?
    private var ticker: Timer?

    private let overrideKey = "lucid.dayState.override"
    private let overrideDateKey = "lucid.dayState.override.date"

    func start(engine: HealthEngine) {
        self.engine = engine
        recompute()
        ticker?.invalidate()
        // 5-minute tick — DayState moves on day-scale signals, no need to recompute often.
        ticker = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Force a specific DayState for the next 24 hours. Used by the manual
    /// "I feel like shit" / "I'm pushing today" buttons. Persists across
    /// app restarts within the 24h window.
    func setOverride(_ state: DayState) {
        UserDefaults.standard.set(state.rawValue, forKey: overrideKey)
        UserDefaults.standard.set(Date(), forKey: overrideDateKey)
        recompute()
    }

    /// Manually clear an active override and let auto-detection take over again.
    func clearOverride() {
        UserDefaults.standard.removeObject(forKey: overrideKey)
        UserDefaults.standard.removeObject(forKey: overrideDateKey)
        recompute()
    }

    /// Whether a user-set override is currently active and unexpired.
    var hasActiveOverride: Bool { activeOverride != nil }

    /// The active manual override, if set within the last 24 hours. Stale
    /// overrides (> 24h old) are ignored so the auto-detector can resume.
    private var activeOverride: DayState? {
        guard let raw = UserDefaults.standard.string(forKey: overrideKey),
              let date = UserDefaults.standard.object(forKey: overrideDateKey) as? Date,
              Date().timeIntervalSince(date) < 24 * 3600,
              let state = DayState(rawValue: raw) else {
            return nil
        }
        return state
    }

    func recompute() {
        guard let engine else { return }
        let resolved = DayStateResolver.resolve(engine: engine, manualOverride: activeOverride)
        if resolved != current {
            current = resolved
        }
    }
}
