import SwiftUI

/// 8px colored category dot + uppercase label — principle #5.
/// Body=violet, Mind=teal, Care=amber, Sleep=lavender, Food=green.
struct CategoryDot: View {
    let category: DS.Category

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DS.Colors.dim)
                .frame(width: 6, height: 6)
            Text(category.label.capitalized)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.secondaryLabel)
        }
    }
}

#Preview {
    ZStack {
        AuroraBackground()
        VStack(alignment: .leading, spacing: 12) {
            CategoryDot(category: .body)
            CategoryDot(category: .mind)
            CategoryDot(category: .care)
            CategoryDot(category: .sleep)
            CategoryDot(category: .food)
        }
        .padding()
    }
}
