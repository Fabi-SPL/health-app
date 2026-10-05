import SwiftUI
import PhotosUI

// MARK: - FoodView
// Principle #11: format diversity — METRICS (bento) → CHIPS (filter) → CARDS (meal list)
// Principle #5: category dot food=amber on each meal entry
// Principle #4: pill radius 100 on all filter chips

struct FoodView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @State private var entries: [FoodEntry] = []
    @State private var favorites: [FoodFavorite] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCamera = false
    @State private var showBarcode = false
    @State private var showManual = false
    @State private var showFABMenu = false
    @State private var showBuilder = false
    @State private var appeared = false
    @State private var saveSuccessCount = 0
    @State private var saveErrorCount = 0
    @State private var deleteSuccessCount = 0
    @State private var pendingDelete: FoodEntry?
    @State private var editing: FoodEntry?
    @State private var detailEntry: FoodEntry?
    @State private var quickEdit: QuickLogSource?
    @State private var shelf: [SupabaseClient.SupplementShelfItem] = []
    @State private var cut: SupabaseClient.CutStatus?
    @State private var pots: [SupabaseClient.FoodPot] = []
    @State private var ingredients: [SupabaseClient.FoodIngredient] = []
    @State private var showPotBuilder = false

    private var todayEntries: [FoodEntry] { entries.filter(isToday) }
    private var todayKcal: Int { entries.filter(isToday).compactMap(\.totalKcal).reduce(0, +) }
    private var todayMindAvg: Double {
        let t = entries.filter(isToday).compactMap(\.mindScore)
        guard !t.isEmpty else { return 0 }
        return Double(t.reduce(0, +)) / Double(t.count)
    }

    private var todayNovaAvg: Double {
        let vals = entries.filter(isToday).compactMap(\.novaAvg)
        guard !vals.isEmpty else { return 0 }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private var todayProtein: Double { entries.filter(isToday).flatMap(\.items).compactMap(\.proteinG).reduce(0, +) }
    private var todayCarbs: Double { entries.filter(isToday).flatMap(\.items).compactMap(\.carbsG).reduce(0, +) }
    private var todayFat: Double { entries.filter(isToday).flatMap(\.items).compactMap(\.fatG).reduce(0, +) }

    private var todayMindTags: [String] {
        let positive: Set<String> = ["leafy_green", "fish", "berries", "olive_oil", "nuts", "legumes", "whole_grain"]
        var seen: [String] = []
        for e in entries.filter(isToday) {
            for it in e.items {
                for t in it.mindTags where positive.contains(t) && !seen.contains(t) { seen.append(t) }
            }
        }
        return seen
    }

    private var caffeineHits: [CaffeineHit] {
        entries.filter(isToday).compactMap { e in
            let cap = (e.caption ?? "").lowercased()
            let tagged = e.items.contains { $0.mindTags.contains("caffeine") }
            guard tagged || cap.contains("caffeine") else { return nil }
            return CaffeineHit(date: e.capturedAt, mg: FoodView.parseCaffeineMg(cap) ?? 80)
        }
    }

    private static func parseCaffeineMg(_ s: String) -> Double? {
        guard let r = s.range(of: #"\d+(?=\s*mg)"#, options: .regularExpression) else { return nil }
        return Double(String(s[r]))
    }

    private var hoursSinceLastMeal: Int? {
        guard let last = entries.first(where: { Calendar.current.isDateInToday($0.capturedAt) }) else { return nil }
        let hours = Int(Date().timeIntervalSince(last.capturedAt) / 3600)
        return hours
    }

    private func isToday(_ e: FoodEntry) -> Bool {
        Calendar.current.isDateInToday(e.capturedAt)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                BoardFoodTop(
                    offline: error != nil,
                    onRetry: { Task { await loadEntries() } },
                    onDescribe: { showManual = true },
                    onPhoto: { showCamera = true },
                    onBarcode: { showBarcode = true },
                    onBuild: { showBuilder = true }
                )
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                todaySection

                Section {
                    if let cut {
                        CutStatusCard(cut: cut)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.top, DS.Spacing.sm)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    PotSection(
                        pots: pots,
                        onServe: { pot, f in Task { await serve(pot, f) } },
                        onCook: { showPotBuilder = true }
                    )
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.md)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    FavoritesBar(
                        favorites: favorites,
                        onLog: { item in quickEdit = .preset(item) },
                        onLogFavorite: { fav in quickEdit = .favorite(fav) }
                    )
                    .padding(.top, DS.Spacing.sm)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    FoodIntakeHero(
                        kcal: todayKcal,
                        protein: todayProtein,
                        carbs: todayCarbs,
                        fat: todayFat,
                        mealCount: todayEntries.count,
                        fastingHours: hoursSinceLastMeal
                    )
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.md)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if !todayEntries.isEmpty {
                        FoodQualityCard(entries: todayEntries, score: todayMindAvg, tags: todayMindTags)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.top, DS.Spacing.md)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    if !caffeineHits.isEmpty {
                        CaffeineCurveCard(hits: caffeineHits)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.top, DS.Spacing.md)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    if !shelf.isEmpty {
                        SupplementShelfCard(items: shelf, onLog: { item in
                            Task { await logSupplement(item) }
                        })
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.top, DS.Spacing.md)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                entriesContent

                Color.clear
                    .frame(height: 100)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)

        }
        .background(DS.Colors.ground)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await loadEntries() }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { entry in
                entries.insert(entry, at: 0)
            }
        }
        .fullScreenCover(isPresented: $showBarcode) {
            BarcodeScannerView { entry in
                entries.insert(entry, at: 0)
            }
        }
        .fullScreenCover(isPresented: $showManual) {
            ManualFoodEntrySheet { entry in
                entries.insert(entry, at: 0)
            }
        }
        .fullScreenCover(isPresented: $showBuilder) {
            MealBuilderSheet { entry in
                entries.insert(entry, at: 0)
            }
        }
        .fullScreenCover(isPresented: $showPotBuilder) {
            PotBuilderSheet(ingredients: ingredients) {
                Task { await loadPots() }
            }
        }
        .task {
            await loadEntries()
            await loadFavorites()
            await loadShelf()
            await loadCut()
            await loadPots()
            withAnimation { appeared = true }
        }
        .sensoryFeedback(.success, trigger: saveSuccessCount)
        .sensoryFeedback(.error, trigger: saveErrorCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: deleteSuccessCount)
        .sheet(item: $editing) { entry in
            EditFoodEntrySheet(
                entry: entry,
                onSaved: { updated in
                    if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
                        entries[idx] = updated
                    }
                    editing = nil
                    deleteSuccessCount += 1  // re-use trigger for haptic on save success
                },
                onCancel: { editing = nil }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $detailEntry) { entry in
            FoodDetailView(entry: entry) { updated in
                if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
                    entries[idx] = updated
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $quickEdit) { source in
            QuickLogEditorSheet(
                source: source,
                onLogged: { saved in
                    entries.insert(saved, at: 0)
                    saveSuccessCount += 1
                    quickEdit = nil
                },
                onCancel: { quickEdit = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                Task { await delete(entry) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { entry in
            Text(entry.caption ?? entry.items.map(\.name).joined(separator: ", "))
        }
        .overlay(alignment: .top) {
            if let e = error, e != "Load failed" {
                AlertBanner(icon: "exclamationmark.triangle", message: e, color: DS.Colors.pink)
                    .padding(.horizontal, DS.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private var entriesContent: some View {
        if isLoading {
            LoadingState(label: "Loading meals…")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if entries.isEmpty {
            EmptyGlassState(
                icon: "fork.knife",
                title: "Nothing logged yet",
                detail: "Tap + to start."
            )
            .padding(DS.Spacing.md)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            let grouped = Dictionary(grouping: entries.filter { !isToday($0) }) { entry in
                Calendar.current.startOfDay(for: entry.capturedAt)
            }
            let sortedDays = grouped.keys.sorted(by: >)

            ForEach(sortedDays, id: \.self) { day in
                Section {
                    ForEach(grouped[day]!.sorted { $0.capturedAt > $1.capturedAt }) { entry in
                        EnhancedMealCard(entry: entry)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, 4)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .contentShape(Rectangle())
                            .onTapGesture { detailEntry = entry }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = entry
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editing = entry
                                } label: {
                                    Label("Edit", systemImage: "square.and.pencil")
                                }
                                .tint(DS.Colors.violet)
                            }
                            .contextMenu {
                                Button {
                                    Task { await saveAsFavorite(entry) }
                                } label: {
                                    Label("Save as favorite", systemImage: "star")
                                }
                                Button {
                                    editing = entry
                                } label: {
                                    Label("Edit", systemImage: "square.and.pencil")
                                }
                                Button(role: .destructive) {
                                    pendingDelete = entry
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } preview: {
                                MealPeekPreview(entry: entry)
                            }
                    }
                } header: {
                    SectionHeader(title: dayLabel(day))
                        .padding(.horizontal, DS.Spacing.md)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    @ViewBuilder
    private var todaySection: some View {
        let today = todayEntries.sorted { $0.capturedAt < $1.capturedAt }
        BoardSectionTitle(title: "Today", trailing: today.isEmpty ? nil : "\(today.count) \(today.count == 1 ? "meal" : "meals") · \(todayKcal) kcal")
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        if today.isEmpty {
            Text(isLoading ? "Loading…" : (error != nil ? "Today's meals load when the server answers." : "Nothing logged yet today."))
                .font(.system(size: 15))
                .foregroundStyle(DS.Colors.secondaryLabel)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        ForEach(today) { entry in
            BoardMealRow(entry: entry)
                .padding(.horizontal, 20)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(DS.Colors.separator)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 20 }
                .contentShape(Rectangle())
                .onTapGesture { detailEntry = entry }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = entry
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editing = entry
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .tint(DS.Colors.accent)
                }
        }
    }

    private var headerSpacer: some View { Color.clear.frame(height: DS.Spacing.sm) }
    private var bottomSpacer: some View { Color.clear.frame(height: 100) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d. MMMM"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date)     { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return Self.dayFormatter.string(from: date)
    }

    private func loadEntries() async {
        isLoading = true
        error = nil
        do {
            entries = try await SupabaseClient.shared.fetchRecentFoodEntries(limit: 60)
        } catch {
            self.error = "Load failed"
        }
        isLoading = false
    }

    private func loadFavorites() async {
        if let favs = try? await SupabaseClient.shared.fetchFavorites() {
            favorites = favs
        }
    }

    private func loadShelf() async {
        if let s = try? await SupabaseClient.shared.supplementShelf() {
            shelf = s
        }
    }

    private func loadCut() async {
        if let c = try? await SupabaseClient.shared.cutStatus() {
            cut = c
        }
    }

    private func loadPots() async {
        if let p = try? await SupabaseClient.shared.openPots() { pots = p }
        if ingredients.isEmpty,
           let i = try? await SupabaseClient.shared.fetchIngredients() { ingredients = i }
    }

    /// Eat a fraction of an open pot. The server writes a normal food_entries
    /// row and decrements what is left, so every other surface just works.
    private func serve(_ pot: SupabaseClient.FoodPot, _ fraction: Double) async {
        do {
            try await SupabaseClient.shared.servePot(id: pot.id, fraction: fraction)
            DS.Haptic.success()
            saveSuccessCount += 1
            await loadPots()
            await loadEntries()
            await loadCut()
        } catch {
            self.error = "Couldn't log that portion"
            saveErrorCount += 1
        }
    }

    private func logSupplement(_ item: SupabaseClient.SupplementShelfItem) async {
        do {
            try await SupabaseClient.shared.logSupplement(productId: item.id)
            await loadShelf()
            saveSuccessCount += 1
        } catch {
            saveErrorCount += 1
        }
    }

    private func saveAsFavorite(_ entry: FoodEntry) async {
        let trimmed = entry.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? entry.items.map(\.name).joined(separator: ", ") : trimmed
        guard !name.isEmpty else { return }
        do {
            try await SupabaseClient.shared.saveFavorite(from: entry, name: name)
            await loadFavorites()
            saveSuccessCount += 1
        } catch {
            self.error = "Couldn't save favorite"
            saveErrorCount += 1
        }
    }

    private func delete(_ entry: FoodEntry) async {
        guard let id = entry.id?.uuidString else { return }
        let ok = await SupabaseClient.shared.deleteFoodEntry(id: id)
        if ok {
            await MainActor.run {
                entries.removeAll { $0.id == entry.id }
                deleteSuccessCount += 1
                pendingDelete = nil
            }
        } else {
            await MainActor.run {
                self.error = "Delete failed"
                pendingDelete = nil
            }
        }
    }

}

// MARK: - Pot (v159) — weigh once at the stove, then eat fractions
//
// Batch cooking isn't a logging problem, it's the most accurate method he has:
// once it's stirred you can't weigh the components back out, but you don't need
// to — the ratio is uniform, and a fraction of a weighed total beats a gram
// guess every time. One weighing covers 2-4 meals.

private struct PotSection: View {
    let pots: [SupabaseClient.FoodPot]
    let onServe: (SupabaseClient.FoodPot, Double) -> Void
    let onCook: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("IN THE POT")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Colors.textMuted)
                    .tracking(0.8)
                Spacer()
                Button {
                    DS.Haptic.tap()
                    onCook()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold))
                        Text("Cook").font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(DS.Colors.violet)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.violet.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }

            if pots.isEmpty {
                Text("Weigh the pan once. Then every serving is a fraction, not a guess.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(DS.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pots.enumerated()), id: \.element.id) { idx, pot in
                        if idx > 0 { Divider().opacity(0.25) }
                        PotRow(pot: pot, onServe: { f in onServe(pot, f) })
                    }
                }
            }
        }
        .glassCard()
    }
}

private struct PotRow: View {
    let pot: SupabaseClient.FoodPot
    let onServe: (Double) -> Void

    /// Fractions are of the WHOLE pot, not of what's left — that's how the
    /// server stores them, and it's how you actually think at the stove.
    private static let fractions: [(String, Double)] = [("¼", 0.25), ("⅓", 1.0 / 3.0), ("½", 0.5)]

    private var cookedNote: String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: pot.cookedAt),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case 0:  return "cooked today"
        case 1:  return "cooked yesterday"
        default: return "cooked \(days)d ago"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Text(pot.emoji ?? "🍲").font(.system(size: 20))

                VStack(alignment: .leading, spacing: 2) {
                    Text(pot.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text("\(Int(pot.leftKcal.rounded())) kcal · \(Int(pot.leftProtein.rounded())) g P left · \(cookedNote)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DS.Colors.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(pot.remainingPct)%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.Colors.teal)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.textFaint.opacity(0.15))
                    Capsule().fill(DS.Colors.teal)
                        .frame(width: max(2, geo.size.width * min(1, max(0, pot.remaining))))
                }
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                ForEach(Array(Self.fractions.enumerated()), id: \.offset) { _, item in
                    servePill(item.0,
                              kcal: Int((pot.totalKcal * item.1).rounded()),
                              enabled: item.1 <= pot.remaining + 0.01) { onServe(item.1) }
                }
                servePill("Rest",
                          kcal: Int(pot.leftKcal.rounded()),
                          enabled: pot.remaining > 0.01) { onServe(pot.remaining) }
            }
        }
        .padding(.vertical, DS.Spacing.sm)
    }

    private func servePill(_ label: String, kcal: Int, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            DS.Haptic.commit()
            action()
        } label: {
            VStack(spacing: 1) {
                Text(label).font(.system(size: 13, weight: .bold, design: .rounded))
                Text("\(kcal)").font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(enabled ? DS.Colors.textPrimary : DS.Colors.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.Colors.surfaceElevated)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// One weighed ingredient in a pot being built.
private struct PotDraftItem: Identifiable {
    let id = UUID()
    let key: String
    let name: String
    let kcal100: Double
    let protein100: Double
    let basis: String?
    var grams: Double

    var kcal: Double { grams / 100 * kcal100 }
    var protein: Double { grams / 100 * protein100 }
}

private struct PotBuilderSheet: View {
    let ingredients: [SupabaseClient.FoodIngredient]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = "🍲"
    @State private var items: [PotDraftItem] = []
    @State private var search = ""
    @State private var isSaving = false
    @State private var error: String?

    private static let emojis = ["🍲", "🍚", "🍗", "🍝", "🥘", "🍛", "🥣", "🍜"]

    private var totalKcal: Int { Int(items.reduce(0) { $0 + $1.kcal }.rounded()) }
    private var totalProtein: Int { Int(items.reduce(0) { $0 + $1.protein }.rounded()) }

    private var filtered: [SupabaseClient.FoodIngredient] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ingredients }
        return ingredients.filter {
            $0.name.lowercased().contains(q) || ($0.nameLocal?.lowercased().contains(q) ?? false)
        }
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return items.prefix(2).map(\.name).joined(separator: " + ")
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.lg) {
                    Color.clear.frame(height: 2)
                    nameCard
                    if !items.isEmpty { draftCard }
                    pickerCard
                    if let error {
                        AlertBanner(icon: "exclamationmark.triangle", message: error, color: DS.Colors.pink)
                    }
                    saveButton
                    Color.clear.frame(height: DS.Spacing.lg)
                }
                .padding(.horizontal, DS.Spacing.md)
            }
            .background(AuroraBackground().ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TwoToneHeadline(primary: "Cook", secondary: " · a pot", font: .system(size: 17, weight: .heavy, design: .rounded))
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(icon: "text.cursor", title: "POT NAME", iconColor: DS.Colors.violet)
            TextField("e.g. Chicken + rice", text: $name)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(DS.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .foregroundStyle(DS.Colors.textPrimary)

            HStack(spacing: 6) {
                ForEach(Self.emojis, id: \.self) { e in
                    Button {
                        DS.Haptic.select()
                        emoji = e
                    } label: {
                        Text(e)
                            .font(.system(size: 18))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(emoji == e ? DS.Colors.violet.opacity(0.18) : DS.Colors.surfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(DS.Spacing.md).glassDefault()
    }

    private var draftCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(icon: "scalemass", title: "WEIGHED IN", iconColor: DS.Colors.teal,
                          trailing: "\(totalKcal) kcal · \(totalProtein) g P")

            ForEach($items) { $item in
                HStack(spacing: DS.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(Self.subline(kcal: item.kcal, basis: item.basis))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(DS.Colors.textMuted)
                    }

                    Spacer()

                    TextField("g", value: $item.grams, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .frame(width: 62)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(DS.Colors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))

                    Text("g")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DS.Colors.textMuted)

                    Button {
                        DS.Haptic.tap()
                        items.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(DS.Colors.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(DS.Spacing.md).glassDefault()
    }

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(icon: "list.bullet", title: "ADD INGREDIENT", iconColor: DS.Colors.amber)

            TextField("Search", text: $search)
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(DS.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .foregroundStyle(DS.Colors.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(filtered.prefix(search.isEmpty ? 12 : 24)) { ing in
                    Button {
                        DS.Haptic.tap()
                        add(ing)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ing.display)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(Self.per100(kcal: ing.kcal100, basis: ing.basisNote))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(DS.Colors.textMuted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .fill(DS.Colors.surfaceElevated)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if ingredients.isEmpty {
                Text("No ingredients loaded — pull to refresh the Food tab.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(DS.Colors.textMuted)
            }
        }
        .padding(DS.Spacing.md).glassDefault()
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 8) {
                if isSaving { ProgressView().tint(.white) }
                Text(isSaving ? "Saving…" : "Save pot · \(totalKcal) kcal")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(DS.Colors.violet)
            )
        }
        .buttonStyle(.plain)
        .disabled(items.isEmpty || isSaving)
        .opacity(items.isEmpty || isSaving ? 0.5 : 1)
    }

    private static func subline(kcal: Double, basis: String?) -> String {
        let base = "\(Int(kcal.rounded())) kcal"
        guard let basis else { return base }
        return base + " · weigh " + basis
    }

    private static func per100(kcal: Double, basis: String?) -> String {
        let base = "\(Int(kcal.rounded())) kcal/100"
        guard let basis else { return base }
        return base + " · " + basis
    }

    private func add(_ ing: SupabaseClient.FoodIngredient) {
        guard !items.contains(where: { $0.key == ing.id }) else { return }
        items.append(PotDraftItem(
            key: ing.id,
            name: ing.display,
            kcal100: ing.kcal100,
            protein100: ing.protein100,
            basis: ing.basisNote,
            grams: ing.defaultGrams ?? 100
        ))
    }

    private func save() async {
        guard !items.isEmpty else { return }
        isSaving = true
        error = nil
        do {
            try await SupabaseClient.shared.createPot(
                name: resolvedName,
                emoji: emoji,
                items: items.map { ($0.key, $0.grams) }
            )
            DS.Haptic.success()
            onSaved()
            dismiss()
        } catch {
            self.error = "Couldn't save the pot"
            DS.Haptic.error()
        }
        isSaving = false
    }
}

// MARK: - Favorites Bar (one-tap quick log, most-used first)

private struct FavoritesBar: View {
    @ObservedObject private var history = QuickLogHistory.shared
    let favorites: [FoodFavorite]
    let onLog: (QuickLogItem) -> Void
    let onLogFavorite: (FoodFavorite) -> Void

    /// Strip punctuation/parentheticals so "Fusilli, Kochschinken & Cheese" and
    /// "Fusilli (dry), Kochschinken, Cheddar & cheese mix" collapse to the same
    /// key. Saving the same dish twice with a slightly different name is the
    /// normal way this list rots.
    private static func dedupeKey(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9äöüß]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").sorted().joined(separator: " ")
    }

    /// Favourites, one per dish. Most-logged wins a tie so the pill that
    /// survives is the one he actually taps.
    private var uniqueFavorites: [FoodFavorite] {
        var seen = Set<String>()
        return favorites
            .sorted { ($0.timesLogged ?? 0) > ($1.timesLogged ?? 0) }
            .filter { seen.insert(Self.dedupeKey($0.name)).inserted }
    }

    /// Curated presets, re-sorted so the items you log most float to the front,
    /// minus anything already covered by a saved meal — the duplicate pills in
    /// one horizontal strip were the whole reason this bar felt scuffed.
    private var items: [QuickLogItem] {
        let counts = Dictionary(history.entries.map { ($0.name, $0.count) }, uniquingKeysWith: { a, _ in a })
        let taken = Set(uniqueFavorites.map { Self.dedupeKey($0.name) })
        return QuickLogItem.defaults
            .filter { !taken.contains(Self.dedupeKey($0.name)) }
            .sorted { (counts[$0.name.lowercased()] ?? 0) > (counts[$1.name.lowercased()] ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("QUICK LOG")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.Colors.textFaint)
                .tracking(1)
                .padding(.horizontal, DS.Spacing.md)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.sm) {
                    // User's saved meals first (violet-tinted), then curated presets.
                    ForEach(uniqueFavorites) { fav in
                        FavoritePill(favorite: fav) { onLogFavorite(fav) }
                    }
                    ForEach(items) { item in
                        QuickLogPill(item: item) { onLog(item) }
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
            }
        }
    }
}

/// Tap-to-open pill for a user FoodFavorite (emoji + name + kcal). Violet-tinted to
/// distinguish saved meals from the curated single-item quick presets. Tap opens
/// the quick editor (pick time, confirm) instead of logging instantly.
private struct FavoritePill: View {
    let favorite: FoodFavorite
    let onTap: () -> Void

    var body: some View {
        Button {
            DS.Haptic.tap()
            onTap()
        } label: {
            HStack(spacing: 6) {
                Text(favorite.emoji ?? "🍽️")
                    .font(.system(size: 14))
                Text(favorite.name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                if let k = favorite.totalKcal, k > 0 {
                    Text("\(k)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.Colors.textFaint)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                Capsule()
                    .fill(DS.Colors.violet.opacity(0.10))
                    .overlay(
                        Capsule().stroke(DS.Colors.borderViolet, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(PressableScale())
    }
}

// MARK: - Cut Status (v156 — "left today", the answer logging never had)

private struct CutStatusCard: View {
    let cut: SupabaseClient.CutStatus

    private var accent: Color { cut.isOver ? DS.Colors.warning : DS.Colors.textPrimary }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(abs(cut.remaining))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                Text(cut.isOver ? "over" : "left today")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(cut.consumed) / \(cut.targetIntake)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text("burn \(cut.tdee) · −\(cut.deficitTarget)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(DS.Colors.textFaint)
                }
            }

            bar(pct: cut.intakePct, tint: cut.isOver ? DS.Colors.warning : DS.Colors.violet)

            HStack(spacing: 6) {
                Text("PROTEIN")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Colors.textMuted)
                    .tracking(0.8)
                Text("\(Int(cut.proteinG)) / \(cut.proteinTarget) g")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(cut.proteinPct >= 1 ? DS.Colors.success : DS.Colors.textSecondary)
                Spacer()
            }

            bar(pct: cut.proteinPct, tint: cut.proteinPct >= 1 ? DS.Colors.success : DS.Colors.teal)
        }
        .glassCard()
    }

    @ViewBuilder
    private func bar(pct: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.textFaint.opacity(0.15))
                Capsule().fill(tint).frame(width: max(2, geo.size.width * pct))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Supplement Shelf (v155 — one tap logs a discrete dose, not a food entry)

private struct SupplementShelfCard: View {
    let items: [SupabaseClient.SupplementShelfItem]
    let onLog: (SupabaseClient.SupplementShelfItem) -> Void

    private var takenCount: Int { items.filter { $0.takenToday > 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("SUPPLEMENTS")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Colors.textMuted)
                    .tracking(0.8)
                Spacer()
                Text("\(takenCount)/\(items.count) today")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(takenCount == items.count ? DS.Colors.success : DS.Colors.textFaint)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider().opacity(0.25) }
                    SupplementRow(item: item, onLog: { onLog(item) })
                }
            }
        }
        .glassCard()
    }
}

private struct SupplementRow: View {
    let item: SupabaseClient.SupplementShelfItem
    let onLog: () -> Void

    private var isDone: Bool {
        guard let t = item.targetDaily, t > 0 else { return item.takenToday > 0 }
        return item.takenToday >= t
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(isDone ? DS.Colors.success : DS.Colors.textFaint)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                if !item.doseSummary.isEmpty {
                    Text(item.doseSummary)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DS.Colors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            if item.takenToday > 0 {
                Text("×\(SupabaseClient.SupplementShelfItem.trim(item.takenToday))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Colors.textFaint)
            }

            Button {
                DS.Haptic.tap()
                onLog()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.Colors.violet)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Colors.violet.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, DS.Spacing.sm)
    }
}

// MARK: - Food Intake Hero (Aurora macro donut + legend — matches v5 mockup)

private struct FoodIntakeHero: View {
    let kcal: Int
    let protein: Double
    let carbs: Double
    let fat: Double
    let mealCount: Int
    let fastingHours: Int?

    private var pCal: Double { protein * 4 }
    private var cCal: Double { carbs * 4 }
    private var fCal: Double { fat * 9 }
    private var total: Double { max(pCal + cCal + fCal, 1) }
    private var hasData: Bool { protein + carbs + fat > 0 }

    private var headerStat: String {
        var parts = ["\(mealCount) meal\(mealCount == 1 ? "" : "s")"]
        if let h = fastingHours, h >= 1 { parts.append("\(h)h since last") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Intake & macros")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                Text(headerStat)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.textFaint)
            }

            HStack(spacing: 18) {
                MacroDonut(
                    kcal: kcal,
                    pFrac: pCal / total,
                    cFrac: cCal / total,
                    fFrac: fCal / total,
                    hasData: hasData
                )
                .frame(width: 122, height: 122)

                VStack(alignment: .leading, spacing: 11) {
                    MacroLegendRow(color: DS.Colors.violet, name: "Protein", grams: protein, pct: pCal / total, hasData: hasData)
                    MacroLegendRow(color: DS.Colors.teal,   name: "Carbs",   grams: carbs,   pct: cCal / total, hasData: hasData)
                    MacroLegendRow(color: DS.Colors.amber,  name: "Fat",     grams: fat,     pct: fCal / total, hasData: hasData)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
    }
}

private struct MacroDonut: View {
    let kcal: Int
    let pFrac: Double
    let cFrac: Double
    let fFrac: Double
    let hasData: Bool

    var body: some View {
        ZStack {
            Circle().stroke(DS.Colors.track, lineWidth: 13)
            if hasData {
                arc(start: 0, len: pFrac, color: DS.Colors.violet)
                arc(start: pFrac, len: cFrac, color: DS.Colors.teal)
                arc(start: pFrac + cFrac, len: fFrac, color: DS.Colors.amber)
            }
            VStack(spacing: 1) {
                Text(kcal > 0 ? "\(kcal)" : "—")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("kcal")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DS.Colors.textMuted)
            }
        }
    }

    private func arc(start: Double, len: Double, color: Color) -> some View {
        Circle()
            .trim(from: start, to: start + max(len, 0))
            .stroke(color, style: StrokeStyle(lineWidth: 13, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

private struct MacroLegendRow: View {
    let color: Color
    let name: String
    let grams: Double
    let pct: Double
    let hasData: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer(minLength: 8)
            Text(hasData ? "\(Int(grams.rounded()))g" : "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.textPrimary)
            Text(hasData ? "\(Int((pct * 100).rounded()))%" : "")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.textMuted)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Brain Food (MIND) meter + Caffeine decay curve (v5 mockup)

struct CaffeineHit {
    let date: Date
    let mg: Double
}

/// One "Food quality" card — brain-food (MIND) meter + NOVA processing histogram.
/// Merged from the old MindMeterCard + FoodQualityRow so today's quality story
/// reads in one place instead of two stacked cards.
private struct FoodQualityCard: View {
    let entries: [FoodEntry]
    let score: Double      // 0..15
    let tags: [String]
    private var filled: Int { max(0, min(15, Int(score.rounded()))) }

    private var novaBuckets: [Int] {
        var counts = [0, 0, 0, 0]  // NOVA 1, 2, 3, 4
        for entry in entries {
            for item in entry.items {
                let idx = max(0, min(3, item.novaClass - 1))
                counts[idx] += 1
            }
        }
        return counts
    }
    private var totalItems: Int { novaBuckets.reduce(0, +) }
    private var hasAlcohol: Bool {
        entries.flatMap { $0.items }.contains { $0.mindTags.contains("alcohol") }
    }

    private func novaColor(_ nova: Int) -> Color {
        DS.Colors.novaColor(Double(nova))
    }

    private func pretty(_ t: String) -> String {
        t.replacingOccurrences(of: "_", with: " ")
         .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Food quality")
                    .font(.system(size: 10, weight: .bold)).tracking(1.4).textCase(.uppercase)
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                if hasAlcohol {
                    Text("Alcohol")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Colors.amber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.amber.opacity(0.12)))
                }
                Text("\(filled)/15")
                    .font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(DS.Colors.violet)
            }

            HStack(spacing: 4) {
                ForEach(0..<15, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i < filled
                              ? AnyShapeStyle(DS.Colors.accent)
                              : AnyShapeStyle(DS.Colors.track))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
            }

            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { t in
                            Text(pretty(t))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.Colors.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(DS.Colors.track))
                        }
                    }
                }
            }

            if totalItems > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NOVA — how processed")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Colors.textFaint)
                        .tracking(1)

                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { i in
                                let count = novaBuckets[i]
                                if count > 0 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(novaColor(i + 1))
                                        .frame(width: max(4, CGFloat(count) / CGFloat(totalItems) * geo.size.width))
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(height: 10)

                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(0..<4, id: \.self) { i in
                            if novaBuckets[i] > 0 {
                                HStack(spacing: 3) {
                                    Circle().fill(novaColor(i + 1)).frame(width: 6, height: 6)
                                    Text("N\(i+1): \(novaBuckets[i])")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(DS.Colors.textFaint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
    }
}

private struct CaffeineCurveCard: View {
    let hits: [CaffeineHit]
    private let halfLife: Double = 5 * 3600   // ~5h plasma half-life

    private func active(at t: Date) -> Double {
        hits.reduce(0) { acc, h in
            let dt = t.timeIntervalSince(h.date)
            return dt >= 0 ? acc + h.mg * pow(0.5, dt / halfLife) : acc
        }
    }

    var body: some View {
        let now = Date()
        let activeNow = active(at: now)
        let earliest = hits.map(\.date).min() ?? now.addingTimeInterval(-6 * 3600)
        let startD = min(earliest, now.addingTimeInterval(-3600)).addingTimeInterval(-1800)
        let endD = now.addingTimeInterval(4 * 3600)
        let start = startD.timeIntervalSinceReferenceDate
        let span = max(endD.timeIntervalSinceReferenceDate - start, 1)
        let maxY = max(hits.map(\.mg).reduce(0, +), activeNow, 1)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Caffeine")
                    .font(.system(size: 10, weight: .bold)).tracking(1.4).textCase(.uppercase)
                    .foregroundStyle(DS.Colors.textMuted)
                Spacer()
                Text("\(Int(activeNow.rounded())) mg active")
                    .font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(DS.Colors.amber)
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let samples: [CGPoint] = stride(from: 0.0, through: 1.0, by: 1.0 / 44.0).map { f in
                    let d = Date(timeIntervalSinceReferenceDate: start + f * span)
                    return CGPoint(x: f * w, y: h - CGFloat(active(at: d) / maxY) * h)
                }
                let nowX = CGFloat((now.timeIntervalSinceReferenceDate - start) / span) * w
                let nowY = h - CGFloat(activeNow / maxY) * h
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        samples.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(DS.Colors.amber.opacity(0.14))
                    Path { p in
                        for (i, s) in samples.enumerated() { i == 0 ? p.move(to: s) : p.addLine(to: s) }
                    }
                    .stroke(DS.Colors.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Path { p in
                        p.move(to: CGPoint(x: nowX, y: 0)); p.addLine(to: CGPoint(x: nowX, y: h))
                    }
                    .stroke(DS.Colors.textMuted, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Circle().fill(DS.Colors.amber).frame(width: 7, height: 7).position(x: nowX, y: nowY)
                }
            }
            .frame(height: 88)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Colors.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
    }
}

// MARK: - Enhanced Meal Card (CategoryDot + StatusChip for NOVA/HRV impact)

private struct EnhancedMealCard: View {
    let entry: FoodEntry

    private var timeString: String {
        entry.capturedAt.formatted(.dateTime.hour().minute())
    }

    private var mindColor: Color {
        DS.Colors.mindColor(Double(entry.mindScore ?? 0))
    }

    private var novaChipStyle: StatusChipStyle? {
        guard let nova = entry.novaAvg else { return nil }
        if nova >= 3.5 { return .danger }
        if nova >= 2.5 { return .amber }
        return .teal
    }

    private var novaChipLabel: String? {
        guard let nova = entry.novaAvg else { return nil }
        if nova >= 3.5 { return "Ultra-processed" }
        if nova >= 2.5 { return "Processed" }
        return "Minimal"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                // Principle #5: category dot — food = amber
                CategoryDot(category: .food)

                Text(entry.caption ?? entry.items.map(\.name).joined(separator: ", "))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(timeString)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(DS.Colors.textFaint)
            }

            HStack(spacing: DS.Spacing.sm) {
                // Left accent bar (mind-score color)
                RoundedRectangle(cornerRadius: 2)
                    .fill(mindColor)
                    .frame(width: 3, height: 28)

                if let kcal = entry.totalKcal, kcal > 0 {
                    Label("\(kcal) kcal", systemImage: "flame.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.amber)
                }

                if let style = novaChipStyle, let label = novaChipLabel {
                    StatusChip(text: label, style: style)
                }

                if let mind = entry.mindScore, mind >= 10 {
                    StatusChip(text: "Brain+", style: .teal, icon: "brain")
                }

                Spacer()
            }
        }
        .padding(DS.Spacing.md)
        .glassDefault()
    }
}

// MARK: - Meal Peek (long-press context-menu preview)

private struct MealPeekPreview: View {
    let entry: FoodEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(entry.caption ?? entry.items.map(\.name).joined(separator: ", "))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text(entry.capturedAt.formatted(.dateTime.weekday().hour().minute()))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(DS.Colors.textFaint)
            HStack(spacing: DS.Spacing.sm) {
                if let kcal = entry.totalKcal, kcal > 0 {
                    Label("\(kcal) kcal", systemImage: "flame.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.amber)
                }
                if let mind = entry.mindScore {
                    Text("Brain \(mind)/15")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.mindColor(Double(mind)))
                }
            }
            ForEach(entry.items.prefix(4)) { item in
                HStack(spacing: 6) {
                    Circle().fill(DS.Colors.novaColor(Double(item.novaClass))).frame(width: 6, height: 6)
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(item.kcal) kcal")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.Colors.textFaint)
                }
            }
            if entry.items.count > 4 {
                Text("+ \(entry.items.count - 4) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.textFaint)
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: 300, alignment: .leading)
        .background(DS.Colors.surfaceElevated)
    }
}

// MARK: - Food Detail View (tap a meal → full breakdown + body response)

private struct FoodDetailView: View {
    @State private var entry: FoodEntry
    let onChanged: (FoodEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var hr: [String: Any]? = nil
    @State private var hrLoading = true

    init(entry: FoodEntry, onChanged: @escaping (FoodEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onChanged = onChanged
    }

    // MARK: derived

    private var raw: [String: Any]? {
        guard let s = entry.geminiRawJson, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    private var mealTotals: [String: Any]? { raw?["meal_totals"] as? [String: Any] }
    private var brain: [String: Any]? { raw?["brain_score"] as? [String: Any] }

    private func intOf(_ a: Any?) -> Int? { (a as? NSNumber)?.intValue ?? (a as? Int) }
    private func dblOf(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue ?? (a as? Double) }
    private func strOf(_ a: Any?) -> String? { a as? String }
    private func strArr(_ a: Any?) -> [String] { (a as? [String]) ?? [] }

    private func macroSum(_ kp: (DetectedItem) -> Double?) -> Double? {
        let v = entry.items.compactMap(kp); return v.isEmpty ? nil : v.reduce(0, +)
    }

    private var kcalLow: Int? { intOf(mealTotals?["estimated_calories_low"]) }
    private var kcalHigh: Int? { intOf(mealTotals?["estimated_calories_high"]) }
    private var protein: Double? { dblOf(mealTotals?["protein_g_estimate"]) ?? macroSum { $0.proteinG } }
    private var carbs: Double? { dblOf(mealTotals?["carbs_g_estimate"]) ?? macroSum { $0.carbsG } }
    private var fat: Double? { dblOf(mealTotals?["fat_g_estimate"]) ?? macroSum { $0.fatG } }
    private var fiber: Double? { dblOf(mealTotals?["fiber_g_estimate"]) ?? macroSum { $0.fiberG } }
    private var brainScore: Int? {
        // Defensive clamp 0-15 (MIND scale is /15 app-wide) — Gemini occasionally
        // returns an unclamped total (e.g. 56).
        guard let s = entry.mindScore ?? intOf(brain?["total"]) else { return nil }
        return min(15, max(0, s))
    }
    private var confidence: String {
        let c = entry.confidence ?? strOf(mealTotals?["confidence_level"]) ?? "—"
        switch c {
        case "rough_text", "estimate": return "rough estimate"
        case "barcode": return "label data"
        case "quick_log", "quick_tag": return "quick log"
        default: return c
        }
    }

    /// Log-quality 1-10 — stored on the row; computed on the fly for older rows.
    private var logQuality: Int {
        entry.logQuality ?? FoodEntry.computeLogQuality(source: entry.source, confidence: entry.confidence, items: entry.items)
    }
    private var logQualityColor: Color {
        switch logQuality {
        case 8...10: return DS.Colors.success
        case 5...7:  return DS.Colors.amber
        default:     return DS.Colors.danger
        }
    }

    private var sourceLabel: String {
        switch entry.source {
        case "photo": return "Photo + AI"
        case "text": return "Described · AI"
        case "manual": return "Typed · AI"
        case "barcode": return "Barcode · label data"
        case "quick_tag", "quick_log": return "Quick log"
        default: return entry.source
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.lg) {
                    Color.clear.frame(height: 2)
                    headerCard
                    kcalCard
                    if protein != nil || carbs != nil || fat != nil { macroCard }
                    scoreCard
                    hrCard
                    itemsSection
                    methodNote
                    editButton
                    Color.clear.frame(height: DS.Spacing.lg)
                }
                .padding(.horizontal, DS.Spacing.md)
            }
            .background(AuroraBackground().ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TwoToneHeadline(primary: "Meal", secondary: " · detail", font: .system(size: 17, weight: .heavy, design: .rounded))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .task {
            guard let id = entry.id?.uuidString else { hrLoading = false; return }
            hr = await SupabaseClient.shared.fetchMealHrResponse(mealId: id)
            hrLoading = false
        }
        .sheet(isPresented: $showEdit) {
            EditFoodEntrySheet(entry: entry, onSaved: { updated in
                entry = updated; onChanged(updated); showEdit = false
            }, onCancel: { showEdit = false })
            .presentationDetents([.large])
        }
    }

    // MARK: cards

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.caption ?? entry.items.map(\.name).joined(separator: ", "))
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            HStack(spacing: DS.Spacing.sm) {
                Text(entry.capturedAt.formatted(.dateTime.weekday().hour().minute()))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(DS.Colors.textFaint)
                StatusChip(text: sourceLabel, style: .violet)
                StatusChip(text: confidence, style: .teal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    private var kcalCard: some View {
        VStack(spacing: 4) {
            Text("\(entry.totalKcal ?? entry.items.reduce(0) { $0 + $1.kcal })")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.amber)
                .monospacedDigit()
            Text("kcal").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textMuted)
            if let lo = kcalLow, let hi = kcalHigh, hi > lo {
                Text("likely \(lo)–\(hi) kcal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textFaint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.lg)
        .glassDefault()
    }

    private var macroCard: some View {
        // Macro color language matches the Food-tab hero legend app-wide:
        // violet = protein, teal = carbs, amber = fat.
        HStack(spacing: DS.Spacing.sm) {
            macroTile("Protein", protein, "g", DS.Colors.violet)
            macroTile("Carbs", carbs, "g", DS.Colors.teal)
            macroTile("Fat", fat, "g", DS.Colors.amber)
            macroTile("Fiber", fiber, "g", DS.Colors.pink)
        }
    }

    private func macroTile(_ label: String, _ v: Double?, _ unit: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(v != nil ? String(format: "%.0f", v!) : "—")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(DS.Colors.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.md)
        .glassDefault()
    }

    private var scoreCard: some View {
        HStack(spacing: DS.Spacing.md) {
            VStack(spacing: 2) {
                Text(brainScore.map { "\($0)" } ?? "—")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Colors.mindColor(Double(brainScore ?? 0)))
                    .monospacedDigit()
                Text("BRAIN /15").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.textFaint).tracking(0.8)
            }
            .frame(maxWidth: .infinity)
            Divider().frame(height: 30)
            VStack(spacing: 2) {
                Text(entry.novaAvg.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Colors.novaColor(entry.novaAvg ?? 1))
                    .monospacedDigit()
                Text("NOVA Ø").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.textFaint).tracking(0.8)
            }
            .frame(maxWidth: .infinity)
            Divider().frame(height: 30)
            VStack(spacing: 2) {
                Text("\(logQuality)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(logQualityColor)
                    .monospacedDigit()
                Text("LOG Q").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.textFaint).tracking(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    @ViewBuilder
    private var hrCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(icon: "heart.fill", title: "YOUR BODY'S RESPONSE", iconColor: DS.Colors.pink)
            if hrLoading {
                HStack(spacing: 8) { ProgressView().tint(DS.Colors.pink); Text("Reading your heart-rate response…").font(.system(size: 12)).foregroundStyle(DS.Colors.textMuted) }
            } else if let hr, let note = strOf(hr["note"]) {
                Text(note).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.textPrimary).fixedSize(horizontal: false, vertical: true)
                if let bump = dblOf(hr["adj_bump_bpm"]) {
                    HStack(spacing: DS.Spacing.sm) {
                        StatusChip(text: String(format: "%+.1f bpm", bump), style: bump >= 8 ? .amber : .teal)
                        if let v = strOf(hr["verdict"]) {
                            StatusChip(text: v == "clean" ? "clean read" : v.replacingOccurrences(of: "_", with: " "), style: v == "clean" ? .teal : .violet)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textFaint)
                    Text("No HR read yet — wear the strap after eating")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    @ViewBuilder
    private var itemsSection: some View {
        if !entry.items.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                SectionHeader(icon: "list.bullet", title: "ITEMS", iconColor: DS.Colors.teal)
                ForEach(entry.items) { item in DetailItemRow(item: item) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var methodNote: some View {
        // De-prosed: source icon + provenance chip + a 10-segment log-quality
        // meter replace the old estimation paragraph.
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("HOW THIS WAS ESTIMATED").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.textFaint).tracking(0.8)
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.violet)
                Text(sourceLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                StatusChip(text: confidence, style: .teal)
                Spacer()
            }
            HStack(spacing: DS.Spacing.sm) {
                HStack(spacing: 3) {
                    ForEach(0..<10, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(i < logQuality ? logQualityColor : DS.Colors.track)
                            .frame(maxWidth: .infinity)
                            .frame(height: 8)
                    }
                }
                Text("Q\(logQuality)/10")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(logQualityColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    private var sourceIcon: String {
        switch entry.source {
        case "photo": return "camera.fill"
        case "barcode": return "barcode.viewfinder"
        case "combined": return "square.stack.3d.up.fill"
        case "text", "manual": return "text.bubble.fill"
        default: return "bolt.fill"
        }
    }

    private var editButton: some View {
        Button { showEdit = true } label: {
            Label("Edit this meal", systemImage: "square.and.pencil")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.violet)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.md)
                .background(Capsule().fill(DS.Colors.violet.opacity(0.12)).overlay(Capsule().stroke(DS.Colors.violet.opacity(0.3), lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }
}

/// One detected item in the meal detail. The NOVA chip is a disclosure — tap it
/// to reveal the AI's classification reasoning instead of always printing prose.
private struct DetailItemRow: View {
    let item: DetectedItem
    @State private var showReasoning = false

    private var hasReasoning: Bool { !(item.novaReasoning ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(DS.Colors.textPrimary)
                Spacer()
                if item.grams > 0 {
                    Text("\(item.grams) g").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(DS.Colors.textFaint)
                }
                Text("\(item.kcal) kcal").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.amber)
            }
            HStack(spacing: DS.Spacing.sm) {
                Button {
                    guard hasReasoning else { return }
                    DS.Haptic.tap()
                    withAnimation(DS.Anim.quick) { showReasoning.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        StatusChip(text: "NOVA \(item.novaClass)", style: item.novaClass >= 4 ? .danger : (item.novaClass >= 3 ? .amber : .teal))
                        if hasReasoning {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(DS.Colors.textFaint)
                                .rotationEffect(.degrees(showReasoning ? 180 : 0))
                        }
                    }
                }
                .buttonStyle(.plain)
                if let q = item.quantityDescription, !q.isEmpty {
                    Text(q).font(.system(size: 10)).foregroundStyle(DS.Colors.textMuted).lineLimit(1)
                }
                Spacer()
                if let qc = item.quantityConfidence { Text(qc).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Colors.textFaint) }
            }
            if showReasoning, let nr = item.novaReasoning, !nr.isEmpty {
                Text(nr).font(.system(size: 10)).foregroundStyle(DS.Colors.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            if !item.mindTags.isEmpty {
                Text(item.mindTags.joined(separator: " · ")).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Colors.teal)
            }
        }
        .padding(DS.Spacing.md)
        .glassDefault()
    }
}

// MARK: - Meal Builder (combine barcode + described + photo into one entry)

private struct MealBuilderSheet: View {
    let onSaved: (FoodEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var eatenAt = Date()
    @State private var items: [DetectedItem] = []
    @State private var describeText = ""
    @State private var isAnalyzing = false
    @State private var analyzingLabel = ""
    @State private var showBarcode = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var error: String?

    private var totalKcal: Int { items.reduce(0) { $0 + $1.kcal } }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.lg) {
                    Color.clear.frame(height: 2)
                    nameCard
                    addRow
                    describeCard
                    if isAnalyzing { analyzingBanner }
                    if !items.isEmpty { draftCard; timeCard }
                    if let error {
                        AlertBanner(icon: "exclamationmark.triangle", message: error, color: DS.Colors.pink)
                    }
                    saveButton
                    Color.clear.frame(height: DS.Spacing.lg)
                }
                .padding(.horizontal, DS.Spacing.md)
            }
            .background(AuroraBackground().ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TwoToneHeadline(primary: "Build", secondary: " · meal", font: .system(size: 17, weight: .heavy, design: .rounded))
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .fullScreenCover(isPresented: $showBarcode) {
            BarcodeItemScannerSheet { item in items.append(item) }
        }
        .onChange(of: photoItem) { _, newVal in
            guard let newVal else { return }
            Task { await analyzePhoto(newVal) }
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(icon: "text.cursor", title: "MEAL NAME", iconColor: DS.Colors.violet)
            TextField("e.g. Toast with cheddar + ham", text: $caption)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(DS.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(DS.Spacing.md).glassDefault()
    }

    private var addRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                addButton(icon: "camera.fill", label: "Photo", color: DS.Colors.violet)
            }
            Button { showBarcode = true } label: {
                addButton(icon: "barcode.viewfinder", label: "Barcode", color: DS.Colors.teal)
            }
            .buttonStyle(.plain)
        }
    }

    private func addButton(icon: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.md).glassDefault()
    }

    private var describeCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(icon: "text.bubble", title: "DESCRIBE & ADD", iconColor: DS.Colors.amber)
            HStack(spacing: DS.Spacing.sm) {
                TextField("e.g. 2 slices toast, baked", text: $describeText, axis: .vertical)
                    .font(.system(size: 14)).lineLimit(1...3)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(DS.Colors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .foregroundStyle(DS.Colors.textPrimary)
                Button { Task { await analyzeText() } } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 30))
                        .foregroundStyle(describeText.isEmpty ? DS.Colors.textMuted : DS.Colors.amber)
                }
                .buttonStyle(.plain).disabled(describeText.trimmingCharacters(in: .whitespaces).isEmpty || isAnalyzing)
            }
        }
        .padding(DS.Spacing.md).glassDefault()
    }

    private var analyzingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().tint(DS.Colors.violet)
            Text(analyzingLabel.isEmpty ? "Analyzing…" : analyzingLabel)
                .font(.system(size: 12)).foregroundStyle(DS.Colors.textMuted)
        }
        .frame(maxWidth: .infinity).padding(DS.Spacing.md).glassDefault()
    }

    private var draftCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                SectionHeader(icon: "list.bullet", title: "THIS MEAL", iconColor: DS.Colors.teal)
                Spacer()
                Text("\(totalKcal) kcal").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(DS.Colors.amber)
            }
            ForEach(items) { item in
                HStack(spacing: DS.Spacing.sm) {
                    Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.textPrimary).lineLimit(1)
                    Spacer()
                    if item.grams > 0 { Text("\(item.grams)g").font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.Colors.textFaint) }
                    Text("\(item.kcal)").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.amber)
                    Button { items.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 16)).foregroundStyle(DS.Colors.danger.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(DS.Colors.surface))
            }
        }
        .padding(DS.Spacing.md).glassDefault()
    }

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(icon: "clock", title: "WHEN DID YOU EAT IT?", iconColor: DS.Colors.violet)
            DatePicker("", selection: $eatenAt, in: ...Date(),
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(DS.Colors.violet)
            HStack(spacing: DS.Spacing.xs) {
                builderTimeChip("Now") { eatenAt = Date() }
                builderTimeChip("1h ago") { eatenAt = Date().addingTimeInterval(-3600) }
                builderTimeChip("2h ago") { eatenAt = Date().addingTimeInterval(-7200) }
            }
        }
        .padding(DS.Spacing.md).glassDefault()
    }

    private func builderTimeChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: { DS.Haptic.tap(); action() }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.violet)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(DS.Colors.violet.opacity(0.12))
                    .overlay(Capsule().stroke(DS.Colors.violet.opacity(0.25), lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button { Task { await save() } } label: {
            HStack {
                if isSaving { ProgressView().tint(.white) }
                else {
                    Image(systemName: "checkmark")
                    Text(items.isEmpty ? "Add something first" : "Save meal · \(items.count) item\(items.count == 1 ? "" : "s")")
                }
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.md)
            .background(Capsule().fill(items.isEmpty ? DS.Colors.textMuted : DS.Colors.violet))
        }
        .buttonStyle(.plain).disabled(items.isEmpty || isSaving)
    }

    // MARK: actions

    private func analyzeText() async {
        let t = describeText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        isAnalyzing = true; analyzingLabel = "Reading “\(t.prefix(24))”…"; error = nil
        if let r = try? await GeminiClient.shared.analyzeFood(description: t) {
            items.append(contentsOf: r.items)
            describeText = ""
        } else {
            error = "Couldn't analyze that — try simpler wording."
            SupabaseClient.shared.logClientError(area: "builder.analyze_text_failed",
                                                 message: "Gemini text analysis returned nil in meal builder",
                                                 context: String(t.prefix(200)))
        }
        isAnalyzing = false; analyzingLabel = ""
    }

    private func analyzePhoto(_ pick: PhotosPickerItem) async {
        isAnalyzing = true; analyzingLabel = "Analyzing photo…"; error = nil
        if let data = try? await pick.loadTransferable(type: Data.self), let img = UIImage(data: data) {
            if let r = try? await GeminiClient.shared.analyzeFood(image: img, caption: caption.isEmpty ? nil : caption) {
                items.append(contentsOf: r.items)
            } else {
                error = "Photo analysis failed — add it another way."
                SupabaseClient.shared.logClientError(area: "builder.analyze_photo_failed",
                                                     message: "Gemini photo analysis returned nil in meal builder",
                                                     context: caption.isEmpty ? nil : String(caption.prefix(200)))
            }
        } else {
            error = "Couldn't read that photo — try another."
            SupabaseClient.shared.logClientError(area: "builder.photo_load_failed",
                                                 message: "PhotosPicker loadTransferable failed or UIImage init failed",
                                                 context: nil)
        }
        photoItem = nil
        isAnalyzing = false; analyzingLabel = ""
    }

    private func save() async {
        guard !items.isEmpty else { return }
        isSaving = true; error = nil
        do {
            let saved = try await SupabaseClient.shared.saveCombinedMeal(items: items, caption: caption, capturedAt: eatenAt)
            onSaved(saved)
            dismiss()
        } catch {
            self.error = "Save failed — check connection."
            SupabaseClient.shared.logClientError(area: "builder.save_failed",
                                                 message: error.localizedDescription,
                                                 context: caption.isEmpty ? nil : String(caption.prefix(200)))
            isSaving = false
        }
    }
}

// MARK: - Barcode scanner in item-return mode (for the meal builder)

private struct BarcodeItemScannerSheet: View {
    let onItem: (DetectedItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            BarcodeScannerView(onItem: { item in onItem(item) }, onEntry: { _ in })
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
            .buttonStyle(.plain)
            VStack {
                Spacer()
                Text("Scan a barcode to add it to the meal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8).background(.black.opacity(0.4)).clipShape(Capsule())
                    .padding(.bottom, DS.Spacing.xl)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Quick Log Editor (tap a quick-log pill → tweak → save)

/// What the quick editor was opened for — a curated preset or a saved favorite.
enum QuickLogSource: Identifiable {
    case preset(QuickLogItem)
    case favorite(FoodFavorite)

    var id: String {
        switch self {
        case .preset(let i):   return "p-\(i.id)"
        case .favorite(let f): return "f-\(f.id?.uuidString ?? f.name)"
        }
    }
}

/// Lightweight pre-filled meal builder. Opens on a quick-log tap so an accidental
/// Subjective, body-relative portion size. "Normal" = your usual amount of THIS
/// food — the server learns what that means in grams from your own history per
/// food + body weight. The factor scales quick-log calorie baselines and hands
/// Hermes a dose dimension so it can separate "what" you ate from "how much".
enum PortionSize: String, CaseIterable, Identifiable {
    case tiny, small, normal, big, huge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiny: return "Tiny"
        case .small: return "Small"
        case .normal: return "Normal"
        case .big: return "Big"
        case .huge: return "Huge"
        }
    }
    /// Multiplier vs your baseline serving (matches v138 column comment).
    var factor: Double {
        switch self {
        case .tiny: return 0.5
        case .small: return 0.75
        case .normal: return 1.0
        case .big: return 1.5
        case .huge: return 2.0
        }
    }
}

/// 5-pill relative-portion selector. Reused by the quick-log editor and the
/// typed-meal sheet (file-scope `internal`, so no new file / no pbxproj edit).
struct PortionSizePicker: View {
    @Binding var selection: PortionSize

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PortionSize.allCases) { size in
                let isOn = size == selection
                Button {
                    DS.Haptic.tap()
                    withAnimation(.easeOut(duration: 0.16)) { selection = size }
                } label: {
                    Text(size.label)
                        .font(.system(size: 12, weight: isOn ? .bold : .medium, design: .rounded))
                        .foregroundStyle(isOn ? .white : DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isOn ? DS.Colors.violet : DS.Colors.surface)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isOn ? Color.clear : DS.Colors.border, lineWidth: 0.5))
                        )
                        .scaleEffect(isOn ? 1.0 : 0.97)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// touch never writes a junk entry — you confirm (and can tweak amount/kcal/time)
/// before it saves. Espresso defaults to Fabi's measured 80ml cup.
private struct QuickLogEditorSheet: View {
    let source: QuickLogSource
    let onLogged: (FoodEntry) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var amountText: String
    @State private var kcal: Int
    @State private var caffeine: Int
    @State private var showCaffeine: Bool
    @State private var eatenAt: Date = Date()
    @State private var isSaving = false
    @State private var error: String?
    @State private var portion: PortionSize = .normal
    @State private var favScale: Double = 1.0

    @Environment(\.dismiss) private var dismiss

    init(source: QuickLogSource, onLogged: @escaping (FoodEntry) -> Void, onCancel: @escaping () -> Void) {
        self.source = source
        self.onLogged = onLogged
        self.onCancel = onCancel
        switch source {
        case .preset(let item):
            let d = Self.intakeDefaults(for: item)
            _name = State(initialValue: item.name)
            _amountText = State(initialValue: d.amount)
            _kcal = State(initialValue: item.kcal)
            _caffeine = State(initialValue: d.caffeine ?? 0)
            _showCaffeine = State(initialValue: d.caffeine != nil)
        case .favorite(let fav):
            _name = State(initialValue: fav.name)
            _amountText = State(initialValue: fav.servingNote ?? "1 serving")
            _kcal = State(initialValue: fav.totalKcal ?? 0)
            _caffeine = State(initialValue: 0)
            _showCaffeine = State(initialValue: false)
        }
    }

    /// Sensible volume + caffeine per known intake item (brand-independent —
    /// espresso caffeine tracks shots/volume, not the bean brand).
    private static func intakeDefaults(for item: QuickLogItem) -> (amount: String, caffeine: Int?) {
        switch item.id {
        case "double_espresso": return ("80 ml", 150)   // Fabi's measured cup
        case "espresso":        return ("40 ml", 75)
        case "cappuccino":      return ("150 ml", 75)
        case "coffee":          return ("250 ml", 95)
        case "water":           return ("250 ml", nil)
        case "wine":            return ("0.2 l", nil)
        case "beer":            return ("0.5 l", nil)
        default:                return ("1 serving", nil)
        }
    }

    private var emoji: String {
        switch source {
        case .preset(let i):   return i.emoji
        case .favorite(let f): return f.emoji ?? "🍽️"
        }
    }

    private var presetItem: QuickLogItem? {
        if case .preset(let i) = source { return i }
        return nil
    }

    var body: some View {
        ZStack {
            AuroraBackground().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.lg) {
                    header
                    if let item = presetItem {
                        presetFields(item)
                    } else {
                        favoriteSummary
                    }
                    timeCard
                    if let error {
                        AlertBanner(icon: "exclamationmark.triangle", message: error, color: DS.Colors.danger)
                    }
                    saveButton
                    Color.clear.frame(height: DS.Spacing.lg)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.lg)
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 4) {
            Text(emoji).font(.system(size: 34))
            Text("Log it")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("Tweak if you want, then save")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func presetFields(_ item: QuickLogItem) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            fieldRow(label: "NAME") {
                TextField("Name", text: $name)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            fieldRow(label: "AMOUNT") {
                TextField("e.g. 80 ml", text: $amountText)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            fieldRow(label: "CALORIES") {
                HStack {
                    TextField("kcal", value: $kcal, format: .number)
                        .keyboardType(.numberPad)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("kcal").font(.system(size: 11)).foregroundStyle(DS.Colors.textFaint)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PORTION")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.textFaint)
                    .tracking(1)
                PortionSizePicker(selection: $portion)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showCaffeine {
                fieldRow(label: "CAFFEINE") {
                    HStack {
                        TextField("mg", value: $caffeine, format: .number)
                            .keyboardType(.numberPad)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("mg").font(.system(size: 11)).foregroundStyle(DS.Colors.textFaint)
                    }
                }
            }
        }
    }

    private var favoriteSummary: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(name)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            HStack(spacing: DS.Spacing.sm) {
                if kcal > 0 {
                    Label("\(Int((Double(kcal) * favScale).rounded())) kcal", systemImage: "flame.fill")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.amber)
                        .monospacedDigit()
                }
                if amountText != "1 serving" {
                    Text(amountText).font(.system(size: 12)).foregroundStyle(DS.Colors.textMuted)
                }
            }

            // How much of the saved recipe actually got eaten. Without this he
            // saves the dish a second time at a smaller size and ends up with
            // two favorites that disagree by hundreds of kcal.
            HStack(spacing: 6) {
                ForEach(Array(FoodFavorite.scales.enumerated()), id: \.offset) { _, s in
                    Button {
                        DS.Haptic.select()
                        favScale = s.1
                    } label: {
                        Text(s.0)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(favScale == s.1 ? DS.Colors.violet : DS.Colors.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                    .fill(favScale == s.1 ? DS.Colors.violet.opacity(0.14) : DS.Colors.surfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    private func fieldRow<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.Colors.textFaint)
                .tracking(1)
            content()
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(DS.Colors.surface)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .stroke(DS.Colors.border, lineWidth: 0.5))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("WHEN")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.Colors.textFaint)
                .tracking(1)
            DatePicker("", selection: $eatenAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(DS.Colors.violet)
            HStack(spacing: DS.Spacing.xs) {
                timeChip("Now") { eatenAt = Date() }
                timeChip("30m ago") { eatenAt = Date().addingTimeInterval(-1800) }
                timeChip("1h ago") { eatenAt = Date().addingTimeInterval(-3600) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .glassDefault()
    }

    private func timeChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: { DS.Haptic.tap(); action() }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.violet)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(DS.Colors.violet.opacity(0.12))
                    .overlay(Capsule().stroke(DS.Colors.violet.opacity(0.25), lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        VStack(spacing: DS.Spacing.sm) {
            Button { Task { await save() } } label: {
                HStack {
                    if isSaving { ProgressView().tint(.white) }
                    else { Image(systemName: "checkmark"); Text("Log it") }
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.md)
                .background(Capsule().fill(DS.Colors.violet))
            }
            .buttonStyle(.plain).disabled(isSaving)

            Button { DS.Haptic.tap(); dismiss(); onCancel() } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Colors.textMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.sm)
            }
            .buttonStyle(.plain).disabled(isSaving)
        }
    }

    // MARK: Save

    private func save() async {
        isSaving = true; error = nil
        do {
            let saved: FoodEntry
            switch source {
            case .favorite(let fav):
                saved = try await SupabaseClient.shared.logFromFavorite(fav, capturedAt: eatenAt, scale: favScale)
            case .preset(let item):
                var notes: [String] = []
                let amt = amountText.trimmingCharacters(in: .whitespaces)
                if !amt.isEmpty && amt.lowercased() != "1 serving" { notes.append(amt) }
                if showCaffeine && caffeine > 0 { notes.append("~\(caffeine)mg caffeine") }
                if portion != .normal { notes.append("\(portion.label.lowercased()) portion") }
                let caption = notes.isEmpty ? name : "\(name) · \(notes.joined(separator: " · "))"
                var tags = item.mindTags
                if showCaffeine && caffeine > 0 && !tags.contains("caffeine") { tags.append("caffeine") }
                // Scale the logged calories by the chosen portion — a "huge" pour
                // of the same drink lands more kcal than a "tiny" one.
                let factor = portion.factor
                let scaledKcal = Int((Double(kcal) * factor).rounded())
                let detected = DetectedItem(name: name, grams: 0, kcal: scaledKcal, novaClass: item.novaClass, mindTags: tags)
                let entry = FoodEntry(
                    id: nil,
                    userId: SupabaseClient.shared.userId,
                    capturedAt: eatenAt,
                    photoUrl: nil,
                    geminiRawJson: nil,
                    items: [detected],
                    caption: caption,
                    totalKcal: scaledKcal,
                    novaAvg: Double(item.novaClass),
                    mindScore: nil,
                    confidence: "quick_log",
                    source: "quick_log",
                    createdAt: nil,
                    logQuality: FoodEntry.computeLogQuality(source: "quick_log", confidence: "quick_log", items: [detected]),
                    portionSize: portion.rawValue,
                    portionFactor: factor
                )
                saved = try await SupabaseClient.shared.saveFoodEntry(entry)
                // Feed the shared "most used" ranking (also the Whoop double-tap signal).
                QuickLogHistory.shared.record(
                    name: item.name.lowercased(), displayName: item.name,
                    emoji: item.emoji, category: item.mirrorCategory, type: item.mirrorType
                )
            }
            DS.Haptic.success()
            dismiss()
            onLogged(saved)
        } catch {
            DS.Haptic.error()
            self.error = "Save failed — check connection."
            isSaving = false
        }
    }
}
