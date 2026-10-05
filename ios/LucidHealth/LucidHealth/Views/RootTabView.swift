import SwiftUI

// MARK: - RootTabView
// Flat bottom tab bar; the wake screen after the smart alarm covers it full screen.

struct RootTabView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var selectedTab: AppTab = LucidScreen.current?.tab ?? .today
    @State private var showWake = LucidScreen.current == .wake
    @State private var wakeFireDate: Date?
    @State private var showSettingsShot = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Living Aurora — shared canvas across all tabs (no reflow). Breathes +
            // reacts to recovery + drifts with circadian phase.
            AuroraBackground(recovery: bleManager.healthEngine.recoveryScore)
                .ignoresSafeArea()

            // Tab content — opacity/zIndex swap, no NavigationStack rerender
            ZStack {
                ForEach(AppTab.allCases, id: \.rawValue) { tab in
                    NavigationStack {
                        tabContent(tab)
                    }
                    .opacity(selectedTab == tab ? 1 : 0)
                    .allowsHitTesting(selectedTab == tab)
                }
            }
            .ignoresSafeArea()

            // Content scrolls under a flat status-bar strip, never under the clock.
            VStack(spacing: 0) {
                Color.clear.frame(height: 0)
                    .background(DS.Colors.ground.ignoresSafeArea(edges: .top))
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            // Floating pill tab bar at bottom
            PillTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(.keyboard)
        .environment(\.selectTab) { selectedTab = $0 }
        .fullScreenCover(isPresented: $showWake) {
            WakeScreen(fireDate: wakeFireDate) { showWake = false }
                .environmentObject(bleManager)
        }
        .sheet(isPresented: $showSettingsShot) {
            NavigationStack { SettingsView() }
                .environmentObject(bleManager)
                .lucidRendered(.settings)
        }
        .task {
            guard LucidScreen.current == .settings else { return }
            try? await Task.sleep(for: .seconds(1.5))
            showSettingsShot = true
        }
        .onReceive(bleManager.healthEngine.$smartAlarmTriggered) { fired in
            guard fired else { return }
            wakeFireDate = bleManager.healthEngine.alarmLastFireDate ?? Date()
            showWake = true
        }
        .onAppear {
            if let f = bleManager.healthEngine.alarmLastFireDate, Date().timeIntervalSince(f) < 30 * 60 {
                wakeFireDate = f
                showWake = true
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .today:
            TodayView()
                .environmentObject(bleManager)
        case .health:
            HealthView()
                .environmentObject(bleManager)
        case .food:
            FoodView()
                .environmentObject(bleManager)
        case .insights:
            InsightsView()
                .environmentObject(bleManager)
        }
    }
}
