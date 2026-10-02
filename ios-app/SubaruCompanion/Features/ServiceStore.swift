import Foundation
import BackgroundTasks

struct ServiceItem: Identifiable {
    let id: String
    let hu: String
    let en: String
    let intervalKm: Double
    var critical = false
    var name: String { tr(hu, en) }
}

struct ServiceStatus: Identifiable {
    let item: ServiceItem
    let lastKm: Double?
    let lastDate: Date?
    /// Hátralévő km (negatív = lejárt). nil, ha még nincs megadva az utolsó csere.
    let remainingKm: Double?
    /// Okos olajcsere: a valós használat szorzója (1 = átlagos)
    var wearFactor: Double = 1
    var id: String { item.id }

    enum Level { case unknown, ok, soon, overdue }
    var level: Level {
        guard let r = remainingKm else { return .unknown }
        if r < 0 { return .overdue }
        return r <= (item.critical ? 3000 : 2000) ? .soon : .ok
    }
    var progress: Double {
        guard let r = remainingKm, item.intervalKm > 0 else { return 0 }
        return min(1, max(0, 1 - r / item.intervalKm))
    }
}

enum ServiceStore {
    private static var db: Database { .shared }

    /// Az autó szervizterve (a sablonból jött, tételenként szerkeszthető).
    static func plan(car: Int = CarStore.activeId) -> [ServiceItem] {
        db.query("SELECT item, hu, en, interval_km, critical FROM service_plan WHERE car_id = ? ORDER BY sort, item", [car]) {
            ServiceItem(id: $0.string(0), hu: $0.string(1), en: $0.string(2), intervalKm: $0.double(3),
                        critical: $0.int(4) == 1)
        }
    }

    static func statuses(odometer: Double, car: Int = CarStore.activeId) -> [ServiceStatus] {
        let rows = db.query("SELECT item, last_km, last_date FROM service_done WHERE car_id = ?", [car]) {
            ($0.string(0), $0.double(1), $0.double(2))
        }
        let byId = Dictionary(rows.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        return plan(car: car).map { item in
            guard let (km, date) = byId[item.id] else {
                return ServiceStatus(item: item, lastKm: nil, lastDate: nil, remainingKm: nil)
            }
            let last = Date(timeIntervalSince1970: date)
            var remaining = item.intervalKm > 0 ? km + item.intervalKm - odometer : nil
            var factor = 1.0
            // Okos olajcsere: rövid utak, hidegindítás, alapjárat többlet-kopása levonódik a hátralévő km-ből
            if AppSettings.shared.featSmartOil, item.id == "oil" || item.id == "oil_filter", let r = remaining {
                let wear = OilWear.since(last, car: car)
                remaining = r - wear.extraKm
                factor = wear.factor
            }
            return ServiceStatus(item: item, lastKm: km, lastDate: last, remainingKm: remaining, wearFactor: factor)
        }
    }

    static func markDone(_ id: String, km: Double, date: Date = Date()) {
        let car = CarStore.activeId
        db.execute("INSERT OR REPLACE INTO service_done(car_id, item, last_km, last_date) VALUES(?,?,?,?)",
                   [car, id, km, date.timeIntervalSince1970])
        UserDefaults.standard.removeObject(forKey: "svcNotified-\(car)-\(id)")
    }

    /// Napi átlagos km az elmúlt 90 nap útjaiból (nil, ha még kevés az adat).
    static func kmPerDay(car: Int = CarStore.activeId) -> Double? {
        let since = Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970
        let row = db.query("SELECT SUM(distance_km), MIN(start) FROM trips WHERE end_t IS NOT NULL AND car_id = ? AND start >= ?",
                           [car, since]) { ($0.double(0), $0.optDouble(1)) }.first
        guard let row, let first = row.1, row.0 >= 20 else { return nil }
        let days = max(14, (Date().timeIntervalSince1970 - first) / 86400)
        return row.0 / days
    }

    static func setInterval(_ id: String, km: Double) {
        guard km.isFinite, km >= 0, km <= 500_000 else { return }
        db.execute("UPDATE service_plan SET interval_km = ? WHERE car_id = ? AND item = ?", [km, CarStore.activeId, id])
    }

    /// Minden autóra, naponta legfeljebb egyszer értesít tételenként.
    static func checkAndNotify() {
        let cars = CarStore.all()
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0

        for car in cars where car.odometerSet && car.odometerKm > 0 {
            let who = cars.count > 1 ? "\(car.name): " : ""
            for s in statuses(odometer: car.odometerKm, car: car.id) {
                guard let r = s.remainingKm, s.level == .soon || s.level == .overdue else { continue }
                let key = "svcNotified-\(car.id)-\(s.item.id)"
                guard UserDefaults.standard.double(forKey: key) < today else { continue }
                UserDefaults.standard.set(today, forKey: key)

                let km = fmt.string(from: NSNumber(value: abs(r))) ?? "\(Int(abs(r)))"
                if s.item.critical && r >= 0 {
                    NotificationManager.shared.send(
                        key: key, title: "🚨 " + who + tr("KRITIKUS — \(s.item.hu)", "CRITICAL — \(s.item.en)"),
                        body: tr("\(s.item.hu): \(km) km múlva esedékes. Egyeztess szervizidőpontot.",
                                 "\(s.item.en): due in \(km) km. Arrange a service appointment."),
                        level: .critical)
                } else if r < 0 {
                    NotificationManager.shared.send(
                        key: key, title: "🔴 " + who + tr("Szerviz lejárt", "Service overdue"),
                        body: tr("\(s.item.hu): \(km) km-rel ezelőtt kellett volna",
                                 "\(s.item.en): overdue by \(km) km"),
                        level: s.item.critical ? .critical : .normal)
                } else {
                    NotificationManager.shared.send(
                        key: key, title: "🔧 " + who + tr("Szerviz közeleg", "Service due soon"),
                        body: tr("\(s.item.hu) \(km) km múlva esedékes", "\(s.item.en) due in \(km) km"))
                }
            }
        }
    }
}

/// Napi háttérellenőrzés (az iOS dönti el, pontosan mikor futtatja).
enum ServiceScheduler {
    static let taskId = "hu.kocsi.subaru.servicecheck"

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            ServiceStore.checkAndNotify()
            MonthlySummary.notifyIfNewMonth()
            schedule()
            Task {
                await FrostCheck.runIfDue()
                task.setTaskCompleted(success: true)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
