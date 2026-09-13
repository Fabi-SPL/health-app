// SKELETON-EDIT 2026-06-12T16:47:26.134Z audit:chat-1781282690088-8diz model:Qwen/Qwen3-Coder-480B-A35B-Instruct revert: node scripts/revert.mjs chat-1781282690088-8diz
import SwiftUI

/// A clean, minimal segmented control for switching between sections.
/// Uses the existing design system (DS) for consistent styling and animations.
struct SegmentedControlView: View {
    @Binding var selection: TodaySection
    private let sections = TodaySection.allCases
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(sections, id: \.self) { section in
                SegmentedControlItem(
                    title: section.rawValue,
                    isSelected: selection == section,
                    action: { 
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            selection = section
                        }
                    }
                )
                
                if section != sections.last {
                    Spacer()
                }
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(DS.Colors.surface)
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.border, lineWidth: 0.5)
                )
                .glassEffect(intensity: 0.1, luminosity: 0.8)
        )
        .frame(height: 44)
    }
}

/// Individual item within the segmented control
private struct SegmentedControlItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Text(title)
            .font(DS.Font.bodyMed)
            .foregroundColor(isSelected ? DS.Colors.violet : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                impactFeedback.impactOccurred()
                action()
            }
    }
}

#Preview {
    VStack {
        SegmentedControlView(selection: .constant(.coreMetrics))
            .padding()
    }
    .background(DS.Colors.bg)
}