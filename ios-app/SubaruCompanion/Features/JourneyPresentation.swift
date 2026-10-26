import Foundation

extension JourneyStore {
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
}
