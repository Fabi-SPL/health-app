// SKELETON-EDIT 2026-06-12T16:46:45.534Z audit:chat-1781282690088-8diz model:Qwen/Qwen3-Coder-480B-A35B-Instruct revert: node scripts/revert.mjs chat-1781282690088-8diz
import SwiftUI

/// A unified glass card component with consistent styling and haptic feedback.
/// Features subtle inner shadows, consistent rounded corners (radius-22),
/// and three distinct haptic levels for different action types.
struct AccentGlassCard<Content: View>: View {
    private let content: Content
    private let hapticLevel: HapticLevel
    private let onTap: (() -> Void)?
    
    enum HapticLevel {
        case light, medium, heavy
    }
    
    init(hapticLevel: HapticLevel = .medium, onTap: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.hapticLevel = hapticLevel
        self.onTap = onTap
    }
    
    var body: some View {
        ZStack {
            // Main card background with glass effect
            Capsule()
                .fill(DS.Colors.surface)
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.border, lineWidth: 0.5)
                )
                .glassEffect(intensity: 0.15, luminosity: 0.8)
                .shadow(color: DS.Colors.violet.opacity(0.1), radius: 8, x: 0, y: 4)
                .shadow(color: DS.Colors.violet.opacity(0.05), radius: 1, x: 0, y: 1)
            
            // Inner shadow for depth
            Capsule()
                .stroke(DS.Colors.shimmer.opacity(0.1), lineWidth: 1)
                .shadow(color: .black.opacity(0.1), radius: 0, x: 0, y: 1)
                .clipShape(Capsule())
            
            // Content
            content
                .padding(DS.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .onTapGesture {
            triggerHapticFeedback()
            onTap?()
        }
    }
    
    private func triggerHapticFeedback() {
        let impactFeedback = UIImpactFeedbackGenerator(style: convertHapticLevel())
        impactFeedback.impactOccurred()
    }
    
    private func convertHapticLevel() -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch hapticLevel {
        case .light:
            return .light
        case .medium:
            return .medium
        case .heavy:
            return .heavy
        }
    }
}

// Extension to add haptic levels to any view
extension View {
    func hapticTap(_ level: AccentGlassCard.HapticLevel = .medium, action: @escaping () -> Void) -> some View {
        AccentGlassCard(hapticLevel: level, onTap: action) {
            self
        }
    }
}

#Preview {
    VStack(spacing: DS.Spacing.lg) {
        AccentGlassCard(hapticLevel: .light) {
            Text("Light Haptic Card")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
        }
        .frame(height: 100)
        
        AccentGlassCard(hapticLevel: .medium) {
            Text("Medium Haptic Card")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
        }
        .frame(height: 100)
        
        AccentGlassCard(hapticLevel: .heavy) {
            Text("Heavy Haptic Card")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
        }
        .frame(height: 100)
    }
    .padding()
    .background(DS.Colors.bg)
}