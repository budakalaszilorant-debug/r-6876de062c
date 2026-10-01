import Foundation

/// Szimulált autó az app kipróbálásához hardver nélkül: hidegindítás, bemelegedés (gyorsítva),
/// városi menet, majd egy hibakód. Ugyanazt a csomagot adja, mint az ESP32.
final class DemoSource {
    static let startTemp: Double = 14

    private var timer: Timer?
    private var t = 0.0
    private var seq = 0
    private var startId = 0

    func start(onPacket: @escaping (VehiclePacket) -> Void) {
        stop()
        t = 0
        seq = 0
        startId = Int(Date().timeIntervalSince1970)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            onPacket(self.next())
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func next() -> VehiclePacket {
        t += 0.25
        seq += 1

        // Az első 8 mp alapjárat, utána hullámzó városi tempó.
        let moving = t > 8
        let speed = moving ? max(0, 48 + 38 * sin(t / 9) + 6 * sin(t / 2.3)) : 0
        let accel = moving ? cos(t / 9) : 0
        let coolant = min(91, Self.startTemp + t * 1.25)          // kb. 1 perc alatt meleg
        let coldIdle = coolant < 60 ? 350.0 : 0                    // hidegen magasabb alapjárat
        let rpm = moving ? 950 + speed * 36 + accel * 250 : 780 + coldIdle + 15 * sin(t * 3)
        let load = moving ? min(95, 28 + max(0, accel) * 45) : 18
        let maf = 2.4 + rpm / 1000 * 3.2 * (0.5 + load / 100)

        var p = VehiclePacket()
        p.seq = seq
        p.uptimeMs = Int(t * 1000)
        p.elm = true
        p.ecu = true
        p.engineRunning = true
        p.startId = startId
        p.rpm = rpm.rounded()
        p.coolantTemp = coolant.rounded()
        p.batteryVoltage = 14.1 + 0.08 * sin(t / 4)
        p.voltageSrc = "pid"
        p.vehicleSpeed = speed.rounded()
        p.engineLoad = load
        p.throttlePos = moving ? min(100, 12 + max(0, accel) * 40) : 0
        p.fuelLevel = 68
        p.intakeTemp = 22
        p.maf = maf
        p.faultCodes = t > 45 ? ["P0420"] : []
        p.vin = "JF1GR7DEMO0000000"
        return p
    }
}
