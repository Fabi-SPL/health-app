import SwiftUI

/// Manual food entry — user types what they ate (e.g. "lasagna I made yesterday")
/// and picks when. Gemini estimates nutrition from text only. No photo required.
struct ManualFoodEntrySheet: View {
    var onSaved: ((FoodEntry) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var description: String = ""
    @State private var eatenAt: Date = Date()
    @State private var items: [DetectedItem] = []
    @State private var caption: String = ""
    @State private var isAnalyzing = false
    @State private var isSaving = false
    @State private var hasAnalyzed = false
    @State private var error: String?
    @State private var geminiResult: GeminiFoodResult?
    @State private var estimate: MealEstimate?
    @State private var isEstimating = false
    @State private var savePhase = "Saving…"
    @State private var portion: PortionSize = .normal

    // Body profile (shared with Settings) — sizes the meal against your own day.
    @AppStorage("lucid_user_weight_kg") private var weightKg: Double = 75.25
    @AppStorage("lucid_user_height_cm") private var heightCm: Double = 178
    @AppStorage("lucid_user_age") private var ageYears: Int = 20

    @FocusState private var descriptionFocused: Bool

    private let gemini = GeminiClient.shared
    private let supabase = SupabaseClient.shared

    private var canAnalyze: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isAnalyzing
    }

    var body: some View {
        ZStack {
            AuroraBackground()

            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    header

                    descriptionCard

                    timeCard

                    portionCard

                    if isAnalyzing {
                        analyzingCard
                    }

                    if hasAnalyzed && !items.isEmpty {
                        VStack(spacing: DS.Spacing.sm) {
                            sectionLabel("Detected items")
                            ForEach($items) { $item in
                                DetectedItemRow(item: $item)
                            }
                        }
                        .padding(.horizontal, DS.Spacing.md)

                        if let totals = geminiResult?.mealTotals {
                            mealTotalsCard(totals)
                        }
                    }

                    if let est = estimate {
                        glycemicCard(est)
                    }

                    if let error {
                        AlertBanner(icon: "exclamationmark.triangle", message: error, color: DS.Colors.danger)
                            .padding(.horizontal, DS.Spacing.md)
                    }

                    actionButton

                    Color.clear.frame(height: DS.Spacing.xl * 2)
                }
                .padding(.top, DS.Spacing.lg)
            }

