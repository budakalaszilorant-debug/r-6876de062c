import Foundation

// MARK: - Hosszú út előtti ellenőrzés

struct TripCheckItem: Identifiable {
    enum Level { case ok, warn, bad }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String
}

enum TripReadiness {
    static func check(tripKm: Double, days: Int, packet: VehiclePacket?, range: Double?) -> [TripCheckItem] {
        let s = AppSettings.shared
        var items: [TripCheckItem] = []

        // Szerviz: lejár-e útközben
        if s.odometerSet {
            let due = ServiceStore.statuses(odometer: s.odometerKm).filter { st in
                guard let r = st.remainingKm else { return false }
                return r < tripKm + 500
            }
            if due.isEmpty {
                items.append(.init(level: .ok, title: tr("Szerviz", "Service"), detail: tr("Útközben nem lesz esedékes.", "Nothing falls due on the way.")))
            } else {
                let critical = due.contains { $0.item.critical || ($0.remainingKm ?? 0) < 0 }
                items.append(.init(level: critical ? .bad : .warn, title: tr("Szerviz", "Service"),
                                   detail: due.map { "\($0.item.name) (\($0.remainingText))" }.joined(separator: ", ")))
            }
        } else {
            items.append(.init(level: .warn, title: tr("Szerviz", "Service"),
                               detail: tr("A km óra nincs megadva, nem tudom ellenőrizni.", "Odometer not set, can't check.")))
        }

        // Hibakódok
        if let p = packet {
            let pending = p.pendingCodes.filter { !p.faultCodes.contains($0) }
            if !p.faultCodes.isEmpty {
                let stop = p.faultCodes.contains { DTC.severity($0) == .stop }
                items.append(.init(level: stop ? .bad : .warn, title: tr("Hibakódok", "Fault codes"),
                                   detail: p.faultCodes.map { "\($0) – \(DTC.describe($0))" }.joined(separator: "; ")))
            } else if !pending.isEmpty {
                items.append(.init(level: .warn, title: tr("Hibakódok", "Fault codes"),
                                   detail: tr("Kialakulóban: ", "Developing: ") + pending.joined(separator: ", ")))
            } else {
                items.append(.init(level: .ok, title: tr("Hibakódok", "Fault codes"), detail: tr("Nincs.", "None.")))
            }
        } else {
            items.append(.init(level: .warn, title: tr("Hibakódok", "Fault codes"),
                               detail: tr("Csatlakozz az autóhoz a friss ellenőrzéshez.", "Connect to the car for a fresh check.")))
        }

        // Akku
        let last = BatteryHealth.recent(limit: 10).last
        switch BatteryHealth.grade(rest: last?.restV, crank: last?.crankV) {
        case .weak: items.append(.init(level: .bad, title: tr("Akku", "Battery"), detail: tr("Gyenge – úton elakadhatsz vele.", "Weak – it could strand you.")))
        case .fair: items.append(.init(level: .warn, title: tr("Akku", "Battery"), detail: tr("Közepes állapotú.", "Fair condition.")))
        case .good: items.append(.init(level: .ok, title: tr("Akku", "Battery"), detail: tr("Jó állapotban.", "Good.")))
        case .unknown: break
        }

        // Hatótáv
        if let range {
            if range < tripKm {
                items.append(.init(level: .warn, title: tr("Üzemanyag", "Fuel"),
                                   detail: tr("Kb. \(Int(range)) km-re elég: útközben tankolni kell.", "Good for about \(Int(range)) km: you'll need to refuel.")))
            } else {
                items.append(.init(level: .ok, title: tr("Üzemanyag", "Fuel"), detail: tr("Kb. \(Int(range)) km-re elég.", "Good for about \(Int(range)) km.")))
            }
        }

        // Lejáratok az út idején
        let limit = Calendar.current.date(byAdding: .day, value: max(1, days), to: Date()) ?? Date()
        let saved = Reminders.all()
        let expiring = Reminders.items.filter { item in saved[item.id].map { $0 <= limit } ?? false }
        if !expiring.isEmpty {
            items.append(.init(level: .bad, title: tr("Lejáratok", "Expiry dates"),
                               detail: tr("Az út alatt lejár: ", "Expires during the trip: ") + expiring.map(\.name).joined(separator: ", ")))
        } else if !saved.isEmpty {
            items.append(.init(level: .ok, title: tr("Lejáratok", "Expiry dates"), detail: tr("Az út alatt semmi nem jár le.", "Nothing expires during the trip.")))
        }

        // Legutóbbi átvilágítás
        if let h = HealthCheck.lastSaved() {
            let age = Int(Date().timeIntervalSince(h.date) / 86400)
            let level: TripCheckItem.Level = h.score >= 85 ? .ok : (h.score >= 60 ? .warn : .bad)
            items.append(.init(level: age > 30 ? .warn : level, title: tr("Átvilágítás", "Health check"),
                               detail: tr("\(h.score) pont, \(age) napja", "\(h.score) points, \(age) days ago")
                                   + (age > 30 ? tr(" – érdemes újra futtatni.", " – worth running again.") : "")))
        }
        return items
    }

