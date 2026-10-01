import Foundation
import SQLite3

/// Helyi SQLite tár. Semmi nem hagyja el a telefont.
final class Database {
    static let shared = Database()
    private var db: OpaquePointer?
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

    private init() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let path = url.appendingPathComponent("subaru.sqlite").path
        sqlite3_open(path, &db)
        // Ne kerüljön iCloud mentésbe.
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        migrate()
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
    }

    @discardableResult
    func execute(_ sql: String, _ args: [Any?] = []) -> Int {
        guard let stmt = prepare(sql, args) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        return Int(sqlite3_last_insert_rowid(db))
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
