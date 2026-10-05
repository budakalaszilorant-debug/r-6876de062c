import Foundation

enum FuelType: String, CaseIterable, Identifiable {
    case petrol, diesel
    var id: String { rawValue }
    var label: String { self == .petrol ? tr("Benzin", "Petrol") : tr("Dízel", "Diesel") }

    /// OBD2 PID 0x51 kódja alapján
    init?(obdCode: Int) {
        switch obdCode {
        case 1: self = .petrol
        case 4: self = .diesel
        default: return nil
        }
    }
}

struct CarProfile: Identifiable, Equatable {
    let id: Int
    var name: String
    var vin: String?
    var fuel: FuelType
    var tankL: Double
    var warmTemp: Double
    var redline: Double
    var odometerKm: Double
    var odometerSet: Bool
    var template: String
}

/// Kiinduló adatok autótípusonként. A szervizintervallumok szokásos értékek: a szervizkönyv az irányadó,
/// és az appban tételenként átírhatók.
struct CarTemplate: Identifiable {
    let id: String
    let name: String
    let fuel: FuelType
    let tankL: Double
    let warmTemp: Double
    let redline: Double
    let service: [ServiceItem]

    static let all: [CarTemplate] = [fiesta, combo, petrol, diesel, subaru]

    static func find(_ id: String) -> CarTemplate { all.first { $0.id == id } ?? petrol }

    static let fiesta = CarTemplate(
        id: "ford_fiesta_14", name: "Ford Fiesta 2008 · 1.4 · 59 kW", fuel: .petrol, tankL: 45, warmTemp: 88, redline: 6300,
        service: [
            .init(id: "oil", hu: "Motorolaj", en: "Engine oil", intervalKm: 15_000),
            .init(id: "oil_filter", hu: "Olajszűrő", en: "Oil filter", intervalKm: 15_000),
            .init(id: "cabin_filter", hu: "Pollenszűrő", en: "Cabin air filter", intervalKm: 15_000),
            .init(id: "air_filter", hu: "Levegőszűrő", en: "Air filter", intervalKm: 30_000),
            .init(id: "spark", hu: "Gyújtógyertyák", en: "Spark plugs", intervalKm: 60_000),
            .init(id: "aux_belt", hu: "Hosszbordás szíj", en: "Auxiliary belt", intervalKm: 60_000),
            .init(id: "brake_fluid", hu: "Fékfolyadék", en: "Brake fluid", intervalKm: 40_000),
            .init(id: "coolant", hu: "Hűtőfolyadék", en: "Coolant", intervalKm: 100_000),
            .init(id: "timing", hu: "Vezérműszíj", en: "Timing belt", intervalKm: 120_000, critical: true),
        ])

    static let combo = CarTemplate(
        id: "opel_combo_16cdti", name: "Opel Combo D · 1.6 dízel · 88 kW", fuel: .diesel, tankL: 60, warmTemp: 85, redline: 4500,
        service: [
            .init(id: "oil", hu: "Motorolaj", en: "Engine oil", intervalKm: 15_000),
            .init(id: "oil_filter", hu: "Olajszűrő", en: "Oil filter", intervalKm: 15_000),
            .init(id: "cabin_filter", hu: "Pollenszűrő", en: "Cabin air filter", intervalKm: 15_000),
            .init(id: "fuel_filter", hu: "Gázolajszűrő", en: "Diesel fuel filter", intervalKm: 30_000),
            .init(id: "air_filter", hu: "Levegőszűrő", en: "Air filter", intervalKm: 30_000),
            .init(id: "aux_belt", hu: "Hosszbordás szíj", en: "Auxiliary belt", intervalKm: 60_000),
            .init(id: "brake_fluid", hu: "Fékfolyadék", en: "Brake fluid", intervalKm: 40_000),
            .init(id: "coolant", hu: "Hűtőfolyadék", en: "Coolant", intervalKm: 100_000),
            .init(id: "timing", hu: "Vezérműszíj és vízpumpa", en: "Timing belt and water pump",
                  intervalKm: 120_000, critical: true),
        ])

