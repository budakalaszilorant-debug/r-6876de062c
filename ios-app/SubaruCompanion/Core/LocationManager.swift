import Foundation
import CoreLocation
import Combine

/// GPS az út rögzítéshez és a parkolási hely mentéséhez. Csak út közben fut.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    @Published private(set) var last: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    let updates = PassthroughSubject<CLLocation, Never>()

    private let manager = CLLocationManager()
    private(set) var isTracking = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()  // háttérben rögzítéshez
        default: break
        }
    }

    func startTracking() {
        guard !isTracking else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        isTracking = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .denied || authorization == .restricted { stopTracking() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 50 {
            last = loc
            updates.send(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
