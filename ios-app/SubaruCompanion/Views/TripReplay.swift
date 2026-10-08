import SwiftUI
import MapKit
import Charts

/// Sebesség szerint színezett útvonalszakasz.
final class ColoredPolyline: MKPolyline {
    var color: UIColor = .systemBlue
}

/// Út visszajátszása: sebesség szerint színezett nyomvonal, mozgatható jelölő és sebesség görbe.
struct TripReplayView: View {
    let track: [TrackPoint]
    var events: [PhoneDriveEvent] = []
    var simplified = false

    @State private var position = 0.0      // 0...1 az út mentén
    @State private var playing = false
    @State private var timer: Timer?

    private var index: Int {
        let target = startT + position * ((track.last?.t ?? startT) - startT)
        var low = 0
        var high = max(0, track.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if track[middle].t <= target { low = middle } else { high = middle - 1 }
        }
        return low
    }
    private var current: TrackPoint { track[index] }
    private var startT: Double { track.first?.t ?? 0 }

    var body: some View {
        VStack(spacing: 12) {
            ReplayMap(track: track, marker: current.coordinate, events: events, simplified: simplified)
                .frame(height: simplified ? 350 : 300)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Card {
                VStack(spacing: 12) {
                    HStack {
                        Button {
                            toggle()
                        } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(Theme.accent, in: Circle())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(playing ? tr("Szünet", "Pause") : tr("Út lejátszása", "Play drive"))

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(current.speed >= 0 ? Fmt.int(current.speed) : "—")
                                    .font(Theme.number(26))
                                    .contentTransition(.numericText())
                                Text("km/h").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                            }
                            Text(DriveReportFormat.duration(current.t - startT))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        if !simplified { legend }
                        else { Text(tr("Visszajátszás", "Replay")).font(.caption).foregroundStyle(Theme.text2) }
                    }
                    .accessibilityElement(children: .contain)

                    // 1:1 követés: a csúszka húzása közvetlenül mozgatja a jelölőt
                    Slider(value: $position, in: 0...1) { editing in
                        if editing { stop() }
                    }
                    .accessibilityLabel(tr("Út visszajátszása", "Drive playback"))

                    Chart {
                        ForEach(Array(sampled.enumerated()), id: \.offset) { _, p in
                            if p.speed >= 0 {
                            AreaMark(x: .value("t", p.t - startT), y: .value("v", p.speed))
                                .foregroundStyle(Theme.accent.opacity(0.18))
                            LineMark(x: .value("t", p.t - startT), y: .value("v", p.speed))
                                .foregroundStyle(Theme.accent)
                            }
                        }
                        RuleMark(x: .value("now", current.t - startT))
                            .foregroundStyle(Theme.text)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(Theme.stroke)
                            AxisValueLabel().foregroundStyle(Theme.text3)
                        }
                    }
                    .frame(height: 90)
                }
            }
        }
        .onDisappear { stop() }
    }

    /// A grafikonhoz legfeljebb ~200 pont, hogy hosszú útnál is gyors maradjon.
    private var sampled: [TrackPoint] {
        let step = max(1, track.count / 200)
        return stride(from: 0, to: track.count, by: step).map { track[$0] }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(Array(SpeedBand.allCases.enumerated()), id: \.offset) { _, band in
                HStack(spacing: 3) {
                    Circle().fill(Color(band.color)).frame(width: 7, height: 7)
                    Text(band.label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text3)
                }
            }
        }
    }

    private func toggle() {
        Haptics.tap()
        if playing { stop(); return }
        if position >= 0.999 { position = 0 }
        playing = true
        // Az egész út kb. 20 mp alatt játszódik le.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            position = min(1, position + 0.05 / 20)
            if position >= 1 { stop() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        playing = false
    }
}

enum SpeedBand: CaseIterable {
    case city, road, highway, fast, unknown

    static func of(_ speed: Double) -> SpeedBand {
        if speed < 0 { return .unknown }
        if speed < 50 { return .city }
        if speed < 90 { return .road }
        return speed < 130 ? .highway : .fast
    }

    var color: UIColor {
        switch self {
        case .city: return UIColor(Theme.accent)
        case .road: return UIColor(Theme.ok)
        case .highway: return UIColor(Theme.warn)
        case .fast: return UIColor(Theme.bad)
        case .unknown: return .systemGray
        }
    }