    static let petrol = CarTemplate(
        id: "generic_petrol", name: "Benzines autó", fuel: .petrol, tankL: 50, warmTemp: 88, redline: 6000,
        service: [
            .init(id: "oil", hu: "Motorolaj", en: "Engine oil", intervalKm: 15_000),
            .init(id: "oil_filter", hu: "Olajszűrő", en: "Oil filter", intervalKm: 15_000),
            .init(id: "cabin_filter", hu: "Pollenszűrő", en: "Cabin air filter", intervalKm: 15_000),
            .init(id: "air_filter", hu: "Levegőszűrő", en: "Air filter", intervalKm: 30_000),
            .init(id: "spark", hu: "Gyújtógyertyák", en: "Spark plugs", intervalKm: 60_000),
            .init(id: "brake_fluid", hu: "Fékfolyadék", en: "Brake fluid", intervalKm: 40_000),
            .init(id: "timing", hu: "Vezérműszíj", en: "Timing belt", intervalKm: 100_000, critical: true),
        ])

    static let diesel = CarTemplate(
        id: "generic_diesel", name: "Dízel autó", fuel: .diesel, tankL: 60, warmTemp: 85, redline: 4500,
        service: [
            .init(id: "oil", hu: "Motorolaj", en: "Engine oil", intervalKm: 15_000),
            .init(id: "oil_filter", hu: "Olajszűrő", en: "Oil filter", intervalKm: 15_000),
            .init(id: "cabin_filter", hu: "Pollenszűrő", en: "Cabin air filter", intervalKm: 15_000),
            .init(id: "fuel_filter", hu: "Gázolajszűrő", en: "Diesel fuel filter", intervalKm: 30_000),
            .init(id: "air_filter", hu: "Levegőszűrő", en: "Air filter", intervalKm: 30_000),
            .init(id: "brake_fluid", hu: "Fékfolyadék", en: "Brake fluid", intervalKm: 40_000),
            .init(id: "timing", hu: "Vezérműszíj", en: "Timing belt", intervalKm: 120_000, critical: true),
        ])

    static let subaru = CarTemplate(
        id: "subaru_ej20", name: "Subaru Impreza RS", fuel: .petrol, tankL: 60, warmTemp: 88, redline: 6500,
        service: [
            .init(id: "oil", hu: "Motorolaj", en: "Engine oil", intervalKm: 10_000),
            .init(id: "oil_filter", hu: "Olajszűrő", en: "Oil filter", intervalKm: 10_000),
            .init(id: "cabin_filter", hu: "Pollenszűrő", en: "Cabin air filter", intervalKm: 15_000),
            .init(id: "air_filter", hu: "Levegőszűrő", en: "Air filter", intervalKm: 20_000),
            .init(id: "fuel_filter", hu: "Üzemanyagszűrő", en: "Fuel filter", intervalKm: 30_000),
            .init(id: "spark", hu: "Gyújtógyertyák (NGK irídium)", en: "Spark plugs (NGK iridium)", intervalKm: 30_000),
            .init(id: "coolant", hu: "Hűtőfolyadék", en: "Coolant flush", intervalKm: 40_000),
            .init(id: "brake_fluid", hu: "Fékfolyadék", en: "Brake fluid", intervalKm: 40_000),
            .init(id: "gearbox", hu: "Váltóolaj", en: "Gearbox oil", intervalKm: 40_000),
            .init(id: "diff", hu: "Differenciálmű olaj (AWD)", en: "AWD diff fluid", intervalKm: 40_000),
            .init(id: "timing", hu: "Vezérműszíj", en: "Timing belt", intervalKm: 100_000, critical: true),
        ])
}

/// Autóprofilok tárolása. Minden más tábla `car_id` oszloppal kapcsolódik ide.
enum CarStore {
    private static var db: Database { .shared }

