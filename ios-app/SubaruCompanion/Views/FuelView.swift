import SwiftUI
import Charts

struct FuelView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var fills: [FuelFill] = []
    @State private var showAdd = false
    @State private var prefillLiters: Double?

    var body: some View {
        let stats = FuelStore.stats(fills)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let liters = monitor.suggestedFill {
                    SuggestedFillCard(liters: liters) {
                        prefillLiters = liters
                        showAdd = true
                    } onDismiss: {
                        monitor.dismissSuggestedFill()
                    }
                }

                PrimaryButton(title: tr("Tankolás rögzítése", "Log a fill-up"), icon: "plus") {
                    prefillLiters = nil
                    showAdd = true
                }

                if fills.isEmpty {
                    Card {
                        EmptyState(icon: "fuelpump",
                                   title: tr("Még nincs tankolás", "No fill-ups yet"),
                                   message: tr("Két teli tank után az app kiszámolja a valós fogyasztást és a km-költséget.",
                                               "After two full tanks the app works out real consumption and cost per km."))
                    }
                } else {
                    HStack(spacing: 12) {
                        StatTile(label: tr("Fogyasztás", "Consumption"), value: Fmt.one(stats.avgL100), unit: "l/100")
                        StatTile(label: "km/l", value: Fmt.one(stats.kmPerLiter), unit: "km/l")
                    }
                    HStack(spacing: 12) {
                        StatTile(label: tr("Költség / km", "Cost / km"), value: Fmt.one(stats.costPerKm), unit: "Ft")
                        StatTile(label: tr("E hónap", "This month"), value: Fmt.km(stats.monthCost), unit: "Ft")
                    }

                    if stats.perFill.count > 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(text: tr("Fogyasztás töltésenként", "Consumption per fill"))
                            Card {
                                Chart {
                                    ForEach(Array(stats.perFill.enumerated()), id: \.offset) { _, f in
                                        LineMark(x: .value("d", f.date), y: .value("l", f.l100))
                                            .foregroundStyle(Theme.accent)
                                        PointMark(x: .value("d", f.date), y: .value("l", f.l100))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                .chartYAxis {
                                    AxisMarks(position: .leading) { _ in
                                        AxisGridLine().foregroundStyle(Theme.stroke)
                                        AxisValueLabel().foregroundStyle(Theme.text3)
                                    }
                                }
                                .frame(height: 160)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: tr("Napló", "Log"))
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(fills) { fill in
                                    FillRow(fill: fill) {
                                        FuelStore.delete(fill.id)
                                        reload()
                                    }
                                    if fill.id != fills.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 16) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showAdd) {
            AddFillSheet(prefillLiters: prefillLiters) {
                monitor.dismissSuggestedFill()
                reload()
            }
                .presentationDetents([.large])
        }
    }

    private func reload() { fills = FuelStore.all() }
}

struct FillRow: View {
    let fill: FuelFill
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Fmt.one(fill.liters)) l · \(Fmt.km(fill.cost)) Ft")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(Fmt.date(fill.date)) · \(Fmt.km(fill.odometer)) km · \(Fmt.int(fill.pricePerLiter)) Ft/l\(fill.full ? "" : tr(" · részleges", " · partial"))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            }
            Spacer()
        }
        .padding(16)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(tr("Törlés", "Delete"), systemImage: "trash")
            }
        }
    }
}

struct AddFillSheet: View {
    var prefillLiters: Double? = nil
    let onSave: () -> Void
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var liters = ""
    @State private var cost = ""
    @State private var odometer = ""
    @State private var full = true
    @State private var date = Date()

    private func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: ""))
    }

    private var valid: Bool {
        (number(liters) ?? 0) > 0 && (number(cost) ?? 0) > 0 && (number(odometer) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field(tr("Liter", "Litres"), text: $liters, unit: "l")
                    field(tr("Fizetett összeg", "Total paid"), text: $cost, unit: "Ft")
                    field(tr("Km óra állás", "Odometer"), text: $odometer, unit: "km")
                } footer: {
                    if let l = number(liters), let c = number(cost), l > 0 {
                        Text("\(Fmt.int(c / l)) Ft/l")
                    }
                }
                Section {
                    Toggle(tr("Teli tank", "Full tank"), isOn: $full)
                    DatePicker(tr("Időpont", "Date"), selection: $date, in: ...Date())
                }
            }
            .navigationTitle(tr("Tankolás", "Fill-up"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Mégse", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Mentés", "Save")) { save() }.disabled(!valid)
                }
            }
            .onAppear {
                if settings.odometerSet { odometer = String(Int(settings.odometerKm)) }
                if let l = prefillLiters {
                    liters = String(Int(l))
                    cost = String(Int(l * settings.lastFuelPrice))
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(Theme.number(17))
            Text(unit).foregroundStyle(Theme.text2)
        }
    }

    private func save() {
        guard let l = number(liters), let c = number(cost), let o = number(odometer) else { return }
        FuelStore.add(date: date, liters: l, cost: c, odometer: o, full: full)
        settings.lastFuelPrice = c / l
        // A most beírt óraállás pontosabb, mint a sebességből integrált érték: ehhez igazítunk.
        // Régi dátumú (utólag rögzített) töltés nem írja felül.
        if !settings.odometerSet || Date().timeIntervalSince(date) < 3600 {
            settings.odometerKm = o
            settings.odometerSet = true
        }
        VehicleMonitor.shared.refreshAverages()
        Haptics.success()
        onSave()
        dismiss()
    }
}
