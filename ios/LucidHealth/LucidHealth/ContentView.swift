import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @AppStorage(V3Appearance.key) private var appearanceRaw: String = V3Appearance.system.rawValue

    init() { LucidScreen.installGuard() }

    var body: some View {
        RootTabView()
            .environmentObject(bleManager)
            .preferredColorScheme((V3Appearance(rawValue: appearanceRaw) ?? .system).scheme)
    }
}
