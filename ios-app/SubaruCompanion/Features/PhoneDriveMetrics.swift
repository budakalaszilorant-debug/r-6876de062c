import Foundation

struct DriveFix {
    var time: Double
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var speed: Double // metres per second; negative means unavailable
    var speedAccuracy: Double

    func distance(to other: DriveFix) -> Double {
        let r = Double.pi / 180
        let a = pow(sin((other.latitude - latitude) * r / 2), 2)
            + cos(latitude * r) * cos(other.latitude * r) * pow(sin((other.longitude - longitude) * r / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, a))))
    }
}

struct PhoneDriveEvent: Codable, Identifiable {
    var id = UUID()
    var time: Double
    var latitude: Double
    var longitude: Double
    var kind: String
    var speed: Double
}

struct PhoneDriveReport: Codable {
    var movingSeconds = 0.0
    var stoppedSeconds = 0.0
    var measuredSeconds = 0.0
    var events: [PhoneDriveEvent] = []
    // Remains true if iOS terminates the recording before the user stops it.
    var interrupted = true
    var measurementVersion: Int? = 2
    var confirmedMovement: Bool? = false
    var lastObservedAt: Double?
    var endReason: String?
}

/// Conservative GPS-only measurement. Gaps and jumps are never bridged into distance.
struct PhoneDriveMetrics {
    private(set) var last: DriveFix?
    private(set) var distanceKm = 0.0
    private(set) var maxSpeed = 0.0
    private(set) var speed: Double?
    private(set) var report = PhoneDriveReport()
    private(set) var routeFixes: [DriveFix] = []
    private(set) var isMoving = false
    private var candidate: [DriveFix] = []
    private var recentSpeeds: [Double] = []
    private var lastEventTime = -Double.infinity

    mutating func accept(_ fix: DriveFix, now: Double, stationary: Bool = false) -> Bool {
        routeFixes = []
        guard fix.time.isFinite, fix.latitude.isFinite, fix.longitude.isFinite,
              abs(fix.latitude) <= 90, abs(fix.longitude) <= 180,
              fix.accuracy.isFinite, fix.accuracy >= 0, fix.accuracy <= 25,
              now - fix.time <= 15, fix.time <= now + 2 else { return false }
        let previous = last
        let dt = previous.map { fix.time - $0.time } ?? 0
        if previous != nil && dt < 0.5 { return false }
        let reliable = fix.speed.isFinite && fix.speed >= 0 && fix.speed <= 70
            && fix.speedAccuracy.isFinite && fix.speedAccuracy >= 0 && fix.speedAccuracy <= 2
        if let previous, dt <= 10 {
            let plausible = reliable ? max(12, max(previous.speed, fix.speed) + 8) : 70
            guard previous.distance(to: fix) / dt <= plausible else { return false }
            if reliable, previous.speed >= 0, previous.speedAccuracy >= 0,
               previous.speedAccuracy <= 2, dt <= 3,
               abs(fix.speed - previous.speed) / dt > 10 { return false }
        } else {
            isMoving = false; candidate = []; recentSpeeds = []
        }
        last = fix
        report.lastObservedAt = fix.time
        let interval = dt <= 10 ? dt : 0
        report.measuredSeconds += interval
        guard reliable else {
            speed = nil; isMoving = false; candidate = []; recentSpeeds = []
            return true // No coordinate-only fallback: indoor drift is not driving.
        }
        if stationary || fix.speed - fix.speedAccuracy < (isMoving ? 0.3 : 1.4)
            || fix.speed < (isMoving ? 1 : 2.5) {
            // Record the braking event before suppressing stationary coordinates.
            if isMoving, !stationary, let previous { event(from: previous, to: fix) }
            isMoving = false; candidate = []; recentSpeeds = []; speed = 0
            report.stoppedSeconds += interval
            return true
        }
        recentSpeeds.append(fix.speed)
        recentSpeeds = Array(recentSpeeds.suffix(3))
        let median = recentSpeeds.sorted()[recentSpeeds.count / 2]
        if !isMoving {
            speed = 0
            report.stoppedSeconds += interval
            candidate.append(fix)
            candidate = Array(candidate.suffix(20))
            guard let first = candidate.first, candidate.count >= 5,
                  fix.time - first.time >= 4 else { return true }
            let displacement = first.distance(to: fix)
            let path = zip(candidate, candidate.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            guard displacement >= max(25, (first.accuracy + fix.accuracy) * 1.5),
                  displacement >= path * 0.65 else { return true }
            isMoving = true; report.confirmedMovement = true
            routeFixes = candidate
            for (a, b) in zip(candidate, candidate.dropFirst()) { addDistance(from: a, to: b) }
            let confirmedSeconds = fix.time - first.time
            report.movingSeconds += confirmedSeconds
            report.stoppedSeconds = max(0, report.stoppedSeconds - confirmedSeconds)
            candidate = []
        } else if let previous {
            addDistance(from: previous, to: fix)
            report.movingSeconds += interval
            routeFixes = [fix]
            event(from: previous, to: fix)
        }
        speed = median * 3.6
        maxSpeed = max(maxSpeed, median * 3.6)
        return true
    }

    private mutating func addDistance(from a: DriveFix, to b: DriveFix) {
        let dt = b.time - a.time
        guard dt > 0, dt <= 10 else { return }
        // Doppler speed constrains coordinate noise without bridging missing observations.
        let speedDistance = max(0, (a.speed + b.speed) / 2) * dt
        distanceKm += min(a.distance(to: b), speedDistance * 1.2) / 1000
    }

    private mutating func event(from a: DriveFix, to b: DriveFix) {
        let dt = b.time - a.time
        guard dt >= 0.5, dt <= 3, a.speedAccuracy >= 0, a.speedAccuracy <= 1,
              b.speedAccuracy >= 0, b.speedAccuracy <= 1, max(a.speed, b.speed) >= 5,
              b.time - lastEventTime >= 10 else { return }
        let acceleration = (b.speed - a.speed) / dt
        guard abs(acceleration) >= 3, abs(acceleration) <= 10 else { return }
        report.events.append(PhoneDriveEvent(time: b.time, latitude: b.latitude, longitude: b.longitude,
            kind: acceleration > 0 ? "acceleration" : "braking", speed: b.speed * 3.6))
        lastEventTime = b.time
    }
}
