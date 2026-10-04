import SwiftUI
import PhotosUI
import UIKit

struct BaselineBanner: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var samples: [DrivingSample] = []
    @State private var show = false
    var body: some View {
        Group {
            if settings.featBaseline, !monitor.demoActive,
               DrivingBaseline.compare(samples, warmup: false)?.elevated == true || DrivingBaseline.compare(samples, warmup: true)?.elevated == true {
                Button { show = true } label: {
                    Card {
                        Label(tr("A legutóbbi út eltér a megszokottól", "Your last trip differs from usual"), systemImage: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(Theme.warn)
                        Text(tr("Nézd meg az összehasonlítást", "View comparison")).font(.caption).foregroundStyle(Theme.text2)
                    }
                }.buttonStyle(.plain)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: monitor.dataVersion) { _ in reload() }
        .onChange(of: settings.activeCarId) { _ in reload() }
        .sheet(isPresented: $show) { BaselineView() }
    }
    private func reload() { samples = GaragePlus.load([DrivingSample].self, key: "baseline") ?? [] }
}

struct GaragePhoto: View {
    let encoded: String?
    var body: some View {
        Group {
            if let encoded, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "car.side.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct CarHomeHeader: View {
    @EnvironmentObject var settings: AppSettings
    @State private var edit = false
    var body: some View {
        Button { edit = true } label: {
            ZStack(alignment: .bottomLeading) {
                GaragePhoto(encoded: settings.carPhoto).frame(height: 150).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("SAJÁT GARÁZS", "MY GARAGE")).font(.caption2.weight(.semibold)).tracking(2)
                        Text(settings.carName).font(.title2.weight(.bold)).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "slider.horizontal.3").padding(10).background(.ultraThinMaterial, in: Circle())
                }.padding(16).foregroundStyle(.white)
            }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.carName + ", " + tr("Megjelenés szerkesztése", "Edit appearance"))
        .sheet(isPresented: $edit) { CarAppearanceView().id(settings.activeCarId) }
    }
}

/// Strip photo metadata, resize and cap each stored image to keep local/cloud snapshots small.
private struct PhotoInput: View {
    @Binding var encoded: String?
    @State private var selection: PhotosPickerItem?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading) {
            if encoded != nil { GaragePhoto(encoded: encoded).frame(height: 150).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }
            PhotosPicker(selection: $selection, matching: .images) {
                Label(tr("Fotó kiválasztása", "Choose photo"), systemImage: "photo")
            }.disabled(loading)
            if loading { ProgressView() }
            if encoded != nil { Button(tr("Fotó eltávolítása", "Remove photo"), role: .destructive) { encoded = nil } }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.bad) }
        }
        .task(id: selection) {
            guard let selection else { return }
            loading = true
            defer { loading = false }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self), data.count <= 30_000_000,
                      let original = UIImage(data: data), original.size.width > 0, original.size.height > 0 else { throw PhotoError.invalid }
                let ratio = min(1, 1000 / max(original.size.width, original.size.height))
                let size = CGSize(width: original.size.width * ratio, height: original.size.height * ratio)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
                var jpeg = image.jpegData(compressionQuality: 0.7)
                if (jpeg?.count ?? 0) > 220_000 { jpeg = image.jpegData(compressionQuality: 0.4) }
                guard let jpeg, jpeg.count <= 300_000, !Task.isCancelled else { throw PhotoError.invalid }
                encoded = jpeg.base64EncodedString(); error = nil
            } catch { if !Task.isCancelled { self.error = tr("A fotó nem tölthető be. Válassz kisebb képet.", "Could not load photo. Choose a smaller image.") } }
        }
    }
    private enum PhotoError: Error { case invalid }
}

