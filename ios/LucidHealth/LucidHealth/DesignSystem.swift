import SwiftUI

// ════════════════════════════════════════════════════════════
// Lucid Design System — single source of truth for all UI
// Canon: Minerva's "bedside instrument" board (2026-10-04).
//   Flat black ground, raised plates, no glass, blur, glow or gradient.
//   One blue for anything touchable; green/yellow/red only for recovery.
//   Each screen: one number, one line under it, one thing to do.
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
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
        static let pill: CGFloat = 100
    }

    // MARK: - Colors (bedside instrument: flat black, one blue, recovery trio)
    enum Colors {
        private static func dyn(_ dark: UInt, _ light: UInt, _ a: CGFloat = 1, _ la: CGFloat? = nil) -> Color {
            Color(UIColor { tc in
                let isDark = tc.userInterfaceStyle == .dark
                let h = isDark ? dark : light
                return UIColor(red: CGFloat((h >> 16) & 0xFF) / 255,
                               green: CGFloat((h >> 8) & 0xFF) / 255,
                               blue: CGFloat(h & 0xFF) / 255,
                               alpha: isDark ? a : (la ?? a))
            })
        }

        // Board tokens
        static let ground = dyn(0x000000, 0xF5F5F7)
        static let raised = dyn(0x1D1D1F, 0xFFFFFF)
        static let raised2 = dyn(0x2C2C2E, 0xF2F2F4)
        static let label = dyn(0xF5F5F7, 0x1D1D1F)
        static let secondaryLabel = dyn(0xA1A1A6, 0x6E6E73)
        static let separator = dyn(0x424245, 0xD2D2D7)
        static let accent = dyn(0x0A84FF, 0x0066CC)
        static let chartNeutral = dyn(0x636366, 0xAEAEB2)
        static let recoveryHigh = dyn(0x30D158, 0x1E7B34)
        static let recoveryMid = dyn(0xFFD60A, 0x9A4E00)
        static let recoveryLow = dyn(0xFF453A, 0xC4001A)
        static let recoveryHighBg = dyn(0x0C2A14, 0xE2F3E5)
        static let recoveryMidBg = dyn(0x2E2700, 0xFBECD9)
        static let recoveryLowBg = dyn(0x3B0F0C, 0xFDE4E6)
        static let primaryFill = dyn(0xF5F5F7, 0x000000)
        static let primaryText = dyn(0x000000, 0xFFFFFF)
        static let dim = dyn(0x6E6E73, 0xAEAEB2)
        static let chartTrack = dyn(0x2C2C2E, 0xE3E3E8)

        static func recoveryBg(_ score: Double) -> Color {
            if score >= 67 { return recoveryHighBg }
            if score >= 34 { return recoveryMidBg }
            return recoveryLowBg
        }

        // Backgrounds
        static let bg = ground
        static let surface = raised
        static let surfaceElevated = raised2
        static let surfaceStrong = dyn(0x3A3A3C, 0xE8E8ED)

        // Cards are opaque raised plates. No glass, no blur, no border glow.
        static let cardFill = raised
        static let cardFillElevated = raised2
        static let glow = Color.clear
        static let track = dyn(0x333336, 0xE5E5EA)

        // Text
        static let textPrimary = label
        static let textSecondary = secondaryLabel
        static let textMuted = dyn(0x8E8E93, 0x6E6E73)
        static let textFaint = dyn(0x636366, 0xAEAEB2)

        // Legacy accent names. Violet is retired: it now means the one blue.
        static let violet = accent
        static let teal = dyn(0xC7C7CC, 0x48484A)

        // Semantic
        static let success = recoveryHigh
        static let danger = recoveryLow
        static let warning = recoveryMid
        static let blue = accent
        static let pink = dyn(0xA1A1A6, 0x6E6E73)
        static let amber = warning

        // Borders
        static let border = dyn(0x2C2C2E, 0xE5E5EA)
        static let borderStrong = separator
        static let borderViolet = dyn(0x0A84FF, 0x0066CC, 0.35)
        static let borderTeal = border

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
            if score < 8 { return textSecondary }
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
            case 1: return chartNeutral
            case 2: return success
            case 3: return warning
            case 4: return danger
            default: return textMuted
            }
        }

        // Deep is the only stage series that takes the accent.
        static func stageColor(_ stage: HealthEngine.SleepStage) -> Color {
            switch stage {
            case .awake: return label
            case .light: return chartNeutral
            case .deep: return accent
            case .rem: return dyn(0x98989D, 0x8E8E93)
            }
        }

        static func mindColor(_ score: Double) -> Color {
            if score >= 10 { return success }
            if score >= 6  { return textSecondary }
            if score >= 3  { return warning }
            return danger
        }

        static func novaColor(_ nova: Double) -> Color {
            switch Int(nova.rounded()) {
            case 1: return success
            case 2: return textSecondary
            case 3: return warning
            default: return danger
            }
        }

        // Kept for callers; flat, no gradient look.
        static let brandGradient = LinearGradient(
            colors: [accent, accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Typography
    // Board scale: large title 34 semibold, section 20, body 17, secondary 15,
    // footnote 13, axis 11. Numerals are rounded semibold, always tabular.
    enum Font {
        static let display = SwiftUI.Font.system(size: 34, weight: .semibold)
        static let title1 = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let title2 = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let title3 = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15, weight: .regular)
        static let bodyMed = SwiftUI.Font.system(size: 15, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 13, weight: .regular)
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let micro = SwiftUI.Font.system(size: 9, weight: .semibold)

        static let heroNumber = SwiftUI.Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
        static let bigNumber = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
        static let scoreNumber = SwiftUI.Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
        static let statNumber = SwiftUI.Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
        static let recoveryNumber = SwiftUI.Font.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit()
        static let clock = SwiftUI.Font.system(size: 120, weight: .semibold, design: .rounded).monospacedDigit()
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
            case .sleep: return DS.Colors.accent
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

// MARK: - Ground
// The aurora is retired: every screen sits on flat ground. The recovery
// parameter is kept so existing call sites compile unchanged.
struct AuroraBackground: View {
    var recovery: Double? = nil

    var body: some View {
        DS.Colors.ground.ignoresSafeArea()
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
    }
}

/// Tier 3 — Pill: chips, tabs, FABs (100px / capsule)
struct AuroraPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(DS.Colors.cardFillElevated))
            .overlay(Capsule().stroke(DS.Colors.separator, lineWidth: 1))
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
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(tint.opacity(active ? 0.45 : 0.0), lineWidth: 1)
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

    static func sentenceCase(_ s: String) -> String {
        guard s == s.uppercased(), let first = s.first else { return s }
        return String(first) + s.dropFirst().lowercased()
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
            }
            Text(Self.sentenceCase(title))
                .font(DS.Font.title2)
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(DS.Colors.textSecondary)
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
    var valueText: String? = nil

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
                Text(valueText ?? "\(Int(score))")
                    .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
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

/// Two-tone typographic headline per Lucid Design Bundle principle 1.
/// Bold primary half locks the eye in 0.3s, muted secondary half adds context
/// without competing. Same font, same size, different weight + color.
struct TwoToneHeadline: View {
    let primary: String
    let secondary: String
    var font: SwiftUI.Font = DS.Font.display

    var body: some View {
        (
            Text(primary)
                .fontWeight(.semibold)
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
                            .fill(tint.opacity(configuration.isPressed ? 0.8 : 1))
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(DS.Colors.raised2.opacity(configuration.isPressed ? 1 : 0.6))
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
