import SwiftUI
import MapKit

struct JourneyShareView: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var photo = false
    @State private var image: UIImage?
    @State private var url: URL?
    @State private var error: String?
    @State private var building = false
    @State private var task: Task<Void,Never>?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let image { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20)) }
                    if building { ProgressView() }
                    Toggle(tr("Autófotó a kártyán", "Include car photo"),isOn: $photo).disabled(building)
                    Text(tr("Az indulás, az érkezés és a privát helyek körül legalább 500 m rejtve marad. A képen nem szerepel cím vagy rendszámmező. A választott fotón látható adatokat ellenőrizd megosztás előtt.", "At least 500 m around endpoints and private places is hidden. No address or plate field is included. Check visible details in your chosen photo before sharing.")).font(.footnote).foregroundStyle(.secondary)
                    if let url, !building { ShareLink(item: url) { Label(tr("Kép megosztása", "Share image"),systemImage: "square.and.arrow.up").font(.headline).padding() } }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(20)
            }.navigationTitle(tr("Útkártya", "Drive card"))
            .toolbar { Button(tr("Kész", "Done")) { dismiss() } }
        }.onAppear(perform: build).onChange(of: photo) { _ in build() }
        .onDisappear { task?.cancel(); if let url { try? FileManager.default.removeItem(at: url) } }
    }
    private func build() {
        task?.cancel(); building = true; error = nil
        if let url { try? FileManager.default.removeItem(at: url) }; url = nil
        let generation = AccountGarage.generation
        task = Task { @MainActor in
            do {
                let segments = PrivateRoute.segments(JourneyStore.points(trip.id),places: PlacesStore.all())
                let result = try await JourneyCardRenderer.image(trip: trip,segments: segments,photo: photo ? AppSettings.shared.carPhoto : nil)
                guard !Task.isCancelled, generation == AccountGarage.generation else { return }
                guard let data = result.pngData() else { throw JourneyError.invalid }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString).png")
                try data.write(to: file,options: [.atomic,.completeFileProtection]); image = result; url = file
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { building = false }
        }
    }
}