struct CarAppearanceView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(settings.carName) { PhotoInput(encoded: $settings.carPhoto) }
                Section(tr("Kiemelőszín", "Accent color")) {
                    ForEach(CarStyle.colors, id: \.self) { color in
                        Button { settings.carAccent = color } label: {
                            HStack {
                                Circle().fill(Theme.accentColor(color)).frame(width: 22, height: 22)
                                Text(colorName(color)).foregroundStyle(Theme.text)
                                Spacer()
                                if settings.carAccent == color { Image(systemName: "checkmark") }
                            }.frame(minHeight: 30)
                        }
                    }
                }
                Section(tr("Műszerfal sorrendje", "Dashboard order")) {
                    ForEach(settings.dashOrder) { section in
                        Toggle(section.title, isOn: Binding(get: { !settings.dashHidden.contains(section) }, set: { enabled in
                            if enabled { settings.dashHidden.remove(section) } else { settings.dashHidden.insert(section) }
                        }))
                    }.onMove { source, destination in settings.dashOrder.move(fromOffsets: source, toOffset: destination) }
                }
                if let error = settings.styleError { Text(error).foregroundStyle(Theme.bad) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(tr("Saját kezdőképernyő", "Your home screen"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } } }
        }.tint(Theme.accent)
    }
    private func colorName(_ name: String) -> String {
        switch name {
        case "mint": return tr("Menta", "Mint")
        case "purple": return tr("Lila", "Purple")
        case "orange": return tr("Narancs", "Orange")
        default: return tr("Kék", "Blue")
        }
    }
}

