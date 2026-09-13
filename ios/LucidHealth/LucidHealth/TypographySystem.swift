// SKELETON-EDIT 2026-06-12T16:48:42.596Z audit:chat-1781282690088-8diz model:Qwen/Qwen3-Coder-480B-A35B-Instruct revert: node scripts/revert.mjs chat-1781282690088-8diz
import SwiftUI

// ════════════════════════════════════════════════════════════
// Lucid Health Typography System
// Locked typography levels for minimalistic luxury design
// ════════════════════════════════════════════════════════════

extension Font {
    /// Display Large: 40pt, semi-bold
    /// Used for: body_battery and other primary display elements
    static var displayLarge: Font {
        return Font.system(size: 40, weight: .semibold)
    }
    
    /// Body Primary: 17pt, regular
    /// Used for: card titles and primary content
    static var bodyPrimary: Font {
        return Font.system(size: 17, weight: .regular)
    }
    
    /// Caption Secondary: 13pt, light
    /// Used for: values, units, and secondary information
    static var captionSecondary: Font {
        return Font.system(size: 13, weight: .light)
    }
}

// ════════════════════════════════════════════════════════════
// Usage Examples:
//
// Text("87")
//     .font(.displayLarge)
//
// Text("Body Battery")
//     .font(.bodyPrimary)
//
// Text("percent")
//     .font(.captionSecondary)
// ════════════════════════════════════════════════════════════