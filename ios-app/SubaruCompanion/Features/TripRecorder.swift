import Foundation
import CoreLocation
import Combine

struct Trip: Identifiable, Equatable {
    let id: Int
    var start: Date
    var end: Date?
    var distanceKm: Double
    var fuelL: Double?
    var maxSpeed: Double
    /// Álló helyzetben járó motorral töltött idő és az ezalatt elfogyott benzin
    var idleS: Double = 0
    var idleFuelL: Double = 0
    /// "work" / "private" / nil
    var tag: String?
    /// Az út benzinköltsége a leállításkori literárral
    var cost: Double?

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    var avgSpeed: Double { duration > 0 ? distanceKm / (duration / 3600) : 0 }
    var avgConsumption: Double? {
        guard let fuelL, distanceKm > 0.5 else { return nil }
        return fuelL / distanceKm * 100
    }
}

struct ParkingSpot: Equatable {
    let date: Date
    let coordinate: CLLocationCoordinate2D

    static func == (a: ParkingSpot, b: ParkingSpot) -> Bool {
        a.date == b.date && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
    }
}

struct TrackPoint {
    let t: Double
    let coordinate: CLLocationCoordinate2D
    let speed: Double
}

enum TripStore {
    private static var db: Database { .shared }

    private static func map(_ r: Database.Row) -> Trip {
        Trip(id: r.int(0), start: Date(timeIntervalSince1970: r.double(1)),
             end: r.optDouble(2).map(Date.init(timeIntervalSince1970:)),
             distanceKm: r.double(3), fuelL: r.optDouble(4), maxSpeed: r.double(5),
             idleS: r.double(6), idleFuelL: r.double(7),
             tag: r.string(8).isEmpty ? nil : r.string(8), cost: r.optDouble(9))
    }

    private static let columns = "id, start, end_t, distance_km, fuel_l, max_speed, idle_s, idle_fuel_l, tag, cost"

    static func all() -> [Trip] {
        db.query("SELECT \(columns) FROM trips WHERE end_t IS NOT NULL AND car_id = ? ORDER BY start DESC",
                 [CarStore.activeId], map: map)
    }

    static func open(startId: Int) -> Trip? {
        db.query("SELECT \(columns) FROM trips WHERE end_t IS NULL AND start_id = ? AND car_id = ? LIMIT 1",
                 [startId, CarStore.activeId], map: map).first
    }

    static func points(_ tripId: Int) -> [CLLocationCoordinate2D] {
        db.query("SELECT lat, lon FROM trip_points WHERE trip_id = ? ORDER BY t", [tripId]) {
            CLLocationCoordinate2D(latitude: $0.double(0), longitude: $0.double(1))
        }
    }

    static func setTag(_ id: Int, _ tag: String?) {
        db.execute("UPDATE trips SET tag = ? WHERE id = ?", [tag, id])
    }

    /// Pontok idővel és sebességgel, az út visszajátszásához.
    static func track(_ tripId: Int) -> [TrackPoint] {
        db.query("SELECT t, lat, lon, speed FROM trip_points WHERE trip_id = ? ORDER BY t", [tripId]) {
            TrackPoint(t: $0.double(0),
                       coordinate: CLLocationCoordinate2D(latitude: $0.double(1), longitude: $0.double(2)),
                       speed: $0.double(3))
        }
    }

    static func delete(_ id: Int) {
        if var samples = GaragePlus.load([DrivingSample].self, key: "baseline") {
            samples.removeAll { $0.id == id }
            try? GaragePlus.save(samples, key: "baseline")
        }
        db.execute("DELETE FROM trip_points WHERE trip_id = ?", [id])
        db.execute("DELETE FROM trips WHERE id = ?", [id])
    }

    /// Félbemaradt utak lezárása (pl. az app leállt út közben).
    static func closeStale(except startId: Int?) {
        let open = db.query("SELECT id, start FROM trips WHERE end_t IS NULL AND start_id IS NOT ? AND car_id = ?", [startId, CarStore.activeId]) {
            ($0.int(0), $0.double(1))
        }
        for (id, start) in open {
            let lastPoint = db.query("SELECT MAX(t) FROM trip_points WHERE trip_id = ?", [id]) { $0.optDouble(0) }.first ?? nil
            db.execute("UPDATE trips SET end_t = ? WHERE id = ?", [lastPoint ?? start, id])
        }
    }

    static func latestParking() -> ParkingSpot? {
        db.query("SELECT date, lat, lon FROM parking WHERE car_id = ? ORDER BY date DESC LIMIT 1", [CarStore.activeId]) {
            ParkingSpot(date: Date(timeIntervalSince1970: $0.double(0)),
                        coordinate: CLLocationCoordinate2D(latitude: $0.double(1), longitude: $0.double(2)))
        }.first
    }

    static func saveParking(_ loc: CLLocation) {
        db.execute("INSERT INTO parking(date, lat, lon, car_id) VALUES(?,?,?,?)",
                   [Date().timeIntervalSince1970, loc.coordinate.latitude, loc.coordinate.longitude, CarStore.activeId])
    }
}

