import SwiftUI
import CoreLocation

struct TripsView: View {
    @State private var mode = UserDefaults.standard.integer(forKey: "uiMode")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text(tr("Utak", "Trips")).tag(0)
                    Text(tr("Tankolás", "Fuel")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if mode == 0 { TripListView() } else { FuelView() }
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct TripListView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @EnvironmentObject var settings: AppSettings
    @State private var trips: [Trip] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Hol parkolok", "Where I parked"))
                    ParkingCard(spot: monitor.parking)
                    if settings.featParkingTimer { ParkingTimerCard() }
                }

                if settings.featMonthly {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: tr("Havi összesítő", "Monthly summary"))
                        MonthlySummaryCard()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Rögzített utak", "Recorded trips"))
                    if trips.isEmpty {
                        Card {
                            EmptyState(icon: "road.lanes",
                                       title: tr("Még nincs út", "No trips yet"),
                                       message: tr("Az utak maguktól rögzülnek motorindítástól leállításig.",
                                                   "Trips record themselves from engine start to stop."))
                        }
                    } else {
                        ForEach(trips) { trip in
                            NavigationLink {
                                TripDetailView(trip: trip) { reload() }
                            } label: {
                                TripRow(trip: trip)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear(perform: reload)
        .onChange(of: monitor.dataVersion) { _ in reload() }
    }

    private func reload() { trips = TripStore.all() }
}

struct TripRow: View {
    let trip: Trip

    private var subtitle: String {
        var parts = [Fmt.duration(trip.duration), "\(Fmt.one(trip.avgConsumption)) l/100"]
        if AppSettings.shared.featTripCost, let cost = trip.cost { parts.append("\(Fmt.km(cost)) Ft") }
        if trip.tag == "work" { parts.append(tr("munka", "work")) }
        if trip.tag == "private" { parts.append(tr("magán", "private")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.date(trip.start))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Fmt.one(trip.distanceKm)).font(Theme.number(22)).foregroundStyle(Theme.text)
                    Text("km").font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
        }
    }
}

struct TripDetailView: View {
    let trip: Trip
    let onDelete: () -> Void
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var track: [TrackPoint] = []
    @State private var tag = ""
    @State private var confirmDelete = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if track.count > 1 {
                    TripReplayView(track: track)
                } else {
                    EmptyState(icon: "location.slash", title: tr("Nincs GPS nyomvonal", "No GPS track"),
                               message: tr("Ehhez az úthoz nem volt helyadat.", "No location data for this trip."))
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                Picker("", selection: $tag) {
                    Text(tr("Nincs címke", "No tag")).tag("")
                    Text(tr("Munka", "Work")).tag("work")
                    Text(tr("Magán", "Private")).tag("private")
                }
                .pickerStyle(.segmented)
                .onChange(of: tag) { value in
                    TripStore.setTag(trip.id, value.isEmpty ? nil : value)
                    onDelete()  // a lista frissítése
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    StatTile(label: tr("Távolság", "Distance"), value: Fmt.one(trip.distanceKm), unit: "km")
                    StatTile(label: tr("Idő", "Duration"), value: Fmt.duration(trip.duration), unit: "")
                    StatTile(label: tr("Fogyasztás", "Consumption"), value: Fmt.one(trip.avgConsumption), unit: "l/100")
                    StatTile(label: tr("Üzemanyag", "Fuel used"), value: Fmt.two(trip.fuelL), unit: "l")
                    if settings.featTripCost {
                        StatTile(label: tr("Benzinköltség", "Fuel cost"), value: trip.cost.map(Fmt.km) ?? "—", unit: "Ft")
                    }
                    StatTile(label: tr("Átlagsebesség", "Avg speed"), value: Fmt.int(trip.avgSpeed), unit: "km/h")
                    StatTile(label: tr("Max sebesség", "Top speed"), value: Fmt.int(trip.maxSpeed), unit: "km/h")
                    if settings.featIdle {
                        StatTile(label: tr("Alapjárat", "Idling"), value: Fmt.duration(trip.idleS), unit: "")
                        StatTile(label: tr("Alapjárati benzin", "Idle fuel"), value: Fmt.two(trip.idleFuelL), unit: "l")
                    }
                }

                PrimaryButton(title: tr("Út törlése", "Delete trip"), icon: "trash", tint: Theme.surface2) {
                    confirmDelete = true
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(Fmt.date(trip.start))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            track = TripStore.track(trip.id)
            tag = trip.tag ?? ""
        }
        .confirmationDialog(tr("Törlöd ezt az utat?", "Delete this trip?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(tr("Törlés", "Delete"), role: .destructive) {
                TripStore.delete(trip.id)
                onDelete()
                dismiss()
            }
        }
    }
}

struct ParkingCard: View {
    let spot: ParkingSpot?

    var body: some View {
        Card(padding: 0) {
            if let spot {
                VStack(alignment: .leading, spacing: 0) {
                    RouteMap(pin: spot.coordinate, showsUser: true)
                        .frame(height: 180)
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr("Leállítva: \(Fmt.date(spot.date))", "Parked: \(Fmt.date(spot.date))"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.text2)
                        PrimaryButton(title: tr("Vezess az autóhoz", "Walk me to the car"), icon: "figure.walk") {
                            MapsLauncher.walk(to: spot.coordinate, name: "Subaru Impreza")
                        }
                    }
                    .padding(16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                EmptyState(icon: "parkingsign.circle",
                           title: tr("Nincs mentett hely", "No saved spot"),
                           message: tr("Leállításkor az app elmenti, hol áll az autó.",
                                       "When you switch off, the app saves where the car is."))
            }
        }
    }
}
