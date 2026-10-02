import SwiftUI

struct ServicePlanEditor: View {
    let car: CarProfile
    @State private var items: [ServiceItem] = []
    @State private var editing: ServiceItem?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    Button { editing = item } label: {
                        HStack {
                            Text(item.name).foregroundStyle(Theme.text)
                            Spacer()
                            Text(item.intervalKm > 0 ? "\(Fmt.km(item.intervalKm)) km" : tr("Beállítás", "Set interval"))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .swipeActions {
                        Button(tr("Törlés", "Delete"), role: .destructive) {
                            Database.shared.execute("DELETE FROM service_plan WHERE car_id = ? AND item = ?", [car.id, item.id])
                            reload()
                        }
                    }
                }
            } header: { Text(car.name) } footer: {
                Text(tr("A km-intervallumokat a szervizkönyv alapján add meg. Az időalapú határidőket a Lejáratoknál rögzítheted.",
                        "Enter mileage intervals from the service handbook. Use expiry reminders for date-based deadlines."))
            }
            Button(tr("Tétel hozzáadása", "Add item")) { adding = true }
        }
        .navigationTitle(tr("Szervizterv", "Service plan"))
        .onAppear(perform: reload)
        .sheet(item: $editing) { item in ServicePlanSheet(carID: car.id, item: item, onSave: reload) }
        .sheet(isPresented: $adding) { ServicePlanSheet(carID: car.id, item: nil, onSave: reload) }
    }
    private func reload() { items = ServiceStore.plan(car: car.id) }
}

private struct ServicePlanSheet: View {
    let carID: Int
    let item: ServiceItem?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var km = ""
    @State private var critical = false

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (Double(km).map { $0.isFinite && (1...500_000).contains($0) } ?? false)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("Megnevezés", "Name"), text: $name)
                HStack {
                    Text(tr("Csereperiódus", "Interval"))
                    TextField("km", text: $km).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    Text("km")
                }
                Toggle(tr("Kiemelt figyelmeztetés", "Priority reminder"), isOn: $critical)
            }
            .navigationTitle(tr("Szerviztétel", "Service item"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Mentés", "Save")) {
                        guard valid, let interval = Double(km) else { return }
                        let id = item?.id ?? UUID().uuidString
                        let hu = name == item?.name ? item!.hu : name
                        let en = name == item?.name ? item!.en : name
                        Database.shared.execute("""
                            INSERT INTO service_plan(car_id,item,hu,en,interval_km,critical,sort) VALUES(?,?,?,?,?,?,100)
                            ON CONFLICT(car_id,item) DO UPDATE SET hu=excluded.hu, en=excluded.en,
                            interval_km=excluded.interval_km, critical=excluded.critical
                            """, [carID,id,hu,en,interval,critical ? 1 : 0])
                        onSave()
                        dismiss()
                    }.disabled(!valid)
                }
            }
            .onAppear {
                name = item?.name ?? ""
                km = item.map { $0.intervalKm > 0 ? String(Int($0.intervalKm)) : "" } ?? ""
                critical = item?.critical ?? false
            }
        }
    }
}
