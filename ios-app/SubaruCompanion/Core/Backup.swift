import Foundation

/// Teljes adatmentés egyetlen JSON fájlba, és visszaállítás belőle.
/// A fájl a telefonon marad, hacsak a felhasználó maga el nem küldi valahova.
enum Backup {
    static let tables = ["cars", "trips", "trip_points", "fills", "parking", "voltage_log", "events",
                         "battery_health", "service_plan", "service_done", "reminder_dates", "dtc_hist"]

    enum RestoreError: Error { case unreadable, wrongFormat }

    private static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var lastBackup: Date? {
        let t = UserDefaults.standard.double(forKey: "lastBackupAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func makeData() -> Data? {
        var tablesOut: [String: Any] = [:]
        for t in tables { tablesOut[t] = Database.shared.dump(table: t) }

        var settings: [String: Any] = [:]
        for key in AppSettings.backupKeys {
            if let v = UserDefaults.standard.object(forKey: key), JSONSerialization.isValidJSONObject([v]) {
                settings[key] = v
            }
        }
        let carState = UserDefaults.standard.dictionaryRepresentation().filter {
            isCarStateKey($0.key) && JSONSerialization.isValidJSONObject([$0.value])
        }
        let root: [String: Any] = [
            "version": 2,
            "carState": carState,
            "created": Date().timeIntervalSince1970,
            "tables": tablesOut,
            "settings": settings
        ]
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Mentés a Fájlok appban látható „Backups” mappába.
    @discardableResult
    static func writeFile() -> URL? {
        guard let data = makeData() else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let url = folder.appendingPathComponent("subaru-mentes-\(f.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBackupAt")
        prune(keep: 5)
        return url
    }

    /// Hetente egyszer magától ment.
    static func autoBackupIfDue() {
        guard let last = lastBackup else { writeFile(); return }
        if Date().timeIntervalSince(last) > 7 * 86400 { writeFile() }
    }

    private static func prune(keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let sorted = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sorted.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    /// Visszaállítás: a jelenlegi adatokat a fájl tartalmára cseréli.
    /// - Returns: a visszaállított sorok száma
    static func restore(from url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw RestoreError.unreadable }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tablesIn = root["tables"] as? [String: Any] else { throw RestoreError.wrongFormat }


        let version = (root["version"] as? Int) ?? 1
        guard (1...2).contains(version) else { throw RestoreError.wrongFormat }
        let settings = (root["settings"] as? [String: Any]) ?? [:]
        var incoming: [String: [[String: Any]]] = [:]
        if tablesIn["cars"] != nil {
            for name in tables {
                guard let rows = tablesIn[name] as? [[String: Any]] else { throw RestoreError.wrongFormat }
                incoming[name] = rows
            }
        } else {
            guard version == 1 else { throw RestoreError.wrongFormat }
            incoming = try convertLegacy(tablesIn, settings: settings)
        }
        try validate(incoming)
        let db = Database.shared
        let count = try db.transaction {
            var count = 0
            for name in tables { count += try db.replace(table: name, rows: incoming[name] ?? []) }
            return count
        }
        // Preferences change only after every database write has committed.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where isCarStateKey(key) {
            defaults.removeObject(forKey: key)
        }
        if let state = root["carState"] as? [String: Any] {
            for (key, value) in state where isCarStateKey(key) && (value is NSNumber || value is String) {
                defaults.set(value, forKey: key)
            }
        }
        for key in AppSettings.backupKeys {
            if let value = settings[key], !(value is NSNull) { defaults.set(value, forKey: key) }
        }
        AppSettings.shared.load()
        return count
    }

    private static func isCarStateKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", maxSplits: 2)
        let allowed: Set<String> = ["fuelPrice", "lastStopFuel", "lastStopAt", "lowRangeNotified", "warmStartId",
                                   "seenStartId", "normCoolant", "suggestedFill", "lastChargeAvg", "alternatorNotified",
                                   "summaryMonth", "battWeakNotified", "parkTimerEnd"]
        return parts.count == 3 && parts[0] == "car" && Int(parts[1]) != nil && allowed.contains(String(parts[2]))
    }

    private static func validate(_ data: [String: [[String: Any]]]) throws {
        guard let cars = data["cars"], !cars.isEmpty else { throw RestoreError.wrongFormat }
        var ids = Set<Int>()
        var vins = Set<String>()
        for car in cars {
            guard let id = car["id"] as? Int, id > 0, ids.insert(id).inserted,
                  let name = car["name"] as? String, !name.isEmpty,
                  let fuel = car["fuel"] as? String, FuelType(rawValue: fuel) != nil,
                  let tank = car["tank_l"] as? Double, tank.isFinite, (10...200).contains(tank),
                  let warm = car["warm_temp"] as? Double, warm.isFinite, (60...110).contains(warm),
                  let rpm = car["redline"] as? Double, rpm.isFinite, (2500...10000).contains(rpm),
                  let odo = car["odo"] as? Double, odo.isFinite, (0...2_000_000).contains(odo)
            else { throw RestoreError.wrongFormat }
            if let vin = car["vin"] as? String, !vin.isEmpty {
                guard CarStore.validVIN(vin), vins.insert(vin).inserted else { throw RestoreError.wrongFormat }
            }
        }
        for table in Database.carTables {
            for row in data[table] ?? [] {
                guard let id = row["car_id"] as? Int, ids.contains(id) else { throw RestoreError.wrongFormat }
            }
        }
        let trips = Set((data["trips"] ?? []).compactMap { $0["id"] as? Int })
        for row in data["trip_points"] ?? [] {
            guard let id = row["trip_id"] as? Int, trips.contains(id) else { throw RestoreError.wrongFormat }
        }
        for row in data["service_plan"] ?? [] {
            guard let km = row["interval_km"] as? Double, km.isFinite, (0...500_000).contains(km) else { throw RestoreError.wrongFormat }
        }
    }

    /// Older files are converted in memory before touching the current database.
    private static func convertLegacy(_ old: [String: Any], settings: [String: Any]) throws -> [String: [[String: Any]]] {
        var result = Dictionary(uniqueKeysWithValues: tables.map { ($0, [[String: Any]]()) })
        for table in ["trips", "trip_points", "fills", "parking", "voltage_log", "events", "battery_health"] {
            guard let rows = old[table] as? [[String: Any]] else { throw RestoreError.wrongFormat }
            result[table] = rows.map { row in
                var row = row
                if table != "trip_points" { row["car_id"] = 1 }
                return row
            }
        }
        for (source, target) in [("service", "service_done"), ("reminders", "reminder_dates"), ("dtc_log", "dtc_hist")] {
            guard let rows = old[source] as? [[String: Any]] else { throw RestoreError.wrongFormat }
            result[target] = rows.map { row in var row = row; row["car_id"] = 1; return row }
        }
        let t = CarTemplate.subaru
        result["cars"] = [["id": 1, "name": settings["carName"] ?? "Korábbi autó",
                           "vin": settings["vin"] ?? NSNull(), "fuel": "petrol",
                           "tank_l": settings["tankLiters"] ?? 60.0, "warm_temp": settings["warmTemp"] ?? 88.0,
                           "redline": settings["redline"] ?? 6500.0, "odo": settings["odo"] ?? 0.0,
                           "odo_set": settings["odoSet"] ?? false, "template": t.id]]
        result["service_plan"] = t.service.enumerated().map { i, item in
            ["car_id": 1, "item": item.id, "hu": item.hu, "en": item.en,
             "interval_km": item.intervalKm, "critical": item.critical ? 1 : 0, "sort": i]
        }
        return result
    }
}
