import Foundation

struct JourneyPoint: Codable, Equatable {
    var time: Double
    var latitude: Double
    var longitude: Double
    var speed: Double
    func distance(to other: JourneyPoint) -> Double {
        let a = DriveFix(time: time, latitude: latitude, longitude: longitude, accuracy: 0, speed: 0, speedAccuracy: 0)
        let b = DriveFix(time: other.time, latitude: other.latitude, longitude: other.longitude, accuracy: 0, speed: 0, speedAccuracy: 0)
        return a.distance(to: b)
    }
}

struct SavedPlace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radius = 150.0
    var privateLocation = true
    var point: JourneyPoint { JourneyPoint(time: 0, latitude: latitude, longitude: longitude, speed: 0) }
}

struct DriveStop: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var latitude: Double
    var longitude: Double
    var duration: Double { max(0, end - start) }
}

struct StopDetector {
    private var anchor: JourneyPoint?
    private var previousTime: Double?
    private var publishedID: UUID?
    private(set) var stops: [DriveStop] = []
    mutating func observe(_ p: JourneyPoint, stopped: Bool) {
        if let last = previousTime, p.time <= last { return }
        defer { previousTime = p.time }
        guard stopped else { anchor = nil; publishedID = nil; return }
        if let last = previousTime, p.time <= last { return }
        if anchor == nil || p.time - (previousTime ?? p.time) > 10 || anchor!.distance(to: p) > 35 {
            anchor = p; publishedID = nil; return
        }
        guard let a = anchor, p.time - a.time >= 60 else { return }
        if let id = publishedID, let index = stops.firstIndex(where: { $0.id == id }) { stops[index].end = p.time }
        else {
            let stop = DriveStop(start: a.time, end: p.time, latitude: a.latitude, longitude: a.longitude)
            stops.append(stop); publishedID = stop.id
        }
    }
}

enum PlacesStore {
    static func all() -> [SavedPlace] { GaragePlus.load([SavedPlace].self, key: "saved-places") ?? [] }
    static func save(_ place: SavedPlace) throws {
        guard !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              place.name.count <= 80, place.latitude.isFinite, place.longitude.isFinite,
              abs(place.latitude) <= 90, abs(place.longitude) <= 180,
              (50...1000).contains(place.radius) else { throw JourneyError.invalid }
        var places = all(); places.removeAll { $0.id == place.id }; places.append(place)
        try GaragePlus.save(places, key: "saved-places")
    }
    static func delete(_ id: UUID) throws { try GaragePlus.save(all().filter { $0.id != id }, key: "saved-places") }
    static func match(_ point: JourneyPoint, places: [SavedPlace]) -> SavedPlace? {
        places.filter { $0.point.distance(to: point) <= $0.radius }
            .min { $0.point.distance(to: point) < $1.point.distance(to: point) }
    }
    static func title(_ points: [JourneyPoint], places: [SavedPlace]) -> String? {
        guard let a = points.first, let b = points.last,
              let start = match(a, places: places), let end = match(b, places: places) else { return nil }
        return start.name + " → " + end.name
    }
}

enum JourneyError: LocalizedError {
    case invalid, active, alreadyEdited, missing, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return tr("Ehhez a művelethez érvényes időtartomány és legalább két GPS-pont szükséges.", "A valid time range and at least two GPS points are required.")
        case .active: return tr("Előbb fejezd be a folyamatban lévő rögzítést.", "Finish the active recording first.")
        case .alreadyEdited: return tr("Előbb állítsd vissza ennek a szerkesztésnek az eredetijét.", "Restore the original of this edit first.")
        case .missing: return tr("A bejegyzés már nem érhető el.", "This entry is no longer available.")
        case .tooLarge: return tr("A fájl túl nagy a helyi és felhőmentéshez. Válassz kisebb fájlt.", "The file exceeds the backup size limit. Choose a smaller file.")
        }
    }
}

struct RouteObservation: Identifiable {
    var id: Int
    var start: Double
    var duration: Double
    var km: Double
    var stopped: Double
    var points: [JourneyPoint]
    var reliable: Bool
}
struct RouteGroup: Identifiable {
    var id: Int { observations[0].id }
    var title: String
    var observations: [RouteObservation]
    var mean: Double { observations.map(\.duration).reduce(0,+) / Double(observations.count) }
    var deviation: Double { sqrt(observations.reduce(0) { $0 + pow($1.duration - mean, 2) } / Double(observations.count)) }
    var averageStop: Double { observations.map(\.stopped).reduce(0,+) / Double(observations.count) }
}