    /// Az éppen kiválasztott autó azonosítója (minden lekérdezés erre szűr).
    static var activeId: Int { AppSettings.shared.activeCarId }

    private static let columns = "id, name, vin, fuel, tank_l, warm_temp, redline, odo, odo_set, template"

    private static func map(_ r: Database.Row) -> CarProfile {
        let vin = r.string(2)
        return CarProfile(id: r.int(0), name: r.string(1), vin: vin.isEmpty ? nil : vin,
                          fuel: FuelType(rawValue: r.string(3)) ?? .petrol,
                          tankL: r.double(4), warmTemp: r.double(5), redline: r.double(6),
                          odometerKm: r.double(7), odometerSet: r.int(8) == 1, template: r.string(9))
    }

    static func all() -> [CarProfile] {
        db.query("SELECT \(columns) FROM cars ORDER BY id", map: map)
    }

    static func get(_ id: Int) -> CarProfile? {
        db.query("SELECT \(columns) FROM cars WHERE id = ?", [id], map: map).first
    }

    static func key(_ name: String, car: Int? = nil) -> String {
        "car-\(car ?? activeId)-\(name)"
    }

    static func validVIN(_ vin: String) -> Bool {
        vin.count == 17 && vin.allSatisfy { "ABCDEFGHJKLMNPRSTUVWXYZ0123456789".contains($0) }
    }

    static func find(vin: String) -> CarProfile? {
        db.query("SELECT \(columns) FROM cars WHERE vin = ?", [vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()], map: map).first
    }

    static func save(_ c: CarProfile) {
        db.execute("""
            UPDATE cars SET name = ?, vin = ?, fuel = ?, tank_l = ?, warm_temp = ?, redline = ?,
                            odo = ?, odo_set = ? WHERE id = ?
            """, [c.name, c.vin, c.fuel.rawValue, c.tankL, c.warmTemp, c.redline,
                  c.odometerKm, c.odometerSet ? 1 : 0, c.id])
    }

    @discardableResult
    static func create(from template: CarTemplate, name: String? = nil, vin: String? = nil) -> Int {
        db.insertCar(template: template, name: name ?? template.name, vin: vin,
                     odometer: 0, odometerSet: false)
    }

    /// Az autó és minden adata törlődik.
    static func delete(_ id: Int) {
        guard all().count > 1, id != activeId else { return }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("car-\(id)-") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        db.execute("DELETE FROM trip_points WHERE trip_id IN (SELECT id FROM trips WHERE car_id = ?)", [id])
        for t in Database.carTables { db.execute("DELETE FROM \(t) WHERE car_id = ?", [id]) }
        db.execute("DELETE FROM cars WHERE id = ?", [id])
    }

    /// Mentés visszaállítása után a régi (autó nélküli) sorok az aktív autóhoz kerülnek.
    static func adoptOrphans() {
        for t in Database.carTables {
            db.execute("UPDATE \(t) SET car_id = ? WHERE car_id IS NULL", [activeId])
        }
    }
}

extension Database {
    /// Azok a táblák, amelyek sorai egy autóhoz tartoznak.
    static let carTables = ["garage_plus", "expenses", "trips", "fills", "parking", "voltage_log", "events", "battery_health",
                            "service_plan", "service_done", "reminder_dates", "dtc_hist"]

