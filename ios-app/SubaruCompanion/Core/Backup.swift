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
        let root: [String: Any] = [
            "version": 1,
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

        var count = 0
        let db = Database.shared
        db.execute("BEGIN")
        for t in tables {  // csak az ismert táblák, a fájlból jövő táblanév nem kerül SQL-be
            guard let rows = tablesIn[t] as? [[String: Any]] else { continue }
            count += db.replace(table: t, rows: rows)
        }
        db.execute("COMMIT")

        if let settings = root["settings"] as? [String: Any] {
            for key in AppSettings.backupKeys {
                if let v = settings[key] { UserDefaults.standard.set(v, forKey: key) }
            }
        }
        AppSettings.shared.load()
        CarStore.adoptOrphans()  // régi, autó nélküli mentésből jött sorok
        return count
    }
}
