import Foundation
import Combine
import CoreLocation
import CoreMotion
import UIKit

/// Route and steps for a workout he started. GPS runs only for an outdoor workout and only while it runs;
/// points stay in memory, land in one small file about once a minute, and go to the server once, at finish.
final class WorkoutTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WorkoutTracker()

    @Published private(set) var recordingId: String? = nil
    @Published private(set) var locationDenied = false
    @UIGated var liveKm: Double = 0
    @UIGated var pointCount: Int = 0

    private struct TrackPoint: Codable {
        let t: Double
        let lat: Double
        let lon: Double
        let alt: Double?
        let acc: Double
        let speed: Double?
    }

    private struct TrackFile: Codable {
        var sessionId: String
        var typeKey: String
        var startedAt: Date
        var outdoor: Bool
        var points: [TrackPoint]
        var finishedAt: Date?
    }

    private static let maxDuration: TimeInterval = 4 * 3600
    private static let worstAccuracy: CLLocationAccuracy = 25
    private static let fastestBelievable: Double = 25

    private var manager: CLLocationManager?
    private var backgroundSession: CLBackgroundActivitySession?
    private let pedometer = CMPedometer()
    private var track: TrackFile?
    private var lastSaved = Date.distantPast
    private var hardStop: DispatchWorkItem?
    private var launchWorkDone = false

    private var disabled: Bool { LucidScreen.current != nil }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopGPS()
            self?.save()
        }
    }

    // MARK: Lifecycle

    /// Call right after workout_start. Indoor never creates a CLLocationManager.
    @MainActor
    func begin(session: SupabaseClient.WorkoutSession, outdoor: Bool) {
        guard !disabled else { return }
        // workout_start hands back the running session on a double tap; keep its route
        if track?.sessionId == session.id, recordingId == session.id { return }
        stopGPS()
        track = TrackFile(sessionId: session.id, typeKey: session.typeKey, startedAt: session.startedAt,
                          outdoor: outdoor, points: [], finishedAt: nil)
        liveKm = 0
        pointCount = 0
        recordingId = session.id
        save()
        if outdoor { startGPS() }
    }

    /// The live screen reopened (app relaunched mid-workout): pick the route back up from the file.
    @MainActor
    func resume(session: SupabaseClient.WorkoutSession) {
        guard !disabled else { return }
        if track?.sessionId == session.id, recordingId == session.id { return }
        guard let file = Self.load(), file.sessionId == session.id, file.finishedAt == nil else { return }
        track = file
        recordingId = session.id
        pointCount = file.points.count
        liveKm = Self.distanceKm(file.points)
        if file.outdoor, Date().timeIntervalSince(file.startedAt) < Self.maxDuration { startGPS() }
    }

    var hasRoute: Bool { (track?.points.count ?? 0) >= 2 }
    func isOutdoor(_ sessionId: String) -> Bool { track?.sessionId == sessionId && track?.outdoor == true }

    /// Stops GPS and marks the end. The upload happens in `upload()`, after workout_finish.
    @MainActor
    func stop(sessionId: String) {
        stopGPS()
        guard track?.sessionId == sessionId else { return }
        if track?.finishedAt == nil { track?.finishedAt = Date() }
        save()
    }

    /// One request: route, steps and pedometer distance. Keeps the file for a retry if it fails.
    @MainActor
    func upload(sessionId: String) async -> SupabaseClient.WorkoutTrackResult? {
        guard !disabled, let file = track ?? Self.load(), file.sessionId == sessionId else { return nil }
        let result = await send(file)
        if result != nil {
            Self.deleteFile()
            track = nil
            recordingId = nil
        }
        return result
    }

    /// Discard: nothing is uploaded and nothing is kept.
    @MainActor
    func cancel() {
        stopGPS()
        track = nil
        recordingId = nil
        liveKm = 0
        pointCount = 0
        Self.deleteFile()
    }

    /// Once per launch: retry a failed upload, never leave GPS on without an open workout, backfill steps.
    @MainActor
    func launchWork() async {
        guard !disabled, !launchWorkDone else { return }
        launchWorkDone = true
        let openNow = await SupabaseClient.shared.workoutOpenChecked()
        if let file = Self.load() {
            if file.finishedAt == nil, case .open(let s) = openNow, s.id == file.sessionId {
                resume(session: s)
            } else if case .unknown = openNow, file.finishedAt == nil {
                // server unreachable: keep the file, the live screen resumes it when it opens
            } else {
                stopGPS()
                track = file
                if await send(file) != nil || Date().timeIntervalSince(file.startedAt) > 7 * 86400 {
                    Self.deleteFile()
                    track = nil
                    recordingId = nil
                }
            }
        } else if case .none = openNow {
            stopGPS()
        }
        await backfillSteps()
    }

    // MARK: Steps

    /// Steps only mean something for walking and running; a bike's pedometer distance would overwrite a real one.
    private static func countsSteps(_ typeKey: String, label: String = "") -> Bool {
        if ["walk", "run"].contains(typeKey) { return true }
        let l = label.lowercased()
        return typeKey.isEmpty && (l.contains("walk") || l.contains("run"))
    }

    private func pedometerData(from: Date, to: Date) async -> (steps: Int, km: Double?)? {
        guard CMPedometer.isStepCountingAvailable(), to > from else { return nil }
        let status = CMPedometer.authorizationStatus()
        if status == .denied || status == .restricted { return nil }
        return await withCheckedContinuation { cont in
            pedometer.queryPedometerData(from: from, to: to) { data, error in
                guard let data, error == nil else { cont.resume(returning: nil); return }
                cont.resume(returning: (data.numberOfSteps.intValue, data.distance.map { $0.doubleValue / 1000 }))
            }
        }
    }

    /// iOS keeps 7 days of pedometer history, so a walk logged late still gets its steps.
    @MainActor
    private func backfillSteps() async {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let key = "lh.workoutStepsBackfilled"
        var tried = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let recent = await SupabaseClient.shared.workoutRecent(limit: 30)
        for w in recent where w.startedAt > weekAgo && w.steps == nil && !tried.contains(w.id)
            && Self.countsSteps(w.typeKey, label: w.label) && w.durationSec > 0 {
            let from = w.detectedStart ?? w.startedAt
            let to = w.detectedEnd ?? w.startedAt.addingTimeInterval(TimeInterval(w.durationSec))
            guard let p = await pedometerData(from: from, to: to) else { continue }
            if await SupabaseClient.shared.workoutAttachTrack(id: w.id, points: [], steps: p.steps, pedometerKm: p.km) != nil {
                tried.insert(w.id)
            }
        }
        UserDefaults.standard.set(Array(tried.suffix(200)), forKey: key)
    }

    @MainActor
    private func send(_ file: TrackFile) async -> SupabaseClient.WorkoutTrackResult? {
        let end = file.finishedAt ?? file.points.last.map { Date(timeIntervalSince1970: $0.t) } ?? Date()
        var steps: Int? = nil
        var km: Double? = nil
        if Self.countsSteps(file.typeKey), let p = await pedometerData(from: file.startedAt, to: end) {
            steps = p.steps
            km = p.km
        }
        var points: [[Any]] = []
        if file.outdoor {
            points = file.points.map { (p: TrackPoint) -> [Any] in
                let alt: Any = p.alt ?? NSNull()
                let speed: Any = p.speed ?? NSNull()
                return [p.t, p.lat, p.lon, alt, p.acc, speed]
            }
        }
        if points.isEmpty && steps == nil { return SupabaseClient.WorkoutTrackResult(distanceKm: nil, distanceSource: nil, elevationGainM: nil, steps: nil) }
        return await SupabaseClient.shared.workoutAttachTrack(id: file.sessionId, points: points, steps: steps, pedometerKm: km)
    }

    // MARK: GPS
    // Apple, "Getting the current location of a device" > power: the largest distanceFilter and lowest accuracy
    // that still give the data. 10 m spacing is plenty for a walking or running line.

    private func startGPS() {
        guard !disabled, manager == nil, let track else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.activityType = .fitness
        m.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        m.distanceFilter = 10
        m.pausesLocationUpdatesAutomatically = false
        m.showsBackgroundLocationIndicator = true
        manager = m
        let remaining = Self.maxDuration - Date().timeIntervalSince(track.startedAt)
        let stopItem = DispatchWorkItem { [weak self] in self?.stopGPS(); self?.save() }
        hardStop = stopItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining), execute: stopItem)
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: beginUpdates()
        default: locationDenied = true
        }
    }

    private func beginUpdates() {
        guard let m = manager else { return }
        locationDenied = false
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        m.allowsBackgroundLocationUpdates = true
        m.startUpdatingLocation()
    }

    private func stopGPS() {
        hardStop?.cancel()
        hardStop = nil
        guard let m = manager else { return }
        m.stopUpdatingLocation()
        m.allowsBackgroundLocationUpdates = false
        m.delegate = nil
        manager = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard m === manager else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: beginUpdates()
        case .notDetermined: break
        default: locationDenied = true
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard m === manager, var file = track, file.outdoor, file.finishedAt == nil else { return }
        if Date().timeIntervalSince(file.startedAt) > Self.maxDuration {
            stopGPS()
            save()
            return
        }
        var added = 0.0
        for loc in locations {
            let acc = loc.horizontalAccuracy
            guard acc >= 0, acc <= Self.worstAccuracy else { continue }
            guard abs(loc.timestamp.timeIntervalSinceNow) < 10, loc.timestamp >= file.startedAt else { continue }
            let t = loc.timestamp.timeIntervalSince1970
            if let last = file.points.last {
                let dt = t - last.t
                guard dt > 0 else { continue }
                let d = loc.distance(from: CLLocation(latitude: last.lat, longitude: last.lon))
                guard d / dt <= Self.fastestBelievable else { continue }
                added += d
            }
            file.points.append(TrackPoint(
                t: t.rounded(),
                lat: (loc.coordinate.latitude * 1e6).rounded() / 1e6,
                lon: (loc.coordinate.longitude * 1e6).rounded() / 1e6,
                alt: loc.verticalAccuracy >= 0 ? (loc.altitude * 10).rounded() / 10 : nil,
                acc: (acc * 10).rounded() / 10,
                speed: loc.speed >= 0 ? (loc.speed * 100).rounded() / 100 : nil
            ))
        }
        track = file
        if added > 0 { liveKm += added / 1000 }
        pointCount = file.points.count
        if Date().timeIntervalSince(lastSaved) >= 60 { save() }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied {
            locationDenied = true
            stopGPS()
            save()
        }
    }

    // MARK: File

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workout-track.json")
    }

    private func save() {
        guard !disabled, let track, let data = try? JSONEncoder().encode(track) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastSaved = Date()
    }

    private static func load() -> TrackFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TrackFile.self, from: data)
    }

    private static func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func distanceKm(_ points: [TrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var m = 0.0
        for i in 1..<points.count {
            m += CLLocation(latitude: points[i - 1].lat, longitude: points[i - 1].lon)
                .distance(from: CLLocation(latitude: points[i].lat, longitude: points[i].lon))
        }
        return m / 1000
    }
}
