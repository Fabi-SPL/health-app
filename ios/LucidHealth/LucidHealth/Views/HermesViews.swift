import SwiftUI

// ════════════════════════════════════════════════════════════
// Hermes Views — Body-state card + conversational chat sheet
//
// Surfaces the Hermes pattern engine on iOS:
//   - HermesCard: lives on TodayView, shows latest /now interpretation
//     + "Ask Hermes" button + manual refresh
//   - HermesChatSheet: modal full-screen chat with grounded context
//     (POSTs to /api/hermes/chat, persists history in @AppStorage)
//
// Auth: uses the iOS Supabase session token (user JWT), which the
// server-side /api/hermes/_auth.ts validates against Fabi's user_id.
// No embedded secrets in the IPA.
// ════════════════════════════════════════════════════════════

// MARK: - Hermes API client + models

private let hermesBaseURL = "https://app.keled.de"

private struct HermesNowSnapshot: Codable {
    let interpretation: String?
    let computed_at: String?
    let raw_signal: [String: AnyCodable]?
    let percentiles: [String: AnyCodable]?
    let context: [String: AnyCodable]?
}

private struct HermesChatReply: Codable {
    let reply: String
    let model: String?
    let tokens_in: Int?
    let tokens_out: Int?
    let latency_ms: Int?
}

/// Minimal Codable for heterogeneous JSON values (numbers / strings / null).
private struct AnyCodable: Codable {
    let value: Any?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if c.decodeNil() { value = nil }
        else { value = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = value as? Double { try c.encode(v) }
        else if let v = value as? String { try c.encode(v) }
        else if let v = value as? Bool { try c.encode(v) }
        else { try c.encodeNil() }
    }
}

struct HermesChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: String   // "user" or "assistant"
    let content: String
    let timestamp: Date

    init(role: String, content: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Typed Hermes failure — carries ONLY a kind/status, never a raw server body.
/// Mapped to calm first-person copy in the views; raw JSON never reaches the UI.
private enum HermesError: Error {
    case notSignedIn
    case offline
    case timeout
    case server(Int)
    case unknown

    var friendly: String {
        switch self {
        case .notSignedIn: return "Sign in to read your body state."
        case .offline:     return "Can't reach your body data right now — check your connection."
        case .timeout:     return "That took a moment too long. I'll try again shortly."
        case .server:      return "I'm having trouble reading my signals right now. Back in a bit."
        case .unknown:     return "Something's off reading my signals right now."
        }
    }
}

private enum HermesAPI {
    static func bearerToken(from supabase: SupabaseClient) -> String? {
        supabase.accessToken
    }

    /// Cheap DB read of the latest /now snapshot — NO recompute, NO /now call.
    /// Used on card appear so the slow/broken /now path isn't hit on every mount.
    /// hermes_now_snapshots is single-user (no user_id column) → no filter.
    static func fetchCached(supabase: SupabaseClient) async -> HermesNowSnapshot? {
        let urlStr = "\(supabase.baseURL)/rest/v1/hermes_now_snapshots?select=interpretation,computed_at&order=computed_at.desc&limit=1"
        guard let u = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: u)
        req.setValue(supabase.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(supabase.accessToken ?? supabase.anonKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12
        struct Row: Codable { let interpretation: String?; let computed_at: String? }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode < 300,
              let rows = try? JSONDecoder().decode([Row].self, from: data),
              let r = rows.first else { return nil }
        return HermesNowSnapshot(interpretation: r.interpretation, computed_at: r.computed_at,
                                 raw_signal: nil, percentiles: nil, context: nil)
    }

    /// Call POST /api/hermes/now with no body to refresh the latest snapshot.
    static func refreshNow(token: String) async throws -> HermesNowSnapshot {
        var req = URLRequest(url: URL(string: "\(hermesBaseURL)/api/hermes/now")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 40
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw HermesError.unknown }
            guard http.statusCode < 300 else { throw HermesError.server(http.statusCode) }
            return try JSONDecoder().decode(HermesNowSnapshot.self, from: data)
        } catch let e as HermesError {
            throw e
        } catch let e as URLError {
            throw e.code == .timedOut ? HermesError.timeout : HermesError.offline
        } catch {
            throw HermesError.unknown
        }
    }

    /// Fetch the latest /now snapshot from DB (no recompute) — for initial card load.
    /// Falls back to refresh if no row exists in the last 60 minutes.
    static func sendChat(message: String, history: [HermesChatMessage], token: String) async throws -> HermesChatReply {
        var req = URLRequest(url: URL(string: "\(hermesBaseURL)/api/hermes/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 40
        let historyPayload = history.suffix(12).map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any] = ["message": message, "history": historyPayload]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw HermesError.unknown }
            guard http.statusCode < 300 else { throw HermesError.server(http.statusCode) }
            return try JSONDecoder().decode(HermesChatReply.self, from: data)
        } catch let e as HermesError {
            throw e
        } catch let e as URLError {
            throw e.code == .timedOut ? HermesError.timeout : HermesError.offline
        } catch {
            throw HermesError.unknown
        }
    }
}

