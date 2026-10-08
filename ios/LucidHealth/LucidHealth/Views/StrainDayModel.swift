import Foundation
import SwiftUI

// MARK: - Model types

enum StrainBlockKind: String {
    case ride, work, play, rest, unknown
}

struct StrainDayBlock: Identifiable {
    let id: String
    var name: String
    var short: String
    var drainName: String
    var kind: StrainBlockKind
    var icon: String
    var start: Date
    var end: Date
    var activity: ActivityEvent? = nil
    var trimp: Double = 0
    var hrAvg: Double? = nil
    var strainAdded: Double = 0
    var strainAfter: Double = 0
    var loadShare: Double = 0
    var batteryStart: Double? = nil
    var batteryEnd: Double? = nil

    var minutes: Double { end.timeIntervalSince(start) / 60 }

    var drained: Double {
        guard let a = batteryStart, let b = batteryEnd else { return 0 }
        return max(0, a - b)
    }
}

struct StrainHRPoint: Identifiable {
    let at: Date
    let bpm: Double
    var id: Date { at }
}

struct StrainBatteryPoint: Identifiable {
    let at: Date
    let value: Double
    var id: Date { at }
}

struct StrainDayData {
    var day = Date()
    var nextDay = Date()
    var isToday = false
    var wake = Date()
    var end = Date()
    var hr: [StrainHRPoint] = []
    var blocks: [StrainDayBlock] = []
    var battery: [StrainBatteryPoint] = []
    var batteryLive = false
    var rhr: Double? = nil
    var dayTrimp: Double? = nil
    var dayStrain: Double? = nil
    var recovery: Double? = nil
    var recoveryNext: Double? = nil
    var physical: Double? = nil
    var stress: Double? = nil
    var autonomic: Double? = nil
    var acwr: Double? = nil
    var monotony: Double? = nil
    var vo2: Double? = nil
    var zoneMinutes: [Double] = [0, 0, 0, 0, 0]

    var windowMinutes: Double { max(0, end.timeIntervalSince(wake) / 60) }
    var hasHR: Bool { !hr.isEmpty && windowMinutes >= 10 && dayStrain != nil }
    var hasBattery: Bool { battery.count > 1 }
    var belowZoneMinutes: Double { max(0, windowMinutes - zoneMinutes.reduce(0, +)) }
    var topBlock: StrainDayBlock? { blocks.max(by: { $0.trimp < $1.trimp }) }
    var peak: StrainHRPoint? { hr.max(by: { $0.bpm < $1.bpm }) }
    var batteryAtWake: Double? { battery.first?.value }
    var batteryAtEnd: Double? { battery.last?.value }

    var partsVisible: Bool {
        guard let p = physical, let s = stress, let a = autonomic else { return false }
        return p + s + a > 0
    }
}

// MARK: - Parsing

