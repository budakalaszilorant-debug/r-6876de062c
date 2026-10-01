import Foundation

/// Az ESP32 által küldött JSON csomag (4 Hz).
struct VehiclePacket: Equatable {
    var seq: Int = 0
    var uptimeMs: Int = 0
    /// Válaszol-e az ELM327 adapter az ESP32-nek (nil = régi firmware, nem küldi)
    var elm: Bool?
    var ecu: Bool = false
    var engineRunning: Bool = false
    var startId: Int = 0
    var rpm: Double?
    var coolantTemp: Double?
    var batteryVoltage: Double?
    var voltageSrc: String?
    var vehicleSpeed: Double?
    var engineLoad: Double?
    var throttlePos: Double?
    var fuelLevel: Double?
    var intakeTemp: Double?
    var maf: Double?
    var faultCodes: [String] = []
    var vin: String?
    var odometerKm: Double?
    var distSinceClearKm: Double?
    var tripKm: Double?
    /// Nyugalmi feszültség az indítás előtt
    var restV: Double?
    /// Legalacsonyabb feszültség önindítózás közben (csak ha a modul ébren volt)
    var crankMinV: Double?

    enum CodingKeys: String, CodingKey {
        case seq, ecu, elm, rpm, vin, maf
        case uptimeMs = "uptime_ms"
        case engineRunning = "engine_running"
        case startId = "start_id"
        case coolantTemp = "coolant_temp"
        case batteryVoltage = "battery_voltage"
        case voltageSrc = "voltage_src"
        case vehicleSpeed = "vehicle_speed"
        case engineLoad = "engine_load"
        case throttlePos = "throttle_pos"
        case fuelLevel = "fuel_level"
        case intakeTemp = "intake_temp"
        case faultCodes = "fault_codes"
        case odometerKm = "odometer_km"
        case distSinceClearKm = "dist_since_clear_km"
        case tripKm = "trip_km"
        case restV = "rest_v"
        case crankMinV = "crank_min_v"
    }

    /// Pillanatnyi fogyasztás l/óra a MAF-ból (benzin: AFR 14.7, sűrűség 745 g/l).
    var fuelRateLph: Double? {
        guard let maf, engineRunning else { return nil }
        return maf * 3600 / (14.7 * 745)
    }

    /// Pillanatnyi fogyasztás l/100 km (álló helyzetben nincs értelme).
    var consumptionL100: Double? {
        guard let rate = fuelRateLph, let v = vehicleSpeed, v > 3 else { return nil }
        return rate / v * 100
    }
}

/// Hiányzó mezőnél alapértéket használ, hogy egy firmware-változás ne némítsa el az egész appot.
extension VehiclePacket: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ k: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: k) }
        self.init()
        seq = opt(.seq) ?? 0
        uptimeMs = opt(.uptimeMs) ?? 0
        elm = opt(.elm)
        ecu = opt(.ecu) ?? false
        engineRunning = opt(.engineRunning) ?? false
        startId = opt(.startId) ?? 0
        rpm = opt(.rpm)
        coolantTemp = opt(.coolantTemp)
        batteryVoltage = opt(.batteryVoltage)
        voltageSrc = opt(.voltageSrc)
        vehicleSpeed = opt(.vehicleSpeed)
        engineLoad = opt(.engineLoad)
        throttlePos = opt(.throttlePos)
        fuelLevel = opt(.fuelLevel)
        intakeTemp = opt(.intakeTemp)
        maf = opt(.maf)
        faultCodes = opt(.faultCodes) ?? []
        vin = opt(.vin)
        odometerKm = opt(.odometerKm)
        distSinceClearKm = opt(.distSinceClearKm)
        tripKm = opt(.tripKm)
        restV = opt(.restV)
        crankMinV = opt(.crankMinV)
    }
}

/// EJ20 motorra és a 2010-es Imprezára vonatkozó fix értékek.
enum EJ20 {
    static let warmTemp: Double = 88
    static let fullWarmTemp: Double = 90
    static let coldStartTemp: Double = 25
    static let redline: Double = 6500
    static let idleRpm: Double = 700

    /// VIN alapján: JF1 = Subaru Japán, 4-5. karakter GH/GR/GE = Impreza (GH/GR generáció).
    static func isSupported(vin: String) -> Bool {
        guard vin.count == 17, vin.hasPrefix("JF1") || vin.hasPrefix("JF2") else { return false }
        let model = String(vin.dropFirst(3).prefix(2))
        return ["GH", "GR", "GE", "GV"].contains(model)
    }
}
