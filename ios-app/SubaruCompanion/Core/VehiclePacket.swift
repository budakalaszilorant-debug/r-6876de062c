import Foundation

/// Az autó pillanatnyi állapota, amit az `ElmSession` a dugó válaszaiból állít össze (kb. 4 Hz).
struct VehiclePacket: Equatable {
    var seq: Int = 0
    var uptimeMs: Int = 0
    /// Válaszol-e a dugó (ELM327) az appnak
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
    var diagnosticsReadAt: Date?
    /// Kialakulóban lévő (még nem megerősített) és állandó hibakódok
    var pendingCodes: [String] = []
    var permanentCodes: [String] = []
    /// Rövid és hosszú távú keverékkorrekció (%), + = szegény keveréket kompenzál
    var stft: Double?
    var ltft: Double?
    var vin: String?
    var odometerKm: Double?
    var distSinceClearKm: Double?
    var tripKm: Double?
    /// Nyugalmi feszültség az indítás előtt
    var restV: Double?
    /// Legalacsonyabb feszültség önindítózás közben (csak ha a modul ébren volt)
    var crankMinV: Double?
    /// A hibakód keletkezésekor az ECU által rögzített adatok
    var freeze: FreezeFrame?
    /// Készenléti tesztek nyers bájtjai (Mode 01 PID 01) és a hibatörlés óta eltelt idő/táv
    var mon: [Int]?
    var distMilKm: Double?
    var timeMilMin: Double?
    var timeClearMin: Double?
    /// Üzemanyag típus (PID 0x51) és a motor által jelentett fogyasztás l/h (PID 0x5E), ha az autó tudja
    var fuelType: Int?
    var fuelRate: Double?

    struct FreezeFrame: Decodable, Equatable {
        var dtc: String?
        var rpm: Double?
        var speed: Double?
        var coolant: Double?
        var load: Double?
    }

    enum CodingKeys: String, CodingKey {
        case seq, ecu, elm, rpm, vin, maf, freeze
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
        case pendingCodes = "pending_codes"
        case permanentCodes = "permanent_codes"
        case stft, ltft
        case odometerKm = "odometer_km"
        case distSinceClearKm = "dist_since_clear_km"
        case tripKm = "trip_km"
        case restV = "rest_v"
        case crankMinV = "crank_min_v"
        case mon
        case distMilKm = "dist_mil_km"
        case timeMilMin = "time_mil_min"
        case timeClearMin = "time_clear_min"
        case fuelType = "fuel_type"
        case fuelRate = "fuel_rate"
    }

    /// Pillanatnyi fogyasztás l/óra. Ha a motor maga jelenti, azt használjuk; különben benzinesnél
    /// a MAF-ból számolunk (AFR 14,7, sűrűség 745 g/l). Dízelnél a keverék arány folyton változik,
    /// ezért ott MAF-ból nem lehet megbízhatóan számolni.
    var fuelRateLph: Double? {
        guard engineRunning else { return nil }
        if let fuelRate { return fuelRate }
        guard let maf, AppSettings.shared.fuelType == .petrol else { return nil }
        return maf * 3600 / (14.7 * 745)
    }

    /// Pillanatnyi fogyasztás l/100 km (álló helyzetben nincs értelme).
    var consumptionL100: Double? {
        guard let rate = fuelRateLph, let v = vehicleSpeed, v > 3 else { return nil }
        return rate / v * 100
    }
}

/// JSON-ból is betölthető (tesztekhez); a hiányzó mezők alapértéket kapnak.
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
        pendingCodes = opt(.pendingCodes) ?? []
        permanentCodes = opt(.permanentCodes) ?? []
        stft = opt(.stft)
        ltft = opt(.ltft)
        vin = opt(.vin)
        odometerKm = opt(.odometerKm)
        distSinceClearKm = opt(.distSinceClearKm)
        tripKm = opt(.tripKm)
        restV = opt(.restV)
        crankMinV = opt(.crankMinV)
        freeze = opt(.freeze)
        mon = opt(.mon)
        distMilKm = opt(.distMilKm)
        timeMilMin = opt(.timeMilMin)
        timeClearMin = opt(.timeClearMin)
        fuelType = opt(.fuelType)
        fuelRate = opt(.fuelRate)
    }
}

/// Az autó jellemzői. Az értékek a Beállításokban autónként átírhatók.
enum CarSpec {
    static var warmTemp: Double { AppSettings.shared.warmTemp }
    static var fullWarmTemp: Double { AppSettings.shared.warmTemp + 2 }
    static let coldStartTemp: Double = 25
    static var redline: Double { AppSettings.shared.redline }
    static let idleRpm: Double = 700

}