// MARK: - HermesCard — sits on TodayView

struct HermesCard: View {
    @EnvironmentObject private var bleManager: BLEManager
    @State private var snapshot: HermesNowSnapshot?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingChat = false
    @State private var showingStats = false
    @State private var appeared = false

    private var interpretation: String {
        let raw = snapshot?.interpretation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Tap refresh to read your current body state." : raw
    }

    private var ageLabel: String {
        guard let iso = snapshot?.computed_at,
              let date = ISO8601DateFormatter.lucid.date(from: iso) else { return "" }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    /// Freshness gate — while the server's /now compute is dead (no snapshot in
    /// 36h+), hide the refresh control instead of shipping a button that 500s.
    private var computeIsLive: Bool {
        guard let iso = snapshot?.computed_at,
              let date = ISO8601DateFormatter.lucid.date(from: iso) else { return false }
        return Date().timeIntervalSince(date) < 36 * 3600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Header row
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Colors.violet)
                Text("HERMES")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(DS.Colors.violet)
                if !ageLabel.isEmpty {
                    Text("·")
                        .foregroundStyle(DS.Colors.textFaint)
                        .padding(.horizontal, 2)
                    Text(ageLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.Colors.textFaint)
                }
                Spacer()
                Button(action: { DS.Haptic.tap(); showingStats = true }) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(DS.Colors.surfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                if computeIsLive {
                    Button(action: { DS.Haptic.tap(); Task { await refresh() } }) {
                        Image(systemName: isLoading ? "ellipsis" : "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .symbolEffect(.pulse, options: .repeating, isActive: isLoading)
                            .frame(width: 28, height: 28)
                            .background(DS.Colors.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }

            // Interpretation — always show the last good reading (or placeholder).
            // A failure appends a soft amber note; it never replaces the body with
            // a raw error, so one transient 500 can't wipe the card to a stub.
            VStack(alignment: .leading, spacing: 6) {
                Text(interpretation)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineSpacing(2)
                    .lineLimit(4)
                    .opacity(snapshot == nil ? 0.45 : 1.0)
                if let err = error {
                    Text(err)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Colors.amber)
                        .lineLimit(2)
                } else if snapshot != nil && !computeIsLive {
                    Text("Live readings are paused — this is my last full read.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Colors.amber.opacity(0.85))
                        .lineLimit(2)
                }
            }

            // Ask Hermes button
            Button(action: { DS.Haptic.tap(); showingChat = true }) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Ask Hermes")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(
                    LinearGradient(
                        colors: [DS.Colors.violet, DS.Colors.violet.opacity(0.78)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            }
            .buttonStyle(.plain)
            .scaleEffect(showingChat ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: showingChat)
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: appeared)
        .onAppear {
            appeared = true
            if snapshot == nil {
                Task {
                    // Cheap cached read only — never auto-fire the heavy /now
                    // recompute on mount (it's been dead server-side; manual
                    // refresh appears only when the snapshot is fresh).
                    if let cached = await HermesAPI.fetchCached(supabase: bleManager.supabase) {
                        await MainActor.run { snapshot = cached }
                    }
                }
            }
        }
        .sheet(isPresented: $showingChat) {
            HermesChatSheet()
                .environmentObject(bleManager)
        }
        .sheet(isPresented: $showingStats) {
            HermesStatsSheet()
                .environmentObject(bleManager)
        }
    }

    private func refresh() async {
        guard let token = HermesAPI.bearerToken(from: bleManager.supabase) else {
            await MainActor.run { error = HermesError.notSignedIn.friendly }
            return
        }
        await MainActor.run { isLoading = true; error = nil }
        do {
            let result = try await HermesAPI.refreshNow(token: token)
            await MainActor.run {
                snapshot = result
                error = nil
                isLoading = false
            }
        } catch let e {
            let msg = (e as? HermesError)?.friendly ?? HermesError.unknown.friendly
            await MainActor.run {
                self.error = msg   // non-destructive — last snapshot stays, shown as sub-note
                isLoading = false
            }
        }
    }
}

// MARK: - HermesChatSheet — full conversation

struct HermesChatSheet: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hermes_chat_history_v1") private var historyJSON: String = "[]"

    @State private var messages: [HermesChatMessage] = []
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    private let quickPrompts: [String] = [
        "Why am I feeling like this?",
        "What's going on with my body?",
        "Should I push or rest right now?",
        "Did I sleep enough?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Conversation
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: DS.Spacing.md) {
                            if messages.isEmpty { emptyState }
                            ForEach(messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                            if isSending {
                                HStack {
                                    TypingDots()
                                        .padding(DS.Spacing.md)
                                        .background(DS.Colors.surfaceElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
                                    Spacer()
                                }
                                .padding(.horizontal, DS.Spacing.md)
                                .transition(.opacity)
                            }
                            if let err = error {
                                Text(err)
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.Colors.amber)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, DS.Spacing.md)
                            }
                            Color.clear.frame(height: 8).id("__bottom__")
                        }
                        .padding(.top, DS.Spacing.md)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation(.spring(response: 0.35)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    }
                    .onChange(of: isSending) { _, sending in
                        if sending {
                            withAnimation(.spring(response: 0.35)) {
                                proxy.scrollTo("__bottom__", anchor: .bottom)
                            }
                        }
                    }
                }

                // Quick prompts (only when empty)
                if messages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.sm) {
                            ForEach(quickPrompts, id: \.self) { p in
                                Button {
                                    input = p
                                    Task { await send() }
                                } label: {
                                    Text(p)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(DS.Colors.textPrimary)
                                        .padding(.horizontal, DS.Spacing.md)
                                        .padding(.vertical, DS.Spacing.sm)
                                        .background(DS.Colors.surfaceElevated)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(DS.Colors.violet.opacity(0.25), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.bottom, DS.Spacing.sm)
                    }
                }

                // Input
                HStack(spacing: DS.Spacing.sm) {
                    TextField("Ask anything…", text: $input, axis: .vertical)
                        .focused($inputFocused)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1...4)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, 10)
                        .background(DS.Colors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
                        .onSubmit { Task { await send() } }

                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: isSending ? "ellipsis" : "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(canSend ? DS.Colors.violet : DS.Colors.textFaint.opacity(0.3))
                            .clipShape(Circle())
                            .symbolEffect(.pulse, options: .repeating, isActive: isSending)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.surface)
            }
            .background(DS.Colors.bg.ignoresSafeArea())
            .navigationTitle("Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            messages = []
                            persist()
                        } label: {
                            Label("Clear conversation", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            loadHistory()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                inputFocused = true
            }
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(DS.Colors.violet)
            Text("Ask Hermes anything")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("He has your body state, last 7 days of tasks, brain dumps, and matched patterns. Speak normally.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        guard let token = HermesAPI.bearerToken(from: bleManager.supabase) else {
            DS.Haptic.error()
            error = "Sign in to use Hermes"
            return
        }
        DS.Haptic.commit()
        let userMsg = HermesChatMessage(role: "user", content: trimmed)
        await MainActor.run {
            messages.append(userMsg)
            input = ""
            error = nil
            isSending = true
        }
        persist()
        do {
            let reply = try await HermesAPI.sendChat(
                message: trimmed,
                history: messages.dropLast(),  // exclude the just-appended user msg from history (server sees it via `message`)
                token: token
            )
            let assistantMsg = HermesChatMessage(role: "assistant", content: reply.reply)
            await MainActor.run {
                DS.Haptic.tap()   // reply landed
                messages.append(assistantMsg)
                isSending = false
            }
            persist()
        } catch let e {
            let msg = (e as? HermesError)?.friendly ?? HermesError.unknown.friendly
            await MainActor.run {
                DS.Haptic.error()
                error = msg
                isSending = false
            }
        }
    }

