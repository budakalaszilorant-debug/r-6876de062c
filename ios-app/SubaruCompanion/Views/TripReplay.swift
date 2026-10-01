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

    @State private var position = 0.0      // 0...1 az út mentén
    @State private var playing = false
    @State private var timer: Timer?

    private var index: Int {
        min(track.count - 1, max(0, Int((position * Double(track.count - 1)).rounded())))
    }
    private var current: TrackPoint { track[index] }
    private var startT: Double { track.first?.t ?? 0 }

    var body: some View {
        VStack(spacing: 12) {
            ReplayMap(track: track, marker: current.coordinate)
                .frame(height: 300)
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

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(Fmt.int(current.speed))
                                    .font(Theme.number(26))
                                    .contentTransition(.numericText())
                                Text("km/h").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                            }
                            Text(Fmt.duration(current.t - startT))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        legend
                    }

                    // 1:1 követés: a csúszka húzása közvetlenül mozgatja a jelölőt
                    Slider(value: $position, in: 0...1) { editing in
                        if editing { stop() }
                    }

                    Chart {
                        ForEach(Array(sampled.enumerated()), id: \.offset) { _, p in
                            AreaMark(x: .value("t", p.t - startT), y: .value("v", p.speed))
                                .foregroundStyle(Theme.accent.opacity(0.18))
                            LineMark(x: .value("t", p.t - startT), y: .value("v", p.speed))
                                .foregroundStyle(Theme.accent)
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
    case city, road, highway, fast

    static func of(_ speed: Double) -> SpeedBand {
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
        }
    }

    var label: String {
        switch self {
        case .city: return "<50"
        case .road: return "50–90"
        case .highway: return "90–130"
        case .fast: return "130+"
        }
    }
}

struct ReplayMap: UIViewRepresentable {
    let track: [TrackPoint]
    let marker: CLLocationCoordinate2D

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.pointOfInterestFilter = .excludingAll

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
        for p in track {
            let b = SpeedBand.of(p.speed)
            if b != band {
                run.append(p.coordinate)   // a szakaszok érjenek össze
                flush()
                run = [p.coordinate]
                band = b
            } else {
                run.append(p.coordinate)
            }
        }
        flush()
        if !bounds.isNull {
            map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                                  animated: false)
        }

        context.coordinator.marker.coordinate = marker
        map.addAnnotation(context.coordinator.marker)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.marker.coordinate = marker
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
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
