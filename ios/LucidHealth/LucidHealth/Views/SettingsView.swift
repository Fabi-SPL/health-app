import SwiftUI

// MARK: - SettingsView
// V3 board "Settings" (minerva/jobs/lh3-full): strap, server, body profile, then the existing tools.
// Battery health, charge cycles, voltage, the cut and protein goal and the notification toggles have no source, so they are not drawn.

struct SettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false
    @State private var showCredentialOverride = false
    @State private var overrideEmail = ""
    @State private var overridePassword = ""
    @State private var isSavingCredentials = false
    @State private var credentialSaved = false

    var body: some View {
        ZStack {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 12) {
                    V3Header(date: "LucidHealth", title: "Settings") {
                        V3IconButton(symbol: "xmark") { dismiss() }
                    }

                    // Group keeps the stack under ViewBuilder's 10-child limit.
                    Group {
                        staggered(0) { SettingsStrapCard(bleManager: bleManager) }
                        staggered(1) { AuthStatusCard() }
                        staggered(2) { PersonalizationCard() }
                        staggered(3) { DisplayCard() }
                        staggered(4) { AppInfoCard() }
                    }

                    // Opt-in experiments. Discord and high-frequency broadcast share one card.
                    staggered(5) { SettingsGroupLabel(title: "Labs", icon: "flask.fill") }
                    staggered(6) { BroadcastCard() }

                    // Strap and data plumbing: the "is the hardware working" instruments.
                    staggered(7) { SettingsGroupLabel(title: "Diagnostics", icon: "stethoscope") }
                    staggered(8) {
                        CredentialOverrideCard(
                            isExpanded: $showCredentialOverride,
                            email: $overrideEmail,
                            password: $overridePassword,
                            isSaving: isSavingCredentials,
                            saved: credentialSaved
                        ) { await saveCredentials() }
                    }
                    staggered(9) { BLEDiagnosticsCard(bleManager: bleManager) }
                    staggered(10) { ManualBackfillCard(bleManager: bleManager) }

                    // Deep strap internals (skin temp, streams, battery, logs) live one level down.
                    staggered(11) {
                        NavigationLink {
                            DiagnosticsView(bleManager: bleManager)
                        } label: {
                            SettingsLinkCard(
                                icon: "stethoscope",
                                color: V3.energy,
                                title: "Diagnostics",
                                detail: "Skin temp, streams, strap battery, logs"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Settings")
        .toolbar(.hidden, for: .navigationBar)
        .presentationBackground(V3.sheet)
        .presentationDragIndicator(.visible)
        .onAppear { withAnimation { appeared = true } }
    }

    /// One entrance choreography for every Settings card; the delay caps at 8 so the long tail settles together.
    @ViewBuilder
    private func staggered<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .offset(y: appeared ? 0 : 16)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.35).delay(Double(min(index, 8)) * 0.04), value: appeared)
    }

    private func saveCredentials() async {
        guard !overrideEmail.isEmpty, !overridePassword.isEmpty else { return }
        isSavingCredentials = true
        SupabaseClient.saveCredentials(email: overrideEmail, password: overridePassword)
        await SupabaseClient.shared.signInIfNeeded()
        credentialSaved = true
        isSavingCredentials = false
    }
}

// MARK: - Shared V3 pieces for Settings

private extension ConnectionState {
    var settingsColor: Color {
        switch self {
        case .connected, .streaming: return V3.green
        case .syncing:               return V3.sleep
        case .scanning, .connecting: return V3.amber
        case .disconnected:          return V3.red
        }
    }

    var settingsLabel: String {
        switch self {
        case .connected:    return "Connected"
        case .streaming:    return "Live"
        case .syncing:      return "Syncing"
        case .scanning:     return "Searching"
        case .connecting:   return "Connecting"
        case .disconnected: return "Disconnected"
        }
    }
}

private struct SettingsRule: View {
    var body: some View {
        Rectangle().fill(V3.line).frame(height: 1)
    }
}

private struct SettingsGroupLabel: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(V3.t2)
            Text(title)
                .font(V3Font.text(13, .semibold))
                .foregroundStyle(V3.t2)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }
}

private struct SettingsChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(V3Font.text(12, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct SettingsStatusDot: View {
    @ObservedObject var bleManager: BLEManager

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(bleManager.connectionState.settingsColor).frame(width: 7, height: 7)
            Text(bleManager.connectionState.settingsLabel)
                .font(V3Font.text(13))
                .foregroundStyle(V3.t2)
        }
    }
}

private struct SettingsInfoRow: View {
    let icon: String
    let label: String
    let value: String
    var first = false