struct BaselineView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var samples: [DrivingSample] = []
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(tr("Eltérésfigyelő", "Deviation monitoring"), isOn: $settings.featBaseline)
                    Text(tr("A saját autód hasonló útjaihoz viszonyít. Nem hibadiagnózis: az időjárás, forgalom és terhelés is számít.", "Compares similar trips in your own car. This is not a diagnosis: weather, traffic and load also matter."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if settings.featBaseline {
                    metric(warmup: false)
                    metric(warmup: true)
                    Section(tr("Mérések", "Measurements")) {
                        Text(tr("\(samples.count) rögzített út", "\(samples.count) recorded trips"))
                        Text(tr("Legalább 5 korábbi, hasonló út szükséges. Eltérő üzemanyag-mérési módot és hiányos adatot nem hasonlítunk össze.", "Needs at least 5 earlier comparable trips. Different fuel measurement sources and incomplete data are excluded."))
                            .font(.footnote).foregroundStyle(.secondary)
                        if let latest = samples.sorted(by: { $0.date > $1.date }).first {
                            Text(latest.date, style: .date)
                            Text(tr("Legutóbbi út adatteljesége: \(Int(latest.coverage * 100))%", "Latest trip data coverage: \(Int(latest.coverage * 100))%"))
                        }
                    }
                }
            }.navigationTitle(tr("Saját autóhoz mérve", "Your car's baseline"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } } }
                .onAppear { samples = GaragePlus.load([DrivingSample].self, key: "baseline") ?? [] }
        }
    }
    @ViewBuilder private func metric(warmup: Bool) -> some View {
        Section(warmup ? tr("Bemelegedési idő", "Warm-up time") : tr("Fogyasztás", "Consumption")) {
            if let finding = DrivingBaseline.compare(samples, warmup: warmup) {
                let divisor = warmup ? 60.0 : 1.0
                let unit = warmup ? tr("perc", "min") : "l/100 km"
                LabeledContent(tr("Legutóbb", "Latest"), value: String(format: "%.1f %@", finding.latest / divisor, unit))
                LabeledContent(tr("Megszokott", "Usual"), value: String(format: "%.1f %@", finding.usual / divisor, unit))
                Label(String(format: "%+.0f%%", finding.percent), systemImage: finding.elevated ? "arrow.up.right" : "equal.circle")
                    .foregroundStyle(finding.elevated ? Theme.warn : Theme.ok)
                Text(tr("\(finding.count) hasonló út mediánjához képest.", "Compared with the median of \(finding.count) similar trips.")).font(.footnote)
            } else {
                Label(tr("Még tanulja az autót", "Learning your car"), systemImage: "chart.xyaxis.line")
                Text(tr("Még nincs elegendő összehasonlítható mérés.", "Not enough comparable measurements yet.")).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct HandoverView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Handover] = []
    @State private var car = CarStore.activeId
    @State private var person = ""
    @State private var km = ""
    @State private var fuel = ""
    @State private var note = ""
    @State private var photo: String?
    @State private var error: String?
    private var open: Handover? { rows.first { $0.end == nil } }
    private func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
    private var valid: Bool {
        guard let value = number(km), value.isFinite, value >= (open?.startKm ?? 0), value <= 3_000_000,
              !monitor.demoActive, car == settings.activeCarId else { return false }
        if !fuel.isEmpty { guard let f = number(fuel), f.isFinite, (0...100).contains(f) else { return false } }
        return open != nil || !person.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(open == nil ? tr("Átadás", "Hand over") : tr("Visszavétel", "Return")) {
                    if let open { Label(open.person, systemImage: "person.crop.circle"); Text(open.start, style: .date) }
                    else { TextField(tr("Kinek adod át?", "Who is borrowing it?"), text: $person) }
                    TextField(tr("Kilométeróra (km)", "Odometer (km)"), text: $km).keyboardType(.decimalPad)
                    TextField(tr("Tankszint (%) – választható", "Fuel (%) – optional"), text: $fuel).keyboardType(.decimalPad)
                    Text(tr("Ellenőrizd a kilométerórán: az app értéke lehet becsült. Hiányzó tankszintet hagyj üresen.", "Check the odometer: the app value may be estimated. Leave unknown fuel level blank."))
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField(tr("Állapot, sérülés, megjegyzés", "Condition, damage, notes"), text: $note, axis: .vertical)
                    PhotoInput(encoded: $photo)
                    Button(open == nil ? tr("Átadás rögzítése", "Record handover") : tr("Visszavétel rögzítése", "Record return")) { save() }.disabled(!valid)
                    if let error { Text(error).foregroundStyle(Theme.bad) }
                }
                ForEach(rows) { row in
                    Section(row.person) {
                        Text(row.start, style: .date)
                        LabeledContent(tr("Átadás", "Start"), value: String(format: "%.0f km", row.startKm))
                        if let distance = row.distance { LabeledContent(tr("Megtett táv", "Distance"), value: String(format: "%.0f km", distance)) }
                        if let before = row.startFuel, let after = row.endFuel {
                            LabeledContent(tr("Tankszint változása", "Fuel level change"), value: String(format: "%+.0f%%", after-before))
                        }
                        LabeledContent(tr("Naplózott kiadások", "Logged expenses"), value: String(format: "%.0f Ft", row.recordedCosts(car: car)))
                        Text(tr("Az időszak tankolásai és egyéb kiadásai; nem automatikus tartozás.", "Fuel purchases and other logged expenses during this period; not an automatic debt.")).font(.caption).foregroundStyle(.secondary)
                        if !row.note.isEmpty { Text(row.note) }
                        if let photo = row.startPhoto { GaragePhoto(encoded: photo).frame(height: 150).clipped() }
                        if let end = row.end { Text(end, style: .date); Text(row.returnNote) }
                        if let photo = row.endPhoto { GaragePhoto(encoded: photo).frame(height: 150).clipped() }
                    }
                }
            }.navigationTitle(tr("Autóátadás", "Car handover"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } } }
                .onAppear { rows = GaragePlus.load([Handover].self, key: "handovers", car: car) ?? []; resetForm() }
                .onChange(of: settings.activeCarId) { _ in dismiss() }
        }
    }
    private func resetForm() {
        km = settings.odometerSet ? String(format: "%.0f", settings.odometerKm) : ""
        fuel = monitor.isLive && !monitor.demoActive ? monitor.packet?.fuelLevel.map { String(format: "%.0f", $0) } ?? "" : ""
        person = ""; note = ""; photo = nil
    }
    private func save() {
        guard valid, let odometer = number(km) else { return }
        var updated = rows
        if let i = updated.firstIndex(where: { $0.end == nil }) {
            updated[i].end = Date(); updated[i].endKm = odometer; updated[i].endFuel = number(fuel)
            updated[i].returnNote = note; updated[i].endPhoto = photo
        } else {
            updated.insert(Handover(person: person, startKm: odometer, startFuel: number(fuel), note: note, startPhoto: photo), at: 0)
        }
        do { try GaragePlus.save(updated, key: "handovers", car: car); rows = updated; error = nil; resetForm(); Haptics.success() }
        catch { self.error = tr("A mentés nem sikerült. Az űrlap megmaradt.", "Save failed. Your form has been kept.") }
    }
}

