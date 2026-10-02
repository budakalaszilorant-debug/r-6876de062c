import Foundation

/// Milyen körülmények között jött a hibakód.
struct DTCSnapshot: Codable, Equatable {
    /// true: az ECU saját rögzítése a hiba pillanatából; false: az app mérése az észleléskor
    var fromEcu: Bool
    var rpm: Double?
    var speed: Double?
    var coolant: Double?
    var load: Double?
}

struct DTCRecord: Identifiable, Equatable {
    let code: String
    let firstSeen: Date
    let lastSeen: Date
    let active: Bool
    var snapshot: DTCSnapshot?
    var id: String { code }
}

enum DTCSeverity {
    case stop, soon, minor

    var label: String {
        switch self {
        case .stop: return tr("Kíméld, azonnal szerviz", "Go easy, service now")
        case .soon: return tr("Mielőbb szerviz", "Service soon")
        case .minor: return tr("Ráér, de nézesd meg", "Not urgent, get it checked")
        }
    }
}

enum DTC {
    /// Gyakori kódok leírása (Subaru EJ motoroknál jellemzők is). Ismeretlen kódnál általános szöveg.
    private static let known: [String: (hu: String, en: String)] = [
        "P0011": ("Szívó vezérműtengely állítás (AVCS) – 1. sor", "Intake cam timing (AVCS) – bank 1"),
        "P0021": ("Szívó vezérműtengely állítás (AVCS) – 2. sor", "Intake cam timing (AVCS) – bank 2"),
        "P0031": ("Lambdaszonda fűtés áramkör alacsony", "O2 sensor heater circuit low"),
        "P0101": ("Légtömegmérő (MAF) jel hibás", "MAF sensor range/performance"),
        "P0113": ("Szívott levegő hőmérő jel magas", "Intake air temp sensor high"),
        "P0117": ("Hűtővíz hőmérő jel alacsony", "Coolant temp sensor low"),
        "P0125": ("Motor nem melegszik fel időben", "Insufficient coolant temp for closed loop"),
        "P0128": ("Termosztát – motor túl lassan melegszik", "Thermostat – coolant below regulating temp"),
        "P0131": ("Első lambdaszonda jel alacsony", "Front O2 sensor low voltage"),
        "P0137": ("Hátsó lambdaszonda jel alacsony", "Rear O2 sensor low voltage"),
        "P0171": ("Szegény keverék", "System too lean"),
        "P0172": ("Dús keverék", "System too rich"),
        "P0300": ("Véletlenszerű égéskimaradás", "Random misfire"),
        "P0301": ("Égéskimaradás – 1. henger", "Misfire – cylinder 1"),
        "P0302": ("Égéskimaradás – 2. henger", "Misfire – cylinder 2"),
        "P0303": ("Égéskimaradás – 3. henger", "Misfire – cylinder 3"),
        "P0304": ("Égéskimaradás – 4. henger", "Misfire – cylinder 4"),
        "P0327": ("Kopogásérzékelő jel alacsony", "Knock sensor low input"),
        "P0335": ("Főtengely jeladó hiba", "Crankshaft position sensor"),
        "P0340": ("Vezérműtengely jeladó hiba", "Camshaft position sensor"),
        "P0420": ("Katalizátor hatásfok alacsony", "Catalyst efficiency below threshold"),
        "P0442": ("EVAP rendszer kis szivárgás", "EVAP small leak"),
        "P0456": ("EVAP rendszer nagyon kis szivárgás (tanksapka?)", "EVAP very small leak (fuel cap?)"),
        "P0457": ("Tanksapka laza vagy hiányzik", "Fuel cap loose/off"),
        "P0500": ("Sebességjeladó hiba", "Vehicle speed sensor"),
        "P0506": ("Alapjárat túl alacsony", "Idle RPM lower than expected"),
        "P0507": ("Alapjárat túl magas", "Idle RPM higher than expected"),
        "P0562": ("Rendszerfeszültség alacsony", "System voltage low"),
        "P2096": ("Katalizátor utáni keverék túl szegény", "Post-catalyst fuel trim too lean"),
    ]

    private static let stopCodes: Set<String> = [
        "P0300", "P0301", "P0302", "P0303", "P0304",   // égéskimaradás: tönkreteheti a katalizátort
        "P0335", "P0340",                              // jeladó: leállhat a motor
        "P0117", "P0217", "P0562"
    ]
    private static let minorCodes: Set<String> = [
        "P0420", "P0442", "P0456", "P0457", "P0128", "P0031", "P0137", "P0506", "P0507"
    ]

    static func severity(_ code: String) -> DTCSeverity {
        if stopCodes.contains(code) { return .stop }
        return minorCodes.contains(code) ? .minor : .soon
    }

    static func saveSnapshot(_ code: String, _ snap: DTCSnapshot) {
        guard let data = try? JSONEncoder().encode(snap), let json = String(data: data, encoding: .utf8) else { return }
        Database.shared.execute("UPDATE dtc_hist SET snap = ? WHERE code = ? AND car_id = ?", [json, code, CarStore.activeId])
    }

    static func describe(_ code: String) -> String {
        if let d = known[code] { return tr(d.hu, d.en) }
        switch code.first {
        case "P": return tr("Hajtáslánc hibakód", "Powertrain fault")
        case "C": return tr("Futómű hibakód", "Chassis fault")
        case "B": return tr("Karosszéria hibakód", "Body fault")
        default:  return tr("Hálózati hibakód", "Network fault")
        }
    }

    static func history() -> [DTCRecord] {
        Database.shared.query("SELECT code, first_seen, last_seen, active, snap FROM dtc_hist WHERE car_id = ? ORDER BY active DESC, last_seen DESC",
                              [CarStore.activeId]) {
            DTCRecord(code: $0.string(0), firstSeen: Date(timeIntervalSince1970: $0.double(1)),
                      lastSeen: Date(timeIntervalSince1970: $0.double(2)), active: $0.int(3) == 1,
                      snapshot: $0.string(4).data(using: .utf8).flatMap { try? JSONDecoder().decode(DTCSnapshot.self, from: $0) })
        }
    }

    /// Frissíti a naplót és visszaadja az újonnan megjelent kódokat.
    static func update(active codes: [String]) -> [String] {
        let db = Database.shared
        let now = Date().timeIntervalSince1970
        let car = CarStore.activeId
        let previouslyActive = Set(db.query("SELECT code FROM dtc_hist WHERE active = 1 AND car_id = ?", [car]) { $0.string(0) })
        let current = Set(codes)

        for code in current {
            db.execute("""
            INSERT INTO dtc_hist(car_id, code, first_seen, last_seen, active) VALUES(?,?,?,?,1)
            ON CONFLICT(car_id, code) DO UPDATE SET last_seen = excluded.last_seen, active = 1
            """, [car, code, now, now])
        }
        for code in previouslyActive.subtracting(current) {
            db.execute("UPDATE dtc_hist SET active = 0 WHERE code = ? AND car_id = ?", [code, car])
        }
        return Array(current.subtracting(previouslyActive)).sorted()
    }
}