@MainActor enum JourneyCardRenderer {
    static func image(trip: Trip,segments: [[JourneyPoint]],photo: String?) async throws -> UIImage {
        let size = CGSize(width: 1000,height: 1300)
        let mapRect = CGRect(x: 40,y: 180,width: 920,height: 720)
        var snapshot: MKMapSnapshotter.Snapshot?
        if !segments.isEmpty {
            let coordinates = segments.flatMap { $0 }.map { CLLocationCoordinate2D(latitude: $0.latitude,longitude: $0.longitude) }
            var bounds = MKMapRect.null
            for coordinate in coordinates { let p = MKMapPoint(coordinate); bounds = bounds.union(MKMapRect(x: p.x,y: p.y,width: 1,height: 1)) }
            let options = MKMapSnapshotter.Options()
            options.size = mapRect.size; options.scale = 1; options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            options.mapRect = bounds.insetBy(dx: -max(500,bounds.width*0.15),dy: -max(500,bounds.height*0.15))
            options.pointOfInterestFilter = .excludingAll
            snapshot = try await MKMapSnapshotter(options: options).start()
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size,format: format).image { context in
            UIColor(red: 0.04,green: 0.05,blue: 0.07,alpha: 1).setFill(); context.fill(CGRect(origin: .zero,size: size))
            func text(_ value: String,_ x: CGFloat,_ y: CGFloat,_ font: CGFloat,_ color: UIColor = .white) {
                value.draw(in: CGRect(x: x,y: y,width: 900,height: 150),withAttributes: [.font:UIFont.systemFont(ofSize: font,weight: .semibold),.foregroundColor:color])
            }
            text(tr("EGY ÚT TÖRTÉNETE", "A DRIVE TO REMEMBER"),40,45,24,UIColor(Theme.accent))
            text(trip.start.formatted(date: .abbreviated,time: .omitted),40,92,40)
            if let snapshot {
                snapshot.image.draw(in: mapRect)
                context.cgContext.saveGState(); context.cgContext.clip(to: mapRect)
                context.cgContext.setStrokeColor(UIColor(Theme.accent).cgColor); context.cgContext.setLineWidth(7); context.cgContext.setLineCap(.round); context.cgContext.setLineJoin(.round)
                for segment in segments {
                    context.cgContext.beginPath()
                    for (i,p) in segment.enumerated() {
                        let point = snapshot.point(for: CLLocationCoordinate2D(latitude: p.latitude,longitude: p.longitude))
                        let q = CGPoint(x: point.x+mapRect.minX,y: point.y+mapRect.minY)
                        if i == 0 { context.cgContext.move(to: q) } else { context.cgContext.addLine(to: q) }
                    }
                    context.cgContext.strokePath()
                }; context.cgContext.restoreGState()
            } else { text(tr("Rövid út · a helyszínek rejtve", "Short drive · locations hidden"),60,440,32,.lightGray) }
            text("\(Fmt.one(trip.distanceKm)) km",40,950,66)
            text(DriveReportFormat.duration(trip.duration),40,1040,38,.lightGray)
            if let photo, let data = Data(base64Encoded: photo), let image = UIImage(data: data) {
                let rect = CGRect(x: 730,y: 940,width: 230,height: 180)
                context.cgContext.saveGState(); UIBezierPath(roundedRect: rect,cornerRadius: 20).addClip()
                let ratio = max(rect.width/image.size.width,rect.height/image.size.height)
                let target = CGRect(x: rect.midX-image.size.width*ratio/2,y: rect.midY-image.size.height*ratio/2,width: image.size.width*ratio,height: image.size.height*ratio)
                image.draw(in: target); context.cgContext.restoreGState()
            }
            text(tr("GARÁZS  /  Saját útnapló", "GARAGE  /  My drive journal"),40,1190,24,.lightGray)
            text(tr("Privát helyszínek elrejtve", "Private locations hidden"),40,1235,18,.lightGray)
        }
    }
}

struct JourneyMapView: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var details = true
    private var track: [TrackPoint] { TripStore.track(trip.id) }
    var body: some View {
        NavigationStack {
            Group {
                if let last = track.last { ReplayMap(track: track,marker: last.coordinate,events: trip.phoneReport?.events ?? [],stops: trip.phoneReport?.stops ?? [],simplified: true) }
                else { Text(tr("Nincs rögzített nyomvonal", "No recorded route")) }
            }.ignoresSafeArea(edges: .bottom)
                .navigationTitle(JourneyStore.title(trip)).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(tr("Kész", "Done")) { details = false; dismiss() } }
                .sheet(isPresented: $details) {
                    ScrollView {
                        VStack(alignment: .leading,spacing: 20) {
                            HStack(alignment: .top) {
                                Text(JourneyStore.title(trip)).font(.title2.bold())
                                Spacer()
                                Button(tr("Kész", "Done")) { details = false; dismiss() }.font(.headline)
                            }
                            Text("\(Fmt.one(trip.distanceKm)) km · \(DriveReportFormat.duration(trip.duration))").font(.headline)
                            JourneyDetails(trip: trip)
                            if track.count > 1 { TripReplayView(track: track,events: trip.phoneReport?.events ?? [], stops: trip.phoneReport?.stops ?? [],simplified: true) }
                            Button(tr("Térkép bezárása", "Close map")) { details = false; dismiss() }
                        }.padding(24)
                    }.presentationDetents([.height(180),.medium,.large]).presentationDragIndicator(.visible)
                        .modifier(MapPanelInteraction())
                        .interactiveDismissDisabled()
                }
        }
    }
}

private struct MapPanelInteraction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.4, *) { content.presentationBackgroundInteraction(.enabled(upThrough: .medium)) }
        else { content }
    }
}
