import Foundation

struct DiagnosticReading: Codable {
    var date: Date
    var codes: [String]
}

/// Small Codable documents keep photos, reports and preferences in the same atomic backup as trips.
enum GaragePlus {
    static func load<T: Decodable>(_ type: T.Type, key: String, car: Int = CarStore.activeId) -> T? {
        guard let json = Database.shared.query("SELECT payload FROM garage_plus WHERE car_id = ? AND key = ?", [car, key], map: { $0.string(0) }).first,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String, car: Int = CarStore.activeId) throws {
        guard CarStore.get(car) != nil else { throw Database.StorageError.failedWrite }
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try Database.shared.checkedExecute("INSERT INTO garage_plus(car_id,key,payload) VALUES(?,?,?) ON CONFLICT(car_id,key) DO UPDATE SET payload=excluded.payload", [car, key, json])
    }
}

struct CarStyle: Codable {
    var accent = "blue"
    var photo: String?
    var order: [String] = DashSection.allCases.map(\.rawValue)
    var hidden: [String] = []
    static let colors = ["blue", "mint", "purple", "orange"]
}

struct Handover: Codable, Identifiable {
    var id = UUID()
    var start = Date()
    var end: Date?
    var person: String
    var startKm: Double
    var endKm: Double?
    var startFuel: Double?
    var endFuel: Double?
    var note: String
    var returnNote: String = ""
    var startPhoto: String?
    var endPhoto: String?
    var distance: Double? { endKm.map { max(0, $0 - startKm) } }

    func recordedCosts(car: Int) -> Double {
        let args: [Any?] = [car, start.timeIntervalSince1970, (end ?? Date()).timeIntervalSince1970]
        let fuel = Database.shared.query("SELECT SUM(cost) FROM fills WHERE car_id=? AND date>=? AND date<=?", args) { $0.double(0) }.first ?? 0
        let other = Database.shared.query("SELECT SUM(amount) FROM expenses WHERE car_id=? AND date>=? AND date<=?", args) { $0.double(0) }.first ?? 0
        return fuel + other
    }
}

struct DrivingSample: Codable, Identifiable {
    var id: Int
    var date: Date
    var km: Double
    var speed: Double
    var idleFraction: Double
    var consumption: Double?
    var startTemp: Double?
    var warmSeconds: Double?
    var coverage: Double
    var source: String
}

struct BaselineFinding {
    var latest: Double
    var usual: Double
    var count: Int
    var percent: Double { (latest / usual - 1) * 100 }
    var elevated: Bool { percent >= 20 }
}

enum DrivingBaseline {
    /// Compare the newest complete trip only with similar, earlier trips; never mix fuel sources.
    static func compare(_ samples: [DrivingSample], warmup: Bool) -> BaselineFinding? {
        let sorted = samples.sorted { $0.date > $1.date }
        guard let latest = sorted.first, latest.km >= 3, latest.coverage >= 0.9 else { return nil }
        func value(_ s: DrivingSample) -> Double? { warmup ? s.warmSeconds : s.consumption }
        guard let current = value(latest), current.isFinite, current > 0 else { return nil }
        let peers = sorted.dropFirst().filter { s in
            guard s.coverage >= 0.9, s.source == latest.source,
                  abs(s.km - latest.km) <= latest.km * 0.3,
                  abs(s.speed - latest.speed) <= max(5, latest.speed * 0.25),
                  abs(s.idleFraction - latest.idleFraction) <= 0.1,
                  let a = s.startTemp, let b = latest.startTemp, abs(a-b) <= 10,
                  let v = value(s), v.isFinite, v > 0 else { return false }
            return !warmup || (a < 50 && b < 50)
        }.prefix(20).compactMap(value).sorted()
        guard peers.count >= 5 else { return nil }
        let mid = peers.count / 2
        let median = peers.count.isMultiple(of: 2) ? (peers[mid-1] + peers[mid])/2 : peers[mid]
        return BaselineFinding(latest: current, usual: median, count: peers.count)
    }
}

struct RepairReport: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var vin: String
    var before: [String: String] = [:]
    var after: [String: String] = [:]
    var originalCodes: [String] = []
    var returnedCodes: [String] = []
    /// prepared, sent, acknowledged, verified, remaining, unknown, refused
    var status = "prepared"
    var detail = ""
}

enum RepairStore {
    static func all(car: Int = CarStore.activeId) -> [RepairReport] {
        GaragePlus.load([RepairReport].self, key: "repairs", car: car) ?? []
    }
    static func save(_ report: RepairReport, car: Int) throws {
        var rows = all(car: car)
        if let i = rows.firstIndex(where: { $0.id == report.id }) { rows[i] = report }
        else { rows.insert(report, at: 0) }
        try GaragePlus.save(rows, key: "repairs", car: car)
    }
    static func observe(_ codes: [String]) {
        // Only a previously confirmed empty stored-code list establishes that a code disappeared.
        guard var last = all().first, last.status == "verified" else { return }
        let returned = Set(codes).intersection(last.originalCodes).union(last.returnedCodes).sorted()
        guard returned != last.returnedCodes else { return }
        last.returnedCodes = returned
        try? save(last, car: CarStore.activeId)
    }
}