/// Automatikus út rögzítés: motorindításkor indul, leállításkor zár és parkolási helyet ment.
final class TripRecorder {
    private(set) var active: Trip?
    private var lastFlush = Date()
    private var sampleTemp: Double?
    private var warmSeconds: Double?
    private var validSeconds = 0.0
    private var source = ""
    private var mixedSource = false
    private var resumed = false
    private var cancellable: AnyCancellable?
    private let db = Database.shared
    private let location = LocationManager.shared

    func ensureStarted(startId: Int, odometer: Double) {
        guard active == nil else { return }
        sampleTemp = nil; warmSeconds = nil; validSeconds = 0; source = ""; mixedSource = false; resumed = false
        TripStore.closeStale(except: startId)
        if let existing = TripStore.open(startId: startId) {
            active = existing
            resumed = true
        } else {
            let now = Date()
            let id = db.execute(
                "INSERT INTO trips(start, distance_km, max_speed, start_odo, start_id, car_id) VALUES(?,0,0,?,?,?)",
                [now.timeIntervalSince1970, odometer, startId, CarStore.activeId])
            active = Trip(id: id, start: now, end: nil, distanceKm: 0, fuelL: nil, maxSpeed: 0)
        }
        location.startTracking()
        cancellable = location.updates.sink { [weak self] loc in
            guard let self, let trip = self.active else { return }
            self.db.execute("INSERT INTO trip_points(trip_id, t, lat, lon, speed) VALUES(?,?,?,?,?)",
                            [trip.id, loc.timestamp.timeIntervalSince1970,
                             loc.coordinate.latitude, loc.coordinate.longitude, max(0, loc.speed * 3.6)])
        }
    }

    func update(packet p: VehiclePacket, dt: TimeInterval) {
        guard var trip = active else { return }
        if sampleTemp == nil, Date().timeIntervalSince(trip.start) <= 5 { sampleTemp = p.coolantTemp }
        if warmSeconds == nil, let initial = sampleTemp, initial < 50,
           let temp = p.coolantTemp, temp >= AppSettings.shared.warmTemp {
            warmSeconds = Date().timeIntervalSince(trip.start)
        }
        if p.engineRunning, p.vehicleSpeed != nil, p.fuelRateLph != nil {
            validSeconds += dt
            let nextSource = p.fuelRate == nil ? "maf" : "pid"
            if !source.isEmpty && source != nextSource { mixedSource = true }
            source = nextSource
        }
        if let v = p.vehicleSpeed {
            trip.distanceKm += v * dt / 3600
            trip.maxSpeed = max(trip.maxSpeed, v)
        }
        if let rate = p.fuelRateLph {
            trip.fuelL = (trip.fuelL ?? 0) + rate * dt / 3600
        }
        if p.engineRunning, (p.vehicleSpeed ?? 0) < 2 {
            trip.idleS += dt
            if let rate = p.fuelRateLph { trip.idleFuelL += rate * dt / 3600 }
        }
        active = trip
        if Date().timeIntervalSince(lastFlush) > 20 { flush() }
    }

    private func flush() {
        guard let t = active else { return }
        lastFlush = Date()
        db.execute("UPDATE trips SET distance_km = ?, fuel_l = ?, max_speed = ?, idle_s = ?, idle_fuel_l = ? WHERE id = ?",
                   [t.distanceKm, t.fuelL, t.maxSpeed, t.idleS, t.idleFuelL, t.id])
    }

    /// - Returns: a mentett parkolási hely (ha volt GPS pozíció) és a lezárt út (ha valódi út volt).
    @discardableResult
    func finish() -> (spot: ParkingSpot?, trip: Trip?) {
        guard var trip = active else { return (nil, nil) }
        flush()
        cancellable = nil
        active = nil

        var spot: ParkingSpot?
        if let loc = location.last, Date().timeIntervalSince(loc.timestamp) < 300 {
            TripStore.saveParking(loc)
            spot = TripStore.latestParking()
        }
        location.stopTracking()

        if trip.distanceKm < 0.2 {
            TripStore.delete(trip.id)  // csak járatás volt, nem út
            return (spot, nil)
        }
        trip.end = Date()
        trip.cost = trip.fuelL.map { $0 * AppSettings.shared.lastFuelPrice }
        db.execute("UPDATE trips SET end_t = ?, cost = ? WHERE id = ?",
                   [Date().timeIntervalSince1970, trip.cost, trip.id])
        if !resumed, !mixedSource, trip.duration > 0 {
            var samples = GaragePlus.load([DrivingSample].self, key: "baseline") ?? []
            samples.removeAll { $0.id == trip.id }
            samples.append(DrivingSample(id: trip.id, date: trip.start, km: trip.distanceKm,
                speed: trip.avgSpeed, idleFraction: trip.idleS / trip.duration,
                consumption: trip.avgConsumption, startTemp: sampleTemp, warmSeconds: warmSeconds,
                coverage: min(1, validSeconds / trip.duration), source: source))
            try? GaragePlus.save(Array(samples.suffix(200)), key: "baseline")
        }
        return (spot, trip)
    }
}
