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
    var stops: [DriveStop] = []
    var simplified = false

    @State private var rate = 5.0
    @State private var position = 0.0      // 0...1 az út mentén
    @State private var playing = false
    @State private var timer: Timer?

    @Environment(\.scenePhase) private var scenePhase
    @State private var lastTick: Date?
    @State private var points: [JourneyPoint] = []
    @State private var chartPoints: [PlaybackSample] = []
    private var playbackTime: Double { startT + position * max(0,(track.last?.t ?? startT)-startT) }
    private var current: TrackPoint? { JourneyPlayback.index(at: playbackTime,points: points).flatMap { track.indices.contains($0) ? track[$0] : nil } }
    private var playbackSpeed: Double? { JourneyPlayback.speed(at: playbackTime,points: points,stops: stops) }
    private var startT: Double { track.first?.t ?? 0 }

    var body: some View {
        VStack(spacing: 12) {
            if let current { ReplayMap(track: track, marker: current.coordinate, events: events, stops: stops, simplified: simplified)
                .frame(height: simplified ? 350 : 300)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)) }

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
                                Text(Fmt.int(playbackSpeed))
                                    .font(Theme.number(26))
                                    .contentTransition(.numericText())
                                Text("km/h").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                            }
                            Text(DriveReportFormat.duration(playbackTime - startT))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        if !simplified { legend }
                        else { Text(tr("Visszajátszás", "Replay")).font(.caption).foregroundStyle(Theme.text2) }
                    }
                    .accessibilityElement(children: .contain)

                    Picker(tr("Lejátszási sebesség", "Playback speed"), selection: $rate) {
                        Text("1×").tag(1.0); Text("5×").tag(5.0); Text("20×").tag(20.0)
                    }.pickerStyle(.segmented)
                    // 1:1 követés: a csúszka húzása közvetlenül mozgatja a jelölőt
                    Slider(value: $position, in: 0...1) { editing in
                        if editing { stop() }
                    }
                    .accessibilityLabel(tr("Út visszajátszása", "Drive playback"))
                    if playbackSpeed == nil { Text(tr("Ezen a pillanaton nincs megbízható sebességadat.", "No reliable speed reading at this moment.")).font(.caption).foregroundStyle(Theme.text2) }

                    Chart {
                        ForEach(chartPoints) { sample in
                            let p = sample.point
                            if p.speed >= 0 {
                            AreaMark(x: .value("t", p.time - startT), y: .value("v", p.speed), series: .value("segment", sample.segment))
                                .foregroundStyle(Theme.accent.opacity(0.18))
                            LineMark(x: .value("t", p.time - startT), y: .value("v", p.speed), series: .value("segment", sample.segment))
                                .foregroundStyle(Theme.accent)
                            }
                        }
                        RuleMark(x: .value("now", playbackTime - startT))
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
        .onAppear {
            points = track.map { JourneyPoint(time: $0.t,latitude: $0.coordinate.latitude,longitude: $0.coordinate.longitude,speed: $0.speed) }
            chartPoints = JourneyPlayback.chart(points)
        }
        .onChange(of: scenePhase) { phase in if phase != .active { stop() } }
        .onDisappear { stop() }
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
        guard track.count > 1 else { return }
        playing = true; lastTick = Date()
        // Advance by elapsed time, not by an assumed timer delivery rate.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = Date(); let elapsed = max(0, now.timeIntervalSince(lastTick ?? now)); lastTick = now
            position = min(1, position + elapsed * rate / max(1, (track.last?.t ?? startT) - startT))
            if position >= 1 { stop() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil; lastTick = nil
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
    var stops: [DriveStop] = []
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
        for stop in stops {
            let name = PlacesStore.match(JourneyPoint(time: stop.start,latitude: stop.latitude,longitude: stop.longitude,speed: 0),places: PlacesStore.all())?.name
            let annotation = DriveAnnotation(coordinate: CLLocationCoordinate2D(latitude: stop.latitude,longitude: stop.longitude),title: name ?? tr("Megállás", "Stop"),glyph: "pause.fill",tint: .systemTeal)
            annotation.subtitle = DriveReportFormat.duration(stop.duration)
            map.addAnnotation(annotation)
        }
        if bounds.isNull, let first = track.first {
            map.setRegion(MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 700, longitudinalMeters: 700), animated: false)
        }
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let signature = "\(track.count)-\(track.first?.t ?? 0)-\(track.last?.t ?? 0)-\(events.count)-\(stops.count)"
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
