import SwiftUI
import MapKit

struct OverviewView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @ObservedObject private var recorder = PhoneDriveRecorder.shared
    @State private var trips: [Trip] = []
    @State private var summary = CostSummary()
    @State private var costs = false
    private var service: ServiceStatus? { ServiceStore.statuses(odometer: settings.odometerKm).filter { $0.remainingKm != nil }.min { $0.remainingKm! < $1.remainingKm! } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading,spacing: 24) {
                    CarHomeHeader()
                    HStack(alignment: .top,spacing: 20) {
                        metric(tr("EBBEN A HÓNAPBAN", "THIS MONTH"), value: Fmt.km(summary.km),unit: "km")
                        Spacer()
                        Button { costs = true } label: { metric(tr("RÖGZÍTETT KIADÁS", "LOGGED SPENDING"),value: Fmt.km(summary.total),unit: "Ft") }.buttonStyle(.plain)
                    }
                    PhoneDriveCard()
                    if let service {
                        NavigationLink { ServiceView() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading,spacing: 4) {
                                    Text(tr("Következő szerviz", "Next service")).font(.caption).foregroundStyle(Theme.text2)
                                    Text(service.item.name).font(.headline)
                                }
                                Spacer()
                                Text("\(Fmt.km(service.remainingKm ?? 0)) km").font(.headline.monospacedDigit())
                            }.padding(18).background(Theme.surface,in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                    }
                    if monitor.isLive || monitor.demoActive {
                        NavigationLink { DashboardView() } label: { Label(tr("Élő műszerfal megnyitása", "Open live instruments"),systemImage: "speedometer").font(.headline).padding(.vertical,12) }
                    }
                    if let last = trips.first {
                        SectionLabel(text: tr("LEGUTÓBBI ÚT", "LAST DRIVE"))
                        NavigationLink { TripDetailView(trip: last,onDelete: reload) } label: { TripRow(trip: last) }.buttonStyle(.plain)
                    }
                    HStack {
                        NavigationLink { RouteInsightsView() } label: { Label(tr("Útvonalaim", "My routes"),systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                        Spacer()
                        NavigationLink { PlacesView() } label: { Label(tr("Saját helyek", "My places"),systemImage: "mappin.and.ellipse") }
                    }.font(.subheadline.weight(.medium))
                }.padding(20)
            }.screenBackground().navigationTitle(tr("Áttekintés", "Overview"))
            .onAppear(perform: reload).onChange(of: monitor.dataVersion) { _ in reload() }.onChange(of: recorder.revision) { _ in reload() }
            .sheet(isPresented: $costs) { CostsView() }
        }
    }
    private func metric(_ label: String,value: String,unit: String) -> some View {
        VStack(alignment: .leading,spacing: 8) {
            Text(label).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(Theme.text2)
            (Text(value).font(.system(size: 30,weight: .bold,design: .rounded)) + Text(" " + unit).font(.subheadline)).foregroundStyle(Theme.text)
        }
    }
    private func reload() {
        trips = TripStore.all()
        summary = ExpenseStore.summary(since: Calendar.current.date(from: Calendar.current.dateComponents([.year,.month],from: Date())))
    }
}

struct GarageHubView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading,spacing: 22) {
                    CarHomeHeader()
                    VStack(spacing: 0) {
                        destination(tr("Autóim", "My cars"),"car.2") { GarageView() }
                        destination(tr("Szervizkönyv", "Service book"),"book.closed") { ServiceJournalView() }
                        destination(tr("Dokumentumtár", "Documents"),"folder") { GarageLibraryView() }
                        destination(tr("Állapot és diagnosztika", "Status and diagnostics"),"waveform.path.ecg") { CarView() }
                        destination(tr("Családi garázs", "Family garage"),"person.2") { FamilyGarageView() }
                        destination(tr("G-erő mérő", "G-force meter"),"scope") { DriveView() }
                    }.background(Theme.surface,in: RoundedRectangle(cornerRadius: 20))
                    ToolsCard()
                }.padding(20)
            }.screenBackground().navigationTitle(tr("Garázs", "Garage"))
        }
    }
    private func destination<V: View>(_ title: String,_ icon: String,@ViewBuilder content: () -> V) -> some View {
        NavigationLink(destination: content()) {
            HStack(spacing: 14) { Image(systemName: icon).frame(width: 24).foregroundStyle(Theme.accent); Text(title); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text3) }.padding(18)
        }.buttonStyle(.plain)
    }
}

