import SwiftUI

/// Floating Aurora tab bar — 60pt, radius-26, icon-only, square accent
/// indicator behind the active icon (per AURORA-DESIGN-SPEC §2).
/// 4 tabs: Today / Health / Food / Insights.
/// Settings is NOT a tab — accessed via SettingsGearButton sheet.
enum AppTab: Int, CaseIterable {
    case today, health, food, insights

    var icon: String {
        switch self {
        case .today:    return "clock"
        case .health:   return "heart"
        case .food:     return "fork.knife"
        case .insights: return "chart.xyaxis.line"
        }
    }

    var label: String {
        switch self {
        case .today:    return "Today"
        case .health:   return "Health"
        case .food:     return "Food"
        case .insights: return "Insights"
        }
    }
}

struct PillTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    tabItem(tab)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
            }
        }
        .frame(height: 49, alignment: .top)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .background(alignment: .top) {
            DS.Colors.ground
                .overlay(alignment: .top) {
                    Rectangle().fill(DS.Colors.separator).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabItem(_ tab: AppTab) -> some View {
        let isActive = selectedTab == tab
        return VStack(spacing: 3) {
            Image(systemName: tab.icon)
                .font(.system(size: 20, weight: .regular))
                .frame(height: 24)
            Text(tab.label)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.top, 7)
        .foregroundStyle(isActive ? DS.Colors.accent : DS.Colors.secondaryLabel)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        AuroraBackground()
        PillTabBar(selectedTab: .constant(.today))
    }
}
