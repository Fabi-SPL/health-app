import SwiftUI

// ════════════════════════════════════════════════════════════
// Design System — single source of truth for all UI
// Canon: AURORA-DESIGN-SPEC.md (LOCKED 2026-06-24) + the four approved mockups
//
// The 5 Aurora laws:
//   1. Depth = ONE Aurora glow + card luminance + 1px borders.
//      Never glass, blur, reflections, specular sweeps, or dark-mode shadows.
//   2. Tokens only — DS.Colors / DS.Font / DS.Spacing / DS.Radius.
//      No raw Color literals, font sizes, or padding values in views.
//   3. Every number is monospacedDigit; display type gets negative tracking;
//      weights regular/semibold/heavy only — never medium for hierarchy.
//   4. One section grammar: uppercase tracked micro-label above a radius-20
//      card (15pt padding); chips and tab bar are pills; nested tiles use a
//      smaller radius than their parent.
//   5. Accents stay restrained: violet/teal brand + the semantic table
//      (green/amber/red/blue). Every section reads as a DIFFERENT chart
//      shape — never two of the same on one screen.
// ════════════════════════════════════════════════════════════

enum DS {
    // MARK: - Spacing (8-point grid)
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Corner Radius
    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let pill: CGFloat = 100
    }

    // MARK: - Colors (Brand — adaptive light/dark)
    enum Colors {
        // Backgrounds
        static let bg = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.031, green: 0.027, blue: 0.051, alpha: 1)    // #08070d Aurora
                : UIColor(red: 0.945, green: 0.941, blue: 0.965, alpha: 1)    // #f1f0f6 Aurora
        })
        static let surface = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.04)
                : UIColor(white: 1.0, alpha: 0.65)
        })
        static let surfaceElevated = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.07)
                : UIColor(white: 1.0, alpha: 0.80)
        })
        static let surfaceStrong = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.10)
                : UIColor(white: 1.0, alpha: 0.90)
        })

        // AURORA card surfaces — translucent dark over the glow (lets the violet
        // bleed through subtly) in dark, solid white in light. NO glass, NO blur,
        // NO reflection. Depth = luminance + 1px border.
        static let cardFill = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.086, green: 0.078, blue: 0.133, alpha: 0.55) // ~#161422 @55%
                : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)        // #ffffff
        })
        static let cardFillElevated = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.106, green: 0.098, blue: 0.157, alpha: 0.72) // ~#1b1928 @72%
                : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)        // #ffffff
        })
        /// Aurora glow — the ONE soft violet radial behind everything (top-center).
        static let glow = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.545, green: 0.486, blue: 0.965, alpha: 0.30) // violet @30%
                : UIColor(red: 0.486, green: 0.361, blue: 0.749, alpha: 0.16) // violet @16%
        })
        /// Empty ring / bar track (Aurora) — what unfilled chart segments sit on.
        static let track = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.10)
                : UIColor(red: 0.902, green: 0.894, blue: 0.933, alpha: 1) // #e6e4ee
        })

        // Text
        static let textPrimary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.91, green: 0.89, blue: 0.94, alpha: 1)       // #e8e4ef
                : UIColor(red: 0.10, green: 0.09, blue: 0.15, alpha: 1)       // #1a1625
        })
        static let textSecondary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.69, green: 0.68, blue: 0.75, alpha: 1)       // #b0adc0
                : UIColor(red: 0.23, green: 0.22, blue: 0.35, alpha: 1)       // #3a3858
        })
        static let textMuted = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.42, green: 0.41, blue: 0.50, alpha: 1)       // #6b6880
                : UIColor(red: 0.42, green: 0.41, blue: 0.53, alpha: 1)       // #6b6888
        })
        static let textFaint = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.29, green: 0.28, blue: 0.38, alpha: 1)       // #4a4760
                : UIColor(red: 0.60, green: 0.60, blue: 0.66, alpha: 1)       // #9a98a8
        })

        // Accent (adaptive violet/teal)
        static let violet = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.545, green: 0.486, blue: 0.965, alpha: 1)    // #8B7CF6
                : UIColor(red: 0.486, green: 0.361, blue: 0.749, alpha: 1)    // #7c5cbf
        })
        static let teal = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.310, green: 0.820, blue: 0.773, alpha: 1)    // #4FD1C5
                : UIColor(red: 0.051, green: 0.580, blue: 0.533, alpha: 1)    // #0d9488
        })

        // Semantic (adaptive) — Aurora table: green #34d39a, amber #f5b948,
        // red #f06464, blue #5b8def in dark; darker siblings in light.
        static let success = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.204, green: 0.827, blue: 0.604, alpha: 1)    // #34d39a
                : UIColor(red: 0.063, green: 0.659, blue: 0.400, alpha: 1)    // #10a866
        })
        static let danger = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.941, green: 0.392, blue: 0.392, alpha: 1)    // #f06464
                : UIColor(red: 0.812, green: 0.251, blue: 0.251, alpha: 1)    // #cf4040
        })
        static let warning = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.961, green: 0.725, blue: 0.282, alpha: 1)    // #f5b948
                : UIColor(red: 0.741, green: 0.490, blue: 0.063, alpha: 1)    // #bd7d10
        })
        static let blue = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.357, green: 0.553, blue: 0.937, alpha: 1)    // #5b8def
                : UIColor(red: 0.247, green: 0.435, blue: 0.816, alpha: 1)    // #3f6fd0
        })

        static let pink = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.925, green: 0.282, blue: 0.600, alpha: 1)    // #EC4899
                : UIColor(red: 0.780, green: 0.157, blue: 0.478, alpha: 1)    // #c7287a
        })
        static let amber = warning

        // Borders (adaptive)
        static let border = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.08)
                : UIColor(white: 0.0, alpha: 0.06)
        })
        static let borderStrong = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 0.15)
                : UIColor(red: 0.486, green: 0.361, blue: 0.749, alpha: 0.15)
        })
        // Adaptive accent borders (were fixed dark-mode hex — invisible-ish in light)
        static let borderViolet = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.545, green: 0.486, blue: 0.965, alpha: 0.18)
                : UIColor(red: 0.486, green: 0.361, blue: 0.749, alpha: 0.22)
        })
        static let borderTeal = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.310, green: 0.820, blue: 0.773, alpha: 0.15)
                : UIColor(red: 0.051, green: 0.580, blue: 0.533, alpha: 0.20)
        })

        // Recovery zones
        static func recoveryColor(_ score: Double) -> Color {
            if score >= 67 { return success }
            if score >= 34 { return warning }
            return danger
        }

        static func sleepColor(_ score: Double) -> Color {
            if score >= 70 { return success }
            if score >= 40 { return warning }
            return danger
        }

        static func strainColor(_ score: Double) -> Color {
            if score < 8 { return teal }
            if score < 14 { return warning }
            return danger
        }

        static func bodyBatteryColor(_ level: Double) -> Color {
            if level >= 60 { return success }
            if level >= 30 { return warning }
            return danger
        }

        static func readinessColor(_ readiness: HealthEngine.ReadinessLevel) -> Color {
            switch readiness {
            case .green: return success
            case .yellow: return warning
            case .red: return danger
            case .unknown: return textMuted
            }
        }

        static func zoneColor(_ zone: Int) -> Color {
            switch zone {
            case 0: return textMuted
            case 1: return teal
            case 2: return success
            case 3: return warning
            case 4: return danger
            default: return textMuted
            }
        }

        static func stageColor(_ stage: HealthEngine.SleepStage) -> Color {
            switch stage {
            case .awake: return warning
            case .light: return Color(hex: 0xFDE68A) // soft yellow
            case .deep: return teal
            case .rem: return blue
            }
        }

        static func mindColor(_ score: Double) -> Color {
            if score >= 10 { return success }
            if score >= 6  { return teal }
            if score >= 3  { return warning }
            return danger
        }

        static func novaColor(_ nova: Double) -> Color {
            switch Int(nova.rounded()) {
            case 1: return success
            case 2: return teal
            case 3: return warning
            default: return danger
            }
        }

        // Gradient
        static let brandGradient = LinearGradient(
            colors: [violet, teal],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Typography
    // Sized for iPhone 15 Pro (393pt wide). Uses .rounded design.
    // Switch to Font.custom("Outfit", ...) when font is bundled.
    enum Font {
        static let display = SwiftUI.Font.system(size: 28, weight: .heavy, design: .rounded)
        static let title1 = SwiftUI.Font.system(size: 22, weight: .heavy, design: .rounded)
        static let title2 = SwiftUI.Font.system(size: 18, weight: .bold, design: .rounded)
        static let title3 = SwiftUI.Font.system(size: 15, weight: .semibold, design: .rounded)
        static let body = SwiftUI.Font.system(size: 14, weight: .regular)
        static let bodyMed = SwiftUI.Font.system(size: 14, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 12, weight: .regular)
        static let label = SwiftUI.Font.system(size: 10, weight: .bold)
        static let micro = SwiftUI.Font.system(size: 8, weight: .bold)

        // Numeric — sized for 393pt width. monospacedDigit baked in (Aurora law
        // #3: tabular numbers everywhere) so callers can't forget it.
        static let heroNumber = SwiftUI.Font.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit()
        static let bigNumber = SwiftUI.Font.system(size: 24, weight: .bold, design: .rounded).monospacedDigit()
        static let scoreNumber = SwiftUI.Font.system(size: 20, weight: .heavy, design: .rounded).monospacedDigit()
        static let statNumber = SwiftUI.Font.system(size: 16, weight: .bold, design: .rounded).monospacedDigit()
    }

    // MARK: - Animations
    // Smoothness pass (2026-06-01): higher damping = no overshoot wobble on UI
    // transitions (Emil rule: ease-out, no bounce for functional motion). Every
    // card-appear / stagger / state change across all 14 screens flows through
    // these, so tuning here smooths the whole app at once.
    enum Anim {
        static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)
        static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.7)
        /// Snappy ease-out for taps / toggles — instant-feeling feedback.
        static let quick = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
        /// Smooth ease-out-quint for content swaps (numbers, text, opacity).
        static let smooth = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
        static let ringFill = Animation.spring(response: 0.85, dampingFraction: 0.82)
        static let countUp = Animation.spring(response: 0.9, dampingFraction: 0.85)
        /// Card entrance — smooth settle, no visible bounce.
        static let cardAppear = Animation.spring(response: 0.46, dampingFraction: 0.85)
        /// Gentle 4s breathing loop for live-data anchors (recovery ring steady-state)
        static let breath = Animation.easeInOut(duration: 4.0).repeatForever(autoreverses: true)
        /// Hero ring fill entrance — slower spring, more drama
        static let ringEntrance = Animation.spring(response: 1.2, dampingFraction: 0.8)

        /// Staggered delay for list items. Capped at 8 so long lists don't drag
        /// the last cards in noticeably late (was a jank tell on Settings/Health).
        static func stagger(index: Int) -> Animation {
            cardAppear.delay(Double(min(index, 8)) * 0.05)
        }
    }

    // MARK: - Haptics (one vocabulary, app-wide)
    // Four verbs only. Every interactive surface speaks the same touch language:
    //   tap     — navigation, chips, toggles, anything light
    //   commit  — state-changing actions (start/end/save-intent/wake)
    //   success — a save/write confirmed
    //   error   — a save/write failed
    //   select  — tab/segment selection (UISelectionFeedback)
    enum Haptic {
        static func tap()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        static func commit()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        static func error()   { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        static func select()  { UISelectionFeedbackGenerator().selectionChanged() }
    }

    // MARK: - Category dot colors (principle #5)
    enum Category {
        case body, mind, care, sleep, food

        var color: Color {
            switch self {
            case .body:  return DS.Colors.violet
            case .mind:  return DS.Colors.teal
            case .care:  return DS.Colors.amber
            case .sleep: return Color(hex: 0xA78BFA)  // soft lavender
            case .food:  return DS.Colors.success
            }
        }

        var label: String {
            switch self {
            case .body:  return "BODY"
            case .mind:  return "MIND"
            case .care:  return "CARE"
            case .sleep: return "SLEEP"
            case .food:  return "FOOD"
            }
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Aurora Background (the LIVING canvas)
// Solid bg + ONE soft violet glow. When given `recovery`, the glow becomes
// ALIVE: it breathes (period paced by recovery), its intensity tracks how
// recovered the body is (depleted = dim/cool, charged = luminous + teal life),
// and it drifts lower/higher with the circadian phase of the day. nil recovery
// = the calm static glow (sheets, previews). No mesh, no reflections.
struct AuroraBackground: View {
    /// 0–100. nil = static calm glow (transient sheets keep the still canvas).
    var recovery: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let rec = recovery, rec > 0, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
                livingGlow(recovery: rec, date: ctx.date, breathing: true)
            }
        } else if let rec = recovery, rec > 0 {
            livingGlow(recovery: rec, date: Date(), breathing: false)
        } else {
            staticGlow
        }
    }

    private var staticGlow: some View {
        ZStack {
            DS.Colors.bg.ignoresSafeArea()
            RadialGradient(
                gradient: Gradient(colors: [DS.Colors.glow, DS.Colors.glow.opacity(0)]),
                center: UnitPoint(x: 0.5, y: -0.05),
                startRadius: 0,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }

    private func livingGlow(recovery: Double, date: Date, breathing: Bool) -> some View {
        let rec = max(0.0, min(1.0, recovery / 100.0))
        let period = 7.0 - rec * 2.5                      // depleted breathes slow (~7s), charged fast (~4.5s)
        let breath = breathing ? sin(date.timeIntervalSinceReferenceDate / period * 2 * .pi) : 0.0
        let opacity = max(0.0, min(1.0, (0.5 + rec * 0.5) + breath * 0.09))
        let radius: CGFloat = 500 + CGFloat(breath) * 30
        let hour = Calendar.current.component(.hour, from: date)
        let dayPhase = 0.5 - 0.5 * cos(Double((hour + 21) % 24) / 24.0 * 2 * .pi)  // 0 at ~3am, 1 at ~3pm
        let yCenter = -0.10 + (1 - dayPhase) * 0.08      // sits lower at night
        let tealMix = rec * (0.4 + dayPhase * 0.35)      // teal life only when charged + daytime
        return ZStack {
            DS.Colors.bg.ignoresSafeArea()
            RadialGradient(
                gradient: Gradient(colors: [DS.Colors.glow.opacity(opacity), DS.Colors.glow.opacity(0)]),
                center: UnitPoint(x: 0.5, y: yCenter),
                startRadius: 0,
                endRadius: radius
            )
            .ignoresSafeArea()
            RadialGradient(
                gradient: Gradient(colors: [DS.Colors.teal.opacity(0.12 * tealMix), .clear]),
                center: UnitPoint(x: 0.5, y: yCenter + 0.02),
                startRadius: 0,
                endRadius: radius * 0.82
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - Aurora card tiers
// Flat luminance cards (Aurora law #1) — the .glass* method names are kept for
// source stability; the tiers themselves are Aurora, not glass.

/// Tier 1 — Subtle: list rows, nested cells (16px radius)
struct AuroraSubtle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(DS.Colors.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .stroke(DS.Colors.border, lineWidth: 0.5)
            )
    }
}

/// Tier 2 — Default: standard cards (20px radius)
struct AuroraDefault: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(DS.Colors.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .stroke(DS.Colors.border, lineWidth: 0.5)
            )
    }
}

/// Tier 3 — Pill: chips, tabs, FABs (100px / capsule)
struct AuroraPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(DS.Colors.cardFillElevated))
            .overlay(Capsule().stroke(DS.Colors.border, lineWidth: 0.5))
    }
}