struct RepairClearView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @ObservedObject private var ble = BLEManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reports: [RepairReport] = []
    @State private var confirm = false
    @State private var result: String?
    private var available: Bool {
        !monitor.demoActive && monitor.isLive && monitor.packet?.rpm == 0 &&
            monitor.packet?.vehicleSpeed == 0 && CarStore.validVIN(AppSettings.shared.vin ?? "") && !ble.clearingFaults
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Javítás után", "After a repair")) {
                    Text(tr("Először mentsük az ECU válaszait, utána töröljük a tárolt emissziós hibakódokat, majd újraolvassuk az autót.", "First save the ECU responses, then clear stored emissions fault codes and read diagnostics again."))
                    Text(tr("A törlés a freeze frame adatokat és a készenléti teszteket is nullázhatja. Az appban tárolt másolat nem állítja ezeket vissza az ECU-ba. Az állandó kódokat az autó saját ellenőrzése törli.", "Clearing can reset freeze frames and readiness monitors. The app's copy cannot restore them to the ECU. Permanent codes are cleared by the car's own checks."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Label(tr("Álló autó · motor leállítva · gyújtás bekapcsolva", "Stationary · engine off · ignition on"), systemImage: "parkingsign.circle")
                    Button(tr("Mentés és hibakódtörlés…", "Back up and clear faults…"), role: .destructive) { confirm = true }.disabled(!available)
                    if ble.clearingFaults { ProgressView(tr("Mentés, ellenőrzés, törlés…", "Saving, checking, clearing…")) }
                    if let result { Text(result).font(.callout) }
                }
                ForEach(reports) { report in
                    Section {
                        Text(report.date, style: .date)
                        Text(status(report.status)).font(.headline)
                        if !report.originalCodes.isEmpty { Text(report.originalCodes.joined(separator: " · ")).monospaced() }
                        if !report.returnedCodes.isEmpty {
                            Label(tr("Visszatért: ", "Returned: ") + report.returnedCodes.joined(separator: ", "), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                        }
                        if !report.detail.isEmpty { Text(report.detail).font(.footnote) }
                        DisclosureGroup(tr("Mentett ECU-válaszok", "Saved ECU responses")) {
                            Text(reportText(report)).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        ShareLink(item: reportText(report)) { Label(tr("Jelentés megosztása", "Share report"), systemImage: "square.and.arrow.up") }
                    }
                }
            }.navigationTitle(tr("Javítás követése", "Repair follow-up"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } } }
                .interactiveDismissDisabled(ble.clearingFaults)
                .onAppear { reports = RepairStore.all() }
                .confirmationDialog(tr("Biztosan törlöd a tárolt hibakódokat?", "Clear stored fault codes?"), isPresented: $confirm, titleVisibility: .visible) {
                    Button(tr("Mentés, majd törlés", "Back up, then clear"), role: .destructive) {
                        ble.clearFaults { message in result = message; reports = RepairStore.all() }
                    }
                } message: {
                    Text(tr("Csak javítás után. A művelet nem vonható vissza, és nem javítja meg a hibát.", "Only after repair. This cannot be undone and does not fix the fault."))
                }
        }
    }
    private func status(_ value: String) -> String {
        switch value {
        case "verified": return tr("Tárolt kódok törlése visszaolvasva", "Stored-code clearing verified")
        case "remaining": return tr("A visszaolvasásban maradt hibakód", "Fault codes remain on read-back")
        case "refused": return tr("Törlés nem történt", "No clear command sent")
        case "acknowledged": return tr("Nyugtázva, ellenőrzés szükséges", "Acknowledged; check required")
        default: return tr("Nem igazolt eredmény – ellenőrizd az autót", "Unconfirmed result – check diagnostics")
        }
    }
    private func reportText(_ report: RepairReport) -> String {
        var text = "Garázs · \(report.date)\nVIN: \(report.vin)\n\(status(report.status))\n\(report.detail)\n"
        for (title, values) in [(tr("Előtte", "Before"), report.before), (tr("Utána", "After"), report.after)] {
            text += "\n\(title)\n"
            for key in values.keys.sorted() { text += "\(key): \(values[key] ?? "")\n" }
        }
        return text
    }
}
