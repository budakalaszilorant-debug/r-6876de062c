import Foundation

struct FuelFill: Identifiable, Equatable {
    let id: Int
    var date: Date
    var liters: Double
    var cost: Double
    var odometer: Double
    var full: Bool
    var station: String = ""

    var pricePerLiter: Double { liters > 0 ? cost / liters : 0 }
}

struct FuelStats {
    var avgL100: Double?      // l/100 km, teli tanktól teli tankig számolva
    var kmPerLiter: Double?
    var costPerKm: Double?
    var totalCost: Double = 0
    var totalLiters: Double = 0
    var monthCost: Double = 0
    /// Töltésenkénti fogyasztás (dátum, l/100 km) a grafikonhoz
    var perFill: [(date: Date, l100: Double)] = []
}

enum FuelStore {
    private static var db: Database { .shared }

    static func all() -> [FuelFill] {
        db.query("SELECT id, date, liters, cost, odometer, full, station FROM fills WHERE car_id = ? ORDER BY odometer DESC, date DESC",
                 [CarStore.activeId]) {
            FuelFill(id: $0.int(0), date: Date(timeIntervalSince1970: $0.double(1)), liters: $0.double(2),
                     cost: $0.double(3), odometer: $0.double(4), full: $0.int(5) == 1, station: $0.string(6))
        }
    }

    static func add(date: Date, liters: Double, cost: Double, odometer: Double, full: Bool, station: String = "") {
        let name = station.trimmingCharacters(in: .whitespacesAndNewlines)
        db.execute("INSERT INTO fills(date, liters, cost, odometer, full, car_id, station) VALUES(?,?,?,?,?,?,?)",
                   [date.timeIntervalSince1970, liters, cost, odometer, full ? 1 : 0, CarStore.activeId,
                    name.isEmpty ? nil : name])
    }

    static func delete(_ id: Int) {
        db.execute("DELETE FROM fills WHERE id = ?", [id])
    }

    /// Teli tank módszer: két teli töltés között elhasznált liter = a közbenső + záró töltések összege.
    static func measuredAverage(_ readings: [(km: Double, liters: Double?)]) -> Double? {
        let valid = readings.filter { $0.km.isFinite && $0.km > 0 && $0.liters.map { $0.isFinite && $0 >= 0 } == true }
        let km = valid.reduce(0) { $0 + $1.km }
        let liters = valid.reduce(0) { $0 + ($1.liters ?? 0) }
        return km > 20 && liters > 0 ? liters / km * 100 : nil
    }

    static func stats(_ fills: [FuelFill], now: Date = Date()) -> FuelStats {
        var s = FuelStats()
        let asc = fills.sorted {
            if $0.odometer != $1.odometer { return $0.odometer < $1.odometer }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        s.totalCost = asc.reduce(0) { $0 + $1.cost }
        s.totalLiters = asc.reduce(0) { $0 + $1.liters }
        let month = Calendar.current.dateInterval(of: .month, for: now)
        s.monthCost = asc.filter { $0.date >= (month?.start ?? now) && $0.date < (month?.end ?? now) }.reduce(0) { $0 + $1.cost }

        var lastFullOdo: Double?
        var litersSince = 0.0, costSince = 0.0
        var km = 0.0, liters = 0.0, cost = 0.0
        for f in asc {
            if let start = lastFullOdo {
                litersSince += f.liters
                costSince += f.cost
                if f.full {
                    let d = f.odometer - start
                    if d > 0 {
                        km += d; liters += litersSince; cost += costSince
                        s.perFill.append((f.date, litersSince / d * 100))
                    }
                    lastFullOdo = f.odometer
                    litersSince = 0; costSince = 0
                }
            } else if f.full {
                lastFullOdo = f.odometer
            }
        }
        if km > 0, liters > 0 {
            s.avgL100 = liters / km * 100
            s.kmPerLiter = km / liters
            s.costPerKm = cost / km
        }
        return s
    }
}
