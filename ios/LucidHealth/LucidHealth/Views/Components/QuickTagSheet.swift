import SwiftUI

/// QuickTagSheet — opens when the Whoop strap is double-tapped (sets
/// BLEManager.showDoubleTapSheet = true).
///
/// Layout (top to bottom):
///   1. "Recent" — top 6 most-used items (frequency × recency decay).
///      After you log espresso 5×, espresso floats to the top.
///   2. Category groups — Intake / Body / Mood / Marker
///   3. Freeform input — "Took magnesium..." with submit button
///
/// All submissions feed QuickLogHistory.shared so the Recent row adapts.
/// Intake events ALSO mirror to food_entries so they show in the Food tab
/// (handled in BLEManager.mirrorIntakeToFoodEntries).
struct QuickTagSheet: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject private var history = QuickLogHistory.shared
    @State private var customText: String = ""
    @State private var lastLogged: String?
    @State private var showBPSheet = false
    @FocusState private var inputFocused: Bool

    private let categories: [QuickLogCategory] = [
        QuickLogCategory(label: "Intake", color: DS.Colors.amber, items: [
            ("☕", "Espresso",        "espresso",        "caffeine", "intake"),
            ("☕", "Double Espresso", "double espresso", "caffeine", "intake"),
            ("☕", "Cappuccino",      "cappuccino",      "caffeine", "intake"),
            ("☕", "Coffee",       "coffee",     "caffeine",   "intake"),
            ("💧", "Water",        "water",      "water",      "intake"),
            ("💊", "Supplement",   "supplement", "supplement", "intake"),
            ("🍽️", "Meal",         "meal",       "meal",       "intake"),
            ("🍷", "Wine",         "wine",       "alcohol",    "intake"),
            ("🍺", "Beer",         "beer",       "alcohol",    "intake"),
        ]),
        QuickLogCategory(label: "Body", color: DS.Colors.violet, items: [
            ("🏋️", "Workout",      "workout",    "exercise",    "physical"),
            ("🚶", "Walk",         "walk",       "walk",        "physical"),
            ("🧖", "Sauna",        "sauna",      "sauna",       "physical"),
            ("🥶", "Cold plunge",  "cold_plunge","cold_plunge", "physical"),
            ("😴", "Nap",          "nap",        "nap",         "physical"),
            ("🧘", "Meditation",   "meditation", "meditation",  "physical"),
        ]),
        QuickLogCategory(label: "Mood", color: DS.Colors.pink, items: [
            ("😤", "Stress",       "stress",      "stress_spike", "mood"),
            ("😰", "Anxiety",      "anxiety",     "anxiety",      "mood"),
            ("😊", "Good mood",    "good mood",   "good_mood",    "mood"),
            ("🔥", "Hyperfocus",   "hyperfocus",  "hyperfocus",   "mood"),
            ("😞", "Low",          "low",         "low_mood",     "mood"),
        ]),
        QuickLogCategory(label: "Marker", color: DS.Colors.teal, items: [
            ("💡", "Idea",         "idea",        "brain_dump",   "marker"),
            ("📌", "Bookmark",     "bookmark",    "bookmark",     "marker"),
            ("💬", "Convo",        "conversation","conversation", "marker"),
            ("🌙", "Bedtime",      "bedtime",     "bedtime",      "marker"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(DS.Colors.borderStrong)
                .frame(width: 42, height: 5)
                .padding(.top, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.md)

            // Header
            VStack(spacing: 4) {
                Text("Quick tag")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Saves to your timeline · intake also into Food tab")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textMuted)
            }
            .padding(.bottom, DS.Spacing.md)

            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.lg) {
                    // 1. Recent row (frequency × recency)
                    if !history.topItems().isEmpty {
                        recentSection
                    }

                    // 2. Categorized chips
                    ForEach(categories) { cat in
                        categorySection(cat)
                    }

                    // 3. Measurements — numeric editor, not one-tap
                    measureSection

                    Color.clear.frame(height: DS.Spacing.lg)
                }
                .padding(.horizontal, DS.Spacing.md)
            }

            // 3. Freeform input + submit (sticky bottom)
            VStack(spacing: 0) {
                Divider().background(DS.Colors.border)
                HStack(spacing: DS.Spacing.sm) {
                    TextField("Or type anything…", text: $customText)
                        .font(.system(size: 14))
                        .focused($inputFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(DS.Colors.surfaceElevated)
                        .clipShape(Capsule())
                        .foregroundStyle(DS.Colors.textPrimary)
                        .submitLabel(.send)
                        .onSubmit { submitCustom() }

                    Button {
                        submitCustom()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(trimmed.isEmpty ? DS.Colors.textMuted : DS.Colors.violet)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty)
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.raised)
            }
        }
        .background(AuroraBackground().ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .overlay(alignment: .top) {
            if let logged = lastLogged {
                savedToast(text: logged)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showBPSheet) { BPLogSheet() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colors.violet)
                Text("MOST USED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.textFaint)
                    .tracking(1.0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(history.topItems()) { item in
                        recentChip(item)
                    }
                }
            }
        }
    }

    private func recentChip(_ item: QuickLogRecent) -> some View {
        Button {
            tap(emoji: item.emoji, displayName: item.displayName, type: item.type, category: item.category)
        } label: {
            HStack(spacing: 6) {
                Text(item.emoji)
                    .font(.system(size: 14))
                Text(item.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("\(item.count)×")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Colors.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(DS.Colors.violet.opacity(0.10))
                    .overlay(Capsule().stroke(DS.Colors.violet.opacity(0.25), lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func categorySection(_ cat: QuickLogCategory) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Circle().fill(cat.color).frame(width: 6, height: 6)
                Text(cat.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.textFaint)
                    .tracking(1.0)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 4), spacing: DS.Spacing.sm) {
                ForEach(cat.items, id: \.1) { (emoji, label, name, type, category) in
                    chipButton(emoji: emoji, label: label, name: name, type: type, category: category, color: cat.color)
                }
            }
        }
    }

    private func chipButton(emoji: String, label: String, name: String, type: String, category: String, color: Color) -> some View {
        Button {
            tap(emoji: emoji, displayName: label, type: type, category: category, name: name)
        } label: {
            VStack(spacing: 4) {
                Text(emoji)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(DS.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .stroke(color.opacity(0.15), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var measureSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Circle().fill(DS.Colors.violet).frame(width: 6, height: 6)
                Text("MEASURE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.textFaint)
                    .tracking(1.0)
            }
            Button {
                let h = UIImpactFeedbackGenerator(style: .light); h.impactOccurred()
                showBPSheet = true
            } label: {
                HStack(spacing: 10) {
                    Text("💓").font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Blood pressure & weight")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("Sys / dia / pulse + a context tag")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(DS.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                .stroke(DS.Colors.violet.opacity(0.18), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func savedToast(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.success)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(DS.Colors.raised)
                .overlay(Capsule().stroke(DS.Colors.success.opacity(0.30), lineWidth: 0.5))
        )
    }

    // MARK: - Actions

    private var trimmed: String {
        customText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tap(emoji: String, displayName: String, type: String, category: String, name: String? = nil) {
        let h = UIImpactFeedbackGenerator(style: .light)
        h.impactOccurred()
        let canonical = name ?? displayName.lowercased()
        history.record(name: canonical, displayName: displayName, emoji: emoji, category: category, type: type)
        ble.logDoubleTapEvent(type: type, category: category, displayName: displayName)
        showSavedToast("\(emoji) \(displayName)")
    }

    private func submitCustom() {
        guard !trimmed.isEmpty else { return }
        let h = UIImpactFeedbackGenerator(style: .medium)
        h.impactOccurred()
        // Local categorization happens inside BLEManager.logCustomEvent.
        // Record with neutral defaults — backend canonicalization will refine.
        history.record(name: trimmed, displayName: trimmed, emoji: "", category: "marker", type: "custom")
        ble.logCustomEvent(note: trimmed)
        showSavedToast(trimmed)
        customText = ""
    }

    private func showSavedToast(_ text: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            lastLogged = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.3)) {
                lastLogged = nil
            }
            // Auto-dismiss the sheet after toast clears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                ble.showDoubleTapSheet = false
            }
        }
    }
}

private struct QuickLogCategory: Identifiable {
    let label: String
    let color: Color
    /// (emoji, label, canonical name, BLE type, BLE category)
    let items: [(String, String, String, String, String)]
    var id: String { label }
}

/// Numeric editor for a blood-pressure reading + optional weigh-in. Opened from
/// QuickTagSheet's MEASURE chip. Writes to blood_pressure_readings (and mirrors
/// weight into user_body_profile) via SupabaseClient. The context tag is what
/// makes the reading correlatable — fasted vs post-caffeine vs post-ride.
private struct BPLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lucid_user_weight_kg") private var storedWeight: Double = 75.25

    @State private var sys = ""
    @State private var dia = ""
    @State private var pulse = ""
    @State private var weight = ""
    @State private var context = "fasted"
    @State private var saving = false
    @State private var saved = false
    @FocusState private var focus: Field?

    private enum Field { case sys, dia, pulse, weight }

    private let contexts: [(String, String)] = [
        ("fasted",        "🌅 Fasted"),
        ("post_caffeine", "☕ Caffeine"),
        ("post_ride",     "🏍️ Ride"),
        ("post_workout",  "🏋️ Workout"),
        ("stressed",      "😤 Stressed"),
        ("post_alcohol",  "🥃 Alcohol"),
        ("relaxed",       "🧘 Evening"),
        ("other",         "• Other"),
    ]

    private var canSave: Bool { (Int(sys) ?? 0) > 0 && (Int(dia) ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(DS.Colors.borderStrong)
                .frame(width: 42, height: 5)
                .padding(.top, DS.Spacing.sm).padding(.bottom, DS.Spacing.md)

            Text("Blood pressure")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("A reading is only useful with its context")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.textMuted)
                .padding(.bottom, DS.Spacing.lg)

            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.lg) {
                    HStack(alignment: .bottom, spacing: DS.Spacing.md) {
                        numField("Systolic", "120", $sys, .sys)
                        Text("/").font(.system(size: 28, weight: .light))
                            .foregroundStyle(DS.Colors.textFaint).padding(.bottom, 8)
                        numField("Diastolic", "80", $dia, .dia)
                    }
                    HStack(spacing: DS.Spacing.md) {
                        numField("Pulse", "66", $pulse, .pulse)
                        numField("Weight kg", "75.2", $weight, .weight)
                    }

                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("CONTEXT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.Colors.textFaint).tracking(1.0)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(contexts, id: \.0) { (key, label) in
                                contextChip(key: key, label: label)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
            }

            Button { save() } label: {
                Text(saved ? "Saved ✓" : (saving ? "Saving…" : "Log reading"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(canSave ? (saved ? DS.Colors.success : DS.Colors.violet) : DS.Colors.borderStrong))
            }
            .buttonStyle(.plain)
            .disabled(!canSave || saving)
            .padding(DS.Spacing.md)
        }
        .background(AuroraBackground().ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .onAppear { focus = .sys }
    }

    private func numField(_ label: String, _ placeholder: String, _ text: Binding<String>, _ field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.Colors.textFaint).tracking(0.8)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .focused($focus, equals: field)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(DS.Colors.surface))
        }
        .frame(maxWidth: .infinity)
    }

    private func contextChip(key: String, label: String) -> some View {
        let active = context == key
        return Button {
            let h = UIImpactFeedbackGenerator(style: .light); h.impactOccurred()
            context = key
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? .white : DS.Colors.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(active ? DS.Colors.violet : DS.Colors.surface))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard canSave else { return }
        saving = true
        let w = Double(weight.replacingOccurrences(of: ",", with: "."))
        let p = Int(pulse)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            await SupabaseClient.shared.saveBPReading(
                systolic: Int(sys) ?? 0,
                diastolic: Int(dia) ?? 0,
                pulse: p,
                weightKg: w,
                context: context
            )
            if let w, w > 0 { storedWeight = w }
            await MainActor.run {
                saving = false
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
            }
        }
    }
}
