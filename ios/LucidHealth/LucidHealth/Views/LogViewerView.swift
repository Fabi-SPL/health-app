import SwiftUI

/// On-phone log viewer — replaces Mac/Console.app for users who don't
/// own a Mac (e.g. Fabi, who builds via GitHub Actions on a CI Mac).
///
/// Reads `LucidLog.read()` and shows the last 500 lines from the shared
/// log file. Filterable by tag (LucidWidget, SharedHealthData, BLE...)
/// via a chip row. Auto-refreshes every 2 seconds while open.
///
/// Use case: debug widgets stuck on zero, BLE drops, sleep boundary
/// detection, anywhere we used to NSLog. Tap the share icon to copy
/// the visible lines for pasting into chat.
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var filter: String = "ALL"
    @State private var refreshTimer: Timer?

    private var availableTags: [String] {
        var tags = Set<String>()
        tags.insert("ALL")
        for line in lines {
            // Format: [timestamp] [tag] message
            if let openIdx = line.range(of: "] [")?.upperBound,
               let closeIdx = line.range(of: "] ", range: openIdx..<line.endIndex)?.lowerBound {
                let tag = String(line[openIdx..<closeIdx])
                tags.insert(tag)
            }
        }
        return tags.sorted()
    }

    private var filteredLines: [String] {
        if filter == "ALL" { return lines }
        return lines.filter { $0.contains("[\(filter)]") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tagFilterRow
                    .padding(.vertical, DS.Spacing.sm)
                    .background(DS.Colors.raised)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if filteredLines.isEmpty {
                                emptyState
                            } else {
                                ForEach(Array(filteredLines.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                                        .foregroundStyle(colorForLine(line))
                                        .padding(.horizontal, DS.Spacing.md)
                                        .padding(.vertical, 3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                                Color.clear.frame(height: DS.Spacing.lg).id("bottom")
                            }
                        }
                    }
                    .onChange(of: filteredLines.count) { _, _ in
                        // Auto-scroll to bottom when new lines arrive (tail -f)
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .background(AuroraBackground().ignoresSafeArea())
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(DS.Colors.violet)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = filteredLines.joined(separator: "\n")
                            let h = UINotificationFeedbackGenerator()
                            h.notificationOccurred(.success)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DS.Colors.teal)
                        }
                        Button {
                            LucidLog.clear()
                            refresh()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DS.Colors.danger)
                        }
                    }
                }
            }
            .onAppear {
                refresh()
                refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    refresh()
                }
            }
            .onDisappear {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
        }
    }

    private var tagFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableTags, id: \.self) { tag in
                    let isOn = filter == tag
                    Button {
                        let h = UIImpactFeedbackGenerator(style: .light)
                        h.impactOccurred()
                        filter = tag
                    } label: {
                        Text(tag)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isOn ? .white : DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isOn ? DS.Colors.violet : DS.Colors.surface)
                                    .overlay(Capsule().stroke(DS.Colors.border, lineWidth: isOn ? 0 : 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(DS.Colors.textMuted)
            Text("No logs yet")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("Open the app for a few seconds. Widget logs appear after the next timeline reload (~5-15 min).")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func refresh() {
        lines = LucidLog.read()
    }

    private func colorForLine(_ line: String) -> Color {
        if line.contains("FAILED") || line.contains("error") || line.contains("denied") {
            return DS.Colors.danger
        }
        if line.contains("[LucidWidget]") {
            return DS.Colors.teal
        }
        if line.contains("[SharedHealthData]") {
            return DS.Colors.violet
        }
        return DS.Colors.textSecondary
    }
}