    /// Kézzel ellenőrizendő dolgok, amiket az autó nem jelent.
    static var manualChecks: [String] {
        [tr("Guminyomás és profil", "Tyre pressure and tread"), tr("Olajszint", "Oil level"),
         tr("Hűtőfolyadék és ablakmosó", "Coolant and washer fluid"), tr("Világítás", "Lights"),
         tr("Láthatósági mellény, elakadásjelző, elsősegély", "Hi-vis vest, warning triangle, first aid")]
    }
}

// MARK: - Szerelőnek szóló üzenet

enum MechanicMessage {
    static func text(packet: VehiclePacket?) -> String {
        let s = AppSettings.shared
        var out = tr("Jó napot! Árajánlatot szeretnék kérni az alábbi hibára.\n\n", "Hello! I'd like a quote for the following fault.\n\n")
        out += tr("Autó: ", "Car: ") + s.carName + " (" + s.fuelType.label + ")\n"
        if let vin = s.vin { out += "VIN: \(vin)\n" }
        if s.odometerSet { out += tr("Km óra: ", "Odometer: ") + Fmt.km(s.odometerKm) + " km\n" }

        let records = Dictionary(DTC.history().map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        let stored = packet?.faultCodes ?? DTC.history().filter(\.active).map(\.code)
        let pending = (packet?.pendingCodes ?? []).filter { !stored.contains($0) }

        if stored.isEmpty && pending.isEmpty {
            out += tr("\nJelenleg nincs tárolt hibakód.\n", "\nNo stored fault codes at the moment.\n")
        }
        if !stored.isEmpty {
            out += tr("\nHibakódok:\n", "\nFault codes:\n")
            for c in stored {
                out += "• \(c) – \(DTC.describe(c))\n"
                if let r = records[c] {
                    out += tr("  először: ", "  first seen: ") + Fmt.date(r.firstSeen) + "\n"
                    if let snap = r.snapshot {
                        var parts: [String] = []
                        if let v = snap.rpm { parts.append("\(Int(v)) \(tr("ford/p", "rpm"))") }
                        if let v = snap.speed { parts.append("\(Int(v)) km/h") }
                        if let v = snap.coolant { parts.append("\(Int(v))°C") }
                        if let v = snap.load { parts.append("\(Int(v))% \(tr("terhelés", "load"))") }
                        if !parts.isEmpty { out += tr("  a hiba pillanatában: ", "  when it occurred: ") + parts.joined(separator: ", ") + "\n" }
                    }
                }
            }
        }
        if !pending.isEmpty {
            out += tr("\nKialakulóban lévő hibák: ", "\nDeveloping faults: ")
                + pending.map { "\($0) (\(DTC.describe($0)))" }.joined(separator: ", ") + "\n"
        }
        if let h = HealthCheck.lastSaved() {
            out += tr("\nLegutóbbi átvilágítás: \(h.score)/100 (\(Fmt.date(h.date)))\n",
                      "\nLast health check: \(h.score)/100 (\(Fmt.date(h.date)))\n")
        }
        out += tr("\nMikor tudnák megnézni, és körülbelül mennyibe kerülne? Köszönöm!",
                  "\nWhen could you look at it, and roughly how much would it cost? Thank you!")
        return out
    }
}

// MARK: - Eladási adatlap

struct SaleSheetData {
    var carName: String
    var fuel: String
    var vin: String?
    var odometer: Double?
    var firstRecord: Date?
    var trips: Int
    var totalKm: Double
    var fills: Int
    var avgL100: Double?
    var services: [(name: String, km: Double, date: Date)]
    var health: (score: Int, date: Date)?
    var activeCodes: [String]

