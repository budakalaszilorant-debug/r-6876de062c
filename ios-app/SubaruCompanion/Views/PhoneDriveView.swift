import SwiftUI

struct PhoneDriveCard: View {
    @ObservedObject private var drive = PhoneDriveRecorder.shared
    @ObservedObject private var monitor = VehicleMonitor.shared
    @ObservedObject private var cloud = CloudSync.shared
    @State private var open = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Label(tr("Telefonos út", "Phone drive"), systemImage: "location.north.line.fill")
                    .font(.headline).foregroundStyle(Theme.accent)
                Text(tr("Az útvonalad, egy érintésre.", "Your journey, one tap away."))
                    .font(.title2.bold()).foregroundStyle(Theme.text)
                Text(tr("GPS-es útnapló autós kapcsolat nélkül. Indítsd el indulás előtt, és mentsd el érkezéskor.", "A GPS drive log without a car connection. Start before leaving and save on arrival."))
                    .font(.subheadline).foregroundStyle(Theme.text2)
                if let trip = drive.active {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(Fmt.one(trip.distanceKm)) km · \(Fmt.duration(context.date.timeIntervalSince(trip.start)))")
                            .font(.title3.monospacedDigit()).foregroundStyle(Theme.text)
                    }
                }
                PrimaryButton(title: drive.isBusy ? tr("Rögzítés megnyitása", "Open recording") : tr("Út indítása", "Start drive"), icon: drive.isBusy ? "record.circle" : "play.fill") {
                    open = true
                    if !drive.isBusy { drive.start() }
                }
                .disabled(!drive.isBusy && (monitor.trip != nil || monitor.isLive || monitor.demoActive || cloud.busy))
                if !drive.isBusy && (monitor.trip != nil || monitor.isLive || monitor.demoActive) {
                    Text(tr("Előbb fejezd be az autós rögzítést vagy kapcsold ki a demót.", "Finish the vehicle recording or turn off demo first."))
                        .font(.caption).foregroundStyle(Theme.text2)
                }
            }
        }
        .sheet(isPresented: $open) { PhoneDriveView() }
    }
}

struct PhoneDriveView: View {
    @ObservedObject private var drive = PhoneDriveRecorder.shared
    @Environment(\.dismiss) private var dismiss
    @State private var saved: Trip?
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if let saved {
                    TripDetailView(trip: saved) { drive.refreshHistory() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let last = drive.track.last {
                                ReplayMap(track: drive.track, marker: last.coordinate, events: drive.report.events)
                                    .frame(height: 320)
                                    .clipShape(RoundedRectangle(cornerRadius: 24))
                            } else {
                                ContentUnavailableDrive()
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let fresh = drive.lastFixDate.map { context.date.timeIntervalSince($0) < 15 } ?? false
                                VStack(alignment: .leading, spacing: 14) {
                                    Label(fresh ? tr("GPS rögzítés folyamatban", "GPS recording") : tr("GPS-jelre várunk", "Waiting for GPS"), systemImage: fresh ? "record.circle" : "location.slash")
                                        .foregroundStyle(fresh ? Theme.ok : Theme.warn)
                                    LazyVGrid(columns: columns, spacing: 12) {
                                        StatTile(label: tr("Megtett táv", "Distance"), value: Fmt.one(drive.active?.distanceKm ?? 0), unit: "km")
                                        StatTile(label: tr("Eltelt idő", "Elapsed"), value: Fmt.duration(drive.active.map { context.date.timeIntervalSince($0.start) } ?? 0), unit: "")
                                        StatTile(label: tr("Sebesség", "Speed"), value: fresh ? Fmt.int(drive.speed) : "—", unit: "km/h")
                                        StatTile(label: tr("Maximum", "Top speed"), value: Fmt.int(drive.active?.maxSpeed), unit: "km/h")
                                    }
                                }
                            }
                            if drive.active != nil {
                                PrimaryButton(title: tr("Leállítás és mentés", "Stop and save"), icon: "stop.fill") {
                                    saved = drive.finish()
                                }
                            } else if drive.waitingForPermission {
                                ProgressView(tr("Helyhozzáférésre várunk…", "Waiting for location permission…"))
                            } else {
                                PrimaryButton(title: tr("Út indítása", "Start drive"), icon: "play.fill") { drive.start() }
                            }
                            Text(tr("A képernyő lezárható: a rögzítés a háttérben is folytatódik engedélyezett helyhozzáféréssel. Az app kényszerített bezárása megszakítja az utat. GPS-kiesés alatt nem becsülünk hozzá kilométereket.", "You can lock the screen: recording continues in the background with location permission. Force-quitting interrupts the drive. No distance is invented during GPS gaps."))
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }.padding(16)
                    }.screenBackground()
                }
            }
            .navigationTitle(saved == nil ? tr("Telefonos út", "Phone drive") : tr("Út összesítője", "Drive report"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(saved == nil && drive.active != nil ? tr("Háttérbe", "Minimize") : tr("Kész", "Done")) { dismiss() }
            } }
            .alert(drive.message ?? "", isPresented: Binding(get: { drive.message != nil }, set: { if !$0 { drive.message = nil } })) {
                Button("OK", role: .cancel) { }
            }
        }.preferredColorScheme(.dark)
        .onDisappear { drive.cancelPending() }
    }
}

private struct ContentUnavailableDrive: View {
    var body: some View {
        Card {
            VStack(spacing: 16) {
                Image(systemName: "location.circle").font(.system(size: 64)).foregroundStyle(Theme.accent)
                Text(tr("Itt rajzolódik az utad", "Your route appears here")).font(.title2.bold())
                Text(tr("A pontos helymeghatározás legyen bekapcsolva. Az első GPS-pont megérkezése néhány másodpercet igényelhet.", "Enable Precise Location. The first GPS fix may take a few seconds."))
                    .font(.subheadline).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 30)
        }
    }
}

struct PhoneDriveReportCard: View {
    let report: PhoneDriveReport
    let trip: Trip
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                Label(tr("Vezetési összesítő · GPS", "Drive report · GPS"), systemImage: "steeringwheel").font(.headline)
                if report.interrupted {
                    Label(tr("Megszakadt rögzítés – a mentett szakasz", "Interrupted recording – saved portion"), systemImage: "exclamationmark.circle").foregroundStyle(Theme.warn)
                }
                HStack(alignment: .top, spacing: 12) {
                    eventCount("acceleration", tr("Erős gyorsítás", "Hard acceleration"), "arrow.up.right", Theme.warn)
                    eventCount("braking", tr("Erős fékezés", "Hard braking"), "arrow.down.right", Theme.bad)
                }
                LabeledContent(tr("Mozgásban", "Moving"), value: Fmt.duration(report.movingSeconds))
                LabeledContent(tr("Álló helyzet", "Stopped"), value: Fmt.duration(report.stoppedSeconds))
                LabeledContent(tr("GPS-lefedettség", "GPS coverage"), value: "\(Int(min(100, max(0, report.measuredSeconds / max(1, trip.duration) * 100))))%")
                Text(tr("A vezetési események GPS-sebességváltozásból becsültek. A megállás nem alapjárat-mérés. Fogyasztást, telefonhasználatot és közúti sebességhatárt ez a mód nem mér.", "Driving events are estimated from GPS speed changes. Stopped time is not engine idling. This mode does not measure fuel use, phone use or road speed limits."))
                    .font(.caption).foregroundStyle(Theme.text2)
            }
        }
    }
    private func eventCount(_ kind: String, _ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(report.events.filter { $0.kind == kind }.count)").font(Theme.number(30))
            Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }
}