enum JourneyAnalysis {
    static func distance(_ points: [JourneyPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let dt = pair.1.time - pair.0.time
            let meters = pair.0.distance(to: pair.1)
            guard dt > 0, dt <= 10, meters / dt < 70 else { return total }
            return total + meters / 1000
        }
    }
    static func sameRoute(_ a: [JourneyPoint], _ b: [JourneyPoint]) -> Bool {
        guard a.count >= 2, b.count >= 2,
              a.first!.distance(to: b.first!) < 250, a.last!.distance(to: b.last!) < 250 else { return false }
        // Bidirectional corridor overlap distinguishes alternative streets, not just endpoints.
        func covered(_ source: [JourneyPoint], _ target: [JourneyPoint]) -> Double {
            let sample = stride(from: 0, to: source.count, by: max(1, source.count / 24)).map { source[$0] }
            let hit = sample.filter { p in target.contains { p.distance(to: $0) < 150 } }.count
            return Double(hit) / Double(max(1, sample.count))
        }
        return covered(a,b) >= 0.8 && covered(b,a) >= 0.8
    }
    static func groups(_ observations: [RouteObservation], places: [SavedPlace]) -> [RouteGroup] {
        var result: [RouteGroup] = []
        for observation in observations where observation.reliable && observation.km >= 0.2 {
            if let i = result.firstIndex(where: { sameRoute($0.observations[0].points, observation.points) }) {
                result[i].observations.append(observation)
            } else {
                result.append(RouteGroup(title: PlacesStore.title(observation.points, places: places) ?? tr("Útvonal", "Route"), observations: [observation]))
            }
        }
        return result.sorted { $0.observations.count > $1.observations.count }
    }
    static func feedback(_ current: RouteObservation, previous: [RouteObservation]) -> String? {
        guard current.reliable else { return tr("Hiányos helyadatok: az út időbeli összehasonlítását kihagytuk.", "Incomplete location data: time comparison is unavailable.") }
        let peers = previous.filter { $0.id != current.id && $0.start < current.start && $0.reliable && sameRoute($0.points, current.points) }
        guard peers.count >= 3 else { return nil }
        let average = peers.map(\.stopped).reduce(0,+) / Double(peers.count)
        let difference = current.stopped - average
        guard abs(difference) >= 60 else { return tr("A megállások ideje közel volt a korábbi \(peers.count) hasonló út átlagához.", "Stopped time was close to the average of \(peers.count) similar drives.") }
        let minutes = Int(abs(difference) / 60)
        return difference < 0
            ? tr("Ma \(minutes) perccel kevesebbet álltál a korábbi \(peers.count) hasonló út átlagához képest.", "Today you stopped \(minutes) minutes less than the average of \(peers.count) similar drives.")
            : tr("Ma \(minutes) perccel többet álltál a korábbi \(peers.count) hasonló út átlagához képest.", "Today you stopped \(minutes) minutes more than the average of \(peers.count) similar drives.")
    }
}

enum PrivateRoute {
    /// Hide endpoints and every private saved place. Never join across a hidden area.
    static func segments(_ points: [JourneyPoint], places: [SavedPlace], radius: Double = 500) -> [[JourneyPoint]] {
        guard let first = points.first, let last = points.last else { return [] }
        let zones: [(JourneyPoint,Double)] = [(first,radius),(last,radius)] + places.filter(\.privateLocation).map { ($0.point,max(radius,$0.radius)) }
        func safe(_ a: JourneyPoint, _ b: JourneyPoint) -> Bool {
            guard b.time > a.time, b.time - a.time <= 10 else { return false }
            // Equirectangular local projection checks the whole segment, not only its ends.
            for (center,r) in zones {
                let scale = cos(center.latitude * .pi / 180)
                let ax = (a.longitude-center.longitude)*111_320*scale, ay = (a.latitude-center.latitude)*111_320
                let bx = (b.longitude-center.longitude)*111_320*scale, by = (b.latitude-center.latitude)*111_320
                let dx = bx-ax, dy = by-ay
                let f = min(1,max(0,-(ax*dx+ay*dy)/max(0.001,dx*dx+dy*dy)))
                if hypot(ax+f*dx,ay+f*dy) <= r { return false }
            }
            return true
        }
        var result: [[JourneyPoint]] = [], run: [JourneyPoint] = []
        for pair in zip(points,points.dropFirst()) {
            if safe(pair.0,pair.1) { if run.isEmpty { run.append(pair.0) }; run.append(pair.1) }
            else { if run.count > 1 { result.append(run) }; run = [] }
        }
        if run.count > 1 { result.append(run) }
        return result
    }
}
