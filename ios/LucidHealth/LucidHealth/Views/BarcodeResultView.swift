import SwiftUI

struct BarcodeResultView: View {
    let product: OpenFoodFactsProduct
    let onSaved: (FoodEntry) -> Void
    var onSavedSupplement: (() -> Void)?

    @State private var isSaving = false
    @State private var error: String?
    @State private var grams: Int

    /// Supplements must not land in food_entries — a capsule logged as a ~2 kcal
    /// meal is exactly how the June ginger-shot signal was lost.
    private var isLikelySupplement: Bool {
        let hay = [(product.productName ?? ""), (product.brand ?? ""),
                   (product.ingredientsText ?? "")].joined(separator: " ").lowercased()
        return ["supplement", "nahrungsergänzung", "vitamin", "magnesium", "zink", "zinc",
                "kreatin", "creatine", "omega", "kapsel", "capsule", "tablette", "d3", "k2"]
            .contains { hay.contains($0) }
    }

    /// Detect liquid/spirit products to pick sensible portion presets.
    private var isLikelyDrink: Bool {
        let name = (product.productName ?? "").lowercased()
        let drinkKeywords = ["whiskey", "whisky", "vodka", "gin", "rum", "tequila",
                             "wine", "beer", "juice", "soda", "cola", "milk", "water",
                             "coffee", "tea", "drink", "beverage", "spirit", "ale", "lager"]
        return drinkKeywords.contains { name.contains($0) }
    }

    private var isLikelySpirit: Bool {
        let name = (product.productName ?? "").lowercased()
        return ["whiskey", "whisky", "vodka", "gin", "rum", "tequila", "spirit", "liqueur"]
            .contains { name.contains($0) }
    }

    private var portionPresets: [(label: String, grams: Int)] {
        if isLikelySpirit {
            return [("1 shot", 44), ("1 glass", 44), ("2 glasses", 88), ("Custom", -1)]
        } else if isLikelyDrink {
            return [("250ml", 250), ("500ml", 500), ("1L", 1000), ("Custom", -1)]
        } else {
            // Solid food
            let serving = product.servingSizeG ?? 100
            return [("¼ pkg", 50), ("½ pkg", 100), ("1 serving", serving), ("Custom", -1)]
        }
    }

    init(product: OpenFoodFactsProduct,
         onSavedSupplement: (() -> Void)? = nil,
         onSaved: @escaping (FoodEntry) -> Void) {
        self.product = product
        self.onSaved = onSaved
        self.onSavedSupplement = onSavedSupplement
        // Default grams: 1 shot for spirits, 250ml for drinks, serving size for solids
        let name = (product.productName ?? "").lowercased()
        let isSpirit = ["whiskey", "whisky", "vodka", "gin", "rum", "tequila"].contains { name.contains($0) }
        let isDrink = isSpirit || ["wine", "beer", "juice", "soda", "milk"].contains { name.contains($0) }
        let defaultGrams: Int = isSpirit ? 44 :
                                isDrink ? 250 :
                                product.servingSizeG ?? 100
        self._grams = State(initialValue: defaultGrams)
    }

    private var scaledKcal: Int {
        let per100 = product.kcalPer100g ?? 0
        return Int((per100 * Double(grams)) / 100.0)
    }

    private var novaColor: Color {
        switch product.novaGroup {
        case 1: return DS.Colors.success
        case 2: return DS.Colors.teal
        case 3: return DS.Colors.warning
        default: return DS.Colors.danger
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                // Product image
                if let imgURL = product.imageURL, let url = URL(string: imgURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 200)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
                        default:
                            RoundedRectangle(cornerRadius: DS.Radius.lg)
                                .fill(DS.Colors.raised2)
                                .frame(height: 200)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                }

                // Name + brand
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(product.productName ?? "Unbekanntes Produkt")
                        .font(DS.Font.title2)
                        .foregroundStyle(DS.Colors.textPrimary)
                    if let brand = product.brand, !brand.isEmpty {
                        Text(brand)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Colors.textMuted)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)

