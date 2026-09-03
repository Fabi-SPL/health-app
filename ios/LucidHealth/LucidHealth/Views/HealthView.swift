import SwiftUI
import Charts

// MARK: - HealthView (biometric explorer)
// Principle #11 format diversity: ring → bar → chart → stacked bar + tiles → zoned bar + number → timeline → gauge
// Each section uses a different visual format — ADHD attention anchored.

struct HealthView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @State private var appeared = false
    @State private var showSleepAdjust = false
    @State private var showResearchMetrics = false
    @State private var recoveryTrend: [Double] = []

    private var engine: HealthEngine { bleManager.healthEngine }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: DS.Spacing.lg) {
                    Color.clear.frame(height: DS.Spacing.sm)

                    // Story order: battery spine → the systems that feed it.
                    // Page opens on the hero — zero controls above it.
                    bodyBatteryHeroSection
                        .staggerIn(appeared: appeared, index: 0)

                    // FORMAT: ROW — live now (biometrics larger)
                    liveNowSection
                        .staggerIn(appeared: appeared, index: 1)

                    // FORMAT: BAR — recovery breakdown + trend + forecast (one cluster)
                    recoveryBreakdownSection
                        .staggerIn(appeared: appeared, index: 2)

                    TomorrowForetoldCard(actualRecoveryToday: engine.recoveryScore)
                        .padding(.horizontal, DS.Spacing.md)
                        .staggerIn(appeared: appeared, index: 2)

                    // FORMAT: CHART — HRV trend (research metrics behind disclosure)
                    hrvTrendSection
                        .staggerIn(appeared: appeared, index: 3)

                    // FORMAT: STACKED BAR + TILES — sleep (score + details + adjust)
                    sleepSection
                        .staggerIn(appeared: appeared, index: 4)

                    // FORMAT: ZONED BAR + NUMBER — strain & activity
                    strainSection
                        .staggerIn(appeared: appeared, index: 5)

                    // FORMAT: GAUGE (conditional) — illness signals
                    if engine.illnessRisk > 0 || engine.lastAlcoholImpact > 10 {
                        illnessSection
                            .staggerIn(appeared: appeared, index: 6)
                    }

                    // One-line device strip — telemetry lives in Settings → Diagnostics
                    deviceStrip
                        .staggerIn(appeared: appeared, index: 7)

                    Color.clear.frame(height: 100)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TwoToneHeadline(
                    primary: "Health",
                    secondary: " · Biometrics",
                    font: .system(size: 17, weight: .heavy, design: .rounded)
                )
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                SettingsGearButton()
            }
        }
        .onAppear { withAnimation { appeared = true } }
        .task { recoveryTrend = await bleManager.supabase.fetchRecoveryTrend() }
        .sheet(isPresented: $showSleepAdjust) {
            SleepAdjustSheet(engine: engine, ble: bleManager) {
                showSleepAdjust = false
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - 1. Live Now (FORMAT: ROW — bigger than Today's version)

    @ViewBuilder
    private var liveNowSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // One connection indicator app-wide (hero header dot); one header grammar (no icons).
            SectionHeader(title: "LIVE NOW")
                .padding(.horizontal, DS.Spacing.md)

            // Tighter 4-cell live row — battery/RSSI/FW moved to Settings → Diagnostics
            // (lucid-design: kill duplicates from Today, focal numbers belong on the headline)
            HStack(spacing: 0) {
                liveCell(icon: "heart.fill", label: "HR",
                         value: bleManager.heartRate > 0 ? "\(bleManager.heartRate)" : "—",
                         unit: "bpm", color: DS.Colors.pink, size: .medium)
                divider
                liveCell(icon: "waveform.path.ecg", label: "HRV",
                         value: engine.currentRMSSD > 0 ? "\(Int(engine.currentRMSSD))" : "—",
                         unit: "ms", color: DS.Colors.teal, size: .medium)
                divider
                liveCell(icon: "lungs", label: "BREATH",
                         value: engine.respiratoryRate > 0 ? String(format: "%.1f", engine.respiratoryRate) : "—",
                         unit: "/min", color: DS.Colors.violet, size: .medium)
                divider
                liveCell(icon: "thermometer.medium", label: "TEMP",
                         value: bleManager.skinTemperature > 0 ? String(format: "%.1f", bleManager.skinTemperature) : "—",
                         unit: "°C", color: DS.Colors.amber, size: .medium)
            }
            .padding(.vertical, DS.Spacing.sm)
            .glassDefault()
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    // MARK: - 2. Recovery Breakdown (FORMAT: BAR)

    @ViewBuilder
    private var recoveryBreakdownSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                CategoryDot(category: .body)
                SectionHeader(title: "RECOVERY BREAKDOWN")
            }
            .padding(.horizontal, DS.Spacing.md)

            // Ring (focal) + status chip beside it — distinct format from the
            // battery gauge above. No per-factor breakdown here (removed
            // 2026-09-03, see comment below) — the ring shows the server's
            // real recovery score with nothing beside it claiming to explain it.
            HStack(alignment: .center, spacing: DS.Spacing.lg) {
                ScoreRing(
                    score: engine.recoveryScore,
                    size: 88,
                    lineWidth: 7,
                    color: DS.Colors.recoveryColor(engine.recoveryScore),
                    label: "RECOVERY"
                )

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    StatusChip(
                        text: engine.recoveryLabel.isEmpty ? "—" : engine.recoveryLabel,
                        style: engine.recoveryScore >= 67 ? .teal : (engine.recoveryScore >= 34 ? .amber : .danger)
                    )

                    // RecoveryBreakdownBar + legend removed (2026-09-03): was fed by
                    // RecoveryEngine.swift's local v100 sigmoid estimate (40/25/25 HRV/
                    // RHR/Sleep weights) while the ring beside it shows the server's
                    // live v153 percentile-rank score (55/30/15 weights, different
                    // methodology entirely). The bar misexplained the real number every
                    // time. No true per-component breakdown is available on-device —
                    // compute_recovery_score's percentile terms (hrv_pct/rhr_pct_inv/
                    // s_score) are local plpgsql variables, never returned by the
                    // recompute_health_metrics RPC or stored on health_metrics — so a
                    // missing bar stands in for a lying one until the server actually
                    // returns real contributions. See health-recon/06-score-truth-audit.md §5.1.
                }
            }
            .padding(DS.Spacing.lg)
            .glassDefault()
            .padding(.horizontal, DS.Spacing.md)

            // 14-day recovery trend (moved off Today's hero zone) — makes the
            // genuinely 9-100 swinging score's movement visible beside the
            // ring it belongs to.
            if recoveryTrend.count >= 3 {
                RecoveryTrendStrip(scores: recoveryTrend)
                    .padding(DS.Spacing.md)
                    .glassSubtle()
                    .padding(.horizontal, DS.Spacing.md)
            }
        }
    }

    // MARK: - 3. HRV Trend (FORMAT: CHART)

    @ViewBuilder
    private var hrvTrendSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                CategoryDot(category: .mind)
                SectionHeader(title: "HRV TREND · 7 DAYS")
            }
            .padding(.horizontal, DS.Spacing.md)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                // RMSSD as the single headline. ln(RMSSD) demoted to mono caption underneath.
                VStack(alignment: .leading, spacing: 2) {
                    Text("RMSSD")
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Colors.textFaint)
                        .tracking(0.8)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(engine.currentRMSSD > 0 ? "\(Int(engine.currentRMSSD))" : "—")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundStyle(DS.Colors.teal)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("ms")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Colors.textFaint)
                        Spacer()
                        if engine.lnRMSSD > 0 {
                            Text(String(format: "ln %.2f", engine.lnRMSSD))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(DS.Colors.textFaint)
                        }
                    }
                }

                // Sparkline chart
                if engine.baselineRMSSD.count >= 3 {
                    let vals = Array(engine.baselineRMSSD.suffix(7))
                    let baseline = engine.baselineRMSSD.reduce(0, +) / Double(engine.baselineRMSSD.count)
                    let sigma = engine.baselineRMSSD.count > 1
                        ? sqrt(engine.baselineRMSSD.map { pow($0 - baseline, 2) }.reduce(0, +) / Double(engine.baselineRMSSD.count))
                        : 5.0
                    SparklineChart(values: vals, baseline: baseline, sigma: sigma, height: 64)
                }

                // vs baseline chip
                if !engine.baselineRMSSD.isEmpty {
                    let baseline = engine.baselineRMSSD.reduce(0, +) / Double(engine.baselineRMSSD.count)
                    let delta = engine.currentRMSSD - baseline
                    let positive = delta >= 0
                    HStack(spacing: DS.Spacing.sm) {
                        StatusChip(
                            text: String(format: "%+.0f ms vs baseline", delta),
                            style: positive ? .teal : .danger,
                            icon: positive ? "arrow.up.right" : "arrow.down.right"
                        )
                        Spacer()
                        Text(String(format: "Ø %.0f ms", baseline))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.textFaint)
                    }
                }

                // Research metrics (SDNN / pNN50 / DFA α1) — same system, so they
                // live inside the HRV card, behind a disclosure.
                if engine.sdnn > 0 || engine.pnn50 > 0 || engine.dfaAlpha1 > 0 {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showResearchMetrics.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Research metrics")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(DS.Colors.textMuted)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DS.Colors.textFaint)
                                .rotationEffect(.degrees(showResearchMetrics ? 180 : 0))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    if showResearchMetrics {
                        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                        LazyVGrid(columns: cols, spacing: DS.Spacing.sm) {
                            MetricTile(label: "SDNN",   value: engine.sdnn > 0 ? "\(Int(engine.sdnn))" : "—",     unit: "ms", color: DS.Colors.teal)
                            MetricTile(label: "pNN50",  value: engine.pnn50 > 0 ? String(format: "%.1f", engine.pnn50) : "—", unit: "%",  color: DS.Colors.violet)
                            MetricTile(label: "DFA α1", value: engine.dfaAlpha1 > 0 ? String(format: "%.2f", engine.dfaAlpha1) : "—", unit: "α", color: DS.Colors.amber)
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(DS.Spacing.lg)
            .glassDefault()
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    // MARK: - 4. Sleep (FORMAT: STACKED BAR + TILES)

    @ViewBuilder
    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                CategoryDot(category: .sleep)
                SectionHeader(title: "SLEEP LAST NIGHT")
                Spacer()
                // Adjust lives on the sleep card it edits (was a floating pill row).
                Button {
                    DS.Haptic.tap()
                    showSleepAdjust = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Adjust")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(DS.Colors.violet)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.violet.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Spacing.md)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                // Score + duration row
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SCORE")
                            .font(DS.Font.label)
                            .foregroundStyle(DS.Colors.textFaint)
                            .tracking(0.8)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(engine.sleepScore > 0 ? "\(Int(engine.sleepScore))" : "—")
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                                .foregroundStyle(DS.Colors.sleepColor(engine.sleepScore))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("/ 100")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.textFaint)
                        }
                    }
                    Spacer()
                    if engine.sleepDurationHours > 0 {
                        let h = Int(engine.sleepDurationHours)
                        let m = Int((engine.sleepDurationHours - Double(h)) * 60)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("DURATION")
                                .font(DS.Font.label)
                                .foregroundStyle(DS.Colors.textFaint)
                                .tracking(0.8)
                            Text("\(h)h \(m)m")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }
                    if engine.sleepEfficiency > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("EFFICIENCY")
                                .font(DS.Font.label)
                                .foregroundStyle(DS.Colors.textFaint)
                                .tracking(0.8)
                            Text(String(format: "%.0f%%", engine.sleepEfficiency))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(DS.Colors.violet)
                                .monospacedDigit()
                        }
                    }
                }

                // Stacked sleep stages bar
                let stages: [(HealthEngine.SleepStage, Double)] = HealthEngine.SleepStage.allCases.compactMap { stage in
                    guard let mins = engine.stageMinutes[stage], mins > 0 else { return nil }
                    return (stage, mins)
                }
                let totalMinutes = stages.map { $0.1 }.reduce(0, +)

                if !stages.isEmpty && totalMinutes > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(stages, id: \.0) { stage, mins in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DS.Colors.stageColor(stage))
                                    .frame(width: max(2, geo.size.width * CGFloat(mins / totalMinutes)))
                            }
                        }
                    }
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    HStack(spacing: DS.Spacing.md) {
                        ForEach(stages, id: \.0) { stage, mins in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(DS.Colors.stageColor(stage))
                                    .frame(width: 7, height: 7)
                                Text(stageName(stage))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(DS.Colors.textFaint)
                                Text("\(Int(mins))m")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                        Spacer()
                    }
                }

                // Details ride in the same card — one sleep story, not two boxes.
                if hasSleepDetails {
                    Rectangle()
                        .fill(DS.Colors.border.opacity(0.4))
                        .frame(height: 0.5)
                        .padding(.vertical, 2)

                    let cols = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: cols, spacing: DS.Spacing.sm) {
                        if engine.sleepDebtHours > 0 {
                            MetricTile(label: "SLEEP DEBT",
                                       value: String(format: "%.1f", engine.sleepDebtHours), unit: "h",
                                       color: engine.sleepDebtHours > 2 ? DS.Colors.pink : DS.Colors.amber)
                        }
                        if engine.sleepFragmentationIndex > 0 {
                            MetricTile(label: "FRAGMENTATION",
                                       value: String(format: "%.1f", engine.sleepFragmentationIndex), unit: "/h",
                                       color: engine.sleepFragmentationIndex > 3 ? DS.Colors.amber : DS.Colors.teal)
                        }
                        if engine.nocturnalHRDip != 0 {
                            MetricTile(label: "HR DIP",
                                       value: String(format: "%.1f", engine.nocturnalHRDip), unit: "%",
                                       color: engine.nocturnalHRDip >= 10 ? DS.Colors.teal : DS.Colors.amber)
                        }
                        if engine.sleepConsistencyScore > 0 {
                            MetricTile(label: "CONSISTENCY",
                                       value: "\(Int(engine.sleepConsistencyScore))", unit: "/ 100",
                                       color: DS.Colors.violet)
                        }
                    }
                }
            }
            .padding(DS.Spacing.lg)
            .glassDefault()
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    private var hasSleepDetails: Bool {
        engine.sleepDebtHours > 0 ||
        engine.sleepFragmentationIndex > 0 ||
        engine.nocturnalHRDip != 0 ||
        engine.sleepConsistencyScore > 0
    }

    // MARK: - 5. Strain & Activity (FORMAT: ZONED BAR + NUMBER)

    @ViewBuilder
    private var strainSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                CategoryDot(category: .body)
                SectionHeader(title: "STRAIN & ACTIVITY")
            }
            .padding(.horizontal, DS.Spacing.md)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("STRAIN")
                            .font(DS.Font.label)
                            .foregroundStyle(DS.Colors.textFaint)
                            .tracking(0.8)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(engine.strainScore > 0 ? String(format: "%.1f", engine.strainScore) : "—")
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                                .foregroundStyle(DS.Colors.strainColor(engine.strainScore))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("/ 21")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.textFaint)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("ACWR")
                            .font(DS.Font.label)
                            .foregroundStyle(DS.Colors.textFaint)
                            .tracking(0.8)
                        Text(String(format: "%.2f", engine.trainingLoadRatio))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(engine.trainingLoadRatio > 1.3 ? DS.Colors.pink : DS.Colors.teal)
                            .monospacedDigit()
                    }
                }

                // Zone bar (different format — horizontal zoned bar)
                StrainZonesBar(zoneMinutes: engine.zoneMinutes)

                // Steps + status
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.teal)
                    Text("\(engine.todaySteps) steps")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    StatusChip(
                        text: engine.trainingLoadStatus,
                        style: engine.trainingLoadRatio > 1.3 ? .danger : .teal
                    )
                }
            }
            .padding(DS.Spacing.lg)
            .glassDefault()
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    // MARK: - Body Battery Hero (FORMAT: HERO — the master spine)
    // Battery is the one number that integrates everything. It leads Health now;
    // every section below is a system that feeds it. Cognitive rides along as a
    // secondary readout. Server-computed (continuous autonomic) — display only.

    @ViewBuilder
    private var bodyBatteryHeroSection: some View {
        let level = engine.bodyBattery
        let battColor = DS.Colors.bodyBatteryColor(level)
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.violet)
                Text("BODY BATTERY")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Colors.textMuted)
                    .tracking(0.8)
                AmbientLiveDot(
                    state: bleManager.connectionState == .connected ? .connected
                        : (bleManager.connectionState == .scanning ? .scanning : .disconnected)
                )
                Spacer()
                Text(batteryTier(level))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.surface))
                    .overlay(Capsule().stroke(DS.Colors.border, lineWidth: 0.5))
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(level > 0 ? "\(Int(level))" : "—")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .foregroundStyle(battColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("/ 100")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DS.Colors.textFaint)
            }

            if level > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DS.Colors.surfaceElevated)
                            .frame(height: 11)
                        Capsule()
                            .fill(LinearGradient(colors: [DS.Colors.amber, battColor],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * CGFloat(min(level, 100) / 100)), height: 11)
                            .animation(DS.Anim.ringFill, value: level)
                    }
                }
                .frame(height: 11)
            }

            // Cognitive rides along — secondary readout, not a competing tile
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.teal)
                Text("COGNITIVE")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Colors.textMuted)
                    .tracking(0.6)
                Spacer()
                Text(engine.cognitiveCapacity > 0 ? "\(Int(engine.cognitiveCapacity))" : "—")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.teal)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("/ 100")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textFaint)
                if !engine.cognitiveLabel.isEmpty && engine.cognitiveLabel != "—" {
                    StatusChip(text: engine.cognitiveLabel, style: .teal)
                }
            }
            .padding(.top, 2)
        }
        .heroCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    private func batteryTier(_ v: Double) -> String {
        switch v {
        case 67...:      return "Charged"
        case 34..<67:    return "Half tank"
        case 1..<34:     return "Low"
        default:         return "—"
        }
    }

    // MARK: - 7. Illness Signals (FORMAT: GAUGE CHIPS)

    @ViewBuilder
    private var illnessSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                CategoryDot(category: .care)
                SectionHeader(title: "SIGNALS")
            }
            .padding(.horizontal, DS.Spacing.md)

            HStack(spacing: DS.Spacing.lg) {
                IllnessRiskGauge(risk: engine.illnessRisk, alert: engine.illnessAlert)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    if engine.lastAlcoholImpact > 5 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ALCOHOL EFFECT")
                                .font(DS.Font.label)
                                .foregroundStyle(DS.Colors.textFaint)
                                .tracking(0.8)
                            Text(String(format: "%.0f%%", engine.lastAlcoholImpact))
                                .font(.system(size: 28, weight: .heavy, design: .rounded))
                                .foregroundStyle(DS.Colors.amber)
                                .monospacedDigit()
                            Text("HRV below baseline")
                                .font(.system(size: 9))
                                .foregroundStyle(DS.Colors.textFaint)
                        }
                    }
                    Spacer()
                    if engine.consecutiveLowHRVDays > 0 {
                        StatusChip(
                            text: "\(engine.consecutiveLowHRVDays) days low HRV",
                            style: .amber,
                            icon: "arrow.down.forward"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DS.Spacing.lg)
            .glassDefault()
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    // MARK: - 8. Device strip (one line — telemetry ≠ health data)
    // Full telemetry (battery, readings, sync points, RSSI) → Settings → Diagnostics.

    @ViewBuilder
    private var deviceStrip: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textFaint)
            Text(deviceStripLabel)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            if bleManager.isCharging {
                GlassStatusPill(icon: "bolt.fill", text: "Charging", color: DS.Colors.amber)
            }
            if bleManager.battery > 0 {
                Text("\(Int(bleManager.battery))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(bleManager.battery < 20 ? DS.Colors.pink : DS.Colors.textFaint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .glassSubtle()
        .padding(.horizontal, DS.Spacing.md)
    }

    private var deviceStripLabel: String {
        let state = bleManager.connectionState == .connected ? "strap live" : "strap"
        if let last = bleManager.lastSync {
            let m = Int(-last.timeIntervalSinceNow / 60)
            return m < 1 ? "\(state) · synced now" : "\(state) · synced \(m)m ago"
        }
        return state
    }

    // MARK: - Helpers

    private enum LiveCellSize { case large, medium, small }

    private func liveCell(icon: String, label: String, value: String, unit: String, color: Color, size: LiveCellSize) -> some View {
        let iconSize: CGFloat = {
            switch size { case .large: return 11; case .medium: return 10; case .small: return 9 }
        }()
        let valueSize: CGFloat = {
            switch size { case .large: return 18; case .medium: return 16; case .small: return 13 }
        }()
        return VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(color.opacity(0.8))
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit.isEmpty ? label : unit)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(DS.Colors.textFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Colors.border.opacity(0.4))
            .frame(width: 0.5, height: 28)
    }

    private func stageName(_ s: HealthEngine.SleepStage) -> String {
        switch s {
        case .awake: return "Awake"
        case .light: return "Light"
        case .deep:  return "Deep"
        case .rem:   return "REM"
        }
    }

    private func legendItem(color: Color, label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DS.Colors.textFaint)
            Text("\(value)%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textSecondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Stagger modifier

private extension View {
    func staggerIn(appeared: Bool, index: Int) -> some View {
        self
            .offset(y: appeared ? 0 : 20)
            .opacity(appeared ? 1 : 0)
            .animation(DS.Anim.stagger(index: index), value: appeared)
    }
}

// MARK: - Tomorrow, Foretold (self-grading recovery oracle)
// Defs moved from TodayView (Build 2) — it forecasts the number the Recovery
// Breakdown above explains, so the whole HRV/recovery cluster lives here.

private struct TomorrowForetoldCard: View {
    let actualRecoveryToday: Double
    @State private var tomorrow: ForecastDay? = nil
    @State private var verdict: (text: String, hit: Bool)? = nil

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        Group {
            if tomorrow != nil || verdict != nil {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Tomorrow, foretold")
                        .font(.system(size: 10, weight: .bold)).tracking(1.4).textCase(.uppercase)
                        .foregroundStyle(DS.Colors.textMuted)

                    if let v = verdict {
                        // Hit/miss badge + delta — the old sentence said the same thing in 14 words.
                        HStack(spacing: 5) {
                            Image(systemName: v.hit ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(v.text)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(v.hit ? DS.Colors.success : DS.Colors.amber)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill((v.hit ? DS.Colors.success : DS.Colors.amber).opacity(0.10)))
                    }

                    if let t = tomorrow, let p50 = t.recoveryP50 {
                        Text("Tomorrow I'll likely run around \(Int(p50.rounded())) recovery.")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        // The range bar carries the swing — the old "could swing
                        // X–Y" sentence repeated it in words, so it's gone.
                        ForecastRangeBar(p10: t.recoveryP10 ?? p50, p50: p50, p90: t.recoveryP90 ?? p50)
                        HStack {
                            Text("\(Int((t.recoveryP10 ?? p50).rounded()))")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DS.Colors.textMuted)
                            Spacer()
                            Text("\(Int((t.recoveryP90 ?? p50).rounded()))")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DS.Colors.textMuted)
                        }
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
            }
        }
        .task { await load() }
    }

    private func load() async {
        let days = await SupabaseClient.shared.fetchForecast(days: 3)
        let cal = Calendar.current
        if let t = days.first(where: { Self.fmt.date(from: $0.targetDate).map { cal.isDateInTomorrow($0) } ?? false }),
           let p50 = t.recoveryP50 {
            UserDefaults.standard.set(p50, forKey: "aura_fc_\(t.targetDate)")
            await MainActor.run { tomorrow = t }
        }
        // Grade the bet made yesterday FOR today.
        let todayKey = "aura_fc_\(Self.fmt.string(from: Date()))"
        if UserDefaults.standard.object(forKey: todayKey) != nil, actualRecoveryToday > 0 {
            let predicted = UserDefaults.standard.double(forKey: todayKey)
            let delta = Int((actualRecoveryToday - predicted).rounded())
            let hit = abs(delta) <= 8
            let text = hit
                ? "Called it · \(delta >= 0 ? "+" : "")\(delta)"
                : "Off by \(abs(delta))"
            await MainActor.run { verdict = (text, hit) }
        }
    }
}

private struct ForecastRangeBar: View {
    let p10: Double
    let p50: Double
    let p90: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lo = max(0.0, min(p10, p90)) / 100
            let hi = min(1.0, max(p10, p90) / 100)
            let mid = max(0.0, min(1.0, p50 / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.track).frame(height: 6)
                Capsule()
                    .fill(LinearGradient(colors: [DS.Colors.violet.opacity(0.55), DS.Colors.teal.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, w * (hi - lo)), height: 6)
                    .offset(x: w * lo)
                Circle().fill(DS.Colors.violet).frame(width: 11, height: 11)
                    .offset(x: max(0, w * mid - 5.5))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 14)
    }
}
