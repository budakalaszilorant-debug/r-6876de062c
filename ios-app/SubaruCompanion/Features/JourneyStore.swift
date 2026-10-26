import Foundation

struct JourneySnapshot: Codable {
    var id: Int
    var row: Data
    var points: [JourneyPoint]
    var report: PhoneDriveReport?
}
struct JourneyArchive: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var originals: [JourneySnapshot]
    var resultIDs: [Int]
}

enum JourneyStore {
    private static var canEdit: Bool {
        #if GARAGE_TESTS
        return Database.shared.query("SELECT COUNT(*) FROM trips WHERE car_id=? AND end_t IS NULL",[CarStore.activeId]) { $0.int(0) }.first == 0
        #else
        return VehicleMonitor.shared.canManageGarage
        #endif
    }
    static func points(_ id: Int) -> [JourneyPoint] {
        Database.shared.query("SELECT t,lat,lon,speed FROM trip_points WHERE trip_id=? AND EXISTS(SELECT 1 FROM trips WHERE id=? AND car_id=?) ORDER BY t",
            [id,id,CarStore.activeId]) { JourneyPoint(time: $0.double(0), latitude: $0.double(1), longitude: $0.double(2), speed: $0.double(3)) }
    }
    #if !GARAGE_TESTS
    static func observation(_ trip: Trip) -> RouteObservation {
        let report = trip.phoneReport
        return RouteObservation(id: trip.id, start: trip.start.timeIntervalSince1970, duration: trip.duration,
            km: trip.distanceKm, stopped: report?.stoppedSeconds ?? trip.idleS, points: points(trip.id),
            reliable: report.map { $0.confirmedMovement == true && $0.measuredSeconds >= trip.duration * 0.85 && $0.edited != true } ?? false)
    }
    static func observations() -> [RouteObservation] { TripStore.all().prefix(100).map(observation) }
    static func title(_ trip: Trip) -> String {
        PlacesStore.title(points(trip.id), places: PlacesStore.all()) ?? Fmt.date(trip.start)
    }
    #endif
    static func archives() -> [JourneyArchive] { GaragePlus.load([JourneyArchive].self, key: "trip-originals") ?? [] }
    static func archive(for id: Int) -> JourneyArchive? { archives().first { $0.resultIDs.contains(id) } }