            closeButton
        }
        .onAppear { descriptionFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Type a meal")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("No photo? Just describe what you ate.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Description card

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            sectionLabel("What did you eat?")
            TextField(
                "e.g. Homemade lasagna, big plate, with side salad",
                text: $description,
                axis: .vertical
            )
            .font(DS.Font.body)
            .foregroundStyle(DS.Colors.textPrimary)
            .lineLimit(3...8)
            .focused($descriptionFocused)
            .submitLabel(.done)
        }
        .glassCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Time card

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            sectionLabel("When did you eat it?")
            DatePicker(
                "",
                selection: $eatenAt,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(DS.Colors.violet)

            HStack(spacing: DS.Spacing.xs) {
                quickTimeChip("Now") { eatenAt = Date() }
                quickTimeChip("1h ago") { eatenAt = Date().addingTimeInterval(-3600) }
                quickTimeChip("Yesterday 7pm") {
                    eatenAt = Calendar.current.date(
                        bySettingHour: 19, minute: 0, second: 0,
                        of: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    ) ?? Date()
                }
            }
            .padding(.top, 4)
        }
        .glassCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    private func quickTimeChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            let h = UIImpactFeedbackGenerator(style: .light)
            h.impactOccurred()
            action()
        }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.violet)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(DS.Colors.violet.opacity(0.12))
                        .overlay(Capsule().stroke(DS.Colors.violet.opacity(0.25), lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Portion

    private var portionCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            sectionLabel("How big a portion?")
            PortionSizePicker(selection: $portion)
            Text("Normal = your usual amount. Health learns what that means for your body over time.")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textMuted)
        }
        .glassCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Analyzing

    private var analyzingCard: some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView().tint(DS.Colors.violet)
            Text("Analyzing with Gemini…")
                .font(DS.Font.body)
                .foregroundStyle(DS.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    private func mealTotalsCard(_ totals: MealTotals) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            sectionLabel("Estimated totals")
            HStack(spacing: DS.Spacing.md) {
                if let mid = totals.caloriesMidpoint {
                    totalsCell(value: "\(mid)", unit: "kcal", color: DS.Colors.violet)
                }
                if let p = totals.proteinG {
                    totalsCell(value: String(format: "%.0f", p), unit: "g protein", color: DS.Colors.teal)
                }
                if let c = totals.carbsG {
                    totalsCell(value: String(format: "%.0f", c), unit: "g carbs", color: DS.Colors.amber)
                }
                if let f = totals.fatG {
                    totalsCell(value: String(format: "%.0f", f), unit: "g fat", color: DS.Colors.danger)
                }
            }
            if let conf = totals.confidenceLevel {
                Text("Confidence: \(conf)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.textFaint)
                    .padding(.top, 4)
            }
            if let line = bodyContextLine(kcal: totals.caloriesMidpoint, proteinG: totals.proteinG) {
                Text(line)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.violet)
                    .padding(.top, 2)
            }
        }
        .glassCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Glycemic card (instant, server-estimated, no Gemini)

    private func glycemicCard(_ est: MealEstimate) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            sectionLabel("Carb impact · instant")
            HStack(spacing: DS.Spacing.md) {
                totalsCell(value: "\(est.netCarbsG)", unit: "g net carbs", color: DS.Colors.amber)
                totalsCell(value: "\(est.glycemicLoad)", unit: "glycemic load", color: bandColor(est.giBand))
                totalsCell(value: est.giBand.capitalized, unit: "GI band", color: bandColor(est.giBand))
            }
            Text(est.note)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(DS.Colors.textMuted)
                .padding(.top, 2)
        }
        .glassCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    private func bandColor(_ band: String) -> Color {
        switch band {
        case "high":   return DS.Colors.danger
        case "medium": return DS.Colors.amber
        default:       return DS.Colors.teal
        }
    }

    private func totalsCell(value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DS.Colors.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action button

    @ViewBuilder
    private var actionButton: some View {
        // Save is ALWAYS available once there's a description — never gate
        // logging behind Gemini. (Was: Save only after hasAnalyzed==true, so a
        // Gemini 429 trapped the user with no way to log.) Analysis is optional
        // enrichment that fills kcal/NOVA when the quota allows.
        VStack(spacing: DS.Spacing.sm) {
            Button { saveEntry() } label: {
                HStack {
                    if isSaving {
                        ProgressView().tint(.white)
                        Text(savePhase)
                    } else {
                        Image(systemName: "checkmark")
                        Text("Save meal")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassActionButtonStyle(tint: DS.Colors.violet, filled: true))
            .disabled(isSaving || !canAnalyze)
            .opacity(canAnalyze ? 1.0 : 0.5)

            // Instant, free, server-side carb/glycemic estimate (no Gemini quota).
            Button { quickEstimate() } label: {
                HStack {
                    if isEstimating {
                        ProgressView().tint(DS.Colors.teal)
                    } else {
                        Image(systemName: "bolt.fill")
                        Text(estimate == nil ? "Estimate carbs · instant, free" : "Re-estimate carbs")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassActionButtonStyle(tint: DS.Colors.teal, filled: false))
            .disabled(!canAnalyze || isSaving || isEstimating)

            Button { hasAnalyzed ? reanalyze() : analyze() } label: {
                HStack {
                    if isAnalyzing {
                        ProgressView().tint(DS.Colors.violet)
                    } else {
                        Image(systemName: hasAnalyzed ? "arrow.clockwise" : "sparkles")
                        Text(hasAnalyzed ? "Re-analyze" : "Deep analysis · Gemini (optional)")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassActionButtonStyle(tint: DS.Colors.textSecondary, filled: false))
            .disabled(!canAnalyze || isSaving)
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Close

    private var closeButton: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .padding(.leading, DS.Spacing.md)
                Spacer()
            }
            .padding(.top, DS.Spacing.md)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DS.Font.label)
            .foregroundStyle(DS.Colors.textMuted)
            .tracking(0.8)
    }

    // MARK: - Actions

    private func quickEstimate() {
        DS.Haptic.tap()
        descriptionFocused = false
        isEstimating = true
        error = nil
        Task {
            if let est = await supabase.estimateMealFromText(description) {
                estimate = est
                if !est.items.isEmpty {
                    items = est.items
                    hasAnalyzed = true
                }
                if !est.recognized {
                    error = "Didn't recognise that one. Type a common food, or use deep analysis."
                } else {
                    DS.Haptic.tap()
                }
            } else {
                error = "Estimate failed. Try deep analysis instead."
            }
            isEstimating = false
        }
    }

    private func analyze() {
        DS.Haptic.tap()
        descriptionFocused = false
        isAnalyzing = true
        error = nil
        Task {
            do {
                let result = try await gemini.analyzeFood(description: description)
                geminiResult = result
                items = result.items
                hasAnalyzed = true
            } catch {
                self.error = "Analysis failed: \(error.localizedDescription)"
                items = []
            }
            isAnalyzing = false
        }
    }

    private func reanalyze() {
        hasAnalyzed = false
        items = []
        geminiResult = nil
        analyze()
    }

    /// "≈ 32% of your day · 41g protein (0.5 g/kg)" — meal sized against your own
    /// TDEE + body weight (Mifflin-St Jeor BMR, moderate activity ×1.55).
    private func bodyContextLine(kcal: Int?, proteinG: Double?) -> String? {
        guard weightKg > 0 else { return nil }
        let bmr = 10 * weightKg + 6.25 * heightCm - 5 * Double(ageYears) + 5
        let tdee = bmr * 1.55
        var parts: [String] = []
        if let k = kcal, tdee > 0 {
            parts.append("≈ \(Int((Double(k) / tdee * 100).rounded()))% of your day")
        }
        if let p = proteinG {
            parts.append(String(format: "%.0fg protein (%.1f g/kg)", p, p / weightKg))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func saveEntry() {
        DS.Haptic.commit()
        isSaving = true
        error = nil
        Task {
            // ACCURACY FIX (German/donut bug): Save now routes through Gemini's
            // text analysis FIRST — it understands German, portions, NOVA, and
            // never confuses "Schokolade" for "Cola". The old keyword matcher
            // (estimate_meal_from_text) is now ONLY an offline fallback when
            // Gemini is unreachable/over-quota, and is flagged confidence
            // "rough_text" so its log-quality score reflects the lower trust.
            var usedRoughFallback = false
            if geminiResult == nil {
                savePhase = "Analyzing with AI…"
                if let r = try? await gemini.analyzeFood(description: description) {
                    geminiResult = r
                    items = r.items
                } else {
                    // Gemini failed — record it, then fall back to the keyword estimate.
                    supabase.logClientError(area: "manual_text.gemini_fallback",
                                            message: "Gemini text analysis failed on Save; used keyword fallback",
                                            context: String(description.prefix(200)))
                    if estimate == nil, let est = await supabase.estimateMealFromText(description), est.recognized {
                        estimate = est
                        if !est.items.isEmpty { items = est.items }
                    }
                    usedRoughFallback = true
                }
                savePhase = "Saving…"
            }
            do {
                let result = geminiResult
                let confidence: String? = result?.confidence
                    ?? (usedRoughFallback ? "rough_text" : estimate?.confidence)
                let source = "manual"
                let entry = FoodEntry(
                    id: nil,
                    userId: SupabaseClient.shared.userId,
                    capturedAt: eatenAt,
                    photoUrl: nil,
                    geminiRawJson: result?.notes,
                    items: items,
                    caption: description,
                    totalKcal: result?.totalKcal ?? estimate?.kcal,
                    novaAvg: result?.novaAvg,
                    mindScore: result?.mindScore,
                    confidence: confidence,
                    source: source,
                    createdAt: nil,
                    logQuality: FoodEntry.computeLogQuality(source: source, confidence: confidence, items: items),
                    portionSize: portion.rawValue,
                    portionFactor: portion.factor
                )

                let saved = try await supabase.saveFoodEntry(entry)
                DS.Haptic.success()
                onSaved?(saved)
                dismiss()
            } catch {
                DS.Haptic.error()
                self.error = error.localizedDescription
                supabase.logClientError(area: "manual_text.save_failed",
                                        message: error.localizedDescription,
                                        context: String(description.prefix(200)))
            }
            isSaving = false
        }
    }
}