// MARK: - Convenience extension for the Aurora tiers
extension View {
    func glassSubtle()  -> some View { modifier(AuroraSubtle()) }
    func glassDefault() -> some View { modifier(AuroraDefault()) }
    func glassPill()    -> some View { modifier(AuroraPill()) }

    /// Subtle scale + opacity falloff as a section leaves the viewport.
    /// Keeps cards feeling alive without the "obvious AI animation" tell.
    /// Use only on top-level scroll sections, not on every nested element.
    func scrollSectionTransition() -> some View {
        scrollTransition { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1.0 : 0.96)
                .opacity(phase.isIdentity ? 1.0 : 0.65)
        }
    }
}

// MARK: - Glass Card (Aurora flat card, legacy name)

struct GlassCard: ViewModifier {
    var padding: CGFloat = DS.Spacing.md
    var radius: CGFloat = DS.Radius.lg
    var tint: Color = DS.Colors.violet
    var tintOpacity: Double = 0.08

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DS.Colors.cardFill)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(DS.Colors.border, lineWidth: 0.5)
            )
    }
}

/// Accent glass card — a standard glass card tinted by a status color. For cards
/// that carry meaning through color (wake-coach verdict, smart-alarm enabled,
/// last-night signal). Same glass DNA as every other card so accent surfaces stop
/// reading as a bolted-on different app. Caller keeps its own content padding.
struct AccentGlassCard: ViewModifier {
    var tint: Color
    var active: Bool = true
    var radius: CGFloat = DS.Radius.lg

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DS.Colors.cardFill)
            )
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint.opacity(active ? 0.07 : 0.0))
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(tint.opacity(active ? 0.32 : 0.12), lineWidth: active ? 1.0 : 0.5)
            )
    }
}

