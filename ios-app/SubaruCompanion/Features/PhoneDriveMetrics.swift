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
}

/// Conservative GPS-only measurement. Gaps and jumps are never bridged into distance.
struct PhoneDriveMetrics {
    private(set) var last: DriveFix?
    private(set) var distanceKm = 0.0
    private(set) var maxSpeed = 0.0
    private(set) var speed: Double?
    private(set) var report = PhoneDriveReport()
    private var lastEventTime = -Double.infinity

    mutating func accept(_ fix: DriveFix, now: Double) -> Bool {
        guard fix.time.isFinite, fix.latitude.isFinite, fix.longitude.isFinite,
              abs(fix.latitude) <= 90, abs(fix.longitude) <= 180,
              fix.accuracy.isFinite, fix.accuracy >= 0, fix.accuracy <= 30,
              now - fix.time <= 15, fix.time <= now + 2 else { return false }
        let validSpeed = fix.speed.isFinite && fix.speed >= 0 && fix.speed <= 85
            && fix.speedAccuracy.isFinite && fix.speedAccuracy >= 0 && fix.speedAccuracy <= 5
        let nextSpeed: Double? = validSpeed ? fix.speed * 3.6 : nil
        if let previous = last {
            let dt = fix.time - previous.time
            guard dt >= 0.5 else { return false }
            let distance = previous.distance(to: fix)
            if dt <= 15 {
                // Reject teleportation, including jumps inconsistent with reported speed.
                let plausible = max(15, max(previous.speed, fix.speed) + 12)
                guard distance / dt <= min(85, plausible) else { return false }
                report.measuredSeconds += dt
                if let nextSpeed {
                    if nextSpeed >= 5 {
                        report.movingSeconds += dt
                        if distance >= 2 { distanceKm += distance / 1000 }
                    } else { report.stoppedSeconds += dt }
                } else if distance > max(5, (previous.accuracy + fix.accuracy) / 2) {
                    distanceKm += distance / 1000
                }
                if validSpeed, previous.speed >= 0, previous.speedAccuracy >= 0,
                   previous.speedAccuracy <= 2, fix.speedAccuracy <= 2,
                   dt <= 3, fix.time - lastEventTime >= 10, max(fix.speed, previous.speed) >= 5 {
                    let acceleration = (fix.speed - previous.speed) / dt
                    if abs(acceleration) >= 3 && abs(acceleration) <= 10 {
                        report.events.append(PhoneDriveEvent(time: fix.time, latitude: fix.latitude,
                            longitude: fix.longitude, kind: acceleration > 0 ? "acceleration" : "braking", speed: fix.speed * 3.6))
                        lastEventTime = fix.time
                    }
                }
            }
        }
        last = fix
        speed = nextSpeed
        if let nextSpeed { maxSpeed = max(maxSpeed, nextSpeed) }
        return true
    }
}
