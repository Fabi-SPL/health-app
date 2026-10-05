import SwiftUI

/// Segmented bar showing the four recovery contributors.
struct RecoveryBreakdownBar: View {
    let hrv: Double       // 0-100 contribution
    let rhr: Double
    let sleep: Double
    let rr: Double        // strain modifier slot

    private struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
        let color: Color
    }

    private var segments: [Segment] {
        let total = hrv + rhr + sleep + rr
        guard total > 0 else { return [] }
        return [
            Segment(label: "HRV", value: hrv / total, color: DS.Colors.teal),
            Segment(label: "RHR", value: rhr / total, color: DS.Colors.violet),
            Segment(label: "Sleep", value: sleep / total, color: DS.Colors.chartNeutral),
            Segment(label: "Strain", value: rr / total, color: DS.Colors.amber),
        ].filter { $0.value > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments) { seg in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(seg.color)
                            .frame(width: max(2, geo.size.width * CGFloat(seg.value)))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Legend
            HStack(spacing: DS.Spacing.md) {
                ForEach(segments) { seg in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(seg.color)
                            .frame(width: 6, height: 6)
                        Text(seg.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(DS.Colors.textFaint)
                        Text(String(format: "%.0f%%", seg.value * 100))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
        }
    }
}