struct HeroCard: ViewModifier {
    var color: Color = DS.Colors.violet

    func body(content: Content) -> some View {
        content
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                    .fill(DS.Colors.cardFillElevated)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                    .stroke(DS.Colors.border, lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard(
        padding: CGFloat = DS.Spacing.md,
        elevated: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(GlassCard(
            padding: padding,
            tint: tint ?? DS.Colors.violet,
            tintOpacity: tint != nil ? 0.08 : 0.04
        ))
    }

    func heroCard(color: Color = DS.Colors.violet) -> some View {
        modifier(HeroCard(color: color))
    }

    /// Status-tinted glass card (wake coach, smart alarm, last-night). Caller
    /// supplies its own content padding before this modifier.
    func accentGlassCard(tint: Color, active: Bool = true) -> some View {
        modifier(AccentGlassCard(tint: tint, active: active))
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    var icon: String = ""
    let title: String
    var iconColor: Color = DS.Colors.violet
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
            }
            Text(title)
                .font(DS.Font.label)
                .foregroundStyle(DS.Colors.textMuted)
                .tracking(0.8)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(iconColor)
            }
        }
    }
}

// MARK: - Score Ring (Recovery / Sleep / Strain hero display)

struct ScoreRing: View {
    let score: Double
    var maxScore: Double = 100
    var size: CGFloat = 56
    var lineWidth: CGFloat = 4
    var color: Color = DS.Colors.success
    var label: String? = nil

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(DS.Colors.track, lineWidth: lineWidth)

