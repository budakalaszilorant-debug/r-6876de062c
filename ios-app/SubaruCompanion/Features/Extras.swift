import Foundation
import Combine

// MARK: - Parkolóóra

/// Visszaszámláló a parkolás lejártáig. Előre ütemezett helyi értesítésekkel működik,
/// így akkor is szól, ha az app nem fut.
final class ParkingTimer: ObservableObject {
    static let shared = ParkingTimer()
    static let presets = [30, 60, 90, 120]

    @Published private(set) var end: Date?

    private let key = "parkTimerEnd"
    private let ids = ["parkTimer-warn", "parkTimer-end"]

    private init() {
        let t = UserDefaults.standard.double(forKey: key)
        if t > Date().timeIntervalSince1970 { end = Date(timeIntervalSince1970: t) }
    }

    var isRunning: Bool { (end ?? .distantPast) > Date() }

    func start(minutes: Int) {
        cancel()
        let total = Double(minutes) * 60
        let finish = Date().addingTimeInterval(total)
        end = finish
        UserDefaults.standard.set(finish.timeIntervalSince1970, forKey: key)

        // Előjelzés: 10 perccel a vége előtt, rövid időnél arányosan korábban.
        let warn = max(1, min(10, minutes / 3))
        NotificationManager.shared.schedule(
            id: ids[0], after: total - Double(warn) * 60,
            title: tr("🅿️ Parkolás hamarosan lejár", "🅿️ Parking expires soon"),
            body: tr("\(warn) perc van hátra.", "\(warn) minutes left."),
            level: .timeSensitive)
        NotificationManager.shared.schedule(
            id: ids[1], after: total,
            title: tr("🅿️ Parkolás lejárt", "🅿️ Parking expired"),
            body: tr("A beállított parkolási idő letelt.", "Your parking time is up."),
            level: .timeSensitive)
    }

    func cancel() {
        end = nil
        UserDefaults.standard.removeObject(forKey: key)
        NotificationManager.shared.cancel(ids: ids)
    }
}

// MARK: - Havi összesítő

struct MonthlySummary {
    var month: Date
    var trips = 0
    var km = 0.0
    var driveSeconds = 0.0
    var idleSeconds = 0.0
    var idleFuelL = 0.0
    var fuelL = 0.0        // az utak becsült fogyasztása
    var cost = 0.0         // a tankolási napló szerint
    var workKm = 0.0       // „munka” címkéjű utak
    var tripCost = 0.0     // az utak becsült benzinköltsége
    var liters = 0.0

    var avgL100: Double? { km > 1 && fuelL > 0 ? fuelL / km * 100 : nil }
    /// Alapjáraton elégetett benzin ára az utolsó tankolás literárával.
    var idleCost: Double { idleFuelL * AppSettings.shared.lastFuelPrice }
    var isEmpty: Bool { trips == 0 && cost == 0 }

    static func monthStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    static func compute(for date: Date) -> MonthlySummary {
        let start = monthStart(date)
        let end = Calendar.current.date(byAdding: .month, value: 1, to: start) ?? start
        let range: [Any?] = [start.timeIntervalSince1970, end.timeIntervalSince1970]
        var s = MonthlySummary(month: start)

        let db = Database.shared
        _ = db.query("""
            SELECT COUNT(*), SUM(distance_km), SUM(end_t - start), SUM(idle_s), SUM(idle_fuel_l), SUM(fuel_l),
                   SUM(CASE WHEN tag = 'work' THEN distance_km ELSE 0 END), SUM(cost)
            FROM trips WHERE end_t IS NOT NULL AND start >= ? AND start < ?
            """, range) { r in
            s.trips = r.int(0)
            s.km = r.double(1)
            s.driveSeconds = r.double(2)
            s.idleSeconds = r.double(3)
            s.idleFuelL = r.double(4)
            s.fuelL = r.double(5)
            s.workKm = r.double(6)
            s.tripCost = r.double(7)
        }
        _ = db.query("SELECT SUM(cost), SUM(liters) FROM fills WHERE date >= ? AND date < ?", range) { r in
            s.cost = r.double(0)
            s.liters = r.double(1)
        }
        return s
    }

    /// A hónap útjai CSV-ben (útnyilvántartáshoz).
    static func csv(for date: Date) -> String {
        let start = monthStart(date)
        let end = Calendar.current.date(byAdding: .month, value: 1, to: start) ?? start
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "indulas;erkezes;km;liter;koltseg_ft;cimke\n"
        let trips = TripStore.all().filter { $0.start >= start && $0.start < end }.reversed()
        for t in trips {
            let tag = t.tag == "work" ? "munka" : (t.tag == "private" ? "magan" : "")
            out += "\(f.string(from: t.start));\(t.end.map { f.string(from: $0) } ?? "");"
            out += String(format: "%.1f;%.2f;%.0f;", t.distanceKm, t.fuelL ?? 0, t.cost ?? 0) + tag + "\n"
        }
        return out
    }

    static func title(_ date: Date) -> String {
        let f = DateFormatter()
        let hu = AppSettings.shared.language == .hu
        f.locale = Locale(identifier: hu ? "hu_HU" : "en_GB")
        f.dateFormat = hu ? "yyyy. LLLL" : "LLLL yyyy"
        return f.string(from: date)
    }