    var label: String {
        switch self {
        case .city: return "<50"
        case .road: return "50–90"
        case .highway: return "90–130"
        case .fast: return "130+"
        case .unknown: return "—"
        }
    }
}

struct ReplayMap: UIViewRepresentable {
    let track: [TrackPoint]
    let marker: CLLocationCoordinate2D
    var events: [PhoneDriveEvent] = []
    var simplified = false

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.showsScale = true
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 450)
        map.addAnnotation(context.coordinator.marker)
        return map
    }

    private func drawRoute(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { $0 is DriveAnnotation })

        // Azonos sebességsávba eső szomszédos pontok egy vonalba kerülnek.
        var run: [CLLocationCoordinate2D] = []
        var band: SpeedBand?
        var bounds = MKMapRect.null
        func flush() {
            guard run.count > 1, let band else { return }
            let line = ColoredPolyline(coordinates: run, count: run.count)
            line.color = band.color
            map.addOverlay(line)
            bounds = bounds.union(line.boundingMapRect)
        }
        var previous: TrackPoint?
        for p in track {
            if let previous, p.t - previous.t > 10 {
                flush(); run = []; band = nil
            }
            let point = MKMapPoint(p.coordinate)
            bounds = bounds.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            let b: SpeedBand = simplified ? .city : SpeedBand.of(p.speed)
            if b != band {
                run.append(p.coordinate)   // a szakaszok érjenek össze
                flush()
                run = [p.coordinate]
                band = b
            } else {
                run.append(p.coordinate)
            }
            previous = p
        }
        flush()
        if !bounds.isNull {
            let minimum = MKMapPointsPerMeterAtLatitude(marker.latitude) * 600
            bounds = MKMapRect(x: bounds.midX - max(bounds.width, minimum) / 2,
                y: bounds.midY - max(bounds.height, minimum) / 2,
                width: max(bounds.width, minimum), height: max(bounds.height, minimum))
            map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                                  animated: false)
        }

        if let first = track.first {
            map.addAnnotation(DriveAnnotation(coordinate: first.coordinate, title: tr("Indulás", "Start"), glyph: "play.fill", tint: .systemGreen))
        }
        if let last = track.last, track.count > 1 {
            map.addAnnotation(DriveAnnotation(coordinate: last.coordinate, title: tr("Utolsó rögzített pont", "Last recorded point"), glyph: "flag.checkered", tint: .systemBlue))
        }
        for event in events {
            let acceleration = event.kind == "acceleration"
            let annotation = DriveAnnotation(coordinate: CLLocationCoordinate2D(latitude: event.latitude, longitude: event.longitude),
                title: acceleration ? tr("Erős gyorsítás (becslés)", "Hard acceleration (estimated)") : tr("Erős fékezés (becslés)", "Hard braking (estimated)"),
                glyph: acceleration ? "arrow.up.right" : "arrow.down.right", tint: acceleration ? .systemOrange : .systemRed)
            annotation.subtitle = "\(Fmt.int(event.speed)) km/h · \(Date(timeIntervalSince1970: event.time).formatted(date: .omitted, time: .standard))"
            map.addAnnotation(annotation)
        }
        if bounds.isNull, let first = track.first {
            map.setRegion(MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 700, longitudinalMeters: 700), animated: false)
        }
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let signature = "\(track.count)-\(track.first?.t ?? 0)-\(track.last?.t ?? 0)-\(events.count)"
        if context.coordinator.signature != signature {
            context.coordinator.signature = signature
            drawRoute(map)
        }
        context.coordinator.marker.coordinate = marker
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var signature = ""
        let marker = MKPointAnnotation()

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? ColoredPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = line.color
            r.lineWidth = 5
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let point = annotation as? DriveAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "event") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: point, reuseIdentifier: "event")
                view.annotation = point; view.canShowCallout = true
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.glyphImage = UIImage(systemName: point.glyph); view.markerTintColor = point.tint
                return view
            }
            let id = "car"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            let size: CGFloat = 18
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.backgroundColor = .white
            view.layer.cornerRadius = size / 2
            view.layer.borderWidth = 4
            view.layer.borderColor = UIColor(Theme.accent).cgColor
            return view
        }
    }
}

final class DriveAnnotation: MKPointAnnotation {
    let glyph: String
    let tint: UIColor
    init(coordinate: CLLocationCoordinate2D, title: String, glyph: String, tint: UIColor) {
        self.glyph = glyph; self.tint = tint
        super.init()
        self.coordinate = coordinate; self.title = title
    }
}