    private func loadHistory() {
        guard let data = historyJSON.data(using: .utf8),
              let parsed = try? JSONDecoder.lucid.decode([HermesChatMessage].self, from: data) else {
            return
        }
        // Keep only last 50 messages to avoid bloat
        messages = Array(parsed.suffix(50))
    }

    private func persist() {
        guard let data = try? JSONEncoder.lucid.encode(messages),
              let s = String(data: data, encoding: .utf8) else { return }
        historyJSON = s
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: HermesChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(message.role == "user" ? .white : DS.Colors.textPrimary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(bubbleBg)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.lg)
                            .stroke(borderColor, lineWidth: 1)
                    )
            }
            if message.role == "assistant" { Spacer(minLength: 40) }
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    private var bubbleBg: some ShapeStyle {
        message.role == "user"
            ? AnyShapeStyle(LinearGradient(colors: [DS.Colors.violet, DS.Colors.violet.opacity(0.85)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(DS.Colors.surfaceElevated)
    }

    private var borderColor: Color {
        message.role == "user" ? .clear : DS.Colors.violet.opacity(0.15)
    }
}

// MARK: - Typing indicator

private struct TypingDots: View {
    @State private var phase: Int = 0
    @State private var timer: Timer?
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(DS.Colors.violet)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase == i ? 1.0 : 0.5)
                    .opacity(phase == i ? 1.0 : 0.45)
                    .animation(.easeInOut(duration: 0.45), value: phase)
            }
        }
        .frame(height: 14)
        .onAppear {
            // Invalidate any prior timer first — onAppear can fire repeatedly,
            // and the old code leaked a new repeating Timer every time.
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Helpers

private extension ISO8601DateFormatter {
    static let lucid: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private extension JSONEncoder {
    static let lucid: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let lucid: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - HermesStatsSheet — cross-referenced dashboard

struct HermesPatternRow: Codable, Identifiable {
    let id: String
    let pattern_name: String
    let pattern_type: String?
    let matched: Bool?
    let correlation_r: Double?
    let n_samples: Int?
    let threshold: Double?
    let computed_at: String?
    let details: HermesPatternDetails?
}

struct HermesPatternDetails: Codable {
    let description: String?
    let lag_days: Int?
    let direction: String?
    let group_by: String?
    let eta_squared: Double?
    let effect_size_cohens_d: Double?
}

private struct HermesNowRow: Codable {
    let computed_at: String?
    let percentiles: [String: Double?]?
}

private struct HermesTaskRow: Codable, Identifiable {
    let id: String
    let title: String
    let energy_level: String?
    let priority: String?
    let project: String?
    let time_estimate_minutes: Int?
    let actual_duration_minutes: Int?
    let difficulty: Int?
    let completed_at: String?
    let status: String?
}

struct HermesStatsSheet: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss

    @State private var patterns: [HermesPatternRow] = []
    @State private var nowRows: [HermesNowRow] = []
    @State private var tasks: [HermesTaskRow] = []
    @State private var dumpCount30d: Int = 0
    @State private var emoCount30d: Int = 0
    @State private var isLoading = true
    @State private var error: String?
    @State private var showAllPatterns = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: DS.Spacing.lg) {
                    if isLoading && patterns.isEmpty {
                        loadingState
                    } else if let err = error {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.pink)
                            .padding(DS.Spacing.md)
                    } else {
                        bodyStateCard
                        matchedPatternsCard
                        allPatternsCard
                        taskStatsCard
                        contextStatsCard
                    }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.md)
            }
            .background(DS.Colors.bg.ignoresSafeArea())
            .navigationTitle("Hermes Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await loadAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await loadAll() }
        }
        .task { await loadAll() }
    }

    private var loadingState: some View {
        VStack(spacing: DS.Spacing.md) {
            ProgressView()
                .scaleEffect(1.1)
            Text("Loading patterns…")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // ── Body state HRV percentile sparkline ────────────────────────────
    private var bodyStateCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader(icon: "waveform.path.ecg", title: "HRV PERCENTILE", subtitle: "last \(nowRows.count) snapshots")
            if nowRows.isEmpty {
                Text("No /now snapshots yet — tap the refresh button on the Hermes card to record one.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textFaint)
                    .padding(.vertical, DS.Spacing.sm)
            } else {
                let pts = nowRows.compactMap { $0.percentiles?["hrv"] ?? nil }
                Sparkline(values: pts, height: 60, color: DS.Colors.violet)
                    .padding(.vertical, DS.Spacing.sm)
                HStack {
                    StatChip(label: "LATEST", value: pts.last.map { "\(Int($0))" } ?? "—", suffix: "%ile", color: DS.Colors.violet)
                    Spacer()
                    StatChip(label: "AVG", value: pts.isEmpty ? "—" : "\(Int(pts.reduce(0, +) / Double(pts.count)))", suffix: "%ile", color: DS.Colors.teal)
                    Spacer()
                    StatChip(label: "LOW", value: pts.min().map { "\(Int($0))" } ?? "—", suffix: "%ile", color: DS.Colors.pink)
                }
            }
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
    }

    // ── Matched patterns (the headline insights) ──────────────────────
    private var matchedPatternsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            let matched = patterns.filter { $0.matched == true }
            cardHeader(icon: "sparkle.magnifyingglass", title: "MATCHED PATTERNS", subtitle: "\(matched.count) detected")
            if matched.isEmpty {
                Text("No patterns matched yet. Engine needs more days of overlapping data — pattern minimum n is 30+.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textFaint)
                    .padding(.vertical, DS.Spacing.sm)
            } else {
                VStack(spacing: DS.Spacing.sm) {
                    ForEach(matched.prefix(10)) { p in
                        PatternRowView(pattern: p, isMatched: true)
                    }
                }
            }
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
    }

    // ── All patterns (collapsed by default) ────────────────────────────
    private var allPatternsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showAllPatterns.toggle()
                }
            } label: {
                HStack {
                    cardHeader(icon: "list.bullet.below.rectangle", title: "ALL PATTERN RUNS", subtitle: "\(patterns.count) total")
                    Spacer()
                    Image(systemName: showAllPatterns ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Colors.textFaint)
                }
            }
            .buttonStyle(.plain)

            if showAllPatterns {
                VStack(spacing: DS.Spacing.sm) {
                    ForEach(patterns) { p in
                        PatternRowView(pattern: p, isMatched: p.matched == true)
                    }
                }
            }
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
    }

    // ── Task stats ─────────────────────────────────────────────────────
    private var taskStatsCard: some View {
        let completed = tasks.filter { $0.completed_at != nil }
        let totalEst = completed.compactMap { $0.time_estimate_minutes }.reduce(0, +)
        let actualTracked = completed.compactMap { $0.actual_duration_minutes }
        let avgActual = actualTracked.isEmpty ? 0 : (actualTracked.reduce(0, +) / actualTracked.count)
        let byEnergy = Dictionary(grouping: completed) { $0.energy_level ?? "unset" }
        let byPriority = Dictionary(grouping: completed) { $0.priority ?? "unset" }
        let byProject = Dictionary(grouping: completed) { $0.project ?? "unset" }
            .sorted { $0.value.count > $1.value.count }.prefix(5)

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader(icon: "checkmark.circle.fill", title: "TASKS", subtitle: "last 30 days · \(completed.count) completed")

            HStack(spacing: DS.Spacing.sm) {
                StatChip(label: "DONE", value: "\(completed.count)", suffix: "", color: DS.Colors.violet)
                Spacer()
                StatChip(label: "EST", value: "\(totalEst / 60)", suffix: "h", color: DS.Colors.teal)
                Spacer()
                StatChip(label: "AVG ACTUAL", value: actualTracked.isEmpty ? "—" : "\(avgActual)", suffix: actualTracked.isEmpty ? "" : "m", color: DS.Colors.amber)
            }

            // Energy breakdown bar
            if !byEnergy.isEmpty {
                Text("BY ENERGY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(DS.Colors.textFaint)
                    .padding(.top, DS.Spacing.sm)
                ForEach(byEnergy.keys.sorted(), id: \.self) { key in
                    HStack(spacing: DS.Spacing.sm) {
                        Text(key)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .frame(width: 70, alignment: .leading)
                        ProgressBar(value: Double(byEnergy[key]!.count) / Double(max(1, completed.count)),
                                    color: energyColor(key))
                        Text("\(byEnergy[key]!.count)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }

            // Priority + Project chips
            HStack(spacing: DS.Spacing.sm) {
                Text("BY PRIORITY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(DS.Colors.textFaint)
                Spacer()
            }
            .padding(.top, DS.Spacing.sm)
            HStack(spacing: 6) {
                ForEach(byPriority.keys.sorted(), id: \.self) { k in
                    Text("\(k) · \(byPriority[k]!.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 4)
                        .background(DS.Colors.surfaceElevated)
                        .clipShape(Capsule())
                }
                Spacer()
            }

            if !byProject.isEmpty {
                Text("TOP PROJECTS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(DS.Colors.textFaint)
                    .padding(.top, DS.Spacing.sm)
                VStack(spacing: 4) {
                    ForEach(Array(byProject), id: \.key) { kv in
                        HStack {
                            Text(kv.key)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(DS.Colors.textSecondary)
                            Spacer()
                            Text("\(kv.value.count) tasks")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DS.Colors.textFaint)
                        }
                    }
                }
            }

            if actualTracked.isEmpty {
                Text("Tip: actual time and difficulty get tracked when you complete a task via the timer (coming next session).")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DS.Colors.textFaint)
                    .padding(.top, DS.Spacing.sm)
            }
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
    }

    // ── Context activity (brain dumps + emotions count) ───────────────
    private var contextStatsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader(icon: "scribble.variable", title: "CONTEXT (LAST 30D)", subtitle: "feeds Hermes interpretations")
            HStack(spacing: DS.Spacing.md) {
                StatChip(label: "BRAIN DUMPS", value: "\(dumpCount30d)", suffix: "", color: DS.Colors.amber)
                StatChip(label: "EMOTIONS", value: "\(emoCount30d)", suffix: "", color: DS.Colors.pink)
                StatChip(label: "/NOW LOGS", value: "\(nowRows.count)", suffix: "", color: DS.Colors.teal)
            }
        }
        .padding(DS.Spacing.lg)
        .glassDefault()
    }

    // ── Helpers ─────────────────────────────────────────────────────────
    private func cardHeader(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.Colors.violet)
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(DS.Colors.violet)
            if let s = subtitle {
                Text("·")
                    .foregroundStyle(DS.Colors.textFaint)
                Text(s)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textFaint)
            }
        }
    }

    private func energyColor(_ k: String) -> Color {
        switch k.lowercased() {
        case "high": return DS.Colors.pink
        case "medium": return DS.Colors.amber
        case "low": return DS.Colors.teal
        default: return DS.Colors.textFaint
        }
    }

    // ── Data loading ────────────────────────────────────────────────────
    private func loadAll() async {
        await MainActor.run { isLoading = true; error = nil }
        let supabase = bleManager.supabase
        let userId = supabase.userId
        let auth = supabase.accessToken ?? supabase.anonKey
        let base = supabase.baseURL
        let anon = supabase.anonKey

        async let patternsTask = restGet(
            url: "\(base)/rest/v1/hermes_pattern_matches?select=*&order=computed_at.desc&limit=80",
            auth: auth, anon: anon, type: [HermesPatternRow].self
        )
        async let nowTask = restGet(
            url: "\(base)/rest/v1/hermes_now_snapshots?select=computed_at,percentiles&order=computed_at.desc&limit=30",
            auth: auth, anon: anon, type: [HermesNowRow].self
        )
        let thirtyDaysAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86400))
        async let tasksTask = restGet(
            url: "\(base)/rest/v1/tasks?user_id=eq.\(userId)&select=id,title,energy_level,priority,project,time_estimate_minutes,actual_duration_minutes,difficulty,completed_at,status&completed_at=gte.\(thirtyDaysAgo)&order=completed_at.desc&limit=200",
            auth: auth, anon: anon, type: [HermesTaskRow].self
        )
        async let dumpCountTask = restCount(
            url: "\(base)/rest/v1/brain_dumps?user_id=eq.\(userId)&created_at=gte.\(thirtyDaysAgo)",
            auth: auth, anon: anon
        )
        async let emoCountTask = restCount(
            url: "\(base)/rest/v1/emotional_snapshots?user_id=eq.\(userId)&created_at=gte.\(thirtyDaysAgo)",
            auth: auth, anon: anon
        )

        do {
            let (p, n, t, dc, ec) = try await (patternsTask, nowTask, tasksTask, dumpCountTask, emoCountTask)
            await MainActor.run {
                patterns = p
                nowRows = n.reversed()  // oldest → newest for chart
                tasks = t
                dumpCount30d = dc
                emoCount30d = ec
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = (error as NSError).localizedDescription
                self.isLoading = false
            }
        }
    }

    private func restGet<T: Decodable>(url: String, auth: String, anon: String, type: T.Type) async throws -> T {
        guard let u = URL(string: url) else { throw NSError(domain: "Hermes", code: -1) }
        var req = URLRequest(url: u)
        req.setValue(anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 300 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Hermes", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "REST GET \(url.suffix(60)) failed: \(body.prefix(200))"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func restCount(url: String, auth: String, anon: String) async throws -> Int {
        guard let u = URL(string: "\(url)&select=id&limit=1") else { return 0 }
        var req = URLRequest(url: u)
        req.setValue(anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("count=exact", forHTTPHeaderField: "Prefer")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              let cr = http.value(forHTTPHeaderField: "content-range")?.split(separator: "/").last else { return 0 }
        return Int(cr) ?? 0
    }
}

// MARK: - Small reusable widgets for the stats sheet

private struct StatChip: View {
    let label: String
    let value: String
    let suffix: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(DS.Colors.textFaint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textFaint)
                }
            }
        }
    }
}