    /// Hónapváltáskor egyszer értesít az előző hónap összesítőjével.
    static func notifyIfNewMonth() {
        guard AppSettings.shared.featMonthly else { return }
        let key = "summaryMonth"
        let current = monthStart(Date()).timeIntervalSince1970
        let stored = UserDefaults.standard.double(forKey: key)
        guard stored != current else { return }
        UserDefaults.standard.set(current, forKey: key)
        guard stored > 0 else { return }  // első futás: nincs előző hónap

        let previous = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let s = compute(for: previous)
        guard !s.isEmpty else { return }
        let avg = s.avgL100.map { String(format: "%.1f l/100", $0) } ?? "—"
        NotificationManager.shared.send(
            key: "monthly",
            title: tr("📊 Havi összesítő — \(title(previous))", "📊 Monthly summary — \(title(previous))"),
            body: tr("\(Fmt.km(s.km)) km · \(s.trips) út · \(avg) · \(Fmt.km(s.cost)) Ft benzin",
                     "\(Fmt.km(s.km)) km · \(s.trips) trips · \(avg) · \(Fmt.km(s.cost)) Ft fuel"))
    }
}

// MARK: - Hatótáv

enum RangeEstimator {
    /// Impreza (GH/GR) tank térfogata
    static var tankLiters: Double { max(10, AppSettings.shared.tankLiters) }
    /// Ha még nincs saját adat, ezzel az átlaggal számol.
    static let fallbackL100 = 8.5

    /// Átlagfogyasztás: elsősorban a tankolási naplóból (valós), másodsorban az utak becsléséből.
    static func averageL100() -> Double {
        if let real = FuelStore.stats(FuelStore.all()).avgL100, real > 3 { return real }
        let recent = TripStore.all().prefix(15)
        let km = recent.reduce(0) { $0 + $1.distanceKm }
        let fuel = recent.compactMap(\.fuelL).reduce(0, +)
        if km > 20, fuel > 0 { return fuel / km * 100 }
        return fallbackL100
    }

    static func rangeKm(fuelLevel: Double, avgL100: Double) -> Double {
        fuelLevel / 100 * tankLiters / avgL100 * 100
    }
}

// MARK: - Akku egészség

struct BatterySample: Identifiable {
    let id: Int
    let date: Date
    /// Nyugalmi feszültség indítás előtt (legalább 1 óra állás után)
    let restV: Double?
    /// Legalacsonyabb feszültség önindítózás közben
    let crankV: Double?
    /// Töltőfeszültség indítás után
    let chargeV: Double?
}

enum BatteryHealth {
    enum Grade: Int { case unknown = 0, good, fair, weak }

    static func grade(rest: Double?, crank: Double?) -> Grade {
        var g = Grade.unknown
        // Egészséges akku önindítózáskor nem esik 9,6 V alá.
        if let c = crank { g = c >= 9.6 ? .good : (c >= 9.0 ? .fair : .weak) }
        // Nyugalmi feszültség: 12,4 V felett jó töltöttség, 12,1 V alatt gyenge.
        if let r = rest {
            let rg: Grade = r >= 12.4 ? .good : (r >= 12.1 ? .fair : .weak)
            if rg.rawValue > g.rawValue { g = rg }
        }
        return g
    }

    static func recent(limit: Int = 60) -> [BatterySample] {
        Database.shared.query(
            "SELECT rowid, t, rest_v, crank_v, charge_v FROM battery_health ORDER BY t DESC LIMIT ?", [limit]) {
            BatterySample(id: $0.int(0), date: Date(timeIntervalSince1970: $0.double(1)),
                          restV: $0.optDouble(2), crankV: $0.optDouble(3), chargeV: $0.optDouble(4))
        }.reversed()
    }

    /// Elmenti az indítás mérését, és gyenge akkunál hetente legfeljebb egyszer értesít.
    static func record(startId: Int, rest: Double?, crank: Double?, charge: Double?) {
        guard rest != nil || crank != nil else { return }
        Database.shared.execute(
            "INSERT INTO battery_health(t, start_id, rest_v, crank_v, charge_v) VALUES(?,?,?,?,?)",
            [Date().timeIntervalSince1970, startId, rest, crank, charge])

        guard grade(rest: rest, crank: crank) == .weak else { return }
        let key = "battWeakNotified"
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: key) > 7 * 86400 else { return }
        UserDefaults.standard.set(now, forKey: key)

        var parts: [String] = []
        if let r = rest { parts.append(tr("nyugalmi \(String(format: "%.1f", r)) V", "resting \(String(format: "%.1f", r)) V")) }
        if let c = crank { parts.append(tr("indításkor \(String(format: "%.1f", c)) V", "cranking \(String(format: "%.1f", c)) V")) }
        NotificationManager.shared.send(
            key: "battWeak", title: tr("🔋 Gyengül az akkumulátor", "🔋 Battery is getting weak"),
            body: parts.joined(separator: ", "), level: .timeSensitive)
    }
}
