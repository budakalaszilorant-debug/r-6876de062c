import Foundation
import SQLite3

/// Helyi SQLite tár. A külön, választható CloudSync menti a felhőbe.
final class Database {
    static let shared = Database()
    private var db: OpaquePointer?
    private var migrationFailed = false
    private var checkingMigration = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        let stmt: OpaquePointer
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func string(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func optDouble(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : double(i)
        }
    }

    init(path testPath: String? = nil) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if GARAGE_TESTS
        let path = testPath ?? ":memory:"
        #else
        let path = testPath ?? url.appendingPathComponent("subaru.sqlite").path
        #endif
        sqlite3_open(path, &db)
        // Az adatbázis bekerül az iPhone saját (iCloud vagy számítógépes) mentésébe:
        // új telefonra visszaállításkor minden adat visszajön.
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? u.setResourceValues(values)
        migrate()
        execute("CREATE TABLE IF NOT EXISTS account_garages(owner TEXT PRIMARY KEY,payload TEXT NOT NULL)")
        execute("CREATE TABLE IF NOT EXISTS account_state(id INTEGER PRIMARY KEY CHECK(id=1),owner TEXT NOT NULL)")
        execute("CREATE TABLE IF NOT EXISTS account_legacy_claim(owner TEXT NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    enum StorageError: Error { case invalidStatement, failedWrite }

    func checkedExecute(_ sql: String, _ args: [Any?] = []) throws {
        guard let stmt = prepare(sql, args) else { throw StorageError.invalidStatement }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageError.failedWrite }
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try checkedExecute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try checkedExecute("COMMIT")
            return result
        } catch {
            try? checkedExecute("ROLLBACK")
            throw error
        }
    }

    private func migrate() {
        execute("PRAGMA journal_mode=WAL")
        execute("""
        CREATE TABLE IF NOT EXISTS trips(
          id INTEGER PRIMARY KEY AUTOINCREMENT, start REAL, end_t REAL,
          distance_km REAL, fuel_l REAL, max_speed REAL, start_odo REAL, start_id INTEGER)
        """)
        execute("CREATE TABLE IF NOT EXISTS trip_points(trip_id INTEGER, t REAL, lat REAL, lon REAL, speed REAL)")
        execute("CREATE INDEX IF NOT EXISTS idx_points ON trip_points(trip_id)")
        execute("""
        CREATE TABLE IF NOT EXISTS fills(
          id INTEGER PRIMARY KEY AUTOINCREMENT, date REAL, liters REAL, cost REAL,
          odometer REAL, full INTEGER)
        """)
        execute("CREATE TABLE IF NOT EXISTS parking(id INTEGER PRIMARY KEY AUTOINCREMENT, date REAL, lat REAL, lon REAL)")
        execute("CREATE TABLE IF NOT EXISTS voltage_log(t REAL, voltage REAL, event TEXT)")
        execute("CREATE TABLE IF NOT EXISTS dtc_log(code TEXT PRIMARY KEY, first_seen REAL, last_seen REAL, active INTEGER)")
        execute("CREATE TABLE IF NOT EXISTS service(item TEXT PRIMARY KEY, last_km REAL, last_date REAL)")
        execute("CREATE TABLE IF NOT EXISTS events(t REAL, kind TEXT, value REAL)")
        execute("CREATE TABLE IF NOT EXISTS battery_health(t REAL, start_id INTEGER, rest_v REAL, crank_v REAL, charge_v REAL)")
        // Bővítés meglévő táblán: ha az oszlop már létezik, a parancs hibával tér vissza, ami itt rendben van.
        execute("ALTER TABLE trips ADD COLUMN idle_s REAL DEFAULT 0")
        execute("ALTER TABLE trips ADD COLUMN idle_fuel_l REAL DEFAULT 0")
        execute("ALTER TABLE trips ADD COLUMN tag TEXT")
        execute("ALTER TABLE trips ADD COLUMN cost REAL")
        execute("ALTER TABLE dtc_log ADD COLUMN snap TEXT")
        execute("CREATE TABLE IF NOT EXISTS reminders(id TEXT PRIMARY KEY, date REAL)")

        let version = query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        if version < 2 {
            do {
                try transaction {
                    checkingMigration = true
                    defer { checkingMigration = false }
                    migrateToGarage()
                    guard !migrationFailed else { throw StorageError.failedWrite }
                    try checkedExecute("PRAGMA user_version = 2")
                }
            } catch {
                fatalError("Garage migration failed; original database preserved: \(error)")
            }
        }
        // Fenntartási költségek és a tankolás kútja
        execute("CREATE TABLE IF NOT EXISTS expenses(id INTEGER PRIMARY KEY AUTOINCREMENT, car_id INTEGER, date REAL, category TEXT, amount REAL, note TEXT)")
        execute("ALTER TABLE fills ADD COLUMN station TEXT")
        execute("CREATE TABLE IF NOT EXISTS garage_plus(car_id INTEGER NOT NULL, key TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(car_id,key))")
    }

    @discardableResult
    func execute(_ sql: String, _ args: [Any?] = []) -> Int {
        guard let stmt = prepare(sql, args) else {
            if checkingMigration { migrationFailed = true }
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            if checkingMigration { migrationFailed = true }
            return 0
        }
        return Int(sqlite3_last_insert_rowid(db))
    }

    // MARK: - Mentés / visszaállítás

    /// Egy tábla minden sora oszlopnév → érték párokkal.
    func dump(table: String) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(table)", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<n {
                guard let cname = sqlite3_column_name(stmt, i) else { continue }
                let name = String(cString: cname)
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, i) { row[name] = String(cString: text) }
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// A tábla tartalmát a megadott sorokra cseréli. Az oszlopnevek fájlból jönnek, ezért csak
    /// betű, szám és aláhúzás lehet bennük.
    @discardableResult
    func replace(table: String, rows: [[String: Any]]) throws -> Int {
        let allowed = Set(query("PRAGMA table_info(\(table))") { $0.string(1) })
        guard !allowed.isEmpty else { throw StorageError.invalidStatement }
        try checkedExecute("DELETE FROM \(table)")
        var count = 0
        for row in rows {
            let keys = row.keys.sorted()
            guard !keys.isEmpty, Set(keys).isSubset(of: allowed), row.values.allSatisfy({
                $0 is NSNull || $0 is String || $0 is NSNumber
            }) else { throw StorageError.invalidStatement }
            let marks = keys.map { _ in "?" }.joined(separator: ",")
            let args: [Any?] = keys.map { k in
                let v = row[k]
                return v is NSNull ? nil : v
            }
            try checkedExecute("INSERT INTO \(table)(\(keys.joined(separator: ","))) VALUES(\(marks))", args)
            count += 1
        }
        return count
    }

    func query<T>(_ sql: String, _ args: [Any?] = [], map: (Row) -> T) -> [T] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let v as Int:    sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Bool:   sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default:              sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}
