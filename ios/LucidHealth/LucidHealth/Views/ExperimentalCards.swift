import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// Experimental feature cards for SettingsView.
// Discord + High-Frequency broadcast merged into ONE Broadcast card (they
// share the pipe — one audience, two cadences). HueMirrorCard deleted:
// config UI for a write path that never ran. Spiral log lives on Insights.
// ════════════════════════════════════════════════════════════════════════

// MARK: - Broadcast Card (Discord webhook + HFB cadence)

struct BroadcastCard: View {
    // Discord webhook settings
    @State private var enabled = false
    @State private var webhookURL = ""
    @State private var customLabel = ""
    @State private var showHR = true
    @State private var showHRV = true
    @State private var showStrain = false
    @State private var showState = false
    @State private var refreshSeconds = 10
    @State private var pushCount = 0
    @State private var lastPushedAt: String? = nil
    @State private var loaded = false
    @State private var saving = false
    @State private var savedFlash = false
    @State private var expanded = false

    // High-frequency cadence (1s vs 10s push interval)
    @State private var hfbEnabled = false
    @State private var hfbLoaded = false

    private let svc = ExperimentalFeaturesService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                SectionHeader(icon: "megaphone.fill", title: "Broadcast", iconColor: DS.Colors.violet)
                Spacer()
                if enabled {
                    AmbientLiveDot(state: .connected)
                }
            }

            // Proof-of-life row — replaces the two intro paragraphs.
            if pushCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11))
                        .foregroundStyle(enabled ? DS.Colors.teal : DS.Colors.textFaint)
                    Text(proofOfLife)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .monospacedDigit()
                    Spacer()
                }
            }

            // Master toggle (Discord webhook push)
            Toggle(isOn: $enabled) {
                Text("Broadcast to Discord")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            .tint(DS.Colors.violet)

            // Push cadence — one 2-segment control instead of a second card.
            VStack(alignment: .leading, spacing: 6) {
                Text("CADENCE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.Colors.textMuted)
                HStack(spacing: 6) {
                    cadenceButton("10s · normal", active: !hfbEnabled) { setHFB(false) }
                    cadenceButton("1s · high drain", active: hfbEnabled) { setHFB(true) }
                }
            }

            // Expand for webhook config
            Button {
                withAnimation(.spring(duration: 0.4)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(expanded ? "Hide config" : "Show config")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Colors.violet)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.violet)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    // Webhook URL
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DISCORD WEBHOOK URL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.Colors.textMuted)
                        TextField("https://discord.com/api/webhooks/...", text: $webhookURL)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(8)
                            .background(DS.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }

                    // Custom label
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CUSTOM LABEL (optional)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.Colors.textMuted)
                        TextField("fabi gaming", text: $customLabel)
                            .font(.system(size: 12, design: .rounded))
                            .padding(8)
                            .background(DS.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Field toggles
                    VStack(spacing: 6) {
                        toggleRow("♥ heart rate", $showHR, color: .red)
                        toggleRow("𝓥 hrv", $showHRV, color: DS.Colors.teal)
                        toggleRow("💪 strain (edwards trimp)", $showStrain, color: DS.Colors.amber)
                        toggleRow("🧠 hmm state", $showState, color: DS.Colors.violet)
                    }

                    // Discord message refresh interval
                    HStack {
                        Text("REFRESH")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.Colors.textMuted)
                        Spacer()
                        ForEach([5, 10, 30], id: \.self) { sec in
                            Button { refreshSeconds = sec } label: {
                                Text("\(sec)s")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .foregroundStyle(refreshSeconds == sec ? .white : DS.Colors.textSecondary)
                                    .background(refreshSeconds == sec ? DS.Colors.violet : DS.Colors.surface)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            // Save button
            Button {
                Task { await save() }
            } label: {
                HStack {
                    if saving {
                        ProgressView().scaleEffect(0.7)
                    } else if savedFlash {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(savedFlash ? "Saved" : "Save settings")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(LinearGradient(colors: [DS.Colors.violet, DS.Colors.teal], startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
            }
            .disabled(saving || webhookURL.isEmpty)
            .opacity(webhookURL.isEmpty ? 0.4 : 1.0)
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
        .task {
            if !loaded { await loadSettings() }
            if !hfbLoaded { await loadHFB() }
        }
    }

    // "last push 12s · 1,204 updates"
    private var proofOfLife: String {
        var parts: [String] = []
        if let iso = lastPushedAt, let d = parseISO(iso) {
            let s = Int(Date().timeIntervalSince(d))
            let ago = s < 60 ? "\(s)s" : (s < 3600 ? "\(s / 60)m" : "\(s / 3600)h")
            parts.append("last push \(ago)")
        }
        parts.append("\(pushCount) updates")
        return parts.joined(separator: " · ")
    }

    private func parseISO(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    @ViewBuilder
    private func cadenceButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .foregroundStyle(active ? .white : DS.Colors.textSecondary)
                .background(active ? DS.Colors.teal : DS.Colors.surface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toggleRow(_ label: String, _ binding: Binding<Bool>, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(color)
                .scaleEffect(0.85)
        }
    }

    // MARK: Discord settings I/O

    private func loadSettings() async {
        if let s = await svc.fetchBroadcastSettings() {
            await MainActor.run {
                enabled = s.enabled
                webhookURL = s.discord_webhook ?? ""
                customLabel = s.custom_label ?? ""
                showHR = s.show_hr
                showHRV = s.show_hrv
                showStrain = s.show_strain
                showState = s.show_state
                refreshSeconds = s.refresh_seconds
                pushCount = s.push_count ?? 0
                lastPushedAt = s.last_pushed_at
                loaded = true
            }
        } else {
            loaded = true
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let s = ExperimentalFeaturesService.BroadcastSettings(
            enabled: enabled,
            discord_webhook: webhookURL.isEmpty ? nil : webhookURL,
            show_hr: showHR, show_hrv: showHRV,
            show_strain: showStrain, show_state: showState,
            refresh_seconds: refreshSeconds,
            custom_label: customLabel.isEmpty ? nil : customLabel,
            push_count: nil, last_pushed_at: nil
        )
        let ok = await svc.upsertBroadcastSettings(s)
        if ok {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await MainActor.run {
                savedFlash = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    savedFlash = false
                }
            }
        }
    }

    // MARK: HFB cadence I/O (mirrors the old High Frequency Broadcast card
    // exactly — UserDefaults mirror + BLEManager retune notification).

    private func setHFB(_ on: Bool) {
        guard hfbEnabled != on else { return }
        hfbEnabled = on
        UserDefaults.standard.set(on, forKey: BLEManager.hfbBroadcastEnabledKey)
        NotificationCenter.default.post(name: .lucidHFBToggleChanged, object: nil)
        if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        Task { await saveHFB() }
    }

    private func loadHFB() async {
        if let s = await svc.fetchHFBSettings() {
            await MainActor.run {
                hfbEnabled = s.enabled
                hfbLoaded = true
                // Sync UserDefaults mirror + notify BLEManager so pushInterval
                // matches the persisted Supabase state on every app launch.
                UserDefaults.standard.set(s.enabled, forKey: BLEManager.hfbBroadcastEnabledKey)
                NotificationCenter.default.post(name: .lucidHFBToggleChanged, object: nil)
            }
        } else {
            hfbLoaded = true
        }
    }

    private func saveHFB() async {
        guard hfbLoaded else { return }
        // Fetch existing settings to preserve fields the broadcaster's UI owns
        // (mode, vibe_style, privacy_mode, etc.). We only mutate enabled.
        if var s = await svc.fetchHFBSettings() {
            s.enabled = hfbEnabled
            _ = await svc.upsertHFBSettings(s)
        } else {
            // First-run: write a sensible default record with just enabled
            let fresh = ExperimentalFeaturesService.HFBSettings(
                enabled: hfbEnabled,
                osc_host: "127.0.0.1", osc_port: 9000, refresh_seconds: 1.0,
                mode: "vibe",
                show_hr: true, show_hrv: true, show_baevsky: false,
                show_strain: false, show_state: false,
                show_recovery: false, show_body_battery: false,
                show_skin_temp: false, show_coherence: false,
                show_streak: false, show_spiral_count: false,
                show_label: true,
                custom_template: nil, custom_label: nil,
                rotate_seconds: 8,
                push_count: nil, last_message: nil,
                privacy_mode: true, vibe_style: "heart",
                show_vibe_duration: true,
                show_energy_bar: false, show_drunk_bar: false,
                drunk_only_when_tagged: true,
                energy_bar_chars: 10, drunk_bar_chars: 10
            )
            _ = await svc.upsertHFBSettings(fresh)
        }
    }
}

// MARK: - Spiral Alerts Log Card

struct SpiralAlertsLogCard: View {
    @State private var alerts: [ExperimentalFeaturesService.SpiralAlert] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                SectionHeader(icon: "tornado", title: "Spiral Alerts", iconColor: DS.Colors.pink)
                Spacer()
                StatusChip(text: !loaded ? "loading" : (alerts.isEmpty ? "not running" : "\(alerts.count) recent"),
                           style: (loaded && alerts.isEmpty) ? .amber : .violet)
            }

            Text("The watcher pings when HRV crashes 20%+ and HR rises 15%+ for ≥10 min. Cooldown 4h.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(DS.Colors.textSecondary)

            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if alerts.isEmpty {
                // Zero rows means the detector never ran, not that the week was
                // clean — never read an empty table back as reassurance.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(DS.Colors.amber)
                    Text("detection isn't running yet — nothing has been checked, so there's nothing to report either way")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(DS.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(alerts) { alert in
                    spiralRow(alert)
                }
            }
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
        .task { await loadAlerts() }
    }

    @ViewBuilder
    private func spiralRow(_ alert: ExperimentalFeaturesService.SpiralAlert) -> some View {
        let dropPct = alert.hrv_drop_pct ?? 0
        let risePct = alert.hr_rise_pct ?? 0
        HStack(spacing: 10) {
            Circle()
                .fill(dropPct > 30 ? DS.Colors.danger : DS.Colors.amber)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(alert.fired_at))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Colors.textPrimary)
                HStack(spacing: 6) {
                    Text("HRV ↓\(Int(dropPct))%")
                        .foregroundStyle(DS.Colors.danger)
                    Text("·").foregroundStyle(DS.Colors.textFaint)
                    Text("HR ↑\(Int(risePct))%")
                        .foregroundStyle(DS.Colors.amber)
                    if let st = alert.hmm_state {
                        Text("·").foregroundStyle(DS.Colors.textFaint)
                        Text(st)
                            .foregroundStyle(DS.Colors.violet)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            Spacer()
            if let resp = alert.user_response {
                StatusChip(text: resp, style: resp == "opened" ? .teal : .violet)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d · HH:mm"
        return out.string(from: d)
    }

    private func loadAlerts() async {
        let result = await ExperimentalFeaturesService.shared.fetchSpiralAlerts(limit: 5)
        await MainActor.run {
            alerts = result
            loaded = true
        }
    }
}