struct PlacesView: View {
    @State private var places = PlacesStore.all()
    @State private var editing: SavedPlace?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                ForEach(places) { place in
                    Button { editing = place } label: { Label(place.name,systemImage: place.privateLocation ? "house.fill" : "mappin") }
                        .swipeActions { Button(role: .destructive) { do { try PlacesStore.delete(place.id); places = PlacesStore.all() } catch { self.error = error.localizedDescription } } label: { Image(systemName: "trash") } }
                }
            } footer: { Text(tr("Az utak neve automatikusan a mentett helyekből készül. A privát helyek környékét a megosztott képen elrejtjük.", "Trips are named from saved places. Private places are hidden on shared images.")) }
        }.navigationTitle(tr("Saját helyek", "My places"))
        .toolbar { Button { let p = JourneyStore.observations().first?.points.last; editing = SavedPlace(name: "",latitude: p?.latitude ?? 47.4979,longitude: p?.longitude ?? 19.0402) } label: { Image(systemName: "plus") } }
        .sheet(item: $editing,onDismiss: { places = PlacesStore.all() }) { PlaceEditor(place: $0) }
        .alert(tr("Nem sikerült", "Could not complete"),isPresented: Binding(get: { error != nil },set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
}

struct PlaceEditor: View {
    @State var place: SavedPlace
    @State private var region: MKCoordinateRegion
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(place: SavedPlace) {
        _place = State(initialValue: place)
        _region = State(initialValue: MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.latitude,longitude: place.longitude),span: MKCoordinateSpan(latitudeDelta: 0.008,longitudeDelta: 0.008)))
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("Név (pl. Otthon, Munka)", "Name (e.g. Home, Work)"),text: $place.name)
                ZStack { Map(coordinateRegion: $region); Image(systemName: "mappin.circle.fill").font(.largeTitle).foregroundStyle(Theme.accent).accessibilityHidden(true) }.frame(height: 280)
                Text(tr("Mozgasd a térképet: a középső jelölő helyét mentjük.", "Move the map: the center pin will be saved.")).font(.caption)
                Toggle(tr("Privát hely", "Private location"),isOn: $place.privateLocation)
                Slider(value: $place.radius,in: 50...1000,step: 50) { Text(tr("Felismerési sugár", "Recognition radius")) }
                Text("\(Int(place.radius)) m")
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(tr("Hely mentése", "Save place"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(tr("Mentés", "Save")) {
                    do { place.latitude = region.center.latitude; place.longitude = region.center.longitude; try PlacesStore.save(place); dismiss() } catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
}

struct RouteInsightsView: View {
    @State private var groups: [RouteGroup] = []
    var body: some View {
        List {
            Section { NavigationLink(tr("Saját helyek elnevezése", "Name my places")) { PlacesView() } }
            ForEach(Array(groups.enumerated()),id: \.element.id) { index,group in
                VStack(alignment: .leading,spacing: 8) {
                    Text("\(group.title) · \(index+1)").font(.headline)
                    Text(tr("\(group.observations.count) út · átlag \(Fmt.duration(group.mean))", "\(group.observations.count) trips · average \(Fmt.duration(group.mean))"))
                    Text(tr("Szórás: \(Fmt.duration(group.deviation)) · megállás: \(Fmt.duration(group.averageStop))", "Variation: \(Fmt.duration(group.deviation)) · stopped: \(Fmt.duration(group.averageStop))")).font(.caption).foregroundStyle(.secondary)
                    if let first = group.observations.first, first.points.count > 1 {
                        RouteMap(route: first.points.map { CLLocationCoordinate2D(latitude: $0.latitude,longitude: $0.longitude) }).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }.padding(.vertical,8)
            }
            if groups.isEmpty { Text(tr("Legalább két megbízható, azonos útvonalú telefonos út után jelenik meg összehasonlítás.", "Comparisons appear after at least two reliable phone drives along the same route.")) }
            Text(tr("A legutóbbi 100 út alapján. A hiányos és szerkesztett mérések kimaradnak. Az eltérő nyomvonalak külön szerepelnek.", "Based on the last 100 trips. Incomplete and edited measurements are excluded. Different routes are shown separately.")).font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle(tr("Útvonalaim", "My routes"))
        .onAppear { groups = JourneyAnalysis.groups(JourneyStore.observations(),places: PlacesStore.all()).filter { $0.observations.count >= 2 } }
    }
}

struct JourneyDetails: View {
    let trip: Trip
    @State private var feedback: String?
    private func endpoint(start: Bool) -> String {
        let points = JourneyStore.points(trip.id)
        if let point = start ? points.first : points.last, let place = PlacesStore.match(point,places: PlacesStore.all()) { return place.name }
        return start ? tr("Indulás", "Departure") : tr("Érkezés", "Arrival")
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                Label(endpoint(start: true),systemImage: "circle")
                Spacer(); Text(trip.start,style: .time)
            }
            HStack {
                Label(endpoint(start: false),systemImage: "flag.checkered")
                Spacer(); if let end = trip.end { Text(end,style: .time) }
            }
            if let report = trip.phoneReport {
                ForEach(report.stops ?? []) { stop in
                    HStack { Image(systemName: "pause.circle"); Text(Date(timeIntervalSince1970: stop.start),style: .time); Spacer(); Text(DriveReportFormat.duration(stop.duration)) }
                }
                if report.edited == true { Text(tr("Szerkesztett GPS-út. A fogyasztás és a teljes mérési lefedettség nem állapítható meg.", "Edited GPS trip. Fuel consumption and full measurement coverage are unavailable.")).font(.footnote).foregroundStyle(Theme.text2) }
            }
            if let feedback { Label(feedback,systemImage: "text.bubble").font(.subheadline).foregroundStyle(Theme.text2) }
        }.padding(18).background(Theme.surface,in: RoundedRectangle(cornerRadius: 18))
        .onAppear { feedback = JourneyAnalysis.feedback(JourneyStore.observation(trip),previous: JourneyStore.observations()) }
    }
}

struct JourneyEditView: View {
    let trip: Trip
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var from = 0.0
    @State private var to = 1.0
    @State private var split = 0.5
    @State private var other = 0
    @State private var error: String?
    @State private var confirm = false
    @State private var points: [JourneyPoint] = []
    private var selectedPoints: [JourneyPoint] { points.filter { $0.time >= time(from) && $0.time <= time(to) } }
    private func time(_ fraction: Double) -> Double { let p = points; return (p.first?.time ?? 0) + fraction * ((p.last?.time ?? 0) - (p.first?.time ?? 0)) }
    var body: some View {
        NavigationStack {
            Form {
                if let archive = JourneyStore.archive(for: trip.id) {
                    Text(tr("Az eredeti út megmaradt. Visszaállításkor a belőle készült módosított utak helyére kerül.", "The original is preserved. Restoring replaces the edited trips created from it."))
                    Button(tr("Eredeti visszaállítása", "Restore original")) { do { try JourneyStore.restore(archive); onSave(); dismiss() } catch { self.error = error.localizedDescription } }
                } else {
                    Picker(tr("Művelet", "Action"),selection: $mode) {
                        Text(tr("Vágás", "Trim")).tag(0); Text(tr("Kettévágás", "Split")).tag(1); Text(tr("Összefűzés", "Merge")).tag(2)
                    }.pickerStyle(.segmented)
                    if mode == 0 {
                        Text(tr("Kezdet", "Start")); Slider(value: $from,in: 0...1)
                        Text(Date(timeIntervalSince1970: time(from)),style: .time)
                        Text(tr("Vége", "End")); Slider(value: $to,in: 0...1)
                        Text(Date(timeIntervalSince1970: time(to)),style: .time)
                    } else if mode == 1 {
                        Slider(value: $split,in: 0...1); Text(Date(timeIntervalSince1970: time(split)),style: .time)
                    } else {
                        Picker(tr("Másik út", "Other trip"),selection: $other) {
                            Text(tr("Válassz", "Choose")).tag(0)
                            ForEach(TripStore.all().filter { $0.id != trip.id && JourneyStore.archive(for: $0.id) == nil }) { Text(Fmt.date($0.start)).tag($0.id) }
                        }
                    }
                    if mode == 0, let first = selectedPoints.first, let last = selectedPoints.last {
                        LabeledContent(tr("Vágás után", "After trimming"),value: "\(Fmt.one(JourneyAnalysis.distance(selectedPoints))) km · \(DriveReportFormat.duration(last.time-first.time))")
                    }
                    Text(tr("Az eredeti visszaállítható. A módosított táv GPS-ből készül; üzemanyag és költség nem kerül becsléssel átmásolásra.", "The original can be restored. Edited distance comes from GPS; fuel and costs will not be guessed."))
                    Button(tr("Módosítás mentése", "Save changes")) { confirm = true }.disabled(points.count < 2 || (mode == 0 && from >= to) || (mode == 2 && other == 0))
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(tr("Út szerkesztése", "Edit trip"))
            .onAppear { points = JourneyStore.points(trip.id) }
            .toolbar { Button(tr("Bezárás", "Close")) { dismiss() } }
            .confirmationDialog(tr("Elmented a módosított utat?", "Save the edited trip?"),isPresented: $confirm) {
                Button(tr("Mentés", "Save")) {
                    do { let action: JourneyStore.Edit = mode == 0 ? .trim(time(from),time(to)) : mode == 1 ? .split(time(split)) : .merge(other)
                        try JourneyStore.edit(trip.id,operation: action); onSave(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}

struct JourneyArchiveView: View {
    let onRestore: () -> Void
    @State private var archives = JourneyStore.archives()
    @State private var selected: JourneyArchive?
    @State private var error: String?
    var body: some View {
        List {
            ForEach(archives) { archive in
                Button { selected = archive } label: {
                    VStack(alignment: .leading) {
                        Text(archive.date,style: .date)
                        Text(tr("\(archive.originals.count) eredeti út visszaállítása", "Restore \(archive.originals.count) original trips")).font(.subheadline)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(tr("Eredeti utak", "Original trips"))
        .confirmationDialog(tr("A szerkesztett változatokat lecseréljük az eredetiekre. Folytatod?", "Replace edited versions with their originals?"),isPresented: Binding(get: { selected != nil },set: { if !$0 { selected = nil } })) {
            Button(tr("Visszaállítás", "Restore")) {
                do { if let selected { try JourneyStore.restore(selected) }; archives = JourneyStore.archives(); onRestore() } catch { self.error = error.localizedDescription }
            }
        }
    }
}
