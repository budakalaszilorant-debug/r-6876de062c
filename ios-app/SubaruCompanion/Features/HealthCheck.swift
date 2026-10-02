import Foundation

/// Autó átvilágítás (vásárlás előtt, műszaki előtt, szerelőnek). Csak olvasott adatokból dolgozik.
struct HealthItem: Identifiable {
    enum Level { case ok, warn, bad, info }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String
}

struct HealthReport {
    let date: Date
    let carName: String
    let vin: String?
    let items: [HealthItem]

    var worst: HealthItem.Level {
        if items.contains(where: { $0.level == .bad }) { return .bad }
        return items.contains(where: { $0.level == .warn }) ? .warn : .ok
    }

    var verdict: String {
        switch worst {
        case .bad: return tr("Problémát találtam", "Problems found")
        case .warn: return tr("Figyelmet érdemel", "Needs attention")
        default: return tr("Nem találtam gondot", "No problems found")
        }
    }

    /// Megosztható szöveges jelentés.
    var text: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "\(carName) — \(tr("átvilágítás", "health check"))\n\(f.string(from: date))\n"
        if let vin { out += "VIN: \(vin)\n" }
        out += "\n\(verdict)\n\n"
        for i in items {
            let mark: String
            switch i.level {
            case .ok: mark = "[OK]"
            case .warn: mark = "[!]"
            case .bad: mark = "[HIBA]"
            case .info: mark = "[i]"
            }
            out += "\(mark) \(i.title): \(i.detail)\n"
        }
        return out
    }
}

/// A Mode 01 PID 01 négy bájtjának értelmezése.
struct Readiness {
    struct Monitor {
        let name: String
        let complete: Bool
    }

    let milOn: Bool
    let storedCodes: Int
    let monitors: [Monitor]

    var incomplete: [Monitor] { monitors.filter { !$0.complete } }

    init?(bytes: [Int]?) {
        guard let b = bytes, b.count == 4 else { return nil }
        let a = b[0], bb = b[1], c = b[2], d = b[3]
        milOn = a & 0x80 != 0
        storedCodes = a & 0x7F

        var list: [Monitor] = []
        // Folyamatos tesztek: támogatás a B bájt alsó bitjei, "nem kész" a 4-6. bit
        let continuous: [(Int, String)] = [
            (0, tr("Égéskimaradás", "Misfire")),
            (1, tr("Tüzelőanyag-rendszer", "Fuel system")),
            (2, tr("Alkatrész-ellenőrzés", "Components")),
        ]
        for (bit, name) in continuous where bb & (1 << bit) != 0 {
            list.append(Monitor(name: name, complete: bb & (1 << (bit + 4)) == 0))
        }

        // Nem folyamatos tesztek: a bit 3 jelzi a dízelt (kompressziós gyújtás)
        let diesel = bb & 0x08 != 0
        let spark: [Int: String] = [
            0: tr("Katalizátor", "Catalyst"), 1: tr("Fűtött katalizátor", "Heated catalyst"),
            2: tr("Üzemanyag-gőz (EVAP)", "Evaporative system"), 3: tr("Szekunder levegő", "Secondary air"),
            4: tr("Klíma hűtőközeg", "A/C refrigerant"), 5: tr("Lambdaszonda", "Oxygen sensor"),
            6: tr("Lambdaszonda fűtés", "Oxygen sensor heater"), 7: "EGR",
        ]
        let compression: [Int: String] = [
            0: tr("Katalizátor (NMHC)", "NMHC catalyst"), 1: tr("NOx utókezelés", "NOx aftertreatment"),
            3: tr("Feltöltés nyomás", "Boost pressure"), 5: tr("Kipufogógáz-szenzor", "Exhaust gas sensor"),
            6: tr("Részecskeszűrő", "Particulate filter"), 7: "EGR / VVT",
        ]
        let names = diesel ? compression : spark
        for bit in 0..<8 {
            guard c & (1 << bit) != 0, let name = names[bit] else { continue }
            list.append(Monitor(name: name, complete: d & (1 << bit) == 0))
        }
        monitors = list
    }
}

