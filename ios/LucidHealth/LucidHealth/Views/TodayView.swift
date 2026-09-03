import SwiftUI
import Charts

// MARK: - TodayView (primary screen — most polished)
// Principles applied: 1 (two-tone toolbar), 2 (textured canvas), 4 (pill radii),
// 5 (category dots), 8 (floating pill bar), 10 (size = hierarchy — 180pt ring),
// 11 (format diversity: ring → row → pills → card → text), 12 (status colors only).

/// Single enum drives all 3 food-entry modals. SwiftUI's per-modifier sheet/cover
/// stacking is unreliable when 2+ are attached to the same view (silently no-ops
/// after the first). One `.fullScreenCover(item:)` switch handles all three
/// modes deterministically.
enum FoodEntryMode: Identifiable {
    case camera, barcode, manual
    var id: Int {
        switch self { case .camera: return 1; case .barcode: return 2; case .manual: return 3 }
    }
}

struct TodayView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var foodEntryMode: FoodEntryMode? = nil
    @State private var showFABMenu = false
    @State private var appeared = false
    @State private var hasLoaded = false
    @State private var bbTrend: [BodyBatteryPoint] = []
    @StateObject private var modeStore = AppModeStore()
    @State private var activityDraft: String = ""
    @State private var showWindDown = false
    @State private var showCoherenceDrill = false
    @State private var lastNight: SleepRestlessness? = nil
    @State private var illness: IllnessRisk? = nil
    @State private var clockHour = Calendar.current.component(.hour, from: Date())

    // MARK: - Computed

    private var engine: HealthEngine { bleManager.healthEngine }
    private var overlay: RecoveryOverlay { RecoveryOverlayResolver.resolve(engine: engine) }

    /// Show the wind-down takeover at most once per calendar day, when wind-down
    /// mode is active. Also fires the wind-down image notification.
    private func maybeShowWindDown(_ mode: AppMode) {
        guard mode == .windDown else { return }
        let key = "lucid_winddown_shown_date"
        let today = Self.dayStamp(Date())
        if UserDefaults.standard.string(forKey: key) == today { return }
        UserDefaults.standard.set(today, forKey: key)
        showWindDown = true
        bleManager.sendWindDownNotification(note: bleManager.tonightPlanNote)
    }

    private static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// v98 — true while a sleep session is unfinished (wake detection hasn't fired).
    private var canManualWake: Bool {
        engine.sleepDetected || (engine.sleepStartTime != nil && engine.sleepEndTime == nil)
    }

    /// 19:00 → 05:00. Own time check, deliberately wider than wind-down mode.
    private var smartWakeControlVisible: Bool {
        clockHour >= 19 || clockHour < 5
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Late-night no longer hijacks the screen with a "sleep is the work"
            // takeover — the body (hero, live stats, alarm) stays visible around
            // the clock. Mode shifts tone via the conditional coach clusters.
            regularContent
            fabSection
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Greeting moved to the prominent in-scroll header; toolbar is just
                // the wordmark now (no duplicate greeting).
                TwoToneHeadline(
                    primary: "Lucid",
                    secondary: "Health",
                    font: .system(size: 17, weight: .heavy, design: .rounded)
                )
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                SettingsGearButton()
            }
        }
        .sheet(isPresented: $bleManager.showDoubleTapSheet) {
            QuickTagSheet(ble: bleManager)
        }
        // Wind-down takeover — comes up once per night when wind-down mode opens.
        .fullScreenCover(isPresented: $showWindDown) {
            WindDownView(bleManager: bleManager) { showWindDown = false }
        }
        // ONE cover for all three food-entry modes. SwiftUI's multi-modifier
        // stacking is flaky (3rd cover on same view silently no-ops). Item-based
        // presentation with an enum is the canonical workaround.
        // Saved entries render on the Food tab — Today doesn't display them.
        .fullScreenCover(item: $foodEntryMode) { mode in
            switch mode {
            case .camera:
                CameraView { _ in }
            case .barcode:
                BarcodeScannerView { _ in }
            case .manual:
                ManualFoodEntrySheet { _ in }
            }
        }
        .task {
            modeStore.start(engine: engine)
            withAnimation(DS.Anim.cardAppear) { appeared = true }
            hasLoaded = true
            await bleManager.syncTonightPlan()
            maybeShowWindDown(modeStore.current)
            await refreshBodyMetrics()
            // Morning cluster data — non-gating, loads after the fold.
            lastNight = await SupabaseClient.shared.fetchSleepRestlessness()
            illness = await SupabaseClient.shared.fetchIllnessRisk()
        }
        .onDisappear { modeStore.stop() }
        // AppModeStore only publishes on a mode CHANGE, so the 19:00 boundary
        // needs its own tick to bring the alarm card in.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            let h = Calendar.current.component(.hour, from: now)
            if h != clockHour { clockHour = h }
        }
        // Wind-down page comes up once per night when the mode flips to wind-down.
        .onChange(of: modeStore.current) { _, newMode in
            maybeShowWindDown(newMode)
        }
        // Foreground → pull fresh server-computed body state. The server's
        // recompute_health_metrics RPC is the source of truth (v100/v121);
        // Today is display-only.
        .onChange(of: scenePhase) { _, newPhase in
            bleManager.evt("app_state", "\(newPhase)")
            if newPhase == .active && hasLoaded {
                clockHour = Calendar.current.component(.hour, from: Date())
                Task { await refreshBodyMetrics() }
                Task { await bleManager.syncTonightPlan() }
            }
        }
        .sensoryFeedback(.success, trigger: hasLoaded)
    }

    /// One refresh path for pull-to-refresh, foreground, and first load —
    /// recovery + sleep recompute, body-battery anchor + 24h curve.
    private func refreshBodyMetrics() async {
        // Never recompute mid-sleep. detect_sleep_window scores
        // (target_date - 1) 19:00 → target_date 12:00, so a 03:00 call measures a
        // half night and the upsert overwrites the real one. Opening the app or
        // pulling to refresh during the night was the only source of the
        // partial-night rows — the 05:00 cron targets yesterday and is safe.
        if !bleManager.healthEngine.sleepDetected,
           let result = await bleManager.supabase.recomputeHealthMetrics() {
            await MainActor.run {
                bleManager.healthEngine.applyServerRecompute(result)
            }
        }
        // v121: server-authoritative Body Battery (reservoir − live drain).
        if let bb = await bleManager.supabase.fetchBodyBatteryAnchor() {
            await MainActor.run { bleManager.healthEngine.bodyBattery = bb }
        }
        // 24h body-battery curve for the hero chart (smooth, server-built)
        let series = await bleManager.supabase.fetchBodyBatterySeries()
        await MainActor.run { bbTrend = series }
    }

    // MARK: - Greeting header (prominent, adaptive, dated)

    private var greetingPhrase: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:       return "Still up"
        }
    }

    private var greetingDateLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: Date()).uppercased()
    }

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(greetingPhrase)
                .foregroundStyle(DS.Colors.textPrimary)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .kerning(-0.6)

            Text(greetingDateLine)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(DS.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Regular Content (Morning / Day / Evening / Wind-Down)

    @ViewBuilder
    private var regularContent: some View {
        // Spacing scale per section role — fixes the "too big / too small" rhythm:
        //   • Mode/overlay banners — sm (8pt) — quick context, tight cluster
        //   • Hero ring zone — xl (32pt) — main focal point, needs breathing
        //   • Live stats — sm (8pt) — extends hero, tight cluster
        //   • Activity composer — xl (32pt) — separate concern
        //   • Last meal + bento — md (16pt) — food cluster, related
        //   • Conditional banners — md/lg — dynamic, varied weight
        //   • Baseline delta — xl (32pt) — analytical surface, separate
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Color.clear.frame(height: DS.Spacing.xs)

                // Prominent adaptive greeting — the day's anchor. Time-aware phrase
                // + today's full date (so it's also a live "you're on a fresh build"
                // tell). Replaces the tiny nav-bar greeting as the warm entry point.
                greetingHeader
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(DS.Anim.cardAppear, value: appeared)

                // Hero ring + live stats — THE focal point, first substantive block
                // (matches the approved mockup: ring immediately under the greeting).
                // ModeBanner folded into the morning cluster below — it renders
                // nothing 4 of 6 modes, so the hero rises above the fold.
                VStack(spacing: 0) {
                    heroSection
                        .padding(.top, DS.Spacing.lg)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 28)
                        .animation(DS.Anim.stagger(index: 0), value: appeared)

                    liveStatsSection
                        .padding(.top, DS.Spacing.sm)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)
                        .animation(DS.Anim.stagger(index: 1), value: appeared)
                }
                .scrollSectionTransition()

                // ONE coach surface, mode-conditional. Tonight cluster = plan
                // card (drinking flag) + THE alarm (v154 smart wake). The legacy
                // v117 SmartAlarmCard is gone — two competing alarm systems the
                // same night was the "doesn't make sense" epicenter.
                if modeStore.current == .windDown || modeStore.current == .lateNight {
                    if modeStore.current == .windDown {
                        // v111 live readiness coach — how far the body is from sleep-ready.
                        WindDownCoachCard(bleManager: bleManager)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.top, DS.Spacing.md)
                            .opacity(appeared ? 1 : 0)
                            .animation(DS.Anim.cardAppear, value: appeared)
                            .scrollSectionTransition()
                    }

                    TonightPlanCard(bleManager: bleManager)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.top, DS.Spacing.md)
                        .opacity(appeared ? 1 : 0)
                        .animation(DS.Anim.cardAppear, value: appeared)
                        .scrollSectionTransition()
                }

                // The alarm is armed from early evening on, not gated to
                // wind-down — bed at 21:30 left no button anywhere in the app.
                if smartWakeControlVisible {
                    SmartWakeControl(bleManager: bleManager)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.top, DS.Spacing.md)
                        .opacity(appeared ? 1 : 0)
                        .animation(DS.Anim.cardAppear, value: appeared)
                        .scrollSectionTransition()
                }

                // v98 safety net (moved from Health): manual wake-up while a sleep
                // session is unfinished. All-day — mode can be .day at noon with
                // sleep still open when HR-driven wake detection misses Fabi's
                // chronic-low baseline. Hidden in .morning, where ModeBanner
                // already carries the big I'm-awake CTA.
                if canManualWake && modeStore.current != .morning && modeStore.current != .justWokeUp {
                    Button {
                        DS.Haptic.success()
                        engine.manualWakeUp()
                    } label: {
                        Label("I'm awake", systemImage: "sun.max.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Colors.amber)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.sm)
                            .frame(maxWidth: .infinity)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.amber.opacity(0.10))
                                    .overlay(Capsule().stroke(DS.Colors.amber.opacity(0.25), lineWidth: 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.md)
                    .opacity(appeared ? 1 : 0)
                    .animation(DS.Anim.cardAppear, value: appeared)
                }

                // Morning: mode banner (I'm-awake CTA) + last-night ribbon + wake coach.
                if modeStore.current == .justWokeUp || modeStore.current == .morning {
                    ModeBanner(mode: modeStore.current, modeStore: modeStore, onWake: { engine.manualWakeUp() })
                        .padding(.top, DS.Spacing.sm)
                        .opacity(appeared ? 1 : 0)
                        .animation(DS.Anim.cardAppear, value: appeared)
                        .scrollSectionTransition()

                    WakeBloomCard(
                        stageMinutes: engine.stageMinutes,
                        durationHours: engine.sleepDurationHours,
                        sleepScore: engine.sleepScore,
                        sleepEfficiency: engine.sleepEfficiency
                    )
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.md)
                    .opacity(appeared ? 1 : 0)
                    .animation(DS.Anim.cardAppear, value: appeared)
                    .scrollSectionTransition()

                    WakeCoachCard(bleManager: bleManager)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.top, DS.Spacing.md)
                        .opacity(appeared ? 1 : 0)
                        .animation(DS.Anim.cardAppear, value: appeared)
                        .scrollSectionTransition()

                    // Last-night signals (restlessness + illness) — a morning status
                    // readout, so it lives here with WakeBloom, not on Insights.
                    LastNightCard(sleep: lastNight, illness: illness)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.top, DS.Spacing.md)
                        .opacity(appeared ? 1 : 0)
                        .animation(DS.Anim.cardAppear, value: appeared)
                        .scrollSectionTransition()
                }

                activityComposerSection
                    .padding(.top, DS.Spacing.xl)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(DS.Anim.stagger(index: 3), value: appeared)
                    .scrollSectionTransition()

                // Coherence drill launcher — a tool for NOW, so it sits in the
                // action zone next to the composer (moved off Insights).
                // Cover attaches HERE, not on the root — TodayView's root already
                // carries 2 covers and SwiftUI silently drops a 3rd sibling.
                CoherenceDrillTile(action: { showCoherenceDrill = true })
                    .fullScreenCover(isPresented: $showCoherenceDrill) {
                        CoherenceDrillView()
                            .environmentObject(bleManager)
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.md)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(DS.Anim.stagger(index: 4), value: appeared)
                    .scrollSectionTransition()

                // v173 — the scale instead of the food log. Whoop measures the
                // burn, the scale measures the result, intake is what has to be
                // true in between.
                WeightTrendCard()
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.md)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(DS.Anim.stagger(index: 5), value: appeared)
                    .scrollSectionTransition()

                // Last meal, food-stats bento + fasting moved to the Food tab
                // (they duplicated Food's own surfaces). FAB keeps logging one tap away.

                if engine.illnessRisk >= 2, let alert = engine.illnessAlert {
                    AlertBanner(icon: "staroflife.fill", message: alert, color: DS.Colors.amber)
                        .padding(.top, DS.Spacing.md)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)
                        .animation(DS.Anim.stagger(index: 6), value: appeared)
                        .scrollSectionTransition()
                }

                // Alcohol has ONE voice on Today: the hero-zone chip. The wine
                // PatternNote that repeated it down here is gone.
                // HRV-vs-baseline delta lives on the Health tab.

                // Outside context — weather + PC, grouped under a collapsed
                // "Context" disclosure so the home screen stays calm but the raw
                // data is one tap away ("keep all, group ambient").
                CollapsibleContext(title: "CONTEXT", icon: "globe.europe.africa.fill") {
                    VStack(spacing: DS.Spacing.md) {
                        WeatherContextTile()
                            .padding(.horizontal, DS.Spacing.md)
                        PCActivityTile()
                            .padding(.horizontal, DS.Spacing.md)
                    }
                    .padding(.top, DS.Spacing.sm)
                }
                .padding(.top, DS.Spacing.lg)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
                .animation(DS.Anim.stagger(index: 9), value: appeared)
                .scrollSectionTransition()

                Color.clear.frame(height: 100)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Pull-to-refresh refreshes the body, not an invisible food list —
        // the old loadEntries()-only path refreshed nothing Today renders.
        .refreshable { await refreshBodyMetrics() }
    }

    // MARK: - Hero Section (FORMAT: BATTERY)

    @ViewBuilder
    private var heroSection: some View {
        VStack(spacing: DS.Spacing.md) {
            // 180pt ring — biggest thing on screen (principle #10)
            // v103 — switchable: Classic (continuous gradient) or Smoke (Mode A
            // with recovery-tinted wisps off the trim tip). Settings → Display.
            // Body Battery is now the hero (the "how much can I push" tank).
            // Recovery is demoted into the secondary strip inside this card.
            // One interpretive slot: the hero's status chip. RecoveryOverlay
            // REPLACES it in-place when active — voices never stack.
            // (recoveryContextLine, RecoveryOverlayBanner, RecoveryTrendStrip
            // all said the same thing 4 ways; trend now lives on Health.)
            BodyBatteryHero(
                level: engine.bodyBattery,
                recovery: engine.recoveryScore,
                sleepHours: engine.sleepDurationHours,
                strain: engine.strainScore,
                trend: bbTrend,
                overlay: overlay
            )
                .padding(.top, DS.Spacing.sm)

            // v106: alcohol-night chip — alcohol's ONE voice on Today. Gives
            // context to a low score so it reads as "the wine, not you".
            if engine.alcoholImpact > 0 {
                AlcoholNightChip()
                    .padding(.horizontal, DS.Spacing.lg)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Live Stats Row (FORMAT: ROW)
    @ViewBuilder
    private var liveStatsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                SectionHeader(icon: "waveform.path.ecg", title: "LIVE", iconColor: DS.Colors.teal)
                AmbientLiveDot(
                    state: bleManager.connectionState == .connected ? .connected : .disconnected
                )
            }
            .padding(.horizontal, DS.Spacing.md)

            // Principle #11 — row format (not ring again)
            LiveBiometricsPanel()
                .environmentObject(bleManager)
                .padding(.horizontal, DS.Spacing.md)
        }
    }

    // MARK: - Activity Composer (FORMAT: COMPOSER) — inline custom-name activity start
    // No predefined picker — Fabi types what he's doing, taps Start. Lucid AI canonicalizes
    // server-side. When a session is active, this shows the active card with End button.
    @ViewBuilder
    private var activityComposerSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                CategoryDot(category: .body)
                SectionHeader(title: "ACTIVITY")
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.md)

            // Tracked workouts (v174) — server owns the catalog and the calorie
            // math. Free-text below still handles everything not worth a row.
            WorkoutStrip()
                .padding(.horizontal, DS.Spacing.md)

            if let active = bleManager.manualActivityType,
               let started = bleManager.manualActivityStart {
                activeSessionCard(type: active, startedAt: started)
                    .padding(.horizontal, DS.Spacing.md)
            } else {
                composerInputCard
                    .padding(.horizontal, DS.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private var composerInputCard: some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField("What are you doing?", text: $activityDraft)
                .font(.system(size: 14, weight: .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(DS.Colors.surfaceElevated)
                .clipShape(Capsule())
                .foregroundStyle(DS.Colors.textPrimary)
                .submitLabel(.go)
                .onSubmit { startActivity() }

            Button {
                startActivity()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(activityDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                       ? DS.Colors.violet.opacity(0.3)
                                       : DS.Colors.violet)
                    )
            }
            .buttonStyle(.plain)
            .disabled(activityDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func activeSessionCard(type: String, startedAt: Date) -> some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { _ in
            HStack(spacing: DS.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(DS.Colors.violet.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Colors.violet)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(elapsedString(from: startedAt) + (bleManager.heartRate > 0 ? " · \(bleManager.heartRate) bpm" : ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Colors.textMuted)
                }

                Spacer()

                Button {
                    let h = UIImpactFeedbackGenerator(style: .medium)
                    h.impactOccurred()
                    bleManager.endManualActivity()
                } label: {
                    Label("End", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.danger)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(DS.Colors.danger.opacity(0.10))
                                .overlay(Capsule().stroke(DS.Colors.danger.opacity(0.30), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(DS.Spacing.md)
            .glassDefault()
        }
    }

    private func elapsedString(from start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func startActivity() {
        let trimmed = activityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let h = UIImpactFeedbackGenerator(style: .medium)
        h.impactOccurred()
        // Slug the name (lowercase, underscores) — Lucid AI canonicalizes anyway
        let slug = trimmed.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        bleManager.startManualActivity(type: slug)
        activityDraft = ""
    }

    // MARK: - FAB
    @ViewBuilder
    private var fabSection: some View {
        VStack(spacing: DS.Spacing.sm) {
            if showFABMenu {
                FABMenu(isOpen: $showFABMenu) {
                    foodEntryMode = .camera
                } onBarcode: {
                    foodEntryMode = .barcode
                } onManual: {
                    foodEntryMode = .manual
                }
                .padding(.trailing, DS.Spacing.lg)
            }
            FABButton(isOpen: $showFABMenu)
                .padding(.trailing, DS.Spacing.lg)
                .padding(.bottom, 100)
        }
    }

}

// MARK: - Wake Bloom (last night painted as a generative aurora — morning ritual)

private struct WakeBloomCard: View {
    let stageMinutes: [HealthEngine.SleepStage: Double]
    let durationHours: Double
    let sleepScore: Double
    let sleepEfficiency: Double
    @State private var revealed = false

    // Explicit chronology-ish order — NOT allCases ([.awake,.light,.deep,.rem]).
    private let order: [HealthEngine.SleepStage] = [.deep, .rem, .light, .awake]
    private var total: Double { max(stageMinutes.values.reduce(0, +), 1) }
    private func frac(_ s: HealthEngine.SleepStage) -> Double { (stageMinutes[s] ?? 0) / total }
    private func mins(_ s: HealthEngine.SleepStage) -> Int { Int((stageMinutes[s] ?? 0).rounded()) }
    private func name(_ s: HealthEngine.SleepStage) -> String {
        switch s { case .deep: return "Deep"; case .rem: return "REM"; case .light: return "Light"; case .awake: return "Awake" }
    }

    private var durationLabel: String {
        let h = Int(durationHours)
        let m = Int((durationHours - Double(h)) * 60)
        let pct = sleepEfficiency > 0 ? Int(sleepEfficiency.rounded()) : Int(sleepScore.rounded())
        let tag = sleepEfficiency > 0 ? "% eff" : ""
        return "\(h)h \(m)m · \(pct)\(tag)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last night")
                    .font(.system(size: 10, weight: .bold)).tracking(1.4).textCase(.uppercase)
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                Text(durationLabel)
                    .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            // Crisp proportional stage ribbon — solid stageColor fills on ONE baseline,
            // defined edges. Aurora glow lives BEHIND the bar, never on the data marks.
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    RadialGradient(
                        gradient: Gradient(colors: [DS.Colors.violet.opacity(0.14), .clear]),
                        center: .center, startRadius: 0, endRadius: w * 0.6
                    )
                    HStack(spacing: 2) {
                        ForEach(order, id: \.self) { stage in
                            if frac(stage) > 0 {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(DS.Colors.stageColor(stage))
                                    .frame(width: max(3, w * frac(stage)))
                                    .scaleEffect(x: revealed ? 1 : 0, anchor: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DS.Colors.border, lineWidth: 0.5))
            .animation(.easeOut(duration: 0.7), value: revealed)

            // Legend — dot + stage + minutes, only for stages actually present.
            HStack(spacing: 14) {
                ForEach(order, id: \.self) { stage in
                    if mins(stage) > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(DS.Colors.stageColor(stage)).frame(width: 7, height: 7)
                            Text(name(stage))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(DS.Colors.textSecondary)
                            Text("\(mins(stage))m")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                                .foregroundStyle(DS.Colors.textMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 0.5))
        .onAppear { revealed = true }
    }
}

// MARK: - AURA Notice (first-person outlier voice — speaks only when it's real)
// ⚠️ UNMOUNTED since the Aurora redesign. Fabi's call (spec §Risks): resurrect
// deliberately on Today, or delete in Build 4. Do not silently re-mount.

private struct AuraNoticeLine: View {
    let recovery: Double
    let rmssd: Double
    @State private var line: String? = nil

    var body: some View {
        Group {
            if let line {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(DS.Colors.violet)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    Text(line)
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.md)
                .transition(.opacity)
            }
        }
        .task { await compute() }
    }

    private func compute() async {
        let sb = SupabaseClient.shared
        var candidates: [(metric: String, pct: Double)] = []
        if recovery > 0, let p = await sb.fetchPersonalPercentile(metric: "recovery_score", value: recovery) {
            candidates.append((metric: "recovery", pct: p))
        }
        if rmssd > 0, let p = await sb.fetchPersonalPercentile(metric: "hrv_avg", value: rmssd) {
            candidates.append((metric: "hrv", pct: p))
        }
        // Most extreme signal vs the 50th percentile; speak only on a true outlier.
        guard let top = candidates.max(by: { abs($0.pct - 50) < abs($1.pct - 50) }),
              top.pct >= 88 || top.pct <= 12 else { return }
        let high = top.pct >= 88
        let phrase: String
        switch (top.metric, high) {
        case ("recovery", true):  phrase = "I'm in the top \(max(1, 100 - Int(top.pct)))% of my recoveries — this is a rare green light. Use it."
        case ("recovery", false): phrase = "One of my lowest recoveries in a month. Go gentle with me today."
        case ("hrv", true):       phrase = "My HRV is unusually high for me right now — I'm calm and deep. Good day to ask a lot."
        case ("hrv", false):      phrase = "My HRV is bottom \(max(1, Int(top.pct)))% lately — something's taxing me. Worth noticing."
        default:                  phrase = ""
        }
        guard !phrase.isEmpty else { return }
        await MainActor.run { withAnimation { line = phrase } }
    }
}

struct PersonalPercentileChip: View {
    let metric: String
    let value: Double
    var windowDays: Int = 30

    @State private var pct: Double?

    var body: some View {
        Group {
            if let p = pct {
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(ordinal(Int(p.rounded()))) for you")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(tint(p))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint(p).opacity(0.12)))
                .overlay(Capsule().stroke(tint(p).opacity(0.25), lineWidth: 0.5))
            }
        }
        .task {
            if pct == nil, value > 0 {
                pct = await SupabaseClient.shared.fetchPersonalPercentile(
                    metric: metric, value: value, windowDays: windowDays)
            }
        }
    }

    private func tint(_ p: Double) -> Color {
        if p >= 66 { return DS.Colors.teal }
        if p >= 33 { return DS.Colors.amber }
        return DS.Colors.textMuted
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"; default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}

// MARK: - Collapsible Context (groups ambient tiles — weather, PC)
// Header row + chevron; expanded state persists. Collapsed by default so Today's
// top stays calm while keeping every raw data point one tap away.
private struct CollapsibleContext<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content
    @AppStorage("lucid_today_context_open") private var open: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                let h = UIImpactFeedbackGenerator(style: .light); h.impactOccurred()
                withAnimation(DS.Anim.cardAppear) { open.toggle() }
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textMuted)
                    Text(title)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Colors.textMuted)
                        .tracking(0.8)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Colors.textFaint)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Tonight Plan Card
//
// The drinking-tonight flag, freed from the deleted legacy SmartAlarmCard
// (v117). Flips the server's tonight plan into alcohol-recovery mode (no
// early wake, humane backstop). Server-flagged + synced — the note below
// the toggle is the server's own copy.
private struct TonightPlanCard: View {
    @ObservedObject var bleManager: BLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\u{1F377}").font(.system(size: 15))
                Text("Drinking tonight")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer()
                // Computed binding: getter reflects server truth; setter ONLY
                // fires on a real user tap. (A @State + onChange re-fired on the
                // programmatic onAppear/sync assignment, which re-flagged the
                // NEXT day on every launch — alcohol mode walked forward forever.)
                Toggle("", isOn: Binding(
                    get: { bleManager.tonightPlanMode == "alcohol" },
                    set: { isOn in
                        let h = UIImpactFeedbackGenerator(style: .light)
                        h.impactOccurred()
                        Task {
                            _ = await bleManager.supabase.setDrinkingTonight(isOn)
                            await bleManager.syncTonightPlan()
                        }
                    }
                ))
                .labelsHidden()
                .tint(DS.Colors.amber)
            }
            if bleManager.tonightPlanMode == "alcohol" {
                Text(bleManager.tonightPlanNote.isEmpty
                     ? "No early alarm tonight — you sleep until your body is done."
                     : bleManager.tonightPlanNote)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accentGlassCard(tint: DS.Colors.amber, active: bleManager.tonightPlanMode == "alcohol")
    }
}

// WakeCoachCard — "Go back or get up?" The in-window decision helper. When Fabi
// wakes before his sleep target, it asks plan_back_to_sleep and shows ONE verdict
// + action. If he goes back, it arms a gentle wake at his next boundary so he
// never gets woken mid-cycle (the thing that makes going back feel pointless).
// Shows once per day (UserDefaults date guard).
private struct WakeCoachCard: View {
    @ObservedObject var bleManager: BLEManager

    @State private var plan: BackToSleepPlan?
    @State private var loading = true
    @State private var dismissed = false

    @AppStorage("lucid_goback_handled_date") private var handledDate: String = ""

    private var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
    private var alreadyHandled: Bool { handledDate == todayKey }
    private var accent: Color {
        (plan?.shouldGoBack ?? false) ? DS.Colors.violet : DS.Colors.warning
    }

    var body: some View {
        if dismissed || alreadyHandled {
            EmptyView()
        } else {
            content.task { await load() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                Text("GO BACK OR GET UP?")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Colors.textFaint)
                    .tracking(1.2)
                Spacer()
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().tint(DS.Colors.textMuted)
                    Text("Checking your night\u{2026}")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if let plan = plan {
                Text(plan.headline)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(DS.Colors.textPrimary)
                if plan.shouldGoBack, let wakeAt = plan.wakeAt, wakeAt > Date() {
                    // The detail paragraph, drawn: now → shaded remaining
                    // cycle → boundary tick at the gentle-wake moment.
                    CycleBoundaryStrip(wakeAt: wakeAt,
                                       wakeLabel: plan.wakeLabel,
                                       sleptH: plan.sleptH,
                                       accent: accent)
                } else {
                    Text(plan.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions(for: plan)
            } else {
                Text("Couldn't reach your sleep data. Trust your gut \u{2014} under an hour left, just get up.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textSecondary)
                Button { handle() } label: {
                    Text("Got it")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Colors.textMuted)
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accentGlassCard(tint: accent)
    }

    @ViewBuilder
    private func actions(for plan: BackToSleepPlan) -> some View {
        if plan.shouldGoBack {
            VStack(spacing: 8) {
                Button {
                    if let w = plan.wakeAt { bleManager.armGoBackWake(at: w) }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    handle()
                } label: {
                    Text(plan.wakeLabel.isEmpty
                         ? "Sleep \u{2014} wake me at my time"
                         : "Sleep \u{2014} wake me at \(plan.wakeLabel)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(DS.Colors.violet))
                }
                Button { handle() } label: {
                    Text("I'm up anyway")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colors.textMuted)
                }
            }
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                handle()
            } label: {
                Text("Start my day")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(DS.Colors.warning))
            }
        }
    }

    private func load() async {
        let start = await currentSleepStart()
        let result = await SupabaseClient.shared.planBackToSleep(sleepStart: start)
        await MainActor.run {
            self.plan = result
            self.loading = false
        }
    }

    @MainActor
    private func currentSleepStart() -> Date {
        bleManager.healthEngine.sleepStartTime ?? Calendar.current.startOfDay(for: Date())
    }

    private func handle() {
        handledDate = todayKey
        withAnimation(.easeOut(duration: 0.25)) { dismissed = true }
    }
}

// MARK: - Cycle Boundary Strip (WakeCoach detail, drawn instead of narrated)
// Now-marker → shaded remaining 90-min cycle → boundary tick. The tick is the
// server-computed next cycle boundary the gentle wake arms at.
private struct CycleBoundaryStrip: View {
    let wakeAt: Date
    let wakeLabel: String
    let sleptH: Double
    let accent: Color

    private var remainingMin: Int { max(1, Int(wakeAt.timeIntervalSinceNow / 60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                // 90-min cycle canvas; the remaining block shades from "now".
                let frac = min(1.0, Double(remainingMin) / 90.0)
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.track).frame(height: 10)
                    Capsule()
                        .fill(LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.65)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, w * frac), height: 10)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(accent)
                        .frame(width: 3, height: 18)
                        .offset(x: max(0, w * frac - 1.5))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)

            HStack {
                Text("NOW")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(DS.Colors.textFaint)
                Spacer()
                Text("\(remainingMin)m → \(wakeLabel.isEmpty ? "next boundary" : wakeLabel)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }
            if sleptH > 0 {
                Text(String(format: "%.1fh slept — waking at the cycle boundary, not mid-cycle", sleptH))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.Colors.textMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gentle wake in \(remainingMin) minutes at \(wakeLabel)")
    }
}

// MARK: - Wind-Down Coach (v111 Sleep Readiness Index)
// Shown in wind-down mode above the smart alarm. Reads the last 10 min of strap
// stream vs his personal sleep baselines (server-computed) and tells him how far
// his body is from sleep-ready + roughly how long to wind down. Display-only.
private struct WindDownCoachCard: View {
    @ObservedObject var bleManager: BLEManager
    @State private var sri: SleepReadiness?
    @State private var hrSeries: [Double] = []
    @State private var loading = true

    private var accent: Color {
        guard let s = sri else { return DS.Colors.textMuted }
        if s.ready { return DS.Colors.success }
        return s.sri >= 40 ? DS.Colors.warning : DS.Colors.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                Text("SLEEP READINESS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Colors.textFaint)
                    .tracking(1.2)
                Spacer()
                if let s = sri {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(s.sri)")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(accent)
                            .monospacedDigit()
                        Text("/100")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DS.Colors.textFaint)
                    }
                }
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().tint(DS.Colors.textMuted)
                    Text("Reading your body\u{2026}")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let s = sri {
                Text(s.message)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .tracking(-0.2)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // HR-descent chart — the last ~10 min of strap HR gliding toward
                // the dashed personal floor. Stat cells became on-chart
                // annotations; the cells survive only as the no-stream fallback.
                if hrSeries.count >= 8 {
                    HRDescentChart(series: hrSeries,
                                   floor: s.hrFloor,
                                   hrNow: s.hrNow,
                                   etaMin: s.etaMin,
                                   ready: s.ready,
                                   accent: accent)
                        .frame(height: 72)
                        .padding(.top, 2)
                } else {
                    HStack(spacing: DS.Spacing.lg) {
                        statCell(value: "\(Int(s.hrNow))", label: "HR now", color: DS.Colors.pink)
                        statCell(value: "\(Int(s.hrFloor))", label: "your floor", color: DS.Colors.textSecondary)
                        statCell(value: s.ready ? "ready" : "~\(s.etaMin)m",
                                 label: s.ready ? "now" : "to ready", color: accent)
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("No recent strap data \u{2014} put the band on to read your wind-down.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accentGlassCard(tint: accent)
        .task { await load() }
    }

    private func statCell(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.Colors.textFaint)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        let r = await SupabaseClient.shared.fetchSleepReadiness()
        let hr = await MainActor.run { Array(bleManager.healthEngine.recentHR.suffix(60)) }
        await MainActor.run {
            self.sri = r
            self.hrSeries = hr
            self.loading = false
        }
    }
}

// MARK: - HR Descent Chart (wind-down: HR gliding to the personal floor)
// Last ~10 min of strap HR (10s cadence) + dashed floor RuleMark + ETA badge.
private struct HRDescentChart: View {
    let series: [Double]
    let floor: Double
    let hrNow: Double
    let etaMin: Int
    let ready: Bool
    let accent: Color

    private var lo: Double { min(series.min() ?? floor, floor) - 3 }
    private var hi: Double { max(series.max() ?? hrNow, hrNow) + 3 }

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("t", i), y: .value("hr", v))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(DS.Colors.pink)
            }
            if let last = series.last {
                PointMark(x: .value("t", series.count - 1), y: .value("hr", last))
                    .symbolSize(30)
                    .foregroundStyle(DS.Colors.pink)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("\(Int(hrNow))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.pink)
                    }
            }
            RuleMark(y: .value("floor", floor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(DS.Colors.textMuted)
                .annotation(position: .bottom, alignment: .leading) {
                    Text("floor \(Int(floor))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Colors.textMuted)
                }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay(alignment: .topLeading) {
            Text(ready ? "ready now" : "~\(etaMin)m to ready")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(accent.opacity(0.12)))
        }
        .accessibilityLabel("Heart rate \(Int(hrNow)), sleep floor \(Int(floor)), \(ready ? "ready for sleep now" : "about \(etaMin) minutes to sleep-ready")")
    }
}

// MARK: - Coherence Drill launcher (moved from Insights — it's a tool, not a pattern)

private struct CoherenceDrillTile: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [DS.Colors.violet, DS.Colors.teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Image(systemName: "wind")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coherence Drill")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("5-min HRV biofeedback · 6 breaths/min")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DS.Colors.textMuted)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(DS.Colors.violet)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassDefault()
        .pressableCard()
    }
}

// MARK: - Last Night Card (moved from Insights — a morning status readout)

private struct LastNightCard: View {
    let sleep: SleepRestlessness?
    let illness: IllnessRisk?

    var body: some View {
        if let s = sleep {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack {
                    Text("LAST NIGHT")
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Colors.textMuted)
                        .tracking(0.8)
                    Spacer()
                    Text(String(format: "%.1fh in bed", s.inBedH))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.textFaint)
                        .monospacedDigit()
                }
                HStack(spacing: DS.Spacing.md) {
                    metric(value: "\(s.stability)/10", label: "stability", color: stabilityColor(s.stability))
                    metric(value: "\(s.restlessMin)m", label: "restless", color: DS.Colors.textSecondary)
                    metric(value: "\(s.wakeups)", label: "wake-ups", color: DS.Colors.textSecondary)
                    metric(value: "\(s.sleepingHr)", label: "sleep HR", color: DS.Colors.teal)
                }
                if let ill = illness, ill.isSignal {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(illnessColor(ill.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        Text(ill.note)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(DS.Spacing.md)
            .glassDefault()
        }
    }

    private func metric(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DS.Colors.textFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private func stabilityColor(_ s: Int) -> Color {
        if s >= 7 { return DS.Colors.teal }
        if s >= 4 { return DS.Colors.amber }
        return DS.Colors.danger
    }

    private func illnessColor(_ level: String) -> Color {
        switch level {
        case "elevated": return DS.Colors.danger
        case "watch":    return DS.Colors.amber
        default:         return DS.Colors.teal
        }
    }
}

// MARK: - Workout Strip (v174) — tracked sessions on top of the free-text composer
//
// The pills come from the server's workout_types table, so adding rowing later
// is an INSERT, not an App Store review. Free-text below still catches
// everything that isn't worth a row in that table.

private struct WorkoutStrip: View {
    @State private var types: [SupabaseClient.WorkoutType] = []
    /// `open` drives the resume banner, `presented` drives the cover. One state
    /// for both would make dismissing the cover also erase the row behind it.
    @State private var open: SupabaseClient.WorkoutSession? = nil
    @State private var presented: SupabaseClient.WorkoutSession? = nil
    @State private var busy: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let open {
                // A session survives the app being killed mid-ride — the server
                // holds it open, so coming back offers to re-enter it.
                Button {
                    DS.Haptic.tap()
                    presented = open
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Text(open.emoji).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(open.label)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(DS.Colors.textPrimary)
                            Text("in progress")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(DS.Colors.teal)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(DS.Colors.textMuted)
                    }
                    .padding(DS.Spacing.md)
                    .glassDefault()
                }
                .buttonStyle(.plain)
            } else if !types.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(types) { t in
                            Button {
                                start(t)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(t.emoji).font(.system(size: 13))
                                    Text(t.label)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(DS.Colors.textPrimary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule()
                                        .fill(DS.Colors.surfaceElevated)
                                        .overlay(Capsule().stroke(DS.Colors.border, lineWidth: 0.5))
                                )
                                .opacity(busy == nil || busy == t.id ? 1 : 0.4)
                            }
                            .buttonStyle(.plain)
                            .disabled(busy != nil)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
        .task {
            open = await SupabaseClient.shared.workoutOpen()
            types = await SupabaseClient.shared.fetchWorkoutTypes()
        }
        .fullScreenCover(item: $presented) { s in
            WorkoutLiveView(session: s) {
                presented = nil
                open = nil
            }
        }
    }

    private func start(_ t: SupabaseClient.WorkoutType) {
        guard busy == nil else { return }
        busy = t.id
        DS.Haptic.commit()
        Task {
            let s = await SupabaseClient.shared.workoutStart(type: t.id)
            await MainActor.run {
                busy = nil
                if let s {
                    open = s
                    presented = s
                } else {
                    DS.Haptic.error()
                }
            }
        }
    }
}

// MARK: - Workout Live (the screen you look at mid-ride)

private struct WorkoutLiveView: View {
    let session: SupabaseClient.WorkoutSession
    let onClosed: () -> Void

    @State private var live: SupabaseClient.WorkoutLive? = nil
    @State private var showFinish = false
    @State private var summary: SupabaseClient.WorkoutSummary? = nil
    @State private var finishing = false

    var body: some View {
        ZStack {
            DS.Colors.bg.ignoresSafeArea()

            if let summary {
                finishedCard(summary)
            } else {
                liveBody
            }
        }
        // Poll the server rather than deriving calories on-device: the same
        // HR-load formula has to produce the same number here and in the daily
        // total, and there is only one place it can live.
        .task {
            while !Task.isCancelled && summary == nil {
                if let l = await SupabaseClient.shared.workoutLive(id: session.id) {
                    await MainActor.run { live = l }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .sheet(isPresented: $showFinish) {
            WorkoutFinishSheet(
                session: session,
                busy: $finishing
            ) { km, load, rpe in
                Task {
                    await MainActor.run { finishing = true }
                    let s = await SupabaseClient.shared.workoutFinish(
                        id: session.id, distanceKm: km, load: load, rpe: rpe
                    )
                    await MainActor.run {
                        finishing = false
                        showFinish = false
                        if let s {
                            DS.Haptic.success()
                            summary = s
                        } else {
                            DS.Haptic.error()
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: Live

    private var liveBody: some View {
        VStack(spacing: DS.Spacing.lg) {
            HStack {
                Button {
                    DS.Haptic.tap()
                    Task {
                        await SupabaseClient.shared.workoutCancel(id: session.id)
                        await MainActor.run { onClosed() }
                    }
                } label: {
                    Text("Discard")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textMuted)
                }
                .buttonStyle(.plain)
                Spacer()
                HStack(spacing: 6) {
                    Text(session.emoji).font(.system(size: 14))
                    Text(session.label)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)

            Spacer()

            // The clock ticks locally — a 5s server poll would stutter it, and
            // elapsed time is the one number that needs no server to be right.
            TimelineView(.periodic(from: session.startedAt, by: 1)) { ctx in
                Text(clock(ctx.date.timeIntervalSince(session.startedAt)))
                    .font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.Colors.textPrimary)
                    .contentTransition(.numericText())
            }

            zoneBar

            HStack(spacing: DS.Spacing.xl) {
                stat(value: live?.hrNow.map { "\($0)" } ?? "—", unit: "bpm", color: DS.Colors.pink)
                stat(value: "\(live?.kcal ?? 0)", unit: "kcal", color: DS.Colors.amber)
                stat(value: live?.hrAvg.map { "\($0)" } ?? "—", unit: "avg", color: DS.Colors.teal)
            }

            Spacer()

            Button {
                DS.Haptic.commit()
                showFinish = true
            } label: {
                Label("Finish", systemImage: "stop.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(DS.Colors.violet))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    private var zoneBar: some View {
        VStack(spacing: DS.Spacing.sm) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(i == zoneIndex ? zoneColor : DS.Colors.track)
                        .frame(height: i == zoneIndex ? 8 : 5)
                }
            }
            .animation(DS.Anim.standard, value: zoneIndex)
            .frame(height: 10)

            Text((live?.zone ?? "warm-up").uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(zoneColor)
        }
        .padding(.horizontal, DS.Spacing.xl)
    }

    private var zoneIndex: Int {
        switch live?.zone ?? "" {
        case let z where z.hasPrefix("zone 5"): return 4
        case let z where z.hasPrefix("zone 4"): return 3
        case let z where z.hasPrefix("zone 3"): return 2
        case let z where z.hasPrefix("zone 2"): return 1
        default: return 0
        }
    }

    private var zoneColor: Color {
        switch zoneIndex {
        case 4: return DS.Colors.danger
        case 3: return DS.Colors.amber
        case 2: return DS.Colors.violet
        case 1: return DS.Colors.teal
        default: return DS.Colors.textMuted
        }
    }

    private func stat(value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(unit.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(DS.Colors.textMuted)
        }
    }

    // MARK: Finished

    private func finishedCard(_ s: SupabaseClient.WorkoutSummary) -> some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Text(session.emoji).font(.system(size: 44))

            Text(s.headline)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.lg)

            // An estimate and a measurement are not the same number, and the
            // card says which one this was rather than pretending.
            if s.kcalSource != "hr" {
                Text("estimated from resistance — strap was off")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Colors.textMuted)
            }

            Spacer()

            Button {
                DS.Haptic.tap()
                onClosed()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(DS.Colors.violet))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    private func clock(_ secs: TimeInterval) -> String {
        let t = max(0, Int(secs))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Finish sheet (distance / resistance / effort)

private struct WorkoutFinishSheet: View {
    let session: SupabaseClient.WorkoutSession
    @Binding var busy: Bool
    let onSave: (Double?, Int?, Int?) -> Void

    @State private var kmText = ""
    @State private var load: Int? = nil
    @State private var rpe: Int? = nil
    @FocusState private var kmFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Text("How was it?")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.top, DS.Spacing.lg)

            if session.tracksDistance {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    SectionHeader(title: "DISTANCE")
                    HStack {
                        TextField("0.0", text: $kmText)
                            .keyboardType(.decimalPad)
                            .focused($kmFocused)
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(DS.Colors.surfaceElevated)
                            .clipShape(Capsule())
                            .frame(width: 120)
                        Text("km")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Colors.textMuted)
                    }
                }
            }

            // Worth filling in: with the strap off this dial IS the calorie
            // number (MET scaled by resistance), not decoration.
            if session.tracksLoad {
                scale(title: "RESISTANCE", value: $load, tint: DS.Colors.violet)
            }

            scale(title: "EFFORT (RPE)", value: $rpe, tint: DS.Colors.amber)

            Spacer()

            Button {
                let km = Double(kmText.replacingOccurrences(of: ",", with: "."))
                onSave(km, load, rpe)
            } label: {
                Text(busy ? "Saving…" : "Save")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(busy ? DS.Colors.violet.opacity(0.4) : DS.Colors.violet))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .padding(.bottom, DS.Spacing.lg)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .background(DS.Colors.bg.ignoresSafeArea())
    }

    @ViewBuilder
    private func scale(title: String, value: Binding<Int?>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(title: title, trailing: value.wrappedValue.map { "\($0)" })
            HStack(spacing: 4) {
                ForEach(1...10, id: \.self) { n in
                    Button {
                        DS.Haptic.select()
                        value.wrappedValue = (value.wrappedValue == n) ? nil : n
                    } label: {
                        Text("\(n)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(value.wrappedValue == n ? .white : DS.Colors.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                    .fill(value.wrappedValue == n ? tint : DS.Colors.surfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Trend Card (v173) — the scale replaces the food log
//
// Energy balance runs backwards just as well as forwards: Whoop measures the
// burn, the scale measures the result, and intake is what has to be true in
// between. One number a morning instead of every meal.

private struct WeightTrendCard: View {
    @State private var series: [SupabaseClient.WeightPoint] = []
    @State private var backsolve: SupabaseClient.IntakeBacksolve? = nil
    @State private var showWeighIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            SectionHeader(icon: "scalemass.fill", title: "TREND", iconColor: DS.Colors.teal,
                          trailing: series.last.map { String(format: "%.1f kg", $0.kg) })

            if let b = backsolve, b.hasNumber {
                numbers(b)
            }

            if series.count >= 2 {
                chart
            }

            Text(backsolve?.headline ?? "Weigh in a few mornings and this starts reading your intake backwards.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                DS.Haptic.tap()
                showWeighIn = true
            } label: {
                Label("Weigh in", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.teal)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        Capsule()
                            .fill(DS.Colors.teal.opacity(0.10))
                            .overlay(Capsule().stroke(DS.Colors.teal.opacity(0.30), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Spacing.md)
        .glassDefault()
        .task { await load() }
        .sheet(isPresented: $showWeighIn) {
            WeighInSheet { kg in
                Task {
                    await SupabaseClient.shared.logWeight(kg: kg)
                    await load()
                    await MainActor.run { showWeighIn = false }
                }
            }
            .presentationDetents([.height(260)])
        }
    }

    private func numbers(_ b: SupabaseClient.IntakeBacksolve) -> some View {
        HStack(spacing: DS.Spacing.md) {
            cell(title: "ATE", value: b.estIntake.map { "\($0)" } ?? "—", tint: DS.Colors.violet)
            cell(title: "BURNED", value: "\(b.avgTdee)", tint: DS.Colors.amber)
            cell(
                title: "BALANCE",
                value: b.estBalance.map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "—",
                tint: (b.estBalance ?? 0) <= 0 ? DS.Colors.success : DS.Colors.textSecondary
            )
        }
    }

    private func cell(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(DS.Colors.textMuted)
            Text(value)
                .font(.system(size: 19, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chart: some View {
        Chart {
            ForEach(series) { p in
                LineMark(x: .value("Day", p.date), y: .value("kg", p.kg))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(DS.Colors.teal)
                PointMark(x: .value("Day", p.date), y: .value("kg", p.kg))
                    .foregroundStyle(DS.Colors.teal)
                    .symbolSize(18)
            }
        }
        // Auto-scaling to the data would turn 200g of water weight into a cliff.
        .chartYScale(domain: yDomain)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .frame(height: 90)
    }

    private var yDomain: ClosedRange<Double> {
        let kgs = series.map(\.kg)
        guard let lo = kgs.min(), let hi = kgs.max() else { return 70...80 }
        let pad = max(0.8, (hi - lo) * 0.35)
        return (lo - pad)...(hi + pad)
    }

    private func load() async {
        let s = await SupabaseClient.shared.fetchWeightSeries(days: 60)
        let b = await SupabaseClient.shared.intakeBacksolve(days: 14)
        await MainActor.run {
            series = s
            backsolve = b
        }
    }
}

private struct WeighInSheet: View {
    let onSave: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var kg: Double? {
        let v = Double(text.replacingOccurrences(of: ",", with: "."))
        guard let v, v >= 30, v <= 250 else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Text("This morning")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.top, DS.Spacing.lg)

            HStack {
                TextField("76.0", text: $text)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .font(.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(DS.Colors.surfaceElevated)
                    .clipShape(Capsule())
                    .frame(width: 150)
                Text("kg")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textMuted)
            }

            Button {
                if let kg { DS.Haptic.success(); onSave(kg) }
            } label: {
                Text("Save")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(kg == nil ? DS.Colors.teal.opacity(0.35) : DS.Colors.teal))
            }
            .buttonStyle(.plain)
            .disabled(kg == nil)

            Spacer()
        }
        .padding(.horizontal, DS.Spacing.lg)
        .background(DS.Colors.bg.ignoresSafeArea())
        .onAppear { focused = true }
    }
}
