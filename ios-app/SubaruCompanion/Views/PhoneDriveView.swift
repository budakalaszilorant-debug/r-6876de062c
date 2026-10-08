import SwiftUI

/// Recording stays on the trips screen; only stopping opens the detailed report.
struct PhoneDriveCard: View {
    @ObservedObject private var drive = PhoneDriveRecorder.shared
    @ObservedObject private var monitor = VehicleMonitor.shared
    @ObservedObject private var cloud = CloudSync.shared
    @State private var saved: Trip?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(tr("Telefonos út", "Phone drive"), systemImage: "location.north.line.fill")
                        .font(.headline)
                    Spacer()
                    if drive.active != nil {
                        Text(tr("RÖGZÍTÉS", "RECORDING")).font(.caption2.bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.ok.opacity(0.14), in: Capsule()).foregroundStyle(Theme.ok)
                    }
                }
                if drive.active != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let fresh = drive.lastFixDate.map { context.date.timeIntervalSince($0) < 15 } ?? false
                        VStack(alignment: .leading, spacing: 8) {
                            Text(!fresh ? tr("GPS-jelre várunk", "Waiting for GPS") : drive.isMoving ? tr("Az utad rögzül", "Recording your drive") : tr("Várakozás indulásra", "Waiting for movement"))
                                .font(.title2.bold())
                            Text(tr("Lezárhatod a képernyőt. Az összesítőt leállítás után mutatjuk.", "You can lock the screen. Your report appears when you stop."))
                                .font(.subheadline).foregroundStyle(Theme.text2)
                        }
                    }
                    PrimaryButton(title: tr("Út befejezése", "Finish drive"), icon: "stop.fill") {
                        saved = drive.finish()
                    }
                } else if drive.waitingForPermission {
                    ProgressView(tr("Helyhozzáférésre várunk…", "Waiting for location access…"))
                    Button(tr("Mégse", "Cancel")) { drive.cancelPending() }
                } else {
                    Text(tr("Indítsd el. Mi rögzítünk.", "Start it. We record."))
                        .font(.title2.bold())
                    Text(tr("Útvonal és vezetési összesítő, autós kapcsolat nélkül. A rögzítés indítás után a háttérben is folytatódik.", "Route and drive report without a car connection. Recording continues in the background after you start."))
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    PrimaryButton(title: tr("Út indítása", "Start drive"), icon: "play.fill") { drive.start() }
                        .disabled(monitor.trip != nil || monitor.isLive || monitor.demoActive || monitor.needsCarSelection || cloud.busy)
                    if monitor.trip != nil || monitor.isLive || monitor.demoActive || monitor.needsCarSelection {
                        Text(tr("Előbb fejezd be az autós rögzítést vagy kapcsold ki a demót.", "Finish the vehicle recording or turn off demo first."))
                            .font(.caption).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
        .sheet(item: $saved) { trip in PhoneDriveView(trip: trip) }
        .alert(drive.message ?? "", isPresented: Binding(get: { drive.message != nil }, set: { if !$0 { drive.message = nil } })) {
            Button("OK", role: .cancel) { }
        }
    }
}

struct PhoneDriveView: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TripDetailView(trip: trip) { PhoneDriveRecorder.shared.refreshHistory() }
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Kész", "Done")) { dismiss() }
                } }
        }.preferredColorScheme(.dark)
    }
}

