import SwiftUI
import Charts

struct CarView: View {
    @State private var mode = UserDefaults.standard.integer(forKey: "uiMode")

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text(tr("Melegedés", "Warm-up")).tag(0)
                Text(tr("Akku", "Battery")).tag(1)
                Text(tr("Szerviz", "Service")).tag(2)
                Text(tr("Hibák", "Faults")).tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            switch mode {
            case 0: WarmUpView()
            case 1: BatteryView()
            case 2: ServiceView()
            default: DiagnosticsView()
            }
        }
        .screenBackground()
    }
}

// MARK: - Bemelegedés

struct WarmUpView: View {
    @EnvironmentObject var monitor: VehicleMonitor

    var body: some View {
        let p = monitor.isLive ? monitor.packet : nil
        let temp = p?.coolantTemp
        let warm = (temp ?? 0) >= CarSpec.warmTemp
        let running = p?.engineRunning ?? false

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(spacing: 14) {
                        ZStack {
                            ArcGauge(value: temp, range: 0...CarSpec.fullWarmTemp,
                                     tint: warm ? Theme.ok : Theme.accent, lineWidth: 16)
                            VStack(spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    Text(Fmt.int(temp))
                                        .font(Theme.number(64, .bold))
                                        .tracking(-1.5)
                                        .contentTransition(.numericText())
                                    Text("°C").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.text2)
                                }
                                Text("/ \(Int(CarSpec.fullWarmTemp))°C")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.text3)
                            }
                        }
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity)

                        Text(statusText(temp: temp, warm: warm, running: running))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(warm ? Theme.ok : Theme.text)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }

                HStack(spacing: 12) {
                    StatTile(label: tr("Indulási hőfok", "Start temp"), value: Fmt.int(monitor.warmUp.startTemp), unit: "°C")
                    StatTile(label: tr("Indítás", "Start type"),
                             value: monitor.warmUp.startTemp == nil ? "—"
                                 : (monitor.warmUp.coldStart ? tr("Hideg", "Cold") : tr("Meleg", "Warm")),
                             unit: "")
                }
            }
            .padding(16)
        }
    }

    private func statusText(temp: Double?, warm: Bool, running: Bool) -> String {
        guard temp != nil else { return tr("Nincs adat", "No data") }
        if warm { return tr("Motor felmelegedett ✓", "Engine warmed up ✓") }
        guard running else { return tr("Motor áll", "Engine off") }
        if let eta = monitor.warmUp.etaMinutes {
            let m = max(1, Int(eta.rounded()))
            return tr("Kb. \(m) perc az üzemi hőfokig", "About \(m) min to operating temp")
        }
        return tr("Melegszik…", "Warming up…")
    }
}

// MARK: - Akkumulátor

struct BatteryView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @EnvironmentObject var settings: AppSettings
    @State private var log: [(t: Date, v: Double)] = []

    var body: some View {
        let p = monitor.isLive ? monitor.packet : nil
        let v = p?.batteryVoltage
        let level = VehicleMonitor.level(for: v, running: p?.engineRunning ?? false)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(spacing: 14) {
                        ZStack {
                            ArcGauge(value: v, range: 10...16, tint: level.color, lineWidth: 16)
                            VStack(spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(Fmt.one(v))
                                        .font(Theme.number(64, .bold))
                                        .tracking(-1.5)
                                        .foregroundStyle(level.color)
                                        .contentTransition(.numericText())
                                    Text("V").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.text2)
                                }
                            }
                        }
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity)

                        Text(label(level, running: p?.engineRunning ?? false))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(level.color)
                            .frame(maxWidth: .infinity)
                    }
                }

                if settings.featBatteryHealth {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: tr("Akku egészség", "Battery health"))
                        BatteryHealthCard()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("30 napos trend", "30-day trend"))
                    Card {
                        if log.count < 2 {
                            EmptyState(icon: "chart.xyaxis.line", title: tr("Gyűlik az adat", "Collecting data"),
                                       message: tr("A feszültség minden indításkor és leállításkor naplózódik.",
                                                   "Voltage is logged at every engine start and stop."))
                        } else {
                            Chart {
                                RectangleMark(yStart: .value("a", 13.8), yEnd: .value("b", 14.7))
                                    .foregroundStyle(Theme.ok.opacity(0.08))
                                ForEach(Array(log.enumerated()), id: \.offset) { _, s in
                                    LineMark(x: .value("t", s.t), y: .value("V", s.v))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .chartYScale(domain: 11...15.5)
                            .chartYAxis {
                                AxisMarks(position: .leading) { _ in
                                    AxisGridLine().foregroundStyle(Theme.stroke)
                                    AxisValueLabel().foregroundStyle(Theme.text3)
                                }
                            }
                            .frame(height: 180)
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear { log = monitor.voltageLog(days: 30) }
        .onChange(of: monitor.dataVersion) { _ in log = monitor.voltageLog(days: 30) }
    }

    private func label(_ level: VoltageLevel, running: Bool) -> String {
        switch level {
        case .unknown: return tr("Nincs adat", "No data")
        case .ok: return running ? tr("Töltés normális", "Charging normally") : tr("Akkumulátor rendben", "Battery healthy")
        case .caution: return tr("Figyelem", "Caution")
        case .low: return tr("Feszültség alacsony", "Voltage low")
        case .high: return tr("Túltöltés — alternátor?", "Overcharging — alternator?")
        }
    }
}

// MARK: - Szerviz

struct ServiceDoneSheet: View {
    let item: ServiceItem
    let onSave: () -> Void
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var km = ""
    @State private var date = Date()
    @State private var interval = ""
    @State private var cost = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(tr("Km óra állás a cserekor", "Odometer at service"))
                        Spacer()
                        TextField("0", text: $km)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(Theme.number(17))
                        Text("km").foregroundStyle(Theme.text2)
                    }
                    DatePicker(tr("Dátum", "Date"), selection: $date, in: ...Date(), displayedComponents: .date)
                }
                Section(tr("Költség (nem kötelező)", "Cost (optional)")) {
                    HStack {
                        Text(tr("Fizetett összeg", "Amount paid"))
                        Spacer()
                        TextField("0", text: $cost)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(Theme.number(17))
                        Text("Ft").foregroundStyle(Theme.text2)
                    }
                }
                Section(tr("Csereperiódus", "Interval")) {
                    HStack {
                        Text(tr("Ennyi km-enként", "Every"))
                        Spacer()
                        TextField("0", text: $interval)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(Theme.number(17))
                        Text("km").foregroundStyle(Theme.text2)
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Mentés", "Save")) {
                        guard let v = Double(km) else { return }
                        if let i = Double(interval), i >= 1000, i != item.intervalKm {
                            ServiceStore.setInterval(item.id, km: i)
                        }
                        ServiceStore.markDone(item.id, km: v, date: date)
                        if let c = Double(cost.replacingOccurrences(of: " ", with: "")), c > 0 {
                            ExpenseStore.add(date: date, category: .service, amount: c, note: item.name)
                        }
                        Haptics.success()
                        onSave()
                        dismiss()
                    }
                    .disabled(Double(km) == nil)
                }
            }
            .onAppear {
                if settings.odometerSet { km = String(Int(settings.odometerKm)) }
                interval = String(Int(item.intervalKm))
            }
        }
    }
}
