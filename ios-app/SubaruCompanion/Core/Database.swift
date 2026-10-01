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
        // Az adatbázis bekerül az iPhone saját (iCloud vagy számítógépes) mentésébe:
        // új telefonra visszaállításkor minden adat visszajön.
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
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
        execute("ALTER TABLE trips ADD COLUMN tag TEXT")
        execute("ALTER TABLE trips ADD COLUMN cost REAL")
        execute("ALTER TABLE dtc_log ADD COLUMN snap TEXT")
        execute("CREATE TABLE IF NOT EXISTS reminders(id TEXT PRIMARY KEY, date REAL)")
    }

    @discardableResult
    func execute(_ sql: String, _ args: [Any?] = []) -> Int {
        guard let stmt = prepare(sql, args) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
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
    func replace(table: String, rows: [[String: Any]]) -> Int {
        execute("DELETE FROM \(table)")
        var count = 0
        for row in rows {
            let keys = row.keys.sorted().filter { k in
                !k.isEmpty && k.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            }
            guard !keys.isEmpty else { continue }
            let marks = keys.map { _ in "?" }.joined(separator: ",")
            let args: [Any?] = keys.map { k in
                let v = row[k]
                return v is NSNull ? nil : v
            }
            execute("INSERT INTO \(table)(\(keys.joined(separator: ","))) VALUES(\(marks))", args)
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
