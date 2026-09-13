import Foundation
import UIKit
import UserNotifications
import AVFoundation

/// Listens for pending nudges in Supabase and fires native iOS notifications.
/// Polls every 30s when foreground, and on every BLE background wake event.
/// Replaces the flaky web push path for delivering Claude-session notifications
/// (notify-fabi skill) and any other `channels` contains 'push' nudges.
///
/// Design:
/// - Polling (not Realtime) because SupabaseClient is pure URLSession — no WS SDK
/// - Deduplication via UserDefaults so reconnects don't double-fire
/// - Marks `status = 'delivered'` + `delivered_at = NOW()` after successful UN dispatch
/// - Uses .timeSensitive interruption level so banners appear while phone is in Focus
class NotificationListener {
    private let supabase: SupabaseClient
    private var pollTimer: Timer?
    private var isPolling = false

    // Dedup key — tracks UUIDs of nudges already fired this session
    private let firedKey = "lucid_notification_listener_fired_ids"
    private let firedCapacity = 200

    // On-screen logger — set by app delegate
    var onLog: ((String) -> Void)?

    init(supabase: SupabaseClient) {
        self.supabase = supabase

        // Listen for BLE background wakes — piggyback on existing infra
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onBackgroundWake),
            name: .lucidReconnectBLE,
            object: nil
        )
    }

    private func log(_ msg: String) {
        let full = "[Notify] \(msg)"
        print(full)
        onLog?(full)
    }

    // MARK: - Lifecycle

    /// Start polling. Call once on app launch.
    func start() {
        log("Starting listener — poll every 30s")
        // On first launch (empty dedup set), prime UserDefaults with current
        // recent nudges WITHOUT firing them. Prevents a banner-storm of stale
        // rows from the pre-install window.
        Task {
            let isFirstRun = loadFiredIds().isEmpty
            if isFirstRun {
                log("First launch — priming dedup set without firing")
                await primeDedup()
            } else {
                await poll()
            }
        }
        // Then periodic timer
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    /// First-launch seed: mark all currently-visible push nudges as already
    /// seen so we don't fire a pile of banners from the last 5 min of history.
    private func primeDedup() async {
        do {
            let existing = try await supabase.fetchPendingNudges()
            let ids = existing.map { $0.id }
            saveFiredIds(Array(ids.suffix(firedCapacity)))
            log("Primed dedup with \(ids.count) existing nudge ID(s) — no banners fired")
        } catch {
            log("Prime failed: \(error.localizedDescription) — will poll normally")
            await poll()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func onBackgroundWake() {
        // BLE background wake — grab any pending notifications that piled up
        log("BLE background wake — polling for pending nudges")
        Task { await poll() }
    }

    // MARK: - Core Poll

    private func poll() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        do {
            let pending = try await supabase.fetchPendingNudges()
            if pending.isEmpty { return }
            log("Found \(pending.count) pending nudge(s)")

            var firedIds = loadFiredIds()

            for nudge in pending {
                // Dedup guard — never fire same ID twice across app restarts
                if firedIds.contains(nudge.id) {
                    log("Skipping already-fired \(nudge.id.prefix(8))")
                    continue
                }

                await fire(nudge: nudge)
                firedIds.append(nudge.id)

                // Cap stored IDs to avoid unbounded UserDefaults growth
                if firedIds.count > firedCapacity {
                    firedIds = Array(firedIds.suffix(firedCapacity))
                }
                saveFiredIds(firedIds)

                // Mark delivered in DB (async, don't block the loop)
                Task {
                    try? await supabase.markNudgeDelivered(id: nudge.id)
                }
            }
        } catch {
            log("Poll error: \(error.localizedDescription)")
        }
    }

    // MARK: - Fire Local Notification

    /// Reads the user-selected Health sound from UserDefaults. Two custom
    /// sounds ship in the bundle (`lucid-warm.caf`, `lucid-halo.caf`) — derived
    /// from the iPhone notification source so they keep that clean character
    /// while being instantly recognizable as Health (not iMessage).
    /// Default = "warm". Falls back to `.default` if pref says "system".
    static func lucidSound() -> UNNotificationSound {
        let pref = UserDefaults.standard.string(forKey: "lucid_notification_sound") ?? "warm"
        switch pref {
        case "halo":   return UNNotificationSound(named: UNNotificationSoundName("lucid-halo.caf"))
        case "warm":   return UNNotificationSound(named: UNNotificationSoundName("lucid-warm.caf"))
        case "system": return .default
        default:       return UNNotificationSound(named: UNNotificationSoundName("lucid-warm.caf"))
        }
    }

    /// Plays the currently-selected ringtone via AVAudioPlayer so the user can
    /// preview from Settings without firing a real notification. System pref =
    /// no preview (no AVPlayer-accessible default), shows brief silence.
    private static var previewPlayer: AVAudioPlayer?

    static func previewSound() {
        let pref = UserDefaults.standard.string(forKey: "lucid_notification_sound") ?? "warm"
        let resource: String? = {
            switch pref {
            case "warm": return "lucid-warm"
            case "halo": return "lucid-halo"
            default:     return nil
            }
        }()

        guard let resource,
              let url = Bundle.main.url(forResource: resource, withExtension: "caf") else {
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.prepareToPlay()
            previewPlayer?.play()
        } catch {
            print("Health sound preview failed: \(error.localizedDescription)")
        }
    }

    private func fire(nudge: PendingNudge) async {
        let content = UNMutableNotificationContent()
        content.title = nudge.title ?? "Health"
        content.body = nudge.message

        if nudge.isSmartWake {
            // v154 wake alarm — highest interruption + critical sound so it
            // pierces silent/DND/Focus. The banner alone won't wake a sleeping
            // person; the strap-buzz actuator (posted below) is the real wake.
            content.sound = .defaultCritical
            content.interruptionLevel = .critical
            content.categoryIdentifier = "LUCID_ALARM"
            var info: [String: Any] = ["nudge_id": nudge.id, "source": "lucid-smart-wake"]
            if let sid = nudge.sessionId { info["session_id"] = sid }
            if let reason = nudge.reason { info["reason"] = reason }
            content.userInfo = info
        } else {
            content.sound = nudge.priority == "voice" ? .defaultCritical : Self.lucidSound()
            content.interruptionLevel = nudge.priority == "voice" ? .critical : .timeSensitive
            content.userInfo = ["nudge_id": nudge.id, "source": "lucid-bridge"]
        }

        let request = UNNotificationRequest(
            identifier: "nudge-\(nudge.id)",
            content: content,
            trigger: nil  // fire immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            log("Fired notification: \(nudge.title ?? "Health") — \(String(nudge.message.prefix(40)))")
        } catch {
            log("Failed to fire notification: \(error.localizedDescription)")
        }

        // v154: hand off to BLEManager to actually WAKE him — buzz the strap on
        // his wrist. Decoupled via NotificationCenter so this listener never
        // needs a BLEManager reference. Dedup upstream (fired-ids) guarantees
        // this posts at most once per nudge; the actuator is idempotent too.
        if nudge.isSmartWake {
            var meta: [String: Any] = ["nudge_id": nudge.id]
            if let sid = nudge.sessionId { meta["session_id"] = sid }
            if let reason = nudge.reason { meta["reason"] = reason }
            NotificationCenter.default.post(name: .lucidSmartWakeFire, object: nil, userInfo: meta)
            log("Posted .lucidSmartWakeFire — session=\(nudge.sessionId?.prefix(8) ?? "?") reason=\(nudge.reason ?? "?")")
        }
    }

    // MARK: - Dedup Persistence

    private func loadFiredIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: firedKey) ?? []
    }

    private func saveFiredIds(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: firedKey)
    }
}

/// Minimal DTO for a pending nudge row.
///
/// The v154 smart-wake fields are all optional so every existing nudge row
/// (Claude-session pushes, mood reminders, etc.) decodes exactly as before —
/// they simply leave the new fields nil / false.
struct PendingNudge {
    let id: String
    let title: String?
    let message: String
    let priority: String  // voice | visual | silent | alarm
    let channels: [String]
    // v154 smart-wake extensions (from `source` + jsonb `metadata`)
    var source: String? = nil       // e.g. "health"
    var metaKind: String? = nil     // metadata.kind — "smart_wake" for a v154 fire
    var sessionId: String? = nil    // metadata.session_id
    var reason: String? = nil       // metadata.reason (recovered_early | target_reached | …)
    /// True only for a real v154 smart-wake row. `priority == "alarm"` alone is
    /// not enough — any nudge source can set it, and that fired the wake actuator.
    var isSmartWake: Bool { metaKind == "smart_wake" }
}
