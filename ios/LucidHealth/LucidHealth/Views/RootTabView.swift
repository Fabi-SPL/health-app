import SwiftUI

// MARK: - RootTabView
// Four tabs on the V3 board: Today, Health, Strain, Insights. Food logging moved
// behind the plus on Today. The wake screen after the smart alarm covers it all.

struct RootTabView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var selectedTab: AppTab = LucidScreen.current?.tab ?? .today
    @State private var showWake = LucidScreen.current == .wake
    @State private var wakeFireDate: Date?
    @State private var showSettingsShot = false
    @State private var showWindDown = false
    @StateObject private var modeStore = AppModeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            V3.bg.ignoresSafeArea()

            // Tab content: opacity swap keeps each tab's scroll position and state.
            ZStack {
                ForEach(AppTab.allCases, id: \.rawValue) { tab in
                    NavigationStack {
                        tabContent(tab)
                            .toolbar(.hidden, for: .navigationBar)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                // Opaque status-bar strip so scrolled cards never run under the clock.
                                Color.clear.frame(height: 0).background(V3.bg, ignoresSafeAreaEdges: .top)
                            }
                    }
                    .opacity(selectedTab == tab ? 1 : 0)
                    .allowsHitTesting(selectedTab == tab)
                }
            }
            .fullScreenCover(isPresented: $showWindDown) {
                WindDownV3View(bleManager: bleManager) { showWindDown = false }
                    .environmentObject(bleManager)
            }

            V3TabBar(selected: $selectedTab)
                .sheet(isPresented: $bleManager.showDoubleTapSheet) {
                    QuickTagSheet(ble: bleManager)
                        .environmentObject(bleManager)
                }
        }
        .ignoresSafeArea(.keyboard)
        .environment(\.selectTab) { selectedTab = $0 }
        .fullScreenCover(isPresented: $showWake) {
            WakeV3Screen(fireDate: wakeFireDate) { showWake = false }
                .environmentObject(bleManager)
        }
        .sheet(isPresented: $showSettingsShot) {
            NavigationStack { SettingsView() }
                .environmentObject(bleManager)
                .lucidRendered(.settings)
        }
        .task {
            modeStore.start(engine: bleManager.healthEngine)
            maybeShowWindDown(modeStore.current)
            switch LucidScreen.current {
            case .settings:
                try? await Task.sleep(for: .seconds(1.5))
                showSettingsShot = true
            default:
                break
            }
        }
        .onChange(of: modeStore.current) { _, mode in
            maybeShowWindDown(mode)
        }
        .onChange(of: scenePhase) { _, phase in
            bleManager.evt("app_state", "\(phase)")
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

    /// The wind-down takeover comes up at most once a night, when wind-down mode opens,
    /// and sends the wind-down notification with tonight's plan note.
    private func maybeShowWindDown(_ mode: AppMode) {
        guard mode == .windDown, LucidScreen.current == nil, !showWake else { return }
        let key = "lucid_winddown_shown_date"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        if UserDefaults.standard.string(forKey: key) == today { return }
        UserDefaults.standard.set(today, forKey: key)
        showWindDown = true
        bleManager.sendWindDownNotification(note: bleManager.tonightPlanNote)
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .today:
            TodayV3View()
                .environmentObject(bleManager)
                .lucidRendered(.offline)
        case .health:
            HealthV3View()
                .environmentObject(bleManager)
        case .strain:
            StrainV3View()
                .environmentObject(bleManager)
        case .insights:
            InsightsV3View()
                .environmentObject(bleManager)
        }
    }
}