            // Progress
            Circle()
                .trim(from: 0, to: min(score / maxScore, 1.0))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(DS.Anim.ringFill, value: score)

            // Center text
            VStack(spacing: 0) {
                Text("\(Int(score))")
                    .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let label {
                    Text(label)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DS.Colors.textMuted)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Info Row (icon + label + value)

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    var color: Color = DS.Colors.textSecondary

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color.opacity(0.7))
                .frame(width: 24)
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Colors.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.xs)
    }
}

// MARK: - Alert Banner

struct AlertBanner: View {
    let icon: String
    let message: String
    var color: Color = DS.Colors.warning

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(3)
            Spacer()
        }
        .glassCard(padding: 12, tint: color)
        .padding(.horizontal)
    }
}

// MARK: - Glass Status Pill

struct GlassStatusPill: View {
    let icon: String
    let text: String
    var color: Color = DS.Colors.violet

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.10))
        .overlay(
            Capsule()
                .stroke(color.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }
}

// MARK: - Metric Tile

struct MetricTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var color: Color = DS.Colors.violet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(DS.Font.micro)
                .foregroundStyle(DS.Colors.textMuted)
                .tracking(0.7)

            Text(value)
                .font(DS.Font.title2)
                .foregroundStyle(color)
                .monospacedDigit()

            if !unit.isEmpty {
                Text(unit)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        // .leading = horizontal-leading + vertical-CENTER. With minHeight 108 the
        // tiles stay row-consistent, but short content (e.g. SDNN/42/ms) no longer
        // pins to the top with a 48pt dead zone below — vertically centered now.
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(DS.Spacing.md)
        .glassCard(padding: 0, tint: color)
    }
}