    var body: some View {
        VStack(spacing: 0) {
            if !first { SettingsRule() }
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(V3.t3)
                    .frame(width: 18)
                Text(label).font(V3Font.text(14)).foregroundStyle(V3.t2)
                Spacer(minLength: 8)
                Text(value)
                    .font(V3Font.text(14, .semibold))
                    .foregroundStyle(V3.t1)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 10)
        }
    }
}

private struct SettingsKeyValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(V3Font.text(12)).foregroundStyle(V3.t2)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(V3.t1)
        }
    }
}

private struct SettingsStat: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(V3Font.text(12)).foregroundStyle(V3.t2)
            Text(value)
                .font(V3Font.num(20))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit).font(V3Font.text(11)).foregroundStyle(V3.t3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(V3.card2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SettingsLinkCard: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        V3Card(padding: 14) {
            HStack(spacing: 12) {
                V3IconWell(symbol: icon, color: color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                    Text(detail).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(V3.t3)
            }
        }
    }
}

// MARK: - Strap card (top of the board's Settings)

private struct SettingsStrapCard: View {
    @ObservedObject var bleManager: BLEManager

    private var battery: Double { bleManager.battery }
    private var hasBattery: Bool { bleManager.battery > 0 }

    private var firmwareLine: String {
        if let fw = bleManager.deviceInfo["firmware"], !fw.isEmpty { return "Firmware \(fw)" }
        return "Firmware not read yet"
    }

    var body: some View {
        V3Card {
            HStack(spacing: 16) {
                batteryRing
                VStack(alignment: .leading, spacing: 2) {
                    Text("Strap").font(V3Font.text(20, .bold)).tracking(-0.6).foregroundStyle(V3.t1)
                    Text(firmwareLine).font(V3Font.text(13)).foregroundStyle(V3.t2).lineLimit(1)
                    HStack(spacing: 8) {
                        SettingsStatusDot(bleManager: bleManager)
                        if bleManager.isCharging { SettingsChip(text: "Charging", color: V3.amber) }
                    }
                    .padding(.top, 4)
                    Text(bleManager.lastSync.map { "Last sync \(V3Format.hhmm($0))" } ?? "No sync yet")
                        .font(V3Font.text(13))
                        .foregroundStyle(V3.t2)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            SettingsRule().padding(.top, 16)
            HStack(spacing: 0) {
                V3LegendItem(label: "Worn", value: bleManager.isWorn ? "Yes" : "No")
                V3LegendItem(label: "Readings today", value: "\(bleManager.readingsToday)")
                V3LegendItem(label: "Points synced", value: "\(bleManager.historySyncCount)")
            }
            .padding(.top, 12)
        }
    }

    private var batteryRing: some View {
        ZStack {
            if hasBattery {
                V3Ring(progress: battery / 100, color: battery < 20 ? V3.red : V3.green, lineWidth: 8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(battery))").font(V3Font.num(22)).tracking(-0.66).foregroundStyle(V3.t1)
                    Text("%").font(V3Font.text(12)).foregroundStyle(V3.t2)
                }
            } else {
                V3Ring(progress: 0, color: V3.t3, lineWidth: 8, dashed: true)
                Text("No data").font(V3Font.text(12, .semibold)).foregroundStyle(V3.t3)
            }
        }
        .frame(width: 84, height: 84)
    }
}

// MARK: - Diagnostics subpage
// Deep strap internals, one level below Settings. Device telemetry that used
// to squat on the Health tab lands here too: telemetry is not health data.

struct DiagnosticsView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var showLogs = false

    var body: some View {
        ZStack {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 12) {
                    deviceTelemetryCard
                    SkinTempDiagnosticsCard(bleManager: bleManager)
                    AllStreamsDiagnosticsCard(bleManager: bleManager)
                    BatteryDiagnosticsCard(bleManager: bleManager)
                    LogViewerCard { showLogs = true }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(V3.sheet, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showLogs) {
            LogViewerView()
                .presentationDetents([.large])
        }
    }

    // Device telemetry (was HealthView's device section).
    private var deviceTelemetryCard: some View {
        V3Card {
            V3CardHeader(icon: "antenna.radiowaves.left.and.right", iconColor: V3.t2, title: "Device")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SettingsStatusDot(bleManager: bleManager)
                    Spacer(minLength: 8)
                    if bleManager.isWorn { SettingsChip(text: "Worn", color: V3.energy) }
                    if bleManager.isCharging { SettingsChip(text: "Charging", color: V3.amber) }
                }

                HStack(spacing: 8) {
                    SettingsStat(label: "Battery",
                                 value: bleManager.battery > 0 ? "\(Int(bleManager.battery))" : "Unknown",
                                 unit: "%",
                                 color: bleManager.battery < 20 ? V3.red : V3.energy)
                    SettingsStat(label: "Readings",
                                 value: "\(bleManager.readingsToday)",
                                 unit: "today",
                                 color: V3.sleep)
                    SettingsStat(label: "Sync",
                                 value: "\(bleManager.historySyncCount)",
                                 unit: "points",
                                 color: V3.t1)
                }

                if let lastSync = bleManager.lastSync {
                    SettingsInfoRow(icon: "arrow.clockwise", label: "Last sync",
                                    value: lastSync.formatted(.dateTime.hour().minute().second()),
                                    first: true)
                }
            }
        }
    }
}

