import SwiftUI

/// Unified discovery card — the ONE card language for every insight system
/// (Health-computed patterns, Gemini cross-domain, featured discovery).
/// Grammar: provenance badge + signed-delta badge → headline → mini-visual
/// (comparison bars or strength meter, never prose) → one caption line.
/// The old sentence-subtitle lives behind the ⓘ toggle.
struct InsightCard: View {
    let pattern: FoodPattern

    @State private var showDetail = false
    @State private var appeared = false

    private var isLucid: Bool { pattern.source == .lucid }
    private var provenanceColor: Color { isLucid ? DS.Colors.teal : DS.Colors.violet }
    private var effectColor: Color { pattern.effectPositive ? DS.Colors.teal : DS.Colors.danger }

    private var provenanceBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: isLucid ? "diamond.fill" : "sparkles")
                .font(.system(size: 8, weight: .bold))
            Text(isLucid ? "LUCID · computed" : "GEMINI · AI guess")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.5)
        }
        .foregroundStyle(provenanceColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(provenanceColor.opacity(0.12)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                provenanceBadge
                Spacer()
                if let badge = pattern.badgeText {
                    DeltaBadge(text: badge, positive: pattern.effectPositive)
                }
            }

            Text(pattern.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Mini-visual — the evidence. Comparison beats meter beats nothing.
            if let comp = pattern.comparison {
                MiniComparisonBars(comparison: comp, accent: effectColor, animate: appeared)
            } else if let r = pattern.rValue {
                StrengthMeter(r: r, positive: pattern.effectPositive, sampleN: pattern.sampleN)
            } else if let effect = pattern.effectDescription {
                // Gemini/speculative rows without numbers — arrow + short effect line.
                HStack(spacing: 6) {
                    Image(systemName: pattern.effectPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(effectColor)
                    Text(effect)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
            }

            // Caption line — confidence · sample, ⓘ opens the prose.
            HStack(spacing: 6) {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.textFaint)
                Spacer()
                Button {
                    DS.Haptic.tap()
                    withAnimation(DS.Anim.quick) { showDetail.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(showDetail ? DS.Colors.violet : DS.Colors.textFaint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if showDetail {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pattern.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Correlation from your daily values · pattern, not causation.")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(DS.Colors.textFaint)
                }
                .transition(.opacity)
            }

            if let note = pattern.dataQualityNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.amber)
                    Text(note)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(DS.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
        .onAppear { appeared = true }
    }

    private var caption: String {
        var parts: [String] = ["\(Int((pattern.confidenceValue * 100).rounded()))% confidence"]
        if let n = pattern.sampleN, n > 0 { parts.append("\(n) days") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shared insight visual primitives

/// Signed effect chip — "+9%", "−12", "r .62". Sign glyph is baked in so the
/// direction never relies on color alone.
struct DeltaBadge: View {
    let text: String
    let positive: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(positive ? DS.Colors.teal : DS.Colors.danger)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill((positive ? DS.Colors.teal : DS.Colors.danger).opacity(0.12)))
    }
}

/// Before/after comparison — two labeled horizontal capsules, widths
/// proportional to value. Replaces "X vs Y" sentences.
struct MiniComparisonBars: View {
    let comparison: PatternComparison
    let accent: Color
    var animate: Bool = true

    private var maxVal: Double { max(comparison.before, comparison.after, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: comparison.beforeLabel, value: comparison.before, color: DS.Colors.textFaint.opacity(0.55), textColor: DS.Colors.textSecondary)
            row(label: comparison.afterLabel, value: comparison.after, color: accent, textColor: accent)
        }
        .padding(.vertical, 2)
    }

    private func row(label: String, value: Double, color: Color, textColor: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textMuted)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(color)
                    .frame(width: animate ? max(8, geo.size.width * CGFloat(value / maxVal)) : 8, height: 10)
                    .animation(DS.Anim.cardAppear, value: animate)
            }
            .frame(height: 10)
            Text(String(format: "%.0f", value))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(textColor)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// 5-dot correlation strength meter — replaces "strong link · r 0.62" jargon.
/// Dots fill by |r| in 0.2 bands; the arrow carries direction.
struct StrengthMeter: View {
    let r: Double
    let positive: Bool
    var sampleN: Int? = nil

    private var filled: Int { min(5, max(1, Int((abs(r) / 0.2).rounded(.up)))) }
    private var color: Color { positive ? DS.Colors.teal : DS.Colors.danger }
    private var word: String {
        switch abs(r) {
        case 0.6...:     return "strong"
        case 0.4..<0.6:  return "clear"
        case 0.25..<0.4: return "mild"
        default:         return "weak"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i < filled ? color : DS.Colors.track)
                        .frame(width: 7, height: 7)
                }
            }
            Image(systemName: positive ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(sampleN.map { "\(word) · \($0) days" } ?? word)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Models

/// One day of health_metrics, dated so food (by day) can be joined to it.
struct DailyMetric {
    let date: String          // "yyyy-MM-dd" (UTC metric_date)
    let recovery: Double?
    let sleepScore: Double?
    let sleepHours: Double?
    let hrv: Double?
    let restingHr: Double?
    let alcoholImpact: Double?
}

/// Two-group comparison behind a pattern (e.g. sober vs drinking nights).
struct PatternComparison {
    let beforeLabel: String
    let afterLabel: String
    let before: Double
    let after: Double
    let unit: String
}

struct FoodPattern: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let confidenceTier: ConfidenceTier
    let confidenceValue: Double    // 0.0–1.0
    let effectDescription: String?
    let effectPositive: Bool
    let source: Source             // who made this connection
    let dataQualityNote: String?   // e.g. "logging inconsistent — read loosely"
    // Visual evidence (2026-07 redesign) — populated by InsightEngine so cards
    // can draw the numbers instead of narrating them.
    let sampleN: Int?
    let rValue: Double?
    let comparison: PatternComparison?
    let badgeText: String?         // signed chip: "+9%", "r .62"

    enum ConfidenceTier { case high, medium, low }
    // Provenance: .lucid = deterministic correlation we computed. .gemini = AI-generated, speculative.
    enum Source { case lucid, gemini }

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        confidenceTier: ConfidenceTier,
        confidenceValue: Double,
        effectDescription: String? = nil,
        effectPositive: Bool = true,
        source: Source = .lucid,
        dataQualityNote: String? = nil,
        sampleN: Int? = nil,
        rValue: Double? = nil,
        comparison: PatternComparison? = nil,
        badgeText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.confidenceTier = confidenceTier
        self.confidenceValue = confidenceValue
        self.effectDescription = effectDescription
        self.effectPositive = effectPositive
        self.source = source
        self.dataQualityNote = dataQualityNote
        self.sampleN = sampleN
        self.rValue = rValue
        self.comparison = comparison
        self.badgeText = badgeText
    }
}
