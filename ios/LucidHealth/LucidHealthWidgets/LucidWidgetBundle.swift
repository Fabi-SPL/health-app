import WidgetKit
import SwiftUI

@main
struct LucidWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        // 2026-04-27 — Restored full bespoke bundle after user feedback.
        // The earlier 9 → 5 cut was made when widgets were stuck at zeros
        // (root cause turned out to be missing App Group entitlement in
        // the IPA — fixed in CI). With the entitlement fix, the iOS
        // refresh budget concern still exists in theory but the Health app
        // is single-user / bespoke-per-mode, so trading "more refreshes
        // per face" for "more faces to choose from" is the right call.
        // Each widget can still pick its preferred lock-screen family.

        // Existing (Apr 15 brainstorm)
        LucidSmallWidget()
        LucidMediumWidget()
        LucidCapacityRingWidget()
        LucidNextMoveWidget()
        LucidReadinessWordWidget()
        LucidLiveMetricsWidget()
        LucidLiveActivity()

        // Added 2026-04-25 — DayState face, Body Battery, Live HR
        LucidDayStateFaceWidget()
        LucidBodyBatteryWidget()
        LucidLiveHRWidget()

        // iOS 18+ Control Center / Action Button (separate budget)
        if #available(iOS 18.0, *) {
            LucidBridgeControl()
        }
    }
}