    private static func snapshot(_ id: Int) throws -> JourneySnapshot {
        guard let row = Database.shared.dump(table: "trips").first(where: { ($0["id"] as? Int) == id && ($0["car_id"] as? Int) == CarStore.activeId }),
              !(row["end_t"] is NSNull), row["end_t"] != nil else { throw JourneyError.missing }
        guard archive(for: id) == nil else { throw JourneyError.alreadyEdited }
        return JourneySnapshot(id: id, row: try JSONSerialization.data(withJSONObject: row), points: points(id),
            report: GaragePlus.load(PhoneDriveReport.self, key: "phone-drive-\(id)"))
    }
    private static func remove(_ id: Int) throws {
        try Database.shared.checkedExecute("DELETE FROM trip_points WHERE trip_id=?", [id])
        try Database.shared.checkedExecute("DELETE FROM trips WHERE id=? AND car_id=?", [id,CarStore.activeId])
        try Database.shared.checkedExecute("DELETE FROM garage_plus WHERE car_id=? AND key=?", [CarStore.activeId,"phone-drive-\(id)"])
    }
    private static func insert(_ points: [JourneyPoint], start: Double, end: Double, reports: [PhoneDriveReport]) throws -> Int {
        guard points.count >= 2, end > start else { throw JourneyError.invalid }
        let db = Database.shared
        try db.checkedExecute("INSERT INTO trips(car_id,start,end_t,distance_km,max_speed) VALUES(?,?,?,?,?)",
            [CarStore.activeId,start,end,JourneyAnalysis.distance(points),points.map(\.speed).max() ?? 0])
        let id = db.query("SELECT last_insert_rowid()") { $0.int(0) }.first!
        for p in points { try db.checkedExecute("INSERT INTO trip_points(trip_id,t,lat,lon,speed) VALUES(?,?,?,?,?)", [id,p.time,p.latitude,p.longitude,p.speed]) }
        var report = PhoneDriveReport()
        report.interrupted = false; report.confirmedMovement = true; report.edited = true; report.endReason = "edited"; report.lastObservedAt = end
        report.events = reports.flatMap(\.events).filter { $0.time >= start && $0.time <= end }
        report.stops = reports.flatMap { $0.stops ?? [] }.compactMap { stop in
            var value = stop; value.start = max(start,stop.start); value.end = min(end,stop.end)
            return value.end > value.start ? value : nil
        }
        // Edited GPS segments cannot retain the original fuel or measured-time totals.
        try GaragePlus.save(report, key: "phone-drive-\(id)")
        return id
    }
    enum Edit { case trim(Double,Double), split(Double), merge(Int) }
    static func edit(_ id: Int, operation: Edit) throws {
        guard canEdit else { throw JourneyError.active }
        let original = try snapshot(id)
        var originals = [original]
        var segments: [[JourneyPoint]] = []
        switch operation {
        case .trim(let from, let to): segments = [original.points.filter { $0.time >= from && $0.time <= to }]
        case .split(let time):
            guard let boundary = original.points.last(where: { $0.time <= time })?.time else { throw JourneyError.invalid }
            segments = [original.points.filter { $0.time <= boundary },original.points.filter { $0.time >= boundary }]
        case .merge(let otherID):
            guard otherID != id else { throw JourneyError.invalid }
            let other = try snapshot(otherID); originals.append(other)
            let ordered = originals.sorted { ($0.points.first?.time ?? 0) < ($1.points.first?.time ?? 0) }
            guard let end = ordered[0].points.last?.time, let start = ordered[1].points.first?.time, start - end > 10 else { throw JourneyError.invalid }
            segments = [ordered.flatMap(\.points)]
        }
        guard segments.allSatisfy({ $0.count >= 2 && $0.last!.time > $0.first!.time }) else { throw JourneyError.invalid }
        try Database.shared.transaction {
            for value in originals { try remove(value.id) }
            let ids = try segments.map { try insert($0, start: $0.first!.time, end: $0.last!.time, reports: originals.compactMap(\.report)) }
            var saved = archives(); saved.append(JourneyArchive(originals: originals, resultIDs: ids))
            try GaragePlus.save(saved, key: "trip-originals")
            guard let backup = Backup.makeData(), backup.count < 18_000_000 else { throw JourneyError.tooLarge }
        }
    }
    static func restore(_ archive: JourneyArchive) throws {
        guard canEdit else { throw JourneyError.active }
        guard let saved = archives().first(where: { $0.id == archive.id }) else { throw JourneyError.missing }
        try Database.shared.transaction {
            for id in saved.resultIDs { try remove(id) }
            let allowed = Set(["id","start","end_t","distance_km","fuel_l","max_speed","start_odo","start_id","car_id","idle_s","idle_fuel_l","tag","cost"])
            for snapshot in saved.originals {
                guard let row = try JSONSerialization.jsonObject(with: snapshot.row) as? [String:Any],
                      Set(row.keys).isSubset(of: allowed), row["car_id"] as? Int == CarStore.activeId else { throw JourneyError.invalid }
                let keys = row.keys.sorted()
                try Database.shared.checkedExecute("INSERT INTO trips(\(keys.joined(separator: ","))) VALUES(\(keys.map { _ in "?" }.joined(separator: ",")))", keys.map { row[$0] is NSNull ? nil : row[$0] })
                for p in snapshot.points { try Database.shared.checkedExecute("INSERT INTO trip_points(trip_id,t,lat,lon,speed) VALUES(?,?,?,?,?)", [snapshot.id,p.time,p.latitude,p.longitude,p.speed]) }
                if let report = snapshot.report { try GaragePlus.save(report,key: "phone-drive-\(snapshot.id)") }
            }
            try GaragePlus.save(archives().filter { $0.id != saved.id }, key: "trip-originals")
        }
    }
}
