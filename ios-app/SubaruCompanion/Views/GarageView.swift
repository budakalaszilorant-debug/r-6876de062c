import SwiftUI

struct GarageView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var cars: [CarProfile] = []
    @State private var editing: CarProfile?
    @State private var adding = false
    @State private var deleting: CarProfile?

    var body: some View {
        List {
            if monitor.needsCarSelection {
                Section {
                    Text(tr("Válaszd ki, melyik autóhoz csatlakoztál.", "Choose the connected car."))
                    if let vin = monitor.pendingVIN { Text(vin).font(.caption.monospaced()) }
                }
            }
            Section(tr("Autóim", "My cars")) {
                ForEach(cars) { car in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: car.fuel == .diesel ? "car.side.fill" : "car.fill")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(car.name).font(.headline)
                                Text(car.fuel.label + " · " + (car.odometerSet ? "\(Fmt.km(car.odometerKm)) km" : tr("Km nincs megadva", "Odometer not set")))
                                    .font(.subheadline).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            if car.id == settings.activeCarId {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                                    .accessibilityLabel(tr("Kiválasztva", "Selected"))
                            }
                        }
                        HStack {
                            Button(monitor.needsCarSelection ? tr("Ehhez csatlakoztam", "Use for this connection") : tr("Kiválasztás", "Select")) {
                                if monitor.needsCarSelection { monitor.confirmCar(car.id) }
                                else { monitor.switchCar(to: car.id, announce: false) }
                                reload()
                            }
                            .disabled(monitor.needsCarSelection
                                      ? (monitor.pendingVIN != nil && car.vin != nil && car.vin != monitor.pendingVIN)
                                      : (!monitor.canManageGarage || car.id == settings.activeCarId))
                            Spacer()
                            Button(tr("Szerkesztés", "Edit")) { editing = car }
                                .disabled(!monitor.canManageGarage)
                        }
                        .buttonStyle(.borderless)
                        if monitor.canManageGarage {
                            NavigationLink(tr("Szervizterv", "Service plan")) { ServicePlanEditor(car: car) }
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 6)
                    .swipeActions {
                        if cars.count > 1 && monitor.canManageGarage {
                            Button(tr("Törlés", "Delete"), role: .destructive) { deleting = car }
                        }
                    }
                }
            }
            if !monitor.canManageGarage && !monitor.needsCarSelection {
                Text(tr("Autóváltáshoz bontsd a kapcsolatot, vagy használd a demo módot.", "Disconnect or use demo mode to change cars."))
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            Section {
                Button { adding = true } label: { Label(tr("Autó hozzáadása", "Add car"), systemImage: "plus") }
                    .disabled(!monitor.canManageGarage && !monitor.needsCarSelection)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle(tr("Garázs", "Garage"))
        .onAppear(perform: reload)
        .onChange(of: monitor.dataVersion) { _ in reload() }
        .sheet(item: $editing) { car in CarEditor(car: car, onSave: reload) }
        .sheet(isPresented: $adding) { CarEditor(car: nil, onSave: reload) }
        .alert(tr("Autó törlése", "Delete car"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("Törlés", "Delete"), role: .destructive) {
                guard monitor.canManageGarage, let car = deleting, cars.count > 1 else { return }
                if car.id == settings.activeCarId, let other = cars.first(where: { $0.id != car.id }) {
                    monitor.switchCar(to: other.id, announce: false)
                }
                CarStore.delete(car.id)
                NotificationManager.shared.cancel(ids: [CarStore.key("parkTimer-warn", car: car.id),
                                                       CarStore.key("parkTimer-end", car: car.id)])
                Reminders.reschedule()
                deleting = nil
                reload()
            }
            Button(tr("Mégse", "Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(tr("Az autó összes útja, tankolása és szervizadata is törlődik. Előtte készíts mentést.", "All trips, fill-ups and service records for this car will be deleted. Make a backup first."))
        }
    }

    private func reload() { cars = CarStore.all() }
}

private struct CarEditor: View {
    let car: CarProfile?
    let onSave: () -> Void
    @EnvironmentObject var monitor: VehicleMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var template = CarTemplate.petrol.id
    @State private var name = ""
    @State private var vin = ""
    @State private var fuel = FuelType.petrol
    @State private var tank = 50.0
    @State private var warm = 88.0
    @State private var redline = 6000.0
    @State private var odometer = ""
    @State private var error: String?

    private var normalizedVIN: String { vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 &&
        (normalizedVIN.isEmpty || CarStore.validVIN(normalizedVIN)) &&
        tank.isFinite && (10...200).contains(tank) && warm.isFinite && (60...110).contains(warm) &&
        redline.isFinite && (2500...10000).contains(redline) &&
        (odometer.isEmpty || (Double(odometer).map { $0.isFinite && (0...2_000_000).contains($0) } ?? false))
    }

    var body: some View {
        NavigationStack {
            Form {
                if car == nil {
                    Picker(tr("Kiinduló profil", "Starting profile"), selection: $template) {
                        ForEach(CarTemplate.all.filter { $0.id != CarTemplate.subaru.id }) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: template) { _ in applyTemplate() }
                }
                Section(tr("Autó", "Car")) {
                    TextField(tr("Név", "Name"), text: $name)
                    Picker(tr("Üzemanyag", "Fuel"), selection: $fuel) {
                        ForEach(FuelType.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("VIN", text: $vin).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField(tr("Km óra állás (opcionális)", "Odometer (optional)"), text: $odometer).keyboardType(.numberPad)
                }
                Section {
                    valueRow(tr("Tank", "Tank"), $tank, "l")
                    valueRow(tr("Melegedési jelzés", "Warm-up alert"), $warm, "°C")
                    valueRow(tr("Fordulatszám-skála határa", "RPM threshold"), $redline, "rpm")
                } footer: {
                    Text(tr("A kiinduló értékeket ellenőrizd az autó kézikönyvében.", "Check the starting values against your vehicle handbook."))
                }
                if let error { Text(error).foregroundStyle(Theme.bad) }
            }
            .navigationTitle(car == nil ? tr("Új autó", "New car") : tr("Autó szerkesztése", "Edit car"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(tr("Mentés", "Save"), action: save).disabled(!valid) }
            }
            .onAppear {
                if let car {
                    template = car.template; name = car.name; vin = car.vin ?? ""; fuel = car.fuel
                    tank = car.tankL; warm = car.warmTemp; redline = car.redline
                    odometer = car.odometerSet ? String(Int(car.odometerKm)) : ""
                } else { applyTemplate() }
            }
        }
    }

    private func valueRow(_ label: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 85)
            Text(unit).foregroundStyle(Theme.text2)
        }
    }

    private func applyTemplate() {
        let t = CarTemplate.find(template)
        name = t.name; fuel = t.fuel; tank = t.tankL; warm = t.warmTemp; redline = t.redline
    }

    private func save() {
        guard valid, monitor.canManageGarage || (car == nil && monitor.needsCarSelection) else { return }
        if !normalizedVIN.isEmpty, let other = CarStore.find(vin: normalizedVIN), other.id != car?.id {
            error = tr("Ez a VIN már egy másik autóhoz tartozik.", "This VIN already belongs to another car.")
            return
        }
        let id = car?.id ?? CarStore.create(from: CarTemplate.find(template))
        CarStore.save(CarProfile(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 vin: normalizedVIN.isEmpty ? nil : normalizedVIN, fuel: fuel,
                                 tankL: tank, warmTemp: warm, redline: redline,
                                 odometerKm: Double(odometer) ?? 0, odometerSet: !odometer.isEmpty, template: template))
        if id == AppSettings.shared.activeCarId { AppSettings.shared.activate(id) }
        monitor.reloadAfterRestore()
        onSave()
        dismiss()
    }
}
