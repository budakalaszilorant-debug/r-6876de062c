import SwiftUI
import MapKit

/// MKMapView csomagoló (iOS 16-on a SwiftUI Map még nem tud útvonalat rajzolni).
struct RouteMap: UIViewRepresentable {
    var route: [CLLocationCoordinate2D] = []
    var pin: CLLocationCoordinate2D? = nil
    var showsUser = false

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.showsUserLocation = showsUser
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let signature = "\(route.count)-\(pin?.latitude ?? 0)-\(pin?.longitude ?? 0)"
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })

        if route.count > 1 {
            let line = MKPolyline(coordinates: route, count: route.count)
            map.addOverlay(line)
            map.setVisibleMapRect(line.boundingMapRect,
                                  edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                                  animated: false)
        }
        if let pin {
            let a = MKPointAnnotation()
            a.coordinate = pin
            map.addAnnotation(a)
            if route.count <= 1 {
                map.setRegion(MKCoordinateRegion(center: pin, latitudinalMeters: 500, longitudinalMeters: 500),
                              animated: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var signature = ""

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = UIColor(Theme.accent)
            r.lineWidth = 5
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }
    }
}

enum MapsLauncher {
    /// Gyalogos navigáció az autóhoz az Apple Térképek appban.
    static func walk(to coordinate: CLLocationCoordinate2D, name: String) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
