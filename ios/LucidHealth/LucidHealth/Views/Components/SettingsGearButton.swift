import SwiftUI

/// Gear icon button (top-trailing) — presents SettingsView as a sheet.
/// 44pt minimum tap target per HIG.
struct SettingsGearButton: View {
    @State private var showSettings = LucidScreen.current == .settings

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(DS.Colors.label)
                .frame(width: 40, height: 40)
                .background(Circle().fill(DS.Colors.raised))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

#Preview {
    ZStack {
        AuroraBackground()
        HStack {
            Spacer()
            SettingsGearButton()
        }
        .padding()
    }
}
