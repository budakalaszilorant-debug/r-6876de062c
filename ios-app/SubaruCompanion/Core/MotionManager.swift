import Foundation
import CoreMotion
import simd

/// G-erő a telefon szenzoraiból. Feltételezés: a telefon tartóban áll, a kijelző a vezető felé néz
/// (álló vagy fekvő). Előre = a telefon hátlapjának iránya, a vízszintes síkra vetítve.
final class MotionManager: ObservableObject {
    static let shared = MotionManager()

    /// Hosszirányú G: + gyorsítás, − fékezés
    @Published private(set) var longitudinal: Double = 0
    /// Oldalirányú G: + jobbra kanyar felé ható gyorsulás
    @Published private(set) var lateral: Double = 0
    @Published private(set) var peakAccel: Double = 0
    @Published private(set) var peakBrake: Double = 0
    @Published private(set) var peakLateral: Double = 0
    @Published private(set) var available = true

    private let motion = CMMotionManager()
    private var offset = SIMD2<Double>(0, 0)
    private var raw = SIMD2<Double>(0, 0)
    private let smoothing = 0.2  // aluláteresztő szűrő, az úthibák rezgése ellen

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

    /// Álló autóban nullázás (lejtő / ferde tartó kompenzálása).
    func zero() {
        offset = raw
        resetPeaks()
    }

    func resetPeaks() {
        peakAccel = 0; peakBrake = 0; peakLateral = 0
    }

    private func process(_ data: CMDeviceMotion) {
        let g = simd_normalize(SIMD3(data.gravity.x, data.gravity.y, data.gravity.z))
        let up = -g
        var forward = SIMD3<Double>(0, 0, -1)
        forward = forward - simd_dot(forward, up) * up   // vízszintes síkra vetítés
        guard simd_length(forward) > 0.2 else { return } // a telefon laposan fekszik: nincs értelmes irány
        forward = simd_normalize(forward)
        let right = simd_cross(forward, up)

        let a = SIMD3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z)
        raw = SIMD2(simd_dot(a, forward), simd_dot(a, right))
        let v = raw - offset

        longitudinal += (v.x - longitudinal) * smoothing
        lateral += (v.y - lateral) * smoothing

        peakAccel = max(peakAccel, longitudinal)
        peakBrake = max(peakBrake, -longitudinal)
        peakLateral = max(peakLateral, abs(lateral))
    }
}