    static func build() -> SaleSheetData {
        let s = AppSettings.shared
        let car = CarStore.activeId
        let db = Database.shared
        let tripRow = db.query("SELECT COUNT(*), SUM(distance_km), MIN(start) FROM trips WHERE car_id = ? AND end_t IS NOT NULL", [car]) {
            ($0.int(0), $0.double(1), $0.optDouble(2))
        }.first
        let firstFill = db.query("SELECT MIN(date) FROM fills WHERE car_id = ?", [car]) { $0.optDouble(0) }.first ?? nil
        let first = [tripRow?.2, firstFill].compactMap { $0 }.min().map { Date(timeIntervalSince1970: $0) }
        let fills = FuelStore.all()
        let plan = Dictionary(ServiceStore.plan().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let services = db.query("SELECT item, last_km, last_date FROM service_done WHERE car_id = ? ORDER BY last_date DESC", [car]) {
            (name: plan[$0.string(0)] ?? $0.string(0), km: $0.double(1), date: Date(timeIntervalSince1970: $0.double(2)))
        }
        return SaleSheetData(
            carName: s.carName, fuel: s.fuelType.label, vin: s.vin,
            odometer: s.odometerSet ? s.odometerKm : nil, firstRecord: first,
            trips: tripRow?.0 ?? 0, totalKm: tripRow?.1 ?? 0, fills: fills.count,
            avgL100: FuelStore.stats(fills).avgL100, services: services,
            health: HealthCheck.lastSaved(),
            activeCodes: DTC.history().filter(\.active).map(\.code))
    }

    var text: String {
        var out = "\(carName)\n" + tr("Eladási adatlap", "Vehicle sale sheet") + " – \(Fmt.date(Date()))\n\n"
        out += tr("Üzemanyag: ", "Fuel: ") + fuel + "\n"
        if let vin { out += "VIN: \(vin)\n" }
        if let odometer { out += tr("Km óra: ", "Odometer: ") + Fmt.km(odometer) + " km\n" }
        if let firstRecord {
            out += tr("\nNyilvántartás kezdete: ", "\nRecords since: ") + Fmt.date(firstRecord) + "\n"
            out += tr("Rögzített utak: \(trips), összesen \(Fmt.km(totalKm)) km\n", "Recorded trips: \(trips), \(Fmt.km(totalKm)) km in total\n")
            out += tr("Tankolások: \(fills)", "Fill-ups: \(fills)") + (avgL100.map { tr(", átlag \(Fmt.one($0)) l/100 km", ", avg \(Fmt.one($0)) l/100 km") } ?? "") + "\n"
        }
        out += tr("\nSzerviztörténet:\n", "\nService history:\n")
        if services.isEmpty { out += tr("  nincs rögzítve\n", "  none recorded\n") }
        for s in services { out += "  • \(s.name): \(Fmt.km(s.km)) km, \(Fmt.date(s.date))\n" }
        if let health { out += tr("\nÁtvilágítás: \(health.score)/100 (\(Fmt.date(health.date)))\n", "\nHealth check: \(health.score)/100 (\(Fmt.date(health.date)))\n") }
        out += activeCodes.isEmpty ? tr("Aktív hibakód: nincs\n", "Active fault codes: none\n")
                                   : tr("Aktív hibakódok: ", "Active fault codes: ") + activeCodes.joined(separator: ", ") + "\n"
        out += tr("\nAz adatokat az autó OBD2 csatlakozóján keresztül rögzített napló adja.",
                  "\nData comes from a log recorded through the car's OBD2 port.")
        return out
    }
}
