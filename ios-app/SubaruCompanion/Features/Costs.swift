import Foundation

// MARK: - Fenntartási költségek

enum ExpenseCategory: String, CaseIterable, Identifiable {
    case service, insurance, tires, vignette, parking, wash, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .service: return tr("Szerviz, javítás", "Service, repair")
        case .insurance: return tr("Biztosítás", "Insurance")
        case .tires: return tr("Gumi", "Tyres")
        case .vignette: return tr("Matrica, útdíj", "Vignette, tolls")
        case .parking: return tr("Parkolás", "Parking")
        case .wash: return tr("Mosás, ápolás", "Washing, care")
        case .other: return tr("Egyéb", "Other")
        }
    }

    var icon: String {
        switch self {
        case .service: return "wrench.and.screwdriver.fill"
        case .insurance: return "shield.fill"
        case .tires: return "circle.circle"
        case .vignette: return "road.lanes"
        case .parking: return "parkingsign"
        case .wash: return "drop.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

struct Expense: Identifiable, Equatable {
    let id: Int
    var date: Date
    var category: ExpenseCategory
    var amount: Double
    var note: String
}

/// Egy autó összesített költsége egy időszakra.
struct CostSummary {
    var fuel = 0.0
    var byCategory: [ExpenseCategory: Double] = [:]
    var km = 0.0

    var other: Double { byCategory.values.reduce(0, +) }
    var total: Double { fuel + other }
    var perKm: Double? { km > 10 ? total / km : nil }
}

enum ExpenseStore {
    private static var db: Database { .shared }

    static func all(car: Int = CarStore.activeId) -> [Expense] {
        db.query("SELECT id, date, category, amount, note FROM expenses WHERE car_id = ? ORDER BY date DESC", [car]) {
            Expense(id: $0.int(0), date: Date(timeIntervalSince1970: $0.double(1)),
                    category: ExpenseCategory(rawValue: $0.string(2)) ?? .other,
                    amount: $0.double(3), note: $0.string(4))
        }
    }

    static func add(date: Date, category: ExpenseCategory, amount: Double, note: String, car: Int = CarStore.activeId) {
        db.execute("INSERT INTO expenses(car_id, date, category, amount, note) VALUES(?,?,?,?,?)",
                   [car, date.timeIntervalSince1970, category.rawValue, amount, note])
    }

    static func delete(_ id: Int) {
        db.execute("DELETE FROM expenses WHERE id = ?", [id])
    }

    /// Összesítés `since` óta (nil = teljes idő). A km az útnaplóból jön.
    static func summary(car: Int = CarStore.activeId, since: Date? = nil) -> CostSummary {
        let from = since?.timeIntervalSince1970 ?? 0
        var s = CostSummary()
        s.fuel = db.query("SELECT SUM(cost) FROM fills WHERE car_id = ? AND date >= ?", [car, from]) { $0.double(0) }.first ?? 0
        for row in db.query("SELECT category, SUM(amount) FROM expenses WHERE car_id = ? AND date >= ? GROUP BY category",
                            [car, from], map: { ($0.string(0), $0.double(1)) }) {
            s.byCategory[ExpenseCategory(rawValue: row.0) ?? .other, default: 0] += row.1
        }
        s.km = db.query("SELECT SUM(distance_km) FROM trips WHERE car_id = ? AND end_t IS NOT NULL AND start >= ?",
                        [car, from]) { $0.double(0) }.first ?? 0
        return s
    }
}

// MARK: - Kutankénti tankolási statisztika

struct StationStat: Identifiable {
    let name: String
    let fills: Int
    let liters: Double
    let cost: Double
    var id: String { name }
    var avgPrice: Double { liters > 0 ? cost / liters : 0 }
}

enum StationStats {
    /// Kutak átlagos literárral, olcsóbbtól a drágábbig (csak a megnevezett kutas tankolások).
    static func all(car: Int = CarStore.activeId, since: Date? = nil) -> [StationStat] {
        Database.shared.query("""
            SELECT station, COUNT(*), SUM(liters), SUM(cost) FROM fills
            WHERE car_id = ? AND date >= ? AND station IS NOT NULL AND station <> ''
            GROUP BY station ORDER BY SUM(cost) / SUM(liters)
            """, [car, since?.timeIntervalSince1970 ?? 0]) {
            StationStat(name: $0.string(0), fills: $0.int(1), liters: $0.double(2), cost: $0.double(3))
        }
    }

    /// Mennyivel fizettél többet, mintha minden litert a legolcsóbb kút átlagárán vetted volna.
    static func overpaid(_ stats: [StationStat]) -> Double {
        guard let cheapest = stats.map(\.avgPrice).filter({ $0 > 0 }).min() else { return 0 }
        return stats.reduce(0) { $0 + max(0, $1.cost - $1.liters * cheapest) }
    }

    /// A korábban használt kutak nevei (gyakoriság szerint), az űrlap gyors választójához.
    static func recentNames(car: Int = CarStore.activeId) -> [String] {
        Database.shared.query("""
            SELECT station FROM fills WHERE car_id = ? AND station IS NOT NULL AND station <> ''
            GROUP BY station ORDER BY COUNT(*) DESC, MAX(date) DESC LIMIT 8
            """, [car]) { $0.string(0) }
    }
}

// MARK: - Okos olajcsere

/// A valós használat okozta többlet-kopás az utolsó olajcsere óta, km-egyenértékben.
/// Rövid utak, hidegindítások és alapjárat jobban terhelik az olajat, mint ugyanannyi km egyenletes autópályán.
struct OilWear {
    var km = 0.0             // ténylegesen megtett km (útnapló)
    var shortTripKm = 0.0    // 8 km alatti utak
    var idleHours = 0.0
    var coldStarts = 0

    /// Többlet km: rövid utak duplán, alapjárati óránként 30 km, hidegindításonként 5 km.
    var extraKm: Double { shortTripKm + idleHours * 30 + Double(coldStarts) * 5 }
    var factor: Double { km > 50 ? (km + extraKm) / km : 1 }

    static func since(_ date: Date, car: Int = CarStore.activeId) -> OilWear {
        let db = Database.shared
        let t = date.timeIntervalSince1970
        var w = OilWear()
        _ = db.query("""
            SELECT SUM(distance_km), SUM(CASE WHEN distance_km < 8 THEN distance_km ELSE 0 END), SUM(idle_s)
            FROM trips WHERE car_id = ? AND end_t IS NOT NULL AND start >= ?
            """, [car, t]) { r in
            w.km = r.double(0)
            w.shortTripKm = r.double(1)
            w.idleHours = r.double(2) / 3600
        }
        w.coldStarts = db.query("SELECT COUNT(*) FROM events WHERE car_id = ? AND kind = 'cold_start' AND t >= ?",
                                [car, t]) { $0.int(0) }.first ?? 0
        return w
    }
}

// MARK: - Akku előrejelzés

enum BatteryForecast {
    enum Result: Equatable {
        case notEnoughData
        case stable
        /// Becsült napok, amíg a nyugalmi feszültség 12,1 V alá esik
        case weakening(days: Int)
    }

    /// Lineáris trend a nyugalmi feszültségekre (legalább 6 mérés, 14 nap).
    static func forecast(_ samples: [BatterySample]) -> Result {
        let pts = samples.compactMap { s in s.restV.map { (x: s.date.timeIntervalSince1970 / 86400, y: $0) } }
        guard pts.count >= 6, let first = pts.first, let last = pts.last, last.x - first.x >= 14 else { return .notEnoughData }
        let n = Double(pts.count)
        let mx = pts.map(\.x).reduce(0, +) / n
        let my = pts.map(\.y).reduce(0, +) / n
        let sxx = pts.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
        guard sxx > 0 else { return .stable }
        let slope = pts.map { ($0.x - mx) * ($0.y - my) }.reduce(0, +) / sxx   // V / nap
        // Évi 0,1 V-nál lassabb esés: stabilnak vesszük
        guard slope < -0.1 / 365 else { return .stable }
        let now = Date().timeIntervalSince1970 / 86400
        let current = my + slope * (now - mx)
        let days = (12.1 - current) / slope
        return .weakening(days: max(0, Int(days)))
    }
}

// MARK: - Fagyriasztás

/// Ha a következő éjszakára erős fagyot jeleznek, és az akku már gyengül, előre szól.
/// Az időjárás az Open-Meteo ingyenes szolgáltatásából jön, kulcs és fiók nélkül;
/// a helyet kb. 10 km-re kerekítve küldjük.
enum FrostCheck {
    static func runIfDue() async {
        guard AppSettings.shared.featFrost else { return }
        let d = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard d.double(forKey: "frostChecked") < today else { return }
        guard let spot = TripStore.latestParking() else { return }
        d.set(today, forKey: "frostChecked")

        let samples = BatteryHealth.recent()
        let last = samples.last
        let grade = BatteryHealth.grade(rest: last?.restV, crank: last?.crankV)
        let weakening: Bool = {
            if case .weakening(let days) = BatteryForecast.forecast(samples), days < 120 { return true }
            return false
        }()
        guard grade == .weak || grade == .fair || weakening else { return }

        let generation = AccountGarage.generation
        let lat = (spot.coordinate.latitude * 10).rounded() / 10
        let lon = (spot.coordinate.longitude * 10).rounded() / 10
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "daily", value: "temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        struct Forecast: Decodable { struct Daily: Decodable { let temperature_2m_min: [Double] }; let daily: Daily }
        guard let f = try? JSONDecoder().decode(Forecast.self, from: data),
              let tomorrow = f.daily.temperature_2m_min.dropFirst().first ?? f.daily.temperature_2m_min.first,
              tomorrow <= -5 else { return }

        let name = AppSettings.shared.carName
        await MainActor.run {
            guard generation == AccountGarage.generation else { return }
            NotificationManager.shared.send(
                key: "frost", title: tr("❄️ Fagy és gyengülő akku", "❄️ Frost and a weakening battery"),
                body: tr("Ma éjjel \(Int(tomorrow))°C várható. A(z) \(name) akkuja gyengül: holnap reggel nehezen indulhat. Ha teheted, töltsd fel, vagy tedd fedett helyre.",
                         "\(Int(tomorrow))°C expected tonight. The \(name) battery is weakening and may struggle to start. Charge it or park under cover if you can."),
                level: .timeSensitive)
        }
    }
}
