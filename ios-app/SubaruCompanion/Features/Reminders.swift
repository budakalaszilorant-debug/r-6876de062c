import Foundation

/// Dátumhoz kötött lejáratok: műszaki, biztosítás, matrica, elsősegély doboz.
/// Az értesítések előre ütemezve vannak, így az app futása nélkül is megjönnek.
struct ReminderItem: Identifiable {
    let id: String
    let hu: String
    let en: String
    let icon: String
    var name: String { tr(hu, en) }
}

enum Reminders {
    static let items: [ReminderItem] = [
        .init(id: "inspection", hu: "Műszaki vizsga", en: "Roadworthiness test", icon: "checkmark.seal"),
        .init(id: "vignette", hu: "Autópálya-matrica", en: "Motorway vignette", icon: "road.lanes"),
        .init(id: "firstaid", hu: "Elsősegély doboz", en: "First aid kit", icon: "cross.case"),
    ]

    /// Ennyi nappal a lejárat előtt szól.
    private static let leadDays = [30, 7, 1]

    static func all(car: Int = CarStore.activeId) -> [String: Date] {
        let rows = Database.shared.query("SELECT id, date FROM reminder_dates WHERE car_id = ?", [car]) {
            ($0.string(0), Date(timeIntervalSince1970: $0.double(1)))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    static func set(_ id: String, date: Date?) {
        let car = CarStore.activeId
        if let date {
            Database.shared.execute("INSERT OR REPLACE INTO reminder_dates(car_id, id, date) VALUES(?,?,?)",
                                    [car, id, date.timeIntervalSince1970])
        } else {
            Database.shared.execute("DELETE FROM reminder_dates WHERE car_id = ? AND id = ?", [car, id])
        }
        reschedule()
    }

    /// Hátralévő napok (negatív = lejárt).
    static func daysLeft(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    /// Minden autó lejárataira ütemez (nem csak az aktívéra).
    static func reschedule() {
        let cars = CarStore.all()
        let cal = Calendar.current
        let generation = AccountGarage.generation
        NotificationManager.shared.cancel(prefix: "reminder-") {
            guard generation == AccountGarage.generation else { return }
            for car in cars {
                schedule(car: car, cal: cal, prefixName: cars.count > 1)
            }
        }
    }

    private static func schedule(car: CarProfile, cal: Calendar, prefixName: Bool) {
        let saved = all(car: car.id)
        for item in items {
            guard let date = saved[item.id] else { continue }
            for d in leadDays {
                guard let day = cal.date(byAdding: .day, value: -d, to: date),
                      let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                      fire > Date() else { continue }
                let when = d == 1 ? tr("holnap lejár", "expires tomorrow")
                                  : tr("\(d) nap múlva lejár", "expires in \(d) days")
                let who = prefixName ? "\(car.name): " : ""
                NotificationManager.shared.schedule(
                    id: "reminder-\(car.id)-\(item.id)-\(d)", at: fire,
                    title: "📅 " + who + tr(item.hu, item.en),
                    body: tr("\(item.hu) \(when).", "\(item.en) \(when)."),
                    level: d == 1 ? .timeSensitive : .normal)
            }
        }
    }
}