    /// Autó beszúrása a sablon szervizterv tételeivel. A migráció is ezt használja, ezért
    /// nem hivatkozhat a `Database.shared`-re.
    @discardableResult
    func insertCar(template t: CarTemplate, name: String, vin: String?, odometer: Double, odometerSet: Bool,
                   tankL: Double? = nil, warmTemp: Double? = nil, redline: Double? = nil) -> Int {
        let id = execute("""
            INSERT INTO cars(name, vin, fuel, tank_l, warm_temp, redline, odo, odo_set, template)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [name, vin, t.fuel.rawValue, tankL ?? t.tankL, warmTemp ?? t.warmTemp, redline ?? t.redline,
                  odometer, odometerSet ? 1 : 0, t.id])
        for (i, s) in t.service.enumerated() {
            execute("""
                INSERT OR REPLACE INTO service_plan(car_id, item, hu, en, interval_km, critical, sort)
                VALUES(?,?,?,?,?,?,?)
                """, [id, s.id, s.hu, s.en, t.id == "subaru_ej20" ? s.intervalKm : 0, s.critical ? 1 : 0, i])
        }
        return id
    }

    /// 2-es séma: több autó. A meglévő adatok egy saját autóprofilba kerülnek.
    func migrateToGarage() {
        execute("""
            CREATE TABLE IF NOT EXISTS cars(
              id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, vin TEXT, fuel TEXT, tank_l REAL,
              warm_temp REAL, redline REAL, odo REAL, odo_set INTEGER, template TEXT)
            """)
        execute("""
            CREATE TABLE IF NOT EXISTS service_plan(
              car_id INTEGER, item TEXT, hu TEXT, en TEXT, interval_km REAL, critical INTEGER, sort INTEGER,
              PRIMARY KEY(car_id, item))
            """)
        execute("CREATE TABLE IF NOT EXISTS service_done(car_id INTEGER, item TEXT, last_km REAL, last_date REAL, PRIMARY KEY(car_id, item))")
        execute("CREATE TABLE IF NOT EXISTS reminder_dates(car_id INTEGER, id TEXT, date REAL, PRIMARY KEY(car_id, id))")
        execute("""
            CREATE TABLE IF NOT EXISTS dtc_hist(
              car_id INTEGER, code TEXT, first_seen REAL, last_seen REAL, active INTEGER, snap TEXT,
              PRIMARY KEY(car_id, code))
            """)
        for t in ["trips", "fills", "parking", "voltage_log", "events", "battery_health"] {
            if !query("PRAGMA table_info(\(t))", map: { $0.string(1) }).contains("car_id") {
                execute("ALTER TABLE \(t) ADD COLUMN car_id INTEGER")
            }
        }

        let d = UserDefaults.standard
        let hasData = (query("SELECT COUNT(*) FROM trips") { $0.int(0) }.first ?? 0) > 0
            || (query("SELECT COUNT(*) FROM fills") { $0.int(0) }.first ?? 0) > 0
        let legacyTables = ["service", "reminders", "dtc_log", "parking", "voltage_log", "events", "battery_health"]
        let used = hasData || d.bool(forKey: "odoSet") || d.string(forKey: "vin") != nil || legacyTables.contains {
            (query("SELECT COUNT(*) FROM \($0)") { $0.int(0) }.first ?? 0) > 0
        }

        if used {
            // Az eddigi adatok a Subaru profilhoz tartoznak
            let s = CarTemplate.subaru
            let old = insertCar(template: s, name: d.string(forKey: "carName") ?? s.name, vin: d.string(forKey: "vin"),
                                odometer: d.double(forKey: "odo"), odometerSet: d.bool(forKey: "odoSet"),
                                tankL: d.object(forKey: "tankLiters") as? Double,
                                warmTemp: d.object(forKey: "warmTemp") as? Double,
                                redline: d.object(forKey: "redline") as? Double)
            for t in ["trips", "fills", "parking", "voltage_log", "events", "battery_health"] {
                execute("UPDATE \(t) SET car_id = ? WHERE car_id IS NULL", [old])
            }
            execute("INSERT OR IGNORE INTO service_done SELECT ?, item, last_km, last_date FROM service", [old])
            execute("INSERT OR IGNORE INTO reminder_dates SELECT ?, id, date FROM reminders", [old])
            execute("INSERT OR IGNORE INTO dtc_hist SELECT ?, code, first_seen, last_seen, active, snap FROM dtc_log", [old])
        }

        if let first = query("SELECT id FROM cars ORDER BY id LIMIT 1", map: { $0.int(0) }).first {
            d.set(first, forKey: "activeCarId")
        }
    }
}
