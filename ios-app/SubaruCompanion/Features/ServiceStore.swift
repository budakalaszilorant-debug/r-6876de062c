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
    var id: String { item.id }

    enum Level { case unknown, ok, soon, overdue }
    var level: Level {
        guard let r = remainingKm else { return .unknown }
        if r < 0 { return .overdue }
        return r <= (item.critical ? 3000 : 2000) ? .soon : .ok
    }
    var progress: Double {
        guard let r = remainingKm else { return 0 }
        return min(1, max(0, 1 - r / item.intervalKm))
    }
}

enum ServiceStore {
    /// EJ20 2.0 boxer szervizterv
    static let items: [ServiceItem] = [
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
    ]

    private static var db: Database { .shared }

    static func statuses(odometer: Double) -> [ServiceStatus] {
        let rows = db.query("SELECT item, last_km, last_date FROM service") {
            ($0.string(0), $0.double(1), $0.double(2))
        }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, ($0.1, $0.2)) })
        return items.map { item in
            guard let (km, date) = byId[item.id] else {
                return ServiceStatus(item: item, lastKm: nil, lastDate: nil, remainingKm: nil)
            }
            return ServiceStatus(item: item, lastKm: km, lastDate: Date(timeIntervalSince1970: date),
                                 remainingKm: km + item.intervalKm - odometer)
        }
    }

    static func markDone(_ id: String, km: Double, date: Date = Date()) {
        db.execute("INSERT OR REPLACE INTO service(item, last_km, last_date) VALUES(?,?,?)",
                   [id, km, date.timeIntervalSince1970])
        UserDefaults.standard.removeObject(forKey: "svcNotified-\(id)")
    }

    /// Naponta legfeljebb egyszer értesít tételenként.
    static func checkAndNotify(odometer: Double) {
        guard odometer > 0 else { return }
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0

        for s in statuses(odometer: odometer) {
            guard let r = s.remainingKm, s.level == .soon || s.level == .overdue else { continue }
            let key = "svcNotified-\(s.item.id)"
            guard UserDefaults.standard.double(forKey: key) < today else { continue }
            UserDefaults.standard.set(today, forKey: key)

            let km = fmt.string(from: NSNumber(value: abs(r))) ?? "\(Int(abs(r)))"
            if s.item.critical && r >= 0 {
                NotificationManager.shared.send(
                    key: key, title: tr("🚨 KRITIKUS — Vezérműszíj", "🚨 CRITICAL — Timing belt"),
                    body: tr("Vezérműszíj csere \(km) km múlva! A szíj szakadása motorkárt okoz.",
                             "Timing belt due in \(km) km! A snapped belt destroys the engine."),
                    level: .critical)
            } else if r < 0 {
                NotificationManager.shared.send(
                    key: key, title: tr("🔴 Szerviz lejárt", "🔴 Service overdue"),
                    body: tr("\(s.item.hu): \(km) km-rel ezelőtt kellett volna",
                             "\(s.item.en): overdue by \(km) km"),
                    level: s.item.critical ? .critical : .normal)
            } else {
                NotificationManager.shared.send(
                    key: key, title: tr("🔧 Szerviz közeleg", "🔧 Service due soon"),
                    body: tr("\(s.item.hu) \(km) km múlva esedékes", "\(s.item.en) due in \(km) km"))
            }
        }
    }
}

/// Napi háttérellenőrzés (az iOS dönti el, pontosan mikor futtatja).
enum ServiceScheduler {
    static let taskId = "hu.kocsi.subaru.servicecheck"

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            ServiceStore.checkAndNotify(odometer: AppSettings.shared.odometerKm)
            schedule()
            task.setTaskCompleted(success: true)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
