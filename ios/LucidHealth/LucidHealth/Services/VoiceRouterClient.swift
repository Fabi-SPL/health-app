import Foundation

/// Sends transcripts to the Hetzner /voice-route endpoint for AI classification.
/// The backend cascades Gemini → DeepSeek → Qwen, classifies the transcript into
/// intents (task / event / brain_dump / mood / habit / note), and writes the
/// resulting rows directly to Supabase. iOS just shows the returned summary.
///
/// Token is stored in UserDefaults under `lucidhealth_voice_token` — mirrors the
/// existing `lucidhealth_email` / `lucidhealth_password` pattern. Set it once
/// from SettingsView (or directly via UserDefaults during initial bring-up).
final class VoiceRouterClient {

    static let shared = VoiceRouterClient()

    // Endpoint is overridable via env var (LUCID_VOICE_ROUTER_URL) for dev,
    // or Info.plist key VOICE_ROUTER_URL for CI-injected builds. Defaults to
    // the production tunnel hostname.
    private let endpoint: String = {
        if let env = ProcessInfo.processInfo.environment["LUCID_VOICE_ROUTER_URL"], !env.isEmpty { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "VOICE_ROUTER_URL") as? String, !plist.isEmpty { return plist }
        return "https://voice.speed-running-life.com/voice-route"
    }()

    private var token: String {
        UserDefaults.standard.string(forKey: "lucidhealth_voice_token") ?? ""
    }

    struct VoiceRouteResult {
        let success: Bool
        let summary: String
        let intents: [[String: Any]]
        let rawResponse: String?
    }

    func route(transcript: String) async -> VoiceRouteResult {
        guard !token.isEmpty else {
            return .init(
                success: false,
                summary: "⚠️ No voice router token. Set lucidhealth_voice_token in Settings.",
                intents: [],
                rawResponse: nil
            )
        }
        guard let url = URL(string: endpoint) else {
            return .init(success: false, summary: "⚠️ Invalid voice router URL", intents: [], rawResponse: nil)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "transcript": transcript,
            "timezone": TimeZone.current.identifier,
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .init(success: false, summary: "⚠️ Encode failed", intents: [], rawResponse: nil)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let raw = String(data: data, encoding: .utf8)
            guard status < 300 else {
                return .init(success: false, summary: "⚠️ HTTP \(status)", intents: [], rawResponse: raw)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .init(success: false, summary: "⚠️ Bad response shape", intents: [], rawResponse: raw)
            }
            let summary = (json["summary"] as? String) ?? "✅ Routed"
            let intents = (json["intents"] as? [[String: Any]]) ?? []
            return .init(success: true, summary: summary, intents: intents, rawResponse: raw)
        } catch {
            return .init(success: false, summary: "⚠️ \(error.localizedDescription)", intents: [], rawResponse: nil)
        }
    }
}