enum HealthCheck {
    static func build(from p: VehiclePacket, carName: String) -> HealthReport {
        var items: [HealthItem] = []

        // 1. Motorhiba lámpa és tárolt hibák
        let readiness = Readiness(bytes: p.mon)
        if let r = readiness {
            items.append(r.milOn
                ? .init(level: .bad, title: tr("Motorhiba lámpa", "Check engine light"),
                        detail: tr("Ég.", "On."))
                : .init(level: .ok, title: tr("Motorhiba lámpa", "Check engine light"),
                        detail: tr("Nem ég.", "Off.")))
        }
        if p.faultCodes.isEmpty {
            items.append(.init(level: .ok, title: tr("Tárolt hibakódok", "Stored fault codes"),
                               detail: tr("Nincs.", "None.")))
        } else {
            let list = p.faultCodes.map { "\($0) (\(DTC.describe($0)))" }.joined(separator: "; ")
            items.append(.init(level: .bad, title: tr("Tárolt hibakódok", "Stored fault codes"), detail: list))
        }

        // 2. Nemrég törölték-e a hibákat? (hibatörlés, akku lecsatlakoztatása)
        let kmClear = p.distSinceClearKm
        let minClear = p.timeClearMin
        if kmClear != nil || minClear != nil {
            let recent = (kmClear ?? .infinity) < 100 || (minClear ?? .infinity) < 2 * 24 * 60
            var parts: [String] = []
            if let km = kmClear { parts.append("\(Int(km)) km") }
            if let m = minClear { parts.append(durationText(minutes: m)) }
            let since = parts.joined(separator: ", ")
            items.append(recent
                ? .init(level: .warn, title: tr("Hibatörlés óta", "Since codes were cleared"),
                        detail: tr("Csak \(since). Nemrég törölték a hibákat, vagy leszedték az akkut. Kérdezd meg az eladót, miért.",
                                   "Only \(since). Codes were recently cleared or the battery was disconnected. Ask the seller why."))
                : .init(level: .ok, title: tr("Hibatörlés óta", "Since codes were cleared"), detail: since))
        } else {
            items.append(.init(level: .info, title: tr("Hibatörlés óta", "Since codes were cleared"),
                               detail: tr("Ez az autó nem adja ki.", "This car does not report it.")))
        }

        // 3. Készenléti tesztek (műszaki vizsgához)
        if let r = readiness {
            let pending = r.incomplete
            if pending.isEmpty {
                items.append(.init(level: .ok, title: tr("Készenléti tesztek", "Readiness tests"),
                                   detail: tr("Mind lefutott (\(r.monitors.count)).", "All complete (\(r.monitors.count)).")))
            } else {
                let names = pending.map(\.name).joined(separator: ", ")
                items.append(.init(level: .warn, title: tr("Készenléti tesztek", "Readiness tests"),
                                   detail: tr("Nem futott le: \(names). Hibatörlés vagy akku lecsatlakoztatása után egy hétnyi vegyes vezetés kell hozzá. Műszaki vizsgán elutasíthatják.",
                                              "Not complete: \(names). After clearing codes or disconnecting the battery they need about a week of mixed driving. This can fail an emissions inspection.")))
            }
        } else {
            items.append(.init(level: .info, title: tr("Készenléti tesztek", "Readiness tests"),
                               detail: tr("Még nincs adat. Járó motornál, kb. fél perc után próbáld újra.",
                                          "No data yet. Try again with the engine running, after about half a minute.")))
        }

        // 4. Azonosítás
        if let vin = p.vin {
            items.append(.init(level: .info, title: "VIN", detail: vin))
        } else {
            items.append(.init(level: .warn, title: "VIN", detail: tr("Nem olvasható ki.", "Cannot be read.")))
        }
        if let odo = p.odometerKm {
            items.append(.init(level: .info, title: tr("Km óra (az autótól)", "Odometer (from the car)"),
                               detail: "\(Fmt.km(odo)) km"))
        }

        // 5. Élő értékek
        if let c = p.coolantTemp {
            items.append(.init(level: .info, title: tr("Hűtővíz", "Coolant"), detail: "\(Int(c))°C"))
        }
        if let v = p.batteryVoltage {
            let level = VehicleMonitor.level(for: v, running: p.engineRunning)
            let l: HealthItem.Level = (level == .low || level == .high) ? .bad : (level == .caution ? .warn : .ok)
            items.append(.init(level: l, title: tr("Akku feszültség", "Battery voltage"),
                               detail: String(format: "%.1f V", v)))
        }

        return HealthReport(date: Date(), carName: carName, vin: p.vin, items: items)
    }

    private static func durationText(minutes: Double) -> String {
        let days = Int(minutes / 1440)
        if days >= 1 { return tr("\(days) napja", "\(days) days ago") }
        let h = Int(minutes / 60)
        return h >= 1 ? tr("\(h) órája", "\(h) h ago") : tr("\(Int(minutes)) perce", "\(Int(minutes)) min ago")
    }
}