enum StrainParse {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    static func iso(_ d: Date) -> String { isoPlain.string(from: d) }

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func pos(_ v: Any?) -> Double? {
        if let d = num(v), d > 0 { return d }
        return nil
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Network

enum StrainDayAPI {
    static func rows(_ table: String, _ items: [URLQueryItem]) async -> [[String: Any]] {
        do {
            let client = SupabaseClient.shared
            try await client.ensureAuth()
            guard let token = client.accessToken else { return [] }
            guard var comps = URLComponents(string: "\(client.baseURL)/rest/v1/\(table)") else { return [] }
            comps.queryItems = items
            guard let url = comps.url else { return [] }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 25
            req.setValue(client.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 300 { return [] }
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            return parsed ?? []
        } catch {
            return []
        }
    }

    // One 15 minute slice: the mean of its readings, or nothing.
    static func sliceAverage(uid: String, from a: Date, to b: Date) async -> [StrainHRPoint] {
        var sum = 0.0
        var n = 0
        var offset = 0
        while offset < 3000 {
            if Task.isCancelled { return [] }
            let items: [URLQueryItem] = [
                URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                URLQueryItem(name: "recorded_at", value: "gte.\(StrainParse.iso(a))"),
                URLQueryItem(name: "recorded_at", value: "lt.\(StrainParse.iso(b))"),
                URLQueryItem(name: "select", value: "heart_rate"),
                URLQueryItem(name: "order", value: "recorded_at.asc"),
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            let page = await rows("realtime_health", items)
            for r in page {
                if let v = StrainParse.num(r["heart_rate"]), v > 30, v <= 220 {
                    sum += v
                    n += 1
                }
            }
            if page.count < 1000 { break }
            offset += 1000
        }
        if n == 0 { return [] }
        return [StrainHRPoint(at: a, bpm: sum / Double(n))]
    }

    // v115: the server averages the 15 minute slices (strain_hr_slices, v202) in one GET, instead of one
    // request per slice over every raw 1 Hz row (~80k rows a day). nil means fall back to the slices.
    static func hrSlicesServer(from: Date, to: Date) async -> [StrainHRPoint]? {
        do {
            let client = SupabaseClient.shared
            try await client.ensureAuth()
            guard let token = client.accessToken,
                  var comps = URLComponents(string: "\(client.baseURL)/rest/v1/rpc/strain_hr_slices") else { return nil }
            comps.queryItems = [
                URLQueryItem(name: "p_from", value: StrainParse.iso(from)),
                URLQueryItem(name: "p_to", value: StrainParse.iso(to))
            ]
            guard let url = comps.url else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 25
            req.setValue(client.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode < 300,
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            var out: [StrainHRPoint] = []
            for r in parsed {
                if let at = StrainParse.date(r["at"]), let bpm = StrainParse.num(r["bpm"]) {
                    out.append(StrainHRPoint(at: at, bpm: bpm))
                }
            }
            return out.sorted { $0.at < $1.at }
        } catch {
            return nil
        }
    }

    static func fetchHR(uid: String, from: Date, to: Date) async -> [StrainHRPoint] {
        if let server = await hrSlicesServer(from: from, to: to) { return server }
        var starts: [Date] = []
        var t = from
        while t < to {
            starts.append(t)
            t = t.addingTimeInterval(900)
        }
        if starts.isEmpty { return [] }
        let slices = starts
        let maxInFlight = 6
        let pts: [StrainHRPoint] = await withTaskGroup(of: [StrainHRPoint].self) { group -> [StrainHRPoint] in
            var out: [StrainHRPoint] = []
            var next = 0
            while next < slices.count && next < maxInFlight {
                let s = slices[next]
                group.addTask { await StrainDayAPI.sliceAverage(uid: uid, from: s, to: s.addingTimeInterval(900)) }
                next += 1
            }
            while let part = await group.next() {
                out.append(contentsOf: part)
                if next < slices.count {
                    let s = slices[next]
                    group.addTask { await StrainDayAPI.sliceAverage(uid: uid, from: s, to: s.addingTimeInterval(900)) }
                    next += 1
                }
            }
            return out
        }
        return pts.sorted { $0.at < $1.at }
    }

    static func fetchActivities(uid: String, from: Date, to: Date) async -> [ActivityEvent] {
        let items: [URLQueryItem] = [
            URLQueryItem(name: "user_id", value: "eq.\(uid)"),
            URLQueryItem(name: "started_at", value: "gte.\(StrainParse.iso(from))"),
            URLQueryItem(name: "started_at", value: "lt.\(StrainParse.iso(to))"),
            URLQueryItem(name: "order", value: "started_at"),
            URLQueryItem(name: "limit", value: "300")
        ]
        let page = await rows("activities", items)
        var result: [ActivityEvent] = []
        for row in page {
            guard let id = row["id"] as? String,
                  let type = row["activity_type"] as? String,
                  let source = row["source"] as? String,
                  let startDate = StrainParse.date(row["started_at"]) else { continue }
            let ev = ActivityEvent(
                id: id,
                activityType: type,
                source: source,
                startedAt: startDate,
                endedAt: StrainParse.date(row["ended_at"]),
                hrAvg: row["hr_avg"] as? Int,
                hrvAvg: row["hrv_avg"] as? Double,
                notes: row["notes"] as? String,
                eventCategory: row["event_category"] as? String ?? "physical"
            )
            result.append(ev)
        }
        return result
    }

    static func loadDay(day: Date, rhrFallback: Double?, monotonyFallback: Double?, vo2Fallback: Double?) async -> StrainDayData {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: day)
        let nextStart = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let isToday = cal.isDate(dayStart, inSameDayAs: now)
        let uid = SupabaseClient.shared.userId

        var out = StrainDayData()
        out.day = dayStart
        out.nextDay = nextStart
        out.isToday = isToday

        let keyA = StrainParse.dayKey(dayStart)
        let keyB = StrainParse.dayKey(nextStart)
        let metricItems: [URLQueryItem] = [
            URLQueryItem(name: "user_id", value: "eq.\(uid)"),
            URLQueryItem(name: "metric_date", value: "gte.\(keyA)"),
            URLQueryItem(name: "metric_date", value: "lte.\(keyB)"),
            URLQueryItem(name: "select", value: "metric_date,recovery_score,strain_physical,strain_stress,strain_autonomic,resting_hr,acwr,training_monotony,vo2max_estimate,sleep_start,sleep_end")
        ]
        let metricRows = await rows("health_metrics", metricItems)
        var rowA: [String: Any]? = nil
        var rowB: [String: Any]? = nil
        for r in metricRows {
            guard let md = r["metric_date"] as? String else { continue }
            let k = String(md.prefix(10))
            if k == keyA { rowA = r } else if k == keyB { rowB = r }
        }

        out.recovery = StrainParse.pos(rowA?["recovery_score"])
        out.recoveryNext = isToday ? nil : StrainParse.pos(rowB?["recovery_score"])
        out.physical = StrainParse.num(rowA?["strain_physical"])
        out.stress = StrainParse.num(rowA?["strain_stress"])
        out.autonomic = StrainParse.num(rowA?["strain_autonomic"])
        out.acwr = StrainParse.pos(rowA?["acwr"])
        out.monotony = StrainParse.pos(rowA?["training_monotony"]) ?? (isToday ? monotonyFallback : nil)
        out.vo2 = StrainParse.pos(rowA?["vo2max_estimate"]) ?? (isToday ? vo2Fallback : nil)

        var wake = dayStart.addingTimeInterval(7 * 3600)
        if let se = StrainParse.date(rowA?["sleep_end"]), cal.isDate(se, inSameDayAs: dayStart), se < now {
            wake = se
        } else if wake > now {
            wake = dayStart
        }

        var nextSleep: Date? = nil
        if !isToday, let ns = StrainParse.date(rowB?["sleep_start"]),
           ns >= wake.addingTimeInterval(7200), ns <= nextStart.addingTimeInterval(12 * 3600) {
            nextSleep = ns
        }

        let hrFrom = Date(timeIntervalSince1970: (wake.timeIntervalSince1970 / 900).rounded(.down) * 900)
        let nightCap = nextStart.addingTimeInterval(2 * 3600)
        let fetchTo = isToday ? now : min(now, nextSleep ?? nightCap)

        async let hrTask = fetchHR(uid: uid, from: hrFrom, to: fetchTo)
        async let actTask = fetchActivities(uid: uid, from: dayStart, to: fetchTo)
        let hrAll = await hrTask
        let acts = await actTask

        var end: Date
        if isToday {
            end = now
        } else if let ns = nextSleep {
            end = ns
        } else if let last = hrAll.last {
            end = min(last.at.addingTimeInterval(900), nightCap)
        } else {
            end = nightCap
        }
        end = max(end, wake.addingTimeInterval(1800))
        end = min(end, now)
        out.wake = wake
        out.end = end

        if end.timeIntervalSince(wake) < 600 { return out }

        let hr = hrAll.filter { $0.at.addingTimeInterval(900) > wake && $0.at < end }
        if hr.isEmpty { return out }

        var rhr = StrainParse.pos(rowA?["resting_hr"])
        if rhr == nil || (rhr ?? 0) <= 30 { rhr = rhrFallback }
        if rhr == nil || (rhr ?? 0) <= 30 { rhr = hr.map { $0.bpm }.min() }
        let rhrValue = rhr ?? 60
        out.rhr = rhrValue
        out.hr = hr

        var blocks = StrainDayBuilder.makeBlocks(acts: acts, wake: wake, end: end, cal: cal)

        var battery: [StrainBatteryPoint] = []
        var live = false
        if isToday {
            let series = await SupabaseClient.shared.fetchBodyBatterySeries()
            let inWindow = series.filter { $0.at >= wake && $0.at <= end }.sorted { $0.at < $1.at }
            let values = inWindow.map { $0.value }
            if inWindow.count >= 12,
               let hi = values.max(), let lo = values.min(),
               hi - lo >= 8, hi > 6 {
                battery = inWindow.map { StrainBatteryPoint(at: $0.at, value: $0.value) }
                live = true
            }
        }
        if !live, let rec = out.recovery {
            battery = StrainDayBuilder.modelBattery(hr: hr, wake: wake, end: end, start: rec, rhr: rhrValue)
        }
        out.battery = battery
        out.batteryLive = live

        let annotated = StrainDayBuilder.annotate(blocks: blocks, hr: hr, rhr: rhrValue, battery: battery)
        blocks = annotated.blocks
        out.blocks = blocks
        out.dayTrimp = annotated.dayTrimp
        out.dayStrain = StrainDayBuilder.strainAt(annotated.dayTrimp)
        out.zoneMinutes = StrainDayBuilder.zoneMinutes(hr: hr, wake: wake, end: end)
        return out
    }
}

// MARK: - Derivation

fileprivate struct StrainSeg {
    let act: ActivityEvent
    var s: Date
    var e: Date
}

enum StrainDayBuilder {
    static let zoneStarts: [Double] = [95, 115, 133, 152, 171]

    static func bucketTrimp(minutes: Double, bpm: Double, rhr: Double) -> Double {
        let hrr = min(max((bpm - rhr) / (190 - rhr), 0), 1)
        return minutes * hrr * 0.64 * exp(1.92 * hrr)
    }

    static func strainAt(_ cum: Double) -> Double {
        21 * (1 - exp(-max(0, cum) / 150))
    }

    // MARK: Activity types

    private static let rideTypes: Set<String> = ["motor_racing", "motorcycle", "riding", "ride", "bike", "biking", "cycling", "motorbike"]
    private static let exerciseTypes: Set<String> = ["exercise", "workout", "gym", "run", "running", "walk", "walking", "hike", "skiing", "stretching", "yoga", "swim", "sport", "cardio"]
    private static let workTypes: Set<String> = ["deep_work", "ee_work", "work", "coding", "pc_work", "reading"]
    private static let playTypes: Set<String> = ["gaming", "game", "social", "creative", "music", "tv", "youtube", "entertainment"]
    private static let restTypes: Set<String> = ["meal", "coffee", "nap", "meditation", "sauna", "cold_plunge", "sleep", "rest", "breakfast", "lunch", "dinner", "relax"]
    private static let nameOverrides: [String: String] = ["ee_work": "EE work", "pc_work": "PC work", "tv": "TV"]

    static func normalized(_ t: String) -> String {
        t.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    static func pretty(_ n: String) -> String {
        if let o = nameOverrides[n] { return o }
        let words = n.split(separator: "_").joined(separator: " ")
        guard let f = words.first else { return "Activity" }
        return f.uppercased() + String(words.dropFirst())
    }

    private static func tokenKind(_ n: String) -> StrainBlockKind {
        let tokens: [String] = n.split(separator: "_").map { String($0) }
        func has(_ stems: [String]) -> Bool {
            for t in tokens {
                for s in stems where t.hasPrefix(s) { return true }
            }
            return false
        }
        if has(["cycl", "bik", "rid", "motor"]) { return .ride }
        if has(["run", "walk", "hik", "swim", "gym", "yoga", "stretch", "workout", "exercis", "sport", "cardio", "lift", "ski", "train"]) { return .ride }
        if has(["work", "cod", "read", "study", "meeting", "call", "email", "writ"]) { return .work }
        if has(["gam", "social", "creativ", "music", "tv", "youtube", "movie", "entertain", "play"]) { return .play }
        return .rest
    }

    static func classify(_ rawType: String) -> (kind: StrainBlockKind, name: String, short: String, icon: String) {
        let n = normalized(rawType)
        if rideTypes.contains(n) {
            var name = "Ride"
            if n == "motor_racing" || n == "motorcycle" || n == "motorbike" {
                name = "Motorcycle ride"
            } else if n == "bike" || n == "biking" || n == "cycling" {
                name = "Bike ride"
            }
            return (.ride, name, "Ride", "bicycle")
        }
        if exerciseTypes.contains(n) { return (.ride, pretty(n), pretty(n), "figure.run") }
        if workTypes.contains(n) { return (.work, pretty(n), pretty(n), "chevron.left.forwardslash.chevron.right") }
        if playTypes.contains(n) { return (.play, pretty(n), pretty(n), "gamecontroller.fill") }
        if restTypes.contains(n) {
            let icon = n == "coffee" ? "cup.and.saucer.fill" : "fork.knife"
            return (.rest, pretty(n), pretty(n), icon)
        }
        let guess = tokenKind(n)
        switch guess {
        case .ride: return (.ride, pretty(n), pretty(n), "figure.run")
        case .work: return (.work, pretty(n), pretty(n), "chevron.left.forwardslash.chevron.right")
        case .play: return (.play, pretty(n), pretty(n), "gamecontroller.fill")
        default: return (.rest, pretty(n), pretty(n), "fork.knife")
        }
    }

    // MARK: Blocks

    static func makeBlocks(acts: [ActivityEvent], wake: Date, end: Date, cal: Calendar) -> [StrainDayBlock] {
        var segs: [StrainSeg] = []
        for a in acts {
            if a.endedAt == nil && end.timeIntervalSince(a.startedAt) > 3 * 3600 { continue }
            let rawEnd = a.endedAt ?? end
            let s = max(a.startedAt, wake)
            let e = min(rawEnd, end)
            if e.timeIntervalSince(s) < 300 { continue }
            segs.append(StrainSeg(act: a, s: s, e: e))
        }
        segs.sort { $0.s < $1.s }

        var cleaned: [StrainSeg] = []
        var cur = wake
        for var sg in segs {
            if sg.s < cur { sg.s = cur }
            if sg.e.timeIntervalSince(sg.s) < 300 { continue }
            cleaned.append(sg)
            cur = sg.e
        }

        var blocks: [StrainDayBlock] = []
        if cleaned.isEmpty {
            blocks = gapBlocks(from: wake, to: end, cal: cal)
        } else {
            var cursor = wake
            for sg in cleaned {
                var start = sg.s
                let gap = sg.s.timeIntervalSince(cursor)
                if gap >= 1200 {
                    blocks.append(contentsOf: gapBlocks(from: cursor, to: sg.s, cal: cal))
                } else if gap > 0 {
                    if blocks.isEmpty {
                        start = cursor
                    } else {
                        blocks[blocks.count - 1].end = sg.s
                    }
                }
                let info = classify(sg.act.activityType)
                var b = StrainDayBlock(
                    id: "act-\(sg.act.id)",
                    name: info.name,
                    short: info.short,
                    drainName: info.short,
                    kind: info.kind,
                    icon: info.icon,
                    start: start,
                    end: sg.e
                )
                b.activity = sg.act
                blocks.append(b)
                cursor = sg.e
            }
            let tail = end.timeIntervalSince(cursor)
            if tail >= 1200 {
                blocks.append(contentsOf: gapBlocks(from: cursor, to: end, cal: cal))
            } else if tail > 0 && !blocks.isEmpty {
                blocks[blocks.count - 1].end = end
            }
        }

        if let first = blocks.first, first.kind == .rest {
            blocks[0].icon = "cup.and.saucer.fill"
        }

        var counts: [String: Int] = [:]
        for b in blocks { counts[b.short, default: 0] += 1 }
        for i in blocks.indices {
            if (counts[blocks[i].short] ?? 0) > 1 {
                blocks[i].drainName = blocks[i].short + " " + V3Format.hhmm(blocks[i].start)
            }
        }
        return blocks
    }

    static func gapBlocks(from a: Date, to b: Date, cal: Calendar) -> [StrainDayBlock] {
        if b.timeIntervalSince(a) <= 0 { return [] }
        var cuts: [Date] = [a]
        var day = cal.startOfDay(for: a)
        var rounds = 0
        while day < b && rounds < 4 {
            for h in [5, 12, 17, 22] {
                if let c = cal.date(bySettingHour: h, minute: 0, second: 0, of: day), c > a, c < b {
                    cuts.append(c)
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? b
            rounds += 1
        }
        cuts.append(b)
        cuts.sort()

        var bounds: [Date] = [a]
        if cuts.count > 2 {
            for i in 1..<(cuts.count - 1) {
                let c = cuts[i]
                let left = c.timeIntervalSince(bounds[bounds.count - 1])
                let right = cuts[i + 1].timeIntervalSince(c)
                if left >= 1200 && right >= 1200 { bounds.append(c) }
            }
        }
        bounds.append(b)

        var result: [StrainDayBlock] = []
        for i in 0..<(bounds.count - 1) {
            let s = bounds[i]
            let e = bounds[i + 1]
            let mid = Date(timeIntervalSince1970: (s.timeIntervalSince1970 + e.timeIntervalSince1970) / 2)
            let hour = cal.component(.hour, from: mid)
            var part = "Late night"
            if hour >= 5 && hour < 12 {
                part = "Morning"
            } else if hour >= 12 && hour < 17 {
                part = "Afternoon"
            } else if hour >= 17 && hour < 22 {
                part = "Evening"
            }
            let block = StrainDayBlock(
                id: "gap-\(Int(s.timeIntervalSince1970))",
                name: "\(part), not labelled",
                short: part,
                drainName: part,
                kind: .unknown,
                icon: "questionmark",
                start: s,
                end: e
            )
            result.append(block)
        }
        return result
    }

    // MARK: Battery

    static func modelBattery(hr: [StrainHRPoint], wake: Date, end: Date, start: Double, rhr: Double) -> [StrainBatteryPoint] {
        var level = max(0, min(100, start))
        var pts: [StrainBatteryPoint] = [StrainBatteryPoint(at: wake, value: level)]
        var cursor = wake
        for p in hr.sorted(by: { $0.at < $1.at }) {
            let s = max(p.at, wake)
            let e = min(p.at.addingTimeInterval(900), end)
            if e <= s || e <= cursor { continue }
            let s2 = max(s, cursor)
            if s2.timeIntervalSince(cursor) > 60 {
                pts.append(StrainBatteryPoint(at: s2, value: level))
            }
            let hours = e.timeIntervalSince(s2) / 3600
            level = max(0, level - 0.09 * max(0, p.bpm - rhr) * hours)
            pts.append(StrainBatteryPoint(at: e, value: level))
            cursor = e
        }
        if end.timeIntervalSince(cursor) > 1 {
            pts.append(StrainBatteryPoint(at: end, value: level))
        }
        return pts
    }

    static func level(at t: Date, in pts: [StrainBatteryPoint]) -> Double? {
        guard let first = pts.first, let last = pts.last else { return nil }
        if t <= first.at { return first.value }
        if t >= last.at { return last.value }
        var lo = 0
        for i in 1..<pts.count where pts[i].at >= t {
            lo = i - 1
            break
        }
        let a = pts[lo]
        let b = pts[lo + 1]
        let span = b.at.timeIntervalSince(a.at)
        if span <= 0 { return b.value }
        let f = t.timeIntervalSince(a.at) / span
        return a.value + (b.value - a.value) * f
    }

    // MARK: Strain per block

    static func annotate(blocks: [StrainDayBlock], hr: [StrainHRPoint], rhr: Double, battery: [StrainBatteryPoint]) -> (blocks: [StrainDayBlock], dayTrimp: Double) {
        var out = blocks
        var total = 0.0
        for i in out.indices {
            var trimp = 0.0
            var weighted = 0.0
            var mins = 0.0
            for p in hr {
                let s = max(p.at, out[i].start)
                let e = min(p.at.addingTimeInterval(900), out[i].end)
                let m = e.timeIntervalSince(s) / 60
                if m <= 0 { continue }
                trimp += bucketTrimp(minutes: m, bpm: p.bpm, rhr: rhr)
                weighted += p.bpm * m
                mins += m
            }
            out[i].trimp = trimp
            out[i].hrAvg = mins > 0 ? weighted / mins : nil
            total += trimp
        }
        var cum = 0.0
        for i in out.indices {
            let before = strainAt(cum)
            let after = strainAt(cum + out[i].trimp)
            out[i].strainAdded = after - before
            out[i].strainAfter = after
            out[i].loadShare = total > 0 ? out[i].trimp / total * 100 : 0
            cum += out[i].trimp
            if !battery.isEmpty {
                out[i].batteryStart = level(at: out[i].start, in: battery)
                out[i].batteryEnd = level(at: out[i].end, in: battery)
            }
        }
        return (out, total)
    }

    static func zoneMinutes(hr: [StrainHRPoint], wake: Date, end: Date) -> [Double] {
        var z: [Double] = [0, 0, 0, 0, 0]
        for p in hr {
            let s = max(p.at, wake)
            let e = min(p.at.addingTimeInterval(900), end)
            let m = e.timeIntervalSince(s) / 60
            if m <= 0 { continue }
            var idx = -1
            for k in 0..<zoneStarts.count where p.bpm >= zoneStarts[k] { idx = k }
            if idx >= 0 { z[idx] += m }
        }
        return z
    }
}

// MARK: - Observable model

@MainActor
final class StrainDayModel: ObservableObject {
    @Published private(set) var data: StrainDayData? = nil
    @Published private(set) var loading = false
    @Published private(set) var rides: [SupabaseClient.WorkoutRecord] = []
    @Published private(set) var lastWorkout: SupabaseClient.WorkoutRecord? = nil
    @Published private(set) var workoutTypes: [SupabaseClient.WorkoutType] = []
    private var generation = 0

    func load(day: Date, engine: HealthEngine) async {
        generation += 1
        let mine = generation
        loading = true
        let rhr: Double? = engine.baselineRHR > 30 ? engine.baselineRHR : nil
        let mono: Double? = engine.trainingMonotony > 0 ? engine.trainingMonotony : nil
        let vo2: Double? = engine.vo2maxEstimate > 0 ? engine.vo2maxEstimate : nil
        let t0 = Date()
        let result = await StrainDayAPI.loadDay(day: day, rhrFallback: rhr, monotonyFallback: mono, vo2Fallback: vo2)
        print("[Strain] loadDay \(StrainParse.dayKey(day)) took \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(result.hr.count) hr points, \(result.blocks.count) blocks, cancelled=\(Task.isCancelled) stale=\(mine != generation)")
        if Task.isCancelled || mine != generation { return }
        data = result
        loading = false
    }

    func loadWorkouts() async {
        async let recentTask = SupabaseClient.shared.workoutRecent(limit: 60)
        async let typesTask = SupabaseClient.shared.fetchWorkoutTypes()
        let recent = await recentTask
        let types = await typesTask
        if Task.isCancelled { return }
        let sorted = recent.sorted { $0.startedAt > $1.startedAt }
        let rideList = sorted.filter { r in
            let l = r.label.lowercased()
            return (l.contains("ride") || l.contains("motor")) && !l.contains("cardio")
        }
        rides = Array(rideList.prefix(5))
        lastWorkout = sorted.first
        workoutTypes = types
    }

    func workoutType(for chip: String) -> SupabaseClient.WorkoutType? {
        var keys: [String] = [chip.lowercased()]
        switch chip {
        case "Gym": keys = ["gym", "strength", "weight"]
        case "Bike": keys = ["bike", "cycl"]
        case "Ride": keys = ["motor", "ride"]
        default: break
        }
        for k in keys {
            if let t = workoutTypes.first(where: { $0.label.lowercased().contains(k) }) { return t }
        }
        return nil
    }
}
