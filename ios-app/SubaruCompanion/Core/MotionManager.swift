import Foundation
import CoreMotion
import simd

struct GSample: Identifiable {
    let id: Int
    let t: Date
    let lon: Double
    let lat: Double
}

/// G-erő a telefon szenzoraiból.
/// Álló vagy fekvő tartóban (kijelző a vezető felé) előre = a telefon hátlapja;
/// vízszintesen fekvő telefonnál előre = a telefon teteje.
final class MotionManager: ObservableObject {
    static let shared = MotionManager()

    /// Hosszirányú G: + gyorsítás, − fékezés
    @Published private(set) var longitudinal: Double = 0
    /// Oldalirányú G: + jobb, − bal
    @Published private(set) var lateral: Double = 0
    @Published private(set) var peakAccel: Double = 0
    @Published private(set) var peakBrake: Double = 0
    @Published private(set) var peakLeft: Double = 0
    @Published private(set) var peakRight: Double = 0
    /// Az utolsó ~1,5 mp pontjai a nyomvonalhoz
    @Published private(set) var trail: [SIMD2<Double>] = []
    /// Az utolsó 30 mp 10 Hz-en a grafikonhoz
    @Published private(set) var timeline: [GSample] = []
    @Published private(set) var available = true
    @Published private(set) var flatMount = false

    var total: Double { hypot(longitudinal, lateral) }
    var peakTotal: Double { max(peakAccel, peakBrake, peakLeft, peakRight) }

    private let motion = CMMotionManager()
    private var offset = SIMD2<Double>(0, 0)
    private var raw = SIMD2<Double>(0, 0)
    private let smoothing = 0.25   // aluláteresztő szűrő az úthibák rezgése ellen
    private var tick = 0
    private var sampleId = 0

    func start() {
        guard motion.isDeviceMotionAvailable else { available = false; return }
        guard !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.process(data)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Álló autóban nullázás (lejtő, ferde tartó kompenzálása) és a csúcsok törlése.
    func zero() {
        offset = raw
        longitudinal = 0
        lateral = 0
        resetPeaks()
    }

    func resetPeaks() {
        peakAccel = 0; peakBrake = 0; peakLeft = 0; peakRight = 0
        trail.removeAll()
        timeline.removeAll()
    }

    private func process(_ data: CMDeviceMotion) {
        let g = simd_normalize(SIMD3(data.gravity.x, data.gravity.y, data.gravity.z))
        let up = -g
        // Álló tartó: előre a hátlap felé (−z). Ha a telefon vízszintesen fekszik, ez függőleges lenne,
        // ilyenkor a telefon teteje (+y) mutat előre.
        var forward = SIMD3<Double>(0, 0, -1)
        forward -= simd_dot(forward, up) * up
        let flat = simd_length(forward) < 0.35
        if flat {
            forward = SIMD3<Double>(0, 1, 0)
            forward -= simd_dot(forward, up) * up
        }
        guard simd_length(forward) > 0.1 else { return }
        if flat != flatMount { flatMount = flat }
        forward = simd_normalize(forward)
        let right = simd_cross(forward, up)

        let a = SIMD3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z)
        raw = SIMD2(simd_dot(a, forward), simd_dot(a, right))
        let v = raw - offset

        longitudinal += (v.x - longitudinal) * smoothing
        lateral += (v.y - lateral) * smoothing

        peakAccel = max(peakAccel, longitudinal)
        peakBrake = max(peakBrake, -longitudinal)
        peakRight = max(peakRight, lateral)
        peakLeft = max(peakLeft, -lateral)

        trail.append(SIMD2(lateral, longitudinal))
        if trail.count > 45 { trail.removeFirst(trail.count - 45) }

        tick += 1
        if tick % 3 == 0 {
            sampleId += 1
            timeline.append(GSample(id: sampleId, t: Date(), lon: longitudinal, lat: lateral))
            if timeline.count > 300 { timeline.removeFirst(timeline.count - 300) }
        }
    }
}