// MARK: - Skin Temp Diagnostics

/// Surfaces the BLE skin-temp pipeline state on-phone (no Mac required).
/// Three possible states:
///   - Never received any TEMP packets: strap firmware doesn't send them
///     on this version, OR notify subscription missing, so log and add a fallback.
///   - Received but skinTemperature == 0: decoder couldn't parse the bytes.
///     Raw hex is shown so we can trace the format.
///   - Received and parsed: great, just slow update cadence (Whoop pushes
///     skin temp every few minutes, not continuously).
private struct SkinTempDiagnosticsCard: View {
    @ObservedObject var bleManager: BLEManager

    private var statusLine: String {
        if let _ = bleManager.lastTempEventAt {
            if bleManager.skinTemperature > 0 {
                return "Receiving and parsing OK"
            } else {
                return "Receiving but decode failed, raw hex below"
            }
        }
        return "No temperature events received yet"
    }

    private var statusColor: Color {
        if bleManager.skinTemperature > 0 { return V3.green }
        if bleManager.lastTempEventAt != nil { return V3.amber }
        return V3.t2
    }

    private func timeAgo(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h \((s % 3600) / 60)m ago"
    }

    var body: some View {
        V3Card {
            V3CardHeader(icon: "thermometer.medium", iconColor: V3.amber, title: "Skin temp")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusLine)
                        .font(V3Font.text(13, .semibold))
                        .foregroundStyle(V3.t1)
                    Spacer(minLength: 8)
                    if bleManager.skinTemperature > 0 {
                        Text("\(String(format: "%.1f", bleManager.skinTemperature))°C")
                            .font(V3Font.num(15))
                            .foregroundStyle(V3.amber)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingsKeyValue(label: "Events received", value: "\(bleManager.totalTempEventsReceived)")
                    SettingsKeyValue(label: "Type-49 packets seen", value: "\(bleManager.totalType49PacketsSeen)")
                    SettingsKeyValue(
                        label: "History sync flag",
                        value: bleManager.isHistorySyncing ? "Syncing, gates temp" : "Idle"
                    )
                    SettingsKeyValue(
                        label: "Last event",
                        value: bleManager.lastTempEventAt.map { timeAgo($0) } ?? "never"
                    )
                    SettingsKeyValue(label: "Source", value: bleManager.lastTempEventSource ?? "unknown")
                    if let raw = bleManager.lastTempRawHex {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Last raw bytes")
                                .font(V3Font.text(11, .semibold))
                                .foregroundStyle(V3.t3)
                            Text(raw)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(V3.t2)
                                .lineLimit(3)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }
}

// MARK: - All-Streams Diagnostics

/// Surfaces every BLE packet type the strap is currently emitting, so we can
/// verify whether power-user mode (cmd 106 IMU, 107/81 raw PPG) actually
/// unlocked new streams or got silently rejected by firmware.
///
/// Known packet types per WhoopProtocol enum + community RE work:
///   - 2  = REALTIME_DATA (HR + RR)
///   - 27 = HISTORICAL_DATA (sync)
///   - 32 = COMMAND_RESPONSE
///   - 33 = EVENT (battery, charging, double-tap, TEMPERATURE event 17)
///   - 43 = REALTIME_RAW_DATA (raw PPG channels)
///   - 47 = HISTORICAL sensor / decode_5c
///   - 49 = METADATA (skin temp 0x31 OR history start/end)
///   - 51 = REALTIME_IMU_DATA (accel + gyro @ 52Hz)
///   - 52 = HISTORICAL_IMU_DATA
private struct AllStreamsDiagnosticsCard: View {
    @ObservedObject var bleManager: BLEManager
    @State private var refreshTick = Date()

    private let typeLabels: [Int: String] = [
        2: "HR + RR",
        27: "History sync",
        32: "Cmd response",
        33: "Event",
        43: "Raw PPG",
        47: "Sensor v70",
        49: "Metadata / temp",
        51: "IMU 52Hz",
        52: "IMU history"
    ]

    private let priorityHighlights: [Int] = [2, 51, 43, 49]

    private var sessionMinutes: Double {
        let s = Date().timeIntervalSince(bleManager.sessionStartedAt) / 60
        return max(s, 0.01)
    }

    private func rate(for type: Int) -> String {
        let count = bleManager.packetTypeCounts[type] ?? 0
        let perMin = Double(count) / sessionMinutes
        if perMin >= 60 { return String(format: "%.0f/s", perMin / 60) }
        if perMin >= 1 { return String(format: "%.1f/min", perMin) }
        if count == 0 { return "none" }
        return "\(count) total"
    }

    private func ageText(_ d: Date?) -> String {
        guard let d else { return "never" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        return "\(s/3600)h ago"
    }

    private func statusColor(_ count: Int, isPriority: Bool) -> Color {
        if count == 0 { return isPriority ? V3.red : V3.t3 }
        if count < 5 { return V3.amber }
        return V3.green
    }

    var body: some View {
        V3Card {
            V3CardHeader(icon: "waveform.path.ecg", iconColor: V3.sleep, title: "All streams")
            VStack(alignment: .leading, spacing: 8) {
                streamRow(type: 2,  label: "HR + RR")
                streamRow(type: 51, label: "IMU 52Hz")
                streamRow(type: 43, label: "Raw PPG")
                streamRow(type: 49, label: "Metadata / temp")
                streamRow(type: 33, label: "Event")
                streamRow(type: 47, label: "Sensor v70")

                // Show any UNKNOWN packet types observed (potential new capabilities)
                let known = Set([2, 27, 32, 33, 43, 47, 49, 51, 52])
                let unknown = bleManager.packetTypeCounts.keys.filter { !known.contains($0) }.sorted()
                if !unknown.isEmpty {
                    SettingsRule().padding(.vertical, 2)
                    Text("Unknown types, potential new signals")
                        .font(V3Font.text(11, .semibold))
                        .foregroundStyle(V3.t3)
                    ForEach(unknown, id: \.self) { t in
                        streamRow(type: t, label: "Unknown type-\(t)")
                    }
                }
            }
            .id(refreshTick)

            Text("Session: \(Int(sessionMinutes))m elapsed")
                .font(V3Font.text(11))
                .foregroundStyle(V3.t3)
                .padding(.top, 12)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshTick = Date()
        }
    }

    @ViewBuilder
    private func streamRow(type: Int, label: String) -> some View {
        let count = bleManager.packetTypeCounts[type] ?? 0
        let isPriority = priorityHighlights.contains(type)
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(count, isPriority: isPriority))
                .frame(width: 7, height: 7)
            Text(label)
                .font(V3Font.text(13, isPriority ? .semibold : .regular))
                .foregroundStyle(V3.t1)
            Spacer()
            Text(rate(for: type))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(count > 0 ? V3.t1 : V3.t3)
            Text(ageText(bleManager.packetTypeLastSeen[type]))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(V3.t2)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

// MARK: - Battery Diagnostics

/// Surfaces strap battery level + drain rate. Power-user mode (continuous
/// IMU + raw PPG) costs battery, so Fabi wants visibility on how much.
private struct BatteryDiagnosticsCard: View {
    @ObservedObject var bleManager: BLEManager

    private var drainText: String {
        guard let r = bleManager.batteryDrainPerHour else { return "Need 30+ min of data" }
        if r < 0 {
            let perHour = abs(r)
            let hoursLeft = bleManager.battery / perHour
            return String(format: "%.1f%%/hr, about %.1fh left", perHour, hoursLeft)
        }
        return String(format: "+%.1f%%/hr (charging)", r)
    }

    private var drainColor: Color {
        guard let r = bleManager.batteryDrainPerHour else { return V3.t3 }
        if r >= 0 { return V3.green }
        if abs(r) > 5 { return V3.red }     // draining > 5%/hr = ~20h life
        if abs(r) > 2 { return V3.amber }   // 2-5%/hr = ~50h life (~2 days)
        return V3.green                     // <2%/hr = 50h+ (normal-ish)
    }

    private var levelColor: Color {
        if bleManager.battery > 50 { return V3.green }
        if bleManager.battery > 20 { return V3.amber }
        return V3.red
    }

    var body: some View {
        V3Card {
            V3CardHeader(icon: "bolt.fill", iconColor: V3.amber, title: "Strap battery")

            HStack(alignment: .center, spacing: 14) {
                V3Ring(progress: bleManager.battery / 100, color: levelColor, lineWidth: 6)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(bleManager.battery))%")
                        .font(V3Font.num(28))
                        .tracking(-0.84)
                        .foregroundStyle(V3.t1)
                    Text(drainText)
                        .font(V3Font.text(12, .semibold))
                        .foregroundStyle(drainColor)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                let history = bleManager.batteryHistorySnapshot
                SettingsKeyValue(label: "Samples logged", value: "\(history.count)")
                if let oldest = history.first {
                    let h = Int(Date().timeIntervalSince(oldest.date) / 3600)
                    SettingsKeyValue(label: "Oldest sample", value: "\(h)h ago @ \(Int(oldest.level))%")
                }
                if !bleManager.batteryPrediction.isEmpty {
                    SettingsKeyValue(label: "Estimate", value: bleManager.batteryPrediction)
                }
            }
            .padding(.top, 14)

            Text("Power-user mode (continuous IMU + raw PPG) drains faster than stock Whoop. About 5%/hr is normal here.")
                .font(V3Font.text(11))
                .foregroundStyle(V3.t3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }
}

// MARK: - Log Viewer Card

private struct LogViewerCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsLinkCard(
                icon: "doc.text.magnifyingglass",
                color: V3.energy,
                title: "Logs",
                detail: "On-phone debug log: widget reads, BLE state, errors"
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Auth Status Card

private struct AuthStatusCard: View {
    // SupabaseClient isn't ObservableObject (would need a deep refactor),
    // so we use a local @State that mirrors auth state and refreshes on:
    //   - View appear (initial render)
    //   - lucidAuthChanged notification (App posts this after every refresh)
    //   - A 5s timer (catches edge cases like network blips)
    @State private var authed: Bool = SupabaseClient.shared.isAuthenticated
    @State private var authError: String? = SupabaseClient.shared.lastAuthError

    // The login is baked into the build, so "not authed" always means the server is unreachable.
    private var title: String {
        authed ? "Signed in" : (SupabaseClient.hasCredentials ? "Can't reach server" : "No account in this build")
    }

    private var detail: String {
        if authed || authError == nil {
            return SupabaseClient.hasCredentials ? (UserDefaults.standard.string(forKey: "lucidhealth_email") ?? "") : ""
        }
        return authError ?? ""
    }

    var body: some View {
        V3Card {
            HStack(spacing: 12) {
                V3IconWell(symbol: "server.rack", color: authed ? V3.green : V3.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                SettingsChip(text: authed ? "Online" : "Offline", color: authed ? V3.green : V3.amber)
            }
            .padding(.top, 2)
            .padding(.bottom, 12)

            SettingsRule()
            HStack(spacing: 12) {
                V3IconWell(symbol: "sparkles", color: V3.fat)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Food AI").font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1)
                    Text("Gemini reads meals and photos").font(V3Font.text(12)).foregroundStyle(V3.t2)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .onAppear {
            refreshAuthed()
            Task {
                await SupabaseClient.shared.signInIfNeeded()
                refreshAuthed()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lucidAuthChanged)) { _ in
            refreshAuthed()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refreshAuthed()
        }
    }

    private func refreshAuthed() {
        authed = SupabaseClient.shared.isAuthenticated
        authError = SupabaseClient.shared.lastAuthError
    }
}

// MARK: - Display Settings (appearance picker)
//
// System, light or dark. Saves to UserDefaults via @AppStorage(V3Appearance.key);
// the app root reads the same key and applies the colour scheme.

private struct DisplayCard: View {
    @AppStorage(V3Appearance.key) private var appearanceRaw: String = V3Appearance.system.rawValue

    private var appearanceBinding: Binding<String> {
        Binding<String>(
            get: { (V3Appearance(rawValue: appearanceRaw) ?? .system).label },
            set: { label in
                appearanceRaw = (V3Appearance.allCases.first { $0.label == label } ?? .system).rawValue
            }
        )
    }

    var body: some View {
        V3Card {
            V3CardHeader(icon: "circle.lefthalf.filled", iconColor: V3.sleep, title: "Appearance")
            V3Segmented(options: V3Appearance.allCases.map { $0.label }, selection: appearanceBinding)
            Text("System follows the phone. Light and dark switch with it.")
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
                .padding(.top, 10)
        }
    }
}

// One About card: app + device facts (absorbed the old Developer info card).
private struct AppInfoCard: View {
    var body: some View {
        V3Card {
            V3CardHeader(icon: "app.badge", iconColor: V3.t2, title: "About")
            SettingsInfoRow(icon: "number", label: "Version", value: BuildInfo.codeVersion, first: true)
            SettingsInfoRow(icon: "chevron.left.forwardslash.chevron.right", label: "Commit", value: BuildInfo.commitHash)
            SettingsInfoRow(icon: "globe", label: "Backend", value: "Supabase \(URL(string: SupabaseClient.shared.baseURL)?.host ?? "unknown")")
            SettingsInfoRow(icon: "iphone", label: "iOS", value: UIDevice.current.systemVersion)
            SettingsInfoRow(icon: "cpu", label: "Device", value: UIDevice.current.model)
        }
    }
}

// MARK: - Credential Override

private struct CredentialOverrideCard: View {
    @Binding var isExpanded: Bool
    @Binding var email: String
    @Binding var password: String
    let isSaving: Bool
    let saved: Bool
    let onSave: () async -> Void

    var body: some View {
        V3Card {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 10) {
                    TextField("Email", text: $email)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(V3.t1)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(V3.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(V3.t1)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(V3.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        Task { await onSave() }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView().tint(V3.ink)
                            } else if saved {
                                Image(systemName: "checkmark")
                            } else {
                                Text("Save")
                            }
                        }
                        .font(V3Font.text(15, .semibold))
                        .foregroundStyle(V3.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(saved ? V3.green : V3.t1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                }
                .padding(.top, 12)
            } label: {
                Label("Override credentials", systemImage: "key.fill")
                    .font(V3Font.text(15, .semibold))
                    .foregroundStyle(V3.t1)
            }
            .tint(V3.t2)
        }
    }
}

// MARK: - BLE Diagnostics Card

private struct BLEDiagnosticsCard: View {
    @ObservedObject var bleManager: BLEManager

    var body: some View {
        V3Card {
            V3CardHeader(icon: "waveform.path.ecg", iconColor: V3.heart, title: "BLE diagnostics")

            // Connection status (absorbed from the old BLE Control card, same subject).
            HStack {
                SettingsStatusDot(bleManager: bleManager)
                Spacer(minLength: 8)
                if bleManager.isWorn { SettingsChip(text: "Worn", color: V3.energy) }
            }

            HStack(spacing: 8) {
                SettingsStat(label: "HR",
                             value: bleManager.heartRate > 0 ? "\(bleManager.heartRate)" : "None",
                             unit: "bpm",
                             color: V3.heart)
                SettingsStat(label: "Battery",
                             value: bleManager.battery > 0 ? "\(Int(bleManager.battery))" : "Unknown",
                             unit: "%",
                             color: V3.energy)
                SettingsStat(label: "Readings",
                             value: "\(bleManager.readingsToday)",
                             unit: "today",
                             color: V3.sleep)
            }
            .padding(.top, 12)

            VStack(spacing: 0) {
                if let fw = bleManager.deviceInfo["firmware"], !fw.isEmpty {
                    SettingsInfoRow(icon: "cpu", label: "Firmware", value: fw, first: true)
                }
                if let hw = bleManager.deviceInfo["hardware"], !hw.isEmpty {
                    SettingsInfoRow(icon: "memorychip", label: "Hardware", value: hw,
                                    first: bleManager.deviceInfo["firmware"]?.isEmpty ?? true)
                }
            }
            .padding(.top, 4)

            // Manual reconnect, full width.
            if bleManager.connectionState == .disconnected {
                V3Button(title: "Reconnect", symbol: "arrow.triangle.2.circlepath", secondary: true) {
                    let h = UIImpactFeedbackGenerator(style: .light)
                    h.impactOccurred()
                    NotificationCenter.default.post(name: .lucidReconnectBLE, object: nil)
                }
                .padding(.top, 12)
            }
        }
    }
}

// MARK: - Manual Backfill Card
//
// Lets the user trigger a 72h gap-fill from the strap's buffer when something
// like a phone-died-overnight scenario leaves holes in realtime_health.
// State machine driven by BLEManager.manualBackfillState:
//   idle, querying, requesting, parsing, uploading, then done or failed
// Button stays disabled while a run is in flight. Result line stays visible
// after a run so the user can see what happened.

private struct ManualBackfillCard: View {
    @ObservedObject var bleManager: BLEManager
    @State private var showFlushConfirm = false
    @State private var flushExpanded = false

    private var isRunning: Bool {
        switch bleManager.manualBackfillState {
        case "querying", "requesting", "parsing", "uploading": return true
        default: return false
        }
    }

    /// The flush escape hatch only earns screen space after a run that pulled
    /// nothing new (stuck-buffer signature), or once a flush already happened.
    private var showFlushSection: Bool {
        (bleManager.manualBackfillState == "done" && !bleManager.manualBackfillResult.contains("Backfilled"))
            || !bleManager.historyFlushResult.isEmpty
    }

    private var stateColor: Color {
        switch bleManager.manualBackfillState {
        case "done":   return V3.green
        case "failed": return V3.red
        default:       return V3.sleep
        }
    }

    private var stateIcon: String {
        switch bleManager.manualBackfillState {
        case "done":       return "checkmark.circle.fill"
        case "failed":     return "exclamationmark.circle.fill"
        case "querying":   return "magnifyingglass"
        case "requesting": return "arrow.down.to.line"
        case "parsing":    return "list.bullet.rectangle"
        case "uploading":  return "arrow.up.to.line"
        default:           return "clock.arrow.circlepath"
        }
    }

    private var canRun: Bool {
        !isRunning && bleManager.connectionState == .streaming
    }

    var body: some View {
        V3Card {
            header

            VStack(alignment: .leading, spacing: 12) {
                // Sync status rides here (absorbed the old Data Sync card, same pipe).
                HStack(spacing: 6) {
                    Image(systemName: bleManager.historySyncCount > 0 ? "checkmark.icloud.fill" : "icloud.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(bleManager.historySyncCount > 0 ? V3.energy : V3.t3)
                    Text(bleManager.historySyncCount > 0
                         ? "\(bleManager.historySyncCount) points synced"
                         : "No sync yet")
                        .font(V3Font.text(13, .semibold))
                        .foregroundStyle(V3.t2)
                    if !bleManager.historySyncProgress.isEmpty {
                        Text(bleManager.historySyncProgress)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(V3.amber)
                    }
                    Spacer(minLength: 0)
                }

                Text("Fills overnight gaps from the strap's buffer. Only writes minutes that aren't already covered.")
                    .font(V3Font.text(13))
                    .foregroundStyle(V3.t2)
                    .fixedSize(horizontal: false, vertical: true)

                // Live progress / result line
                if !bleManager.manualBackfillProgress.isEmpty {
                    Text(bleManager.manualBackfillProgress)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(V3.sleep)
                }
                if !bleManager.manualBackfillResult.isEmpty {
                    Text(bleManager.manualBackfillResult)
                        .font(V3Font.text(13, .semibold))
                        .foregroundStyle(stateColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                V3Button(title: isRunning ? "Running" : "Backfill last 72h", symbol: "arrow.clockwise") {
                    let h = UIImpactFeedbackGenerator(style: .medium)
                    h.impactOccurred()
                    bleManager.manualBackfill72h()
                }
                .disabled(!canRun)
                .opacity(canRun ? 1 : 0.45)

                if bleManager.connectionState != .streaming && !isRunning {
                    Text("Connect the strap first to enable.")
                        .font(V3Font.text(12))
                        .foregroundStyle(V3.t3)
                }

                // Escape hatch: flush a stuck buffer. Destructive and rare, so it is hidden
                // until a run returns 0 new minutes (the stuck-buffer signature), then behind a disclosure.
                if showFlushSection { flushSection }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            V3IconWell(symbol: stateIcon, color: stateColor)
            Text("Manual backfill").font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1).lineLimit(1)
            Spacer(minLength: 8)
            if isRunning {
                ProgressView().controlSize(.small).tint(V3.sleep)
            } else {
                Text("Last 72 hours").font(V3Font.text(13)).foregroundStyle(V3.t2)
            }
        }
        .padding(.bottom, 12)
    }

    private var flushSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRule()

            DisclosureGroup(isExpanded: $flushExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if !bleManager.historyFlushResult.isEmpty {
                        Text(bleManager.historyFlushResult)
                            .font(V3Font.text(13, .semibold))
                            .foregroundStyle(bleManager.historyFlushState == "failed" ? V3.red : V3.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Erases the strap's internal history buffer and forces a clean re-dump. Live tracking keeps working. Can't be undone.")
                        .font(V3Font.text(12))
                        .foregroundStyle(V3.t2)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        showFlushConfirm = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(bleManager.historyFlushState == "erasing" ? "Flushing" : "Flush stuck history")
                                .font(V3Font.text(14, .semibold))
                        }
                        .foregroundStyle(V3.amber)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(V3.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning || bleManager.connectionState != .streaming || bleManager.historyFlushState == "erasing")
                }
                .padding(.top, 10)
            } label: {
                Label("Buffer stuck? Flush it", systemImage: "exclamationmark.arrow.circlepath")
                    .font(V3Font.text(13, .semibold))
                    .foregroundStyle(V3.amber)
            }
            .tint(V3.amber)
            .confirmationDialog("Wipe the strap's history buffer?", isPresented: $showFlushConfirm, titleVisibility: .visible) {
                Button("Flush and re-pull", role: .destructive) {
                    let h = UINotificationFeedbackGenerator()
                    h.notificationOccurred(.warning)
                    bleManager.flushHistoryBuffer()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This erases the data the strap is holding in its internal buffer, then pulls a fresh 72h backfill. Live tracking keeps working. This cannot be undone.")
            }
        }
    }
}

// MARK: - Personalization Card

/// Weight + derived BMR/TDEE: feeds calorie targets, alcohol BAC calc,
/// and strain-per-kg metrics. Persisted via @AppStorage (UserDefaults key
/// `lucid_user_weight_kg`) so any engine can read it without a singleton.
private struct PersonalizationCard: View {
    @AppStorage(PersonalizationCard.weightKey) private var weightKg: Double = 75.25
    @AppStorage("lucid_user_height_cm") private var heightCm: Double = 178
    @AppStorage("lucid_user_age") private var ageYears: Int = 20
    @AppStorage("lucid_user_sex") private var sex: String = "male"
    @State private var weightText: String = ""
    @State private var heightText: String = ""
    @State private var ageText: String = ""
    @State private var savedFlash = false

    static let weightKey = "lucid_user_weight_kg"

    // Mifflin-St Jeor BMR: real height/age/sex (+5 male, -161 female).
    private var bmr: Int {
        let sexTerm: Double = sex == "female" ? -161 : 5
        let value = 10 * weightKg + 6.25 * heightCm - 5 * Double(ageYears) + sexTerm
        return Int(value.rounded())
    }

    private var tdee: Int {
        // moderate activity factor 1.55
        Int((Double(bmr) * 1.55).rounded())
    }

    private var sexBinding: Binding<String> {
        Binding<String>(
            get: { sex == "female" ? "Female" : "Male" },
            set: { sex = $0 == "Female" ? "female" : "male" }
        )
    }

    var body: some View {
        V3Card {
            V3CardHeader(title: "Body profile", trailing: "kcal a day")

            // Derived metrics, a preview of the inputs below.
            HStack(alignment: .firstTextBaseline) {
                V3BigNumber(value: "\(tdee)", unit: "burned")
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("BMR").font(V3Font.text(13)).foregroundStyle(V3.t2)
                    Text("\(bmr)").font(V3Font.num(13, .semibold)).foregroundStyle(V3.t1)
                }
            }
            .padding(.bottom, 8)

            profileRow(label: "Weight", text: $weightText, unit: "kg",  placeholder: "75", first: true)
            profileRow(label: "Height", text: $heightText, unit: "cm",  placeholder: "178")
            profileRow(label: "Age",    text: $ageText,    unit: "yrs", placeholder: "20")

            // Sex is a real control: it feeds the BMR sex term and the server profile.
            SettingsRule()
            HStack {
                Text("Sex").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1)
                Spacer(minLength: 8)
                V3Segmented(options: ["Male", "Female"], selection: sexBinding)
                    .frame(width: 170)
            }
            .padding(.vertical, 10)

            V3Button(title: savedFlash ? "Saved, the food AI now uses this" : "Save profile") { commit() }
                .padding(.top, 6)

            Text("Estimated at 1.55 activity. Feeds the food AI, BAC, strain and targets.")
                .font(V3Font.text(12))
                .foregroundStyle(V3.t2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .onAppear {
            weightText = formatWeight(weightKg)
            heightText = formatWeight(heightCm)
            ageText = "\(ageYears)"
            // Server is the source of truth for weight (your logged baseline).
            // Don't auto-push the local value on open: a stale device default
            // (e.g. 76) would overwrite a fresher server weight. The Save button
            // and the BP/weight logger remain the explicit writers.
        }
    }

    @ViewBuilder
    private func profileRow(label: String, text: Binding<String>, unit: String, placeholder: String, first: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first { SettingsRule() }
            HStack {
                Text(label).font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    TextField(placeholder, text: text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(V3Font.num(18))
                        .foregroundStyle(V3.t1)
                        .frame(width: 70)
                    Text(unit).font(V3Font.text(13)).foregroundStyle(V3.t2)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func commit() {
        if let w = Double(weightText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), w >= 30, w <= 250 { weightKg = w }
        if let h = Double(heightText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), h >= 120, h <= 230 { heightCm = h }
        if let a = Int(ageText.trimmingCharacters(in: .whitespaces)), a >= 10, a <= 120 { ageYears = a }
        weightText = formatWeight(weightKg)
        heightText = formatWeight(heightCm)
        ageText = "\(ageYears)"
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { savedFlash = false }
        }
        Task { await pushProfile() }
    }

    private func pushProfile() async {
        await SupabaseClient.shared.saveBodyProfile(weightKg: weightKg, heightCm: heightCm, age: ageYears, sex: sex)
    }

    private func formatWeight(_ v: Double) -> String {
        // 1 decimal for non-integer, no decimal for whole numbers (76.0 -> "76")
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