enum DriveReportFormat {
    static func duration(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct PhoneDriveSummaryHeader: View {
    let trip: Trip
    let report: PhoneDriveReport
    private var noMovement: Bool { report.confirmedMovement == false }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                Label(noMovement ? tr("Nem észleltünk elindulást", "No confirmed movement") : tr("Út összesítője", "Drive summary"),
                      systemImage: noMovement ? "parkingsign.circle" : "checkmark.circle.fill")
                    .foregroundStyle(noMovement ? Theme.text2 : Theme.ok).font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.2f", trip.distanceKm)).font(Theme.number(46))
                    Text("km").font(.title3).foregroundStyle(Theme.text2)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(DriveReportFormat.duration(trip.duration)).font(.title2.monospacedDigit())
                        Text(tr("teljes idő", "total time")).font(.caption).foregroundStyle(Theme.text2)
                    }
                }
                if noMovement {
                    Text(tr("A telefon nem jelzett megerősített mozgást. A GPS-ingadozást nem számoltuk megtett útnak.", "No movement was confirmed. GPS drift was not counted as distance."))
                        .font(.subheadline).foregroundStyle(Theme.text2)
                }
                HStack(alignment: .top) {
                    endpoint(tr("INDÍTÁS", "STARTED"), trip.start, "circle.fill")
                    Spacer()
                    endpoint(tr("LEÁLLÍTÁS", "STOPPED"), trip.end ?? trip.start, "flag.checkered")
                }
            }
        }
    }
    private func endpoint(_ title: String, _ date: Date, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption2.bold()).foregroundStyle(Theme.text2)
            Text(date.formatted(date: .omitted, time: .standard)).font(.subheadline.monospacedDigit())
        }
    }
}

struct PhoneDriveReportCard: View {
    let report: PhoneDriveReport
    let trip: Trip
    private var reason: String {
        switch report.endReason {
        case "permission": return tr("A helyhozzáférés megszűnt", "Location permission was removed")
        case "storage": return tr("Mentési hiba miatt megszakadt", "Interrupted by a saving error")
        case "account": return tr("Fiókváltás miatt lezárva", "Ended for an account change")
        case "stopped": return tr("Te állítottad le", "Stopped by you")
        default: return report.interrupted ? tr("A rögzítés megszakadt", "Recording was interrupted") : tr("Te állítottad le", "Stopped by you")
        }
    }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                Text(tr("Az út részletei", "Drive details")).font(.headline)
                if report.confirmedMovement != false {
                    HStack(spacing: 12) {
                        metric(Fmt.int(trip.avgSpeed), tr("Átlag · km/h", "Average · km/h"))
                        metric(Fmt.int(trip.maxSpeed), tr("Maximum · km/h", "Top · km/h"))
                    }
                    HStack(alignment: .top, spacing: 12) {
                        eventCount("acceleration", tr("Erős gyorsítás", "Hard acceleration"), "arrow.up.right", Theme.warn)
                        eventCount("braking", tr("Erős fékezés", "Hard braking"), "arrow.down.right", Theme.bad)
                    }
                }
                LabeledContent(tr("Mozgásban", "Moving"), value: DriveReportFormat.duration(report.movingSeconds))
                LabeledContent(tr("Álló helyzet / indulásra várva", "Stopped / awaiting movement"), value: DriveReportFormat.duration(report.stoppedSeconds))
                LabeledContent(tr("GPS-lefedettség", "GPS coverage"), value: "\(Int(min(100, max(0, report.measuredSeconds / max(1, trip.duration) * 100))))%")
                Divider()
                Label(reason, systemImage: report.interrupted ? "exclamationmark.circle" : "stop.circle")
                    .font(.subheadline).foregroundStyle(report.interrupted ? Theme.warn : Theme.text2)
                Text(tr("A sebesség és a vezetési események GPS-alapú becslések. A kimaradt szakaszokra nem számolunk hozzá távolságot.", "Speed and driving events are GPS estimates. Missing sections do not add estimated distance."))
                    .font(.caption).foregroundStyle(Theme.text2)
                if report.measurementVersion == nil {
                    Text(tr("Korábbi mérés: még a szigorúbb állóhelyzet-szűrés előtt készült.", "Older recording: captured before the improved stationary filter."))
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }
        }
    }
    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(Theme.number(30))
            Text(title).font(.caption).foregroundStyle(Theme.text2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func eventCount(_ kind: String, _ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text("\(report.events.filter { $0.kind == kind }.count)").font(Theme.number(24))
            }
            Text(title).font(.caption).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}
