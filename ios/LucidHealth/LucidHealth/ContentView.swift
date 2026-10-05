import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager

    init() { LucidScreen.installGuard() }

    var body: some View {
        RootTabView()
            .environmentObject(bleManager)
    }
}
