import ActivityKit
import SwiftUI
import WidgetKit

/// Health brand palette — local copy because LucidWidgets.swift's
/// WidgetPalette is file-private. Same hex values, kept in sync.
private enum WidgetLAPalette {
    static let violet = Color(red: 0.545, green: 0.486, blue: 0.965)
    static let teal = Color(red: 0.310, green: 0.820, blue: 0.773)
}

struct LucidLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LucidActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Text(context.state.emoji)
                            .font(.system(size: 24))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.activityType.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(formatDuration(context.state.duration))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                            Text("\(context.state.heartRate)")
                                .font(.system(size: 20, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        Text(zoneName(context.state.currentHRZone))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(zoneColor(context.state.currentHRZone))
                            .tracking(0.8)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        expandedStat(
                            icon: "flame.fill",
                            iconColor: strainColor(context.state.strainAccumulated),
                            value: String(format: "%.1f", context.state.strainAccumulated),
                            label: "STRAIN"
                        )

                        expandedStat(
                            icon: "waveform.path.ecg",
                            iconColor: zoneColor(context.state.currentHRZone),
                            value: "Z\(context.state.currentHRZone)",
                            label: zoneName(context.state.currentHRZone)
                        )

                        expandedStat(
                            icon: "battery.75",
                            iconColor: batteryColor(context.state.bodyBattery),
                            value: "\(Int(context.state.bodyBattery))%",
                            label: "BATTERY"
                        )

                        Text(liveCoachLabel(context.state))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(liveCoachColor(context.state))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(liveCoachColor(context.state).opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Text(context.state.emoji)
                    .font(.system(size: 15))
            } compactTrailing: {
                Text("\(context.state.heartRate)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(zoneColor(context.state.currentHRZone))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } minimal: {
                Text(context.state.emoji)
                    .font(.system(size: 14))
            }
        }
    }

    /// Lock-screen face — branches on activityType so the bridge has its
    /// own bespoke render (clean, HR-centric, ambient) and doesn't get
    /// shoehorned into the workout layout that was designed for sauna /
    /// cold plunge / exercise. Per Fabi's bespoke-per-mode philosophy.
    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<LucidActivityAttributes>) -> some View {
        if context.attributes.activityType == "bridge" {
            bridgeLockFace(context: context)
        } else {
            workoutLockFace(context: context)
        }
    }

    /// Bespoke "Bridge Live" face — runs always while BLE streams.
    /// Center of gravity is the live BPM (the whole reason this exists).
    /// HRV + strain sit secondary on the right, body battery flank as a
    /// quiet accent. No duration counter (this isn't a workout — it's
    /// the ambient connection face).
    @ViewBuilder
    private func bridgeLockFace(context: ActivityViewContext<LucidActivityAttributes>) -> some View {
        HStack(spacing: 16) {
            // Left — bridge identity + zone label
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetLAPalette.violet)
                    Text("BRIDGE LIVE")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(1.2)
                }

                Text(zoneName(context.state.currentHRZone))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(zoneColor(context.state.currentHRZone))
                    .tracking(0.6)

                Text(bridgeCoachLabel(context.state))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer(minLength: 8)

            // Center — the BPM. This is the whole point.
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text("\(context.state.heartRate)")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Text("BPM")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(1.4)
            }

            Spacer(minLength: 8)

            // Right — secondary metrics column. HRV (RMSSD) is the
            // signature ambient metric for the bridge face since the user
            // isn't actively training; body battery is the slow-moving
            // companion. Strain lives in widgets/timeline, not here.
            VStack(alignment: .trailing, spacing: 5) {
                bridgeStat(
                    icon: "waveform.path.ecg",
                    iconColor: WidgetLAPalette.teal,
                    value: context.state.currentRMSSD > 0
                        ? "\(Int(context.state.currentRMSSD))"
                        : "—",
                    label: "HRV"
                )
                bridgeStat(
                    icon: "bolt.fill",
                    iconColor: batteryColor(context.state.bodyBattery),
                    value: "\(Int(context.state.bodyBattery))",
                    label: "BAT"
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.04, blue: 0.10),
                    Color(red: 0.08, green: 0.05, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                // Subtle violet pulse — soft brand glow on the left edge.
                LinearGradient(
                    colors: [WidgetLAPalette.violet.opacity(0.18), .clear],
                    startPoint: .leading,
                    endPoint: .center
                )
            )
        )
    }

    /// Existing workout face — preserved for sauna / cold_plunge / exercise /
    /// skiing / nap / anxiety / deep_work / meditation. Activity-type-driven
    /// emoji and duration counter make sense here; not on the bridge face.
    @ViewBuilder
    private func workoutLockFace(context: ActivityViewContext<LucidActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(context.state.emoji)
                        .font(.system(size: 20))
                    Text(context.attributes.activityType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Text(formatDuration(context.state.duration))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))

                Text(liveCoachLabel(context.state))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(liveCoachColor(context.state))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(liveCoachColor(context.state).opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text("\(context.state.heartRate)")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }

                Text(zoneName(context.state.currentHRZone))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(zoneColor(context.state.currentHRZone))
                    .tracking(0.6)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(strainColor(context.state.strainAccumulated))
                    Text(String(format: "%.1f", context.state.strainAccumulated))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 4) {
                    Image(systemName: "battery.75")
                        .font(.system(size: 9))
                        .foregroundStyle(batteryColor(context.state.bodyBattery))
                    Text("\(Int(context.state.bodyBattery))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.12, green: 0.08, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    /// Compact stat block used by the bridge face — small icon + value + label.
    private func bridgeStat(icon: String, iconColor: Color, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.42))
                    .tracking(0.8)
            }
        }
    }

    /// Bridge-specific coach label — softer than workout copy. Reads as
    /// ambient state ("idle / steady / active / hot") rather than coaching
    /// because the user isn't necessarily exercising while wearing the strap.
    private func bridgeCoachLabel(_ state: LucidActivityAttributes.ContentState) -> String {
        switch state.currentHRZone {
        case 0:  return "Idle"
        case 1:  return "Steady"
        case 2:  return "Active"
        case 3:  return "Hot"
        case 4:  return "Peak"
        default: return "Idle"
        }
    }

    private func expandedStat(icon: String, iconColor: Color, value: String, label: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(iconColor)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Text(label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(0.8)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60

        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }

        return String(format: "%02d:%02d", m, s)
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 0: return .gray
        case 1: return .blue
        case 2: return .green
        case 3: return .orange
        case 4: return .red
        default: return .gray
        }
    }

    private func zoneName(_ zone: Int) -> String {
        switch zone {
        case 0: return "REST"
        case 1: return "EASY"
        case 2: return "BUILD"
        case 3: return "HARD"
        case 4: return "MAX"
        default: return "REST"
        }
    }

    private func strainColor(_ strain: Double) -> Color {
        if strain < 8 { return .blue }
        if strain < 14 { return .orange }
        return .red
    }

    private func batteryColor(_ battery: Double) -> Color {
        if battery >= 60 { return .green }
        if battery >= 30 { return .orange }
        return .red
    }

    private func liveCoachLabel(_ state: LucidActivityAttributes.ContentState) -> String {
        if state.bodyBattery <= 25 { return "Protect" }
        if state.currentHRZone >= 3 { return "Push" }
        if state.strainAccumulated >= 10 { return "Steady" }
        return "Build"
    }

    private func liveCoachColor(_ state: LucidActivityAttributes.ContentState) -> Color {
        switch liveCoachLabel(state) {
        case "Protect": return .red
        case "Push": return .green
        case "Steady": return .orange
        default: return .blue
        }
    }
}
