import SwiftUI

private enum LogV3EntryMode: String, Identifiable {
    case camera, barcode, manual, recipe
    var id: String { rawValue }
}

struct LogV3Sheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var opened: Date = Date()
    @State private var text = ""
    @State private var portionLabel = "Normal"
    @State private var sending = false
    @State private var busy = false
    @State private var errorText: String? = nil
    @State private var favorites: [FoodFavorite] = []
    @State private var pots: [SupabaseClient.FoodPot] = []
    @State private var shelf: [SupabaseClient.SupplementShelfItem] = []
    @State private var potPick: [String: String] = [:]
    @State private var entryMode: LogV3EntryMode? = nil
    @State private var toast: LogV3Toast? = nil
    @State private var successCount = 0
    @State private var errorCount = 0
    @FocusState private var focused: Bool

    init() {}

    var body: some View {
        ZStack {
            V3.sheet.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    header
                    describeCard
                    tileRow
                    coffeeRow
                    portionCard
                    favoritesCard
                    potsSection
                    shelfCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.snappy(duration: 0.25), value: toast?.id)
        .presentationDragIndicator(.visible)
        .presentationBackground(V3.sheet)
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: errorCount)
        .task { await loadAll() }
        .task(id: toast?.id) { await expireToast() }
        // One item-driven cover: stacked fullScreenCover modifiers on one view silently drop the third.
        .fullScreenCover(item: $entryMode) { (m: LogV3EntryMode) in
            switch m {
            case .camera:
                CameraView { entry in finish(entry) }
            case .barcode:
                BarcodeScannerView(onEntry: { entry in finish(entry) })
            case .manual:
                ManualFoodEntrySheet { entry in finish(entry) }
            case .recipe:
                MealBuilderV3Entry { entry in finish(entry) }
            }
        }
        .lucidRendered(.log)
    }

    // MARK: - Data

    @MainActor private func loadAll() async {
        let client = SupabaseClient.shared
        async let favResult = try? client.fetchFavorites()
        async let potResult = try? client.openPots()
        async let shelfResult = try? client.supplementShelf()
        if let f = await favResult { favorites = f }
        if let p = await potResult { pots = p }
        if let s = await shelfResult { shelf = s }
    }

    @MainActor private func expireToast() async {
        guard toast != nil else { return }
        do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
        toast = nil
    }

    private var portion: PortionSize {
        switch portionLabel {
        case "Tiny": return .tiny
        case "Small": return .small
        case "Large": return .big
        case "Huge": return .huge
        default: return .normal
        }
    }

    private var uniqueFavorites: [FoodFavorite] {
        let ranked: [FoodFavorite] = favorites.sorted { ($0.timesLogged ?? 0) > ($1.timesLogged ?? 0) }
        var seen = Set<String>()
        var out: [FoodFavorite] = []
        for f in ranked where (f.totalKcal ?? 0) > 0 {
            if seen.insert(LogV3Text.dedupeKey(f.name)).inserted { out.append(f) }
            if out.count >= 12 { break }
        }
        return out
    }

    private var openPots: [SupabaseClient.FoodPot] {
        pots.filter { $0.remaining > 0.01 }
    }

    private var coffeeItem: QuickLogItem? {
        QuickLogItem.defaults.first(where: { $0.id == "double_espresso" })
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending && !busy
    }

    private func show(_ message: String, undoID: String? = nil) {
        toast = LogV3Toast(text: message, undoID: undoID)
    }

    private func finish(_ saved: FoodEntry) {
        successCount += 1
        show("Logged \(LogV3Text.label(saved)), \(LogV3Text.kcal(saved)) kcal", undoID: saved.id?.uuidString)
    }

    private func undo(_ id: String) {
        toast = nil
        Task { @MainActor in
            let ok = await SupabaseClient.shared.deleteFoodEntry(id: id)
            if !ok { errorCount += 1 }
            show(ok ? "Removed" : "Could not remove it")
        }
    }

    // MARK: - Actions

    @MainActor private func send() async {
        let desc = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty, !sending, !busy else { return }
        sending = true
        errorText = nil
        focused = false
        defer { sending = false }
        let p = portion
        do {
            let result = try await GeminiClient.shared.analyzeFood(description: desc)
            let source = "manual"
            let entry = FoodEntry(
                id: nil,
                userId: SupabaseClient.shared.userId,
                capturedAt: Date(),
                photoUrl: nil,
                geminiRawJson: result.notes,
                items: result.items,
                caption: desc,
                totalKcal: result.totalKcal,
                novaAvg: result.novaAvg,
                mindScore: result.mindScore,
                confidence: result.confidence,
                source: source,
                createdAt: nil,
                logQuality: FoodEntry.computeLogQuality(source: source, confidence: result.confidence, items: result.items),
                portionSize: p.rawValue,
                portionFactor: p.factor
            )
            let saved = try await SupabaseClient.shared.saveFoodEntry(entry)
            text = ""
            finish(saved)
        } catch {
            SupabaseClient.shared.logClientError(area: "log_v3.describe", message: error.localizedDescription, context: String(desc.prefix(200)))
            errorText = "Could not read that meal. Try again, or use Manual."
            errorCount += 1
        }
    }

    @MainActor private func logCoffee(_ item: QuickLogItem) async {
        guard !busy, !sending else { return }
        busy = true
        defer { busy = false }
        let p = portion
        var notes: [String] = [LogV3Text.coffeeAmount, "~\(LogV3Text.coffeeCaffeine)mg caffeine"]
        if p != .normal { notes.append("\(p.label.lowercased()) portion") }
        let caption = "\(item.name) · \(notes.joined(separator: " · "))"
        var tags: [String] = item.mindTags
        tags.append("caffeine")
        let scaledKcal = Int((Double(item.kcal) * p.factor).rounded())
        let detected = DetectedItem(name: item.name, grams: 0, kcal: scaledKcal, novaClass: item.novaClass, mindTags: tags)
        let entry = FoodEntry(
            id: nil,
            userId: SupabaseClient.shared.userId,
            capturedAt: Date(),
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
            portionSize: p.rawValue,
            portionFactor: p.factor
        )
        do {
            let saved = try await SupabaseClient.shared.saveFoodEntry(entry)
            QuickLogHistory.shared.record(
                name: item.name.lowercased(),
                displayName: item.name,
                emoji: item.emoji,
                category: item.mirrorCategory,
                type: item.mirrorType
            )
            finish(saved)
        } catch {
            errorCount += 1
            show("Could not log the coffee")
        }
    }

    @MainActor private func logFavorite(_ fav: FoodFavorite) async {
        guard !busy, !sending else { return }
        busy = true
        defer { busy = false }
        do {
            let saved = try await SupabaseClient.shared.logFromFavorite(fav, scale: portion.factor)
            finish(saved)
        } catch {
            errorCount += 1
            show("Could not log \(fav.name)")
        }
    }

    @MainActor private func servePot(_ pot: SupabaseClient.FoodPot, _ fraction: LogV3Fraction) async {
        guard !busy, !sending else { return }
        busy = true
        defer { busy = false }
        do {
            try await SupabaseClient.shared.servePot(id: pot.id, fraction: fraction.value)
            potPick[pot.id] = nil
            successCount += 1
            show("Logged \(fraction.word.lowercased()) of \(pot.name)")
            if let p = try? await SupabaseClient.shared.openPots() { pots = p }
        } catch {
            errorCount += 1
            show("Could not log from the pot")
        }
    }

    @MainActor private func takeSupplement(_ item: SupabaseClient.SupplementShelfItem) async {
        guard !busy, !sending else { return }
        busy = true
        defer { busy = false }
        do {
            try await SupabaseClient.shared.logSupplement(productId: item.id)
            successCount += 1
            show("Logged \(item.name)")
            if let s = try? await SupabaseClient.shared.supplementShelf() { shelf = s }
        } catch {
            errorCount += 1
            show("Could not log \(item.name)")
        }
    }

    // MARK: - Header and describe

    private var header: some View {
        V3Header(date: V3Format.dayTitle(opened) + " · " + V3Format.hhmm(opened), title: "Log") {
            V3IconButton(symbol: "xmark") { dismiss() }
        }
    }

    private var describeCard: some View {
        V3Card {
            TextField(
                "Describe a meal",
                text: $text,
                prompt: Text("Describe a meal, like two eggs on toast").foregroundColor(V3.t3),
                axis: .vertical
            )
            .font(V3Font.text(16))
            .foregroundStyle(V3.t1)
            .lineLimit(1...4)
            .focused($focused)
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(V3.t2)
                Text("Gemini reads it").font(V3Font.text(12)).foregroundStyle(V3.t2)
                Spacer(minLength: 8)
                sendButton
            }
            .padding(.top, 14)
            describeError
        }
    }

    private var sendButton: some View {
        Button { Task { await send() } } label: {
            ZStack {
                Circle().fill(canSend || sending ? V3.t1 : V3.chrome)
                if sending {
                    ProgressView().tint(V3.ink)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSend ? V3.ink : V3.t3)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    @ViewBuilder private var describeError: some View {
        if let e = errorText {
            Text(e).font(V3Font.text(12)).foregroundStyle(V3.red).padding(.top, 10)
        }
    }

    // MARK: - Tiles, coffee, portion

    private var tileRow: some View {
        HStack(spacing: 10) {
            tile(symbol: "camera.fill", label: "Photo") { entryMode = .camera }
            tile(symbol: "barcode.viewfinder", label: "Barcode") { entryMode = .barcode }
            tile(symbol: "keyboard", label: "Manual") { entryMode = .manual }
            tile(symbol: "fork.knife", label: "Recipe") { entryMode = .recipe }
        }
    }

    private func tile(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(V3.kcal)
                Text(label).font(V3Font.text(12, .semibold)).foregroundStyle(V3.t1)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(V3.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var coffeeRow: some View {
        if let item = coffeeItem {
            Button { Task { await logCoffee(item) } } label: {
                HStack(spacing: 12) {
                    V3IconWell(symbol: item.icon, color: V3.kcal, size: 30)
                    Text("Coffee").font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1)
                    Spacer(minLength: 8)
                    Text("Double espresso, \(LogV3Text.coffeeCaffeine) mg")
                        .font(V3Font.text(12))
                        .foregroundStyle(V3.t2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(V3.card2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var portionCard: some View {
        V3Card {
            V3CardHeader(title: "Portion", trailing: "for the next log")
            V3Segmented(options: ["Tiny", "Small", "Normal", "Large", "Huge"], selection: $portionLabel)
        }
    }

    // MARK: - Favourites

    @ViewBuilder private var favoritesCard: some View {
        let favs: [FoodFavorite] = uniqueFavorites
        if !favs.isEmpty {
            V3Card {
                V3CardHeader(title: "Favourites", trailing: "one tap")
                LogV3Flow(spacing: 8) {
                    ForEach(favs.indices, id: \.self) { i in
                        favoriteChip(favs[i])
                    }
                }
            }
        }
    }

    private func favoriteChip(_ f: FoodFavorite) -> some View {
        let kcal = Int((Double(f.totalKcal ?? 0) * portion.factor).rounded())
        return Button { Task { await logFavorite(f) } } label: {
            HStack(spacing: 6) {
                Text(f.name).font(V3Font.text(14, .semibold)).foregroundStyle(V3.t1).lineLimit(1)
                Text("\(kcal)").font(V3Font.num(12, .medium)).foregroundStyle(V3.t2)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(V3.card2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pots

    @ViewBuilder private var potsSection: some View {
        let list: [SupabaseClient.FoodPot] = openPots
        if !list.isEmpty {
            VStack(spacing: 12) {
                ForEach(list) { pot in
                    potCard(pot)
                }
            }
        }
    }

    private func potCard(_ pot: SupabaseClient.FoodPot) -> some View {
        let fractions: [LogV3Fraction] = LogV3Text.fractions(for: pot)
        let picked: LogV3Fraction? = fractions.first(where: { $0.id == potPick[pot.id] })
        return V3Card {
            V3CardHeader(icon: "fork.knife", iconColor: V3.kcal, title: pot.name, trailing: "\(pot.remainingPct)% left")
            potSlots(pot)
            potChips(pot, fractions: fractions, picked: picked)
            potCaption(pot, picked: picked)
            potConfirm(pot, picked: picked)
        }
    }

    private func potSlots(_ pot: SupabaseClient.FoodPot) -> some View {
        let filled = Int((pot.remaining * 4).rounded())
        return HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(i < filled ? V3.kcal : V3.track)
                    .frame(height: 22)
            }
        }
    }

    private func potChips(_ pot: SupabaseClient.FoodPot, fractions: [LogV3Fraction], picked: LogV3Fraction?) -> some View {
        HStack(spacing: 8) {
            ForEach(fractions) { fr in
                let enabled = fr.value > 0.01 && fr.value <= pot.remaining + 0.01
                let on = picked?.id == fr.id
                Button { potPick[pot.id] = on ? nil : fr.id } label: {
                    Text(fr.label)
                        .font(V3Font.text(14, .semibold))
                        .foregroundStyle(on ? V3.ink : V3.t1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(on ? V3.t1 : V3.card2, in: Capsule())
                        .opacity(enabled ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder private func potCaption(_ pot: SupabaseClient.FoodPot, picked: LogV3Fraction?) -> some View {
        if let fr = picked {
            let isRest = fr.id == "r"
            let kcal = Int((isRest ? pot.leftKcal : pot.totalKcal * fr.value).rounded())
            let protein = Int((isRest ? pot.leftProtein : pot.totalProtein * fr.value).rounded())
            let lead: Text = Text("\(fr.word) is ").font(V3Font.text(13)).foregroundColor(V3.t2)
            let kcalText: Text = Text("\(kcal) kcal").font(V3Font.text(13, .semibold)).foregroundColor(V3.t1)
            let comma: Text = Text(", ").font(V3Font.text(13)).foregroundColor(V3.t2)
            let proteinText: Text = Text("\(protein) g protein").font(V3Font.text(13, .semibold)).foregroundColor(V3.t1)
            let line: Text = lead + kcalText + comma + proteinText
            line.padding(.top, 12)
        } else {
            Text("Pick a share, then log it")
                .font(V3Font.text(13))
                .foregroundStyle(V3.t2)
                .padding(.top, 12)
        }
    }

    @ViewBuilder private func potConfirm(_ pot: SupabaseClient.FoodPot, picked: LogV3Fraction?) -> some View {
        if let fr = picked {
            V3Button(title: "Log \(fr.word.lowercased())", symbol: "plus") {
                Task { await servePot(pot, fr) }
            }
            .padding(.top, 14)
        }
    }

    // MARK: - Supplement shelf

    @ViewBuilder private var shelfCard: some View {
        let items: [SupabaseClient.SupplementShelfItem] = Array(shelf.prefix(12))
        if !items.isEmpty {
            V3Card {
                V3CardHeader(title: "Supplement shelf", trailing: "tap logs a dose")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                    ForEach(items) { item in
                        shelfCell(item)
                    }
                }
            }
        }
    }

    private func shelfCell(_ item: SupabaseClient.SupplementShelfItem) -> some View {
        let done: Bool = (item.targetDaily ?? 0) > 0 && item.takenToday >= (item.targetDaily ?? 0)
        return Button { Task { await takeSupplement(item) } } label: {
            VStack(spacing: 6) {
                Image(systemName: done ? "checkmark" : "pills.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(done ? V3.green : V3.t1)
                    .frame(width: 48, height: 48)
                    .background(done ? V3.green.opacity(0.14) : V3.card2, in: Circle())
                Text(item.name)
                    .font(V3Font.text(12))
                    .foregroundStyle(V3.t2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toast

    @ViewBuilder private var toastOverlay: some View {
        if let t = toast {
            HStack(spacing: 12) {
                Text(t.text).font(V3Font.text(14, .semibold)).foregroundStyle(V3.t1).lineLimit(2)
                Spacer(minLength: 8)
                if let id = t.undoID {
                    Button { undo(id) } label: {
                        Text("Undo").font(V3Font.text(14, .bold)).foregroundStyle(V3.kcal)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(V3.card2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(V3.line, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Support types

private struct LogV3Toast: Identifiable {
    let id = UUID()
    let text: String
    let undoID: String?
}

private struct LogV3Fraction: Identifiable {
    let id: String
    let label: String
    let value: Double
    let word: String
}

private enum LogV3Text {
    static let coffeeAmount = "80 ml"
    static let coffeeCaffeine = 150

    static func dedupeKey(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9äöüß]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").sorted().joined(separator: " ")
    }

    static func kcal(_ e: FoodEntry) -> Int {
        e.totalKcal ?? e.items.reduce(0) { $0 + $1.kcal }
    }

    static func label(_ e: FoodEntry) -> String {
        let cap = (e.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cap.isEmpty { return clip(cap, 28) }
        let names: [String] = e.items.map { $0.name }.filter { !$0.isEmpty }
        if !names.isEmpty { return clip(names.joined(separator: ", "), 28) }
        return "meal"
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func fractions(for pot: SupabaseClient.FoodPot) -> [LogV3Fraction] {
        return [
            LogV3Fraction(id: "q", label: "¼", value: 0.25, word: "A quarter"),
            LogV3Fraction(id: "t", label: "⅓", value: 1.0 / 3.0, word: "A third"),
            LogV3Fraction(id: "h", label: "½", value: 0.5, word: "Half"),
            LogV3Fraction(id: "r", label: "Rest", value: pot.remaining, word: "The rest")
        ]
    }
}

private struct LogV3Flow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW: CGFloat = proposal.width ?? .infinity
        let limit: CGFloat? = maxW.isFinite ? maxW : nil
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var usedW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            if x > 0 && x + sz.width > maxW {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            usedW = max(usedW, x - spacing)
        }
        return CGSize(width: usedW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + sz.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sz.width, height: sz.height))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