private struct ProgressBar: View {
    let value: Double   // 0..1
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DS.Colors.surfaceElevated)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * value))
            }
        }
        .frame(height: 6)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let height: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let pts = mapPoints(in: geo.size)
            ZStack {
                // baseline 50th percentile
                Path { p in
                    let y = geo.size.height / 2
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(DS.Colors.textFaint.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // line
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // last-point dot
                if let last = pts.last {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .position(last)
                }
            }
        }
        .frame(height: height)
    }

    private func mapPoints(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let minV: Double = 0
        let maxV: Double = 100
        let range = max(1.0, maxV - minV)
        return values.enumerated().map { (i, v) in
            let x = values.count == 1 ? size.width / 2 : (CGFloat(i) / CGFloat(values.count - 1)) * size.width
            let y = size.height - CGFloat((v - minV) / range) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

private struct PatternRowView: View {
    let pattern: HermesPatternRow
    let isMatched: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Circle()
                .fill(isMatched ? DS.Colors.violet : DS.Colors.textFaint.opacity(0.25))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(pattern.pattern_name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
                if let desc = pattern.details?.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(DS.Colors.textFaint)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(strengthLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isMatched ? DS.Colors.violet : DS.Colors.textSecondary)
                    if let n = pattern.n_samples {
                        Text("n=\(n)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(DS.Colors.textFaint)
                    }
                    if let when = relativeTimeAgo {
                        Text("· \(when)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.textFaint)
                    }
                    Spacer()
                }
            }
        }
    }

    private var strengthLabel: String {
        guard let r = pattern.correlation_r else { return "—" }
        switch pattern.pattern_type {
        case "stratified_anova": return String(format: "η²=%.3f", r)
        case "t_test_two_sample": return String(format: "d=%+.2f", r)
        default: return String(format: "r=%+.3f", r)
        }
    }

    private var relativeTimeAgo: String? {
        guard let iso = pattern.computed_at,
              let date = ISO8601DateFormatter.lucid.date(from: iso) else { return nil }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        if secs < 86400 * 7 { return "\(secs / 86400)d ago" }
        return "\(secs / (86400 * 7))w ago"
    }
}