// MARK: - Empty Glass State

struct EmptyGlassState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(DS.Colors.textFaint)
            Text(title)
                .font(DS.Font.bodyMed)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Colors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .glassCard(padding: DS.Spacing.md)
    }
}

// MARK: - Two-Tone Headline

/// Two-tone typographic headline per Design Bundle principle 1.
/// Bold primary half locks the eye in 0.3s, muted secondary half adds context
/// without competing. Same font, same size, different weight + color.
struct TwoToneHeadline: View {
    let primary: String
    let secondary: String
    var font: SwiftUI.Font = DS.Font.display

    var body: some View {
        (
            Text(primary)
                .fontWeight(.heavy)
                .foregroundStyle(DS.Colors.textPrimary)
            + Text(secondary.hasPrefix(" ") ? "" : " ")
                .foregroundStyle(DS.Colors.textPrimary)
            + Text(secondary)
                .fontWeight(.regular)
                .foregroundStyle(DS.Colors.textMuted)
        )
        .font(font)
        .kerning(-0.5)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Glass Action Button Style

struct GlassActionButtonStyle: ButtonStyle {
    var tint: Color = DS.Colors.violet
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(filled ? Color.white : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Group {
                    if filled {
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(tint.opacity(configuration.isPressed ? 0.52 : 0.70))
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(tint.opacity(configuration.isPressed ? 0.18 : 0.10))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Pressable Card Style

/// Press feedback for whole-card buttons (tiles, list rows) that currently use
/// `.buttonStyle(.plain)` and feel dead on tap. Subtle scale + opacity dip —
/// makes every tappable surface feel physically responsive (Emil rule).
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension View {
    /// Apply tactile press feedback to a card-shaped Button.
    func pressableCard() -> some View { buttonStyle(PressableCardStyle()) }

    /// Canonical card entrance — rise + fade, staggered by index. One source of
    /// truth for the offset(20)/opacity/stagger pattern that was hand-copied
    /// across every screen (often with duplicated indices). Drive it from a
    /// single `appeared` flag set in the view's .task/.onAppear.
    func entrance(_ appeared: Bool, index: Int) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .animation(DS.Anim.stagger(index: index), value: appeared)
    }
}
