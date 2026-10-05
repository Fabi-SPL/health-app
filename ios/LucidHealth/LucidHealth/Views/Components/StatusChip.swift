import SwiftUI

/// Pill-shaped status chip — principle #4 pill radii, principle #9 *CONCEPT marker.
/// Three color styles: violet (default), teal, amber, danger.
enum StatusChipStyle {
    case violet, teal, amber, danger

    var color: Color {
        switch self {
        case .violet:  return DS.Colors.violet
        case .teal:    return DS.Colors.teal
        case .amber:   return DS.Colors.amber
        case .danger:  return DS.Colors.danger
        }
    }
}

struct StatusChip: View {
    let text: String
    var style: StatusChipStyle = .violet
    var icon: String? = nil

    private var color: Color { style.color }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.10))
        .overlay(
            Capsule().stroke(color.opacity(0.20), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }
}

#Preview {
    ZStack {
        AuroraBackground()
        VStack(spacing: 12) {
            StatusChip(text: "*CONCEPT", style: .violet)
            StatusChip(text: "n=12/14", style: .teal, icon: "chart.line.uptrend.xyaxis")
            StatusChip(text: "+6% HRV", style: .amber)
            StatusChip(text: "LOW", style: .danger, icon: "exclamationmark.triangle.fill")
        }
        .padding()
    }
}