                // Stat chips
                HStack(spacing: DS.Spacing.sm) {
                    if let kcal = product.kcalPer100g {
                        statChip(label: "\(Int(kcal)) kcal", icon: "flame.fill", color: DS.Colors.amber)
                    }
                    if let nova = product.novaGroup {
                        statChip(label: "NOVA \(nova)", icon: "square.stack.3d.up.fill", color: novaColor)
                    }
                    if let ns = product.nutriscore {
                        statChip(label: "Nutri-\(ns)", icon: "leaf.fill", color: DS.Colors.teal)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)

                // Ingredients
                if let ing = product.ingredientsText, !ing.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("ZUTATEN")
                            .font(DS.Font.label)
                            .foregroundStyle(DS.Colors.textMuted)
                            .tracking(0.8)
                        Text(ing)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(4)
                    }
                    .glassCard()
                    .padding(.horizontal, DS.Spacing.md)
                }

                // Portion picker — fixes the v70 bug where every barcode scan
                // saved exactly 100g regardless of actual consumption (whiskey
                // 2 glasses logged as 100g/0kcal). Now you pick portion before save.
                portionPicker

                if let err = error {
                    AlertBanner(icon: "exclamationmark.triangle", message: err, color: DS.Colors.danger)
                        .padding(.horizontal, DS.Spacing.md)
                }

                // Save
                Button { save() } label: {
                    HStack {
                        if isSaving { ProgressView().tint(.white).padding(.trailing, 4) }
                        Text(isSaving ? "Saving…" : "Looks right · Save")
                            .font(DS.Font.bodyMed)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [DS.Colors.violet, DS.Colors.teal],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                }
                .disabled(isSaving)
                .padding(.horizontal, DS.Spacing.md)

                // Shelf path — promoted to the top action when the product looks
                // like a supplement, since portion/kcal are meaningless for it.
                Button { saveAsSupplement() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pills.fill").font(.system(size: 13))
                        Text(isLikelySupplement ? "This is a supplement · Add to shelf"
                                                : "Add to supplement shelf instead")
                            .font(DS.Font.bodyMed)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(DS.Colors.violet)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(DS.Colors.raised2)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                                .stroke(DS.Colors.violet.opacity(0.28), lineWidth: 0.5))
                    )
                }
                .disabled(isSaving)
                .padding(.horizontal, DS.Spacing.md)

                Color.clear.frame(height: DS.Spacing.xl)
            }
            .padding(.top, DS.Spacing.md)
        }
    }

    @ViewBuilder
    private func statChip(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var portionPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("HOW MUCH DID YOU HAVE?")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Colors.textMuted)
                    .tracking(0.8)
                Spacer()
                Text("\(scaledKcal) kcal")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.amber)
                    .monospacedDigit()
            }

            // Quick presets
            HStack(spacing: 6) {
                ForEach(portionPresets, id: \.label) { preset in
                    Button {
                        let h = UIImpactFeedbackGenerator(style: .light)
                        h.impactOccurred()
                        if preset.grams > 0 {
                            grams = preset.grams
                        }
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(grams == preset.grams ? .white : DS.Colors.violet)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(grams == preset.grams
                                          ? AnyShapeStyle(DS.Colors.violet)
                                          : AnyShapeStyle(DS.Colors.violet.opacity(0.12)))
                                    .overlay(Capsule().stroke(DS.Colors.violet.opacity(0.3), lineWidth: 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Manual gram input + Stepper
            HStack(spacing: DS.Spacing.sm) {
                Text("\(grams)\(isLikelyDrink ? "ml" : "g")")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .leading)

                Stepper("", value: $grams, in: 1...2000, step: isLikelyDrink ? 25 : 10)
                    .labelsHidden()
                    .tint(DS.Colors.violet)
            }
        }
        .glassCard()
        .padding(.horizontal, DS.Spacing.md)
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            do {
                let entry = try await SupabaseClient.shared.saveBarcodeEntry(
                    product: product,
                    gramsOverride: grams
                )
                onSaved(entry)
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }

    /// Open Food Facts carries no dose panel, so the shelf entry starts empty and
    /// gets its actives filled in from a label photo or by hand.
    private func saveAsSupplement() {
        isSaving = true
        error = nil
        Task {
            do {
                try await SupabaseClient.shared.upsertSupplementProduct(
                    name: product.productName ?? "Unbekanntes Supplement",
                    barcode: product.barcode,
                    brand: product.brand,
                    source: "barcode"
                )
                onSavedSupplement?()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}
