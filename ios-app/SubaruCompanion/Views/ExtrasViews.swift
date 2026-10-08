import SwiftUI
import Charts

// MARK: - Parkolóóra

struct ParkingTimerCard: View {
    @ObservedObject private var timer = ParkingTimer.shared

    var body: some View {
        Card {
            if let end = timer.end, end > Date() {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: tr("Parkolóóra", "Parking timer"))
                        Text(end, style: .timer)
                            .font(Theme.number(34))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Button {
                        timer.cancel()
                        Haptics.tap()
                    } label: {
                        Text(tr("Leállítás", "Stop"))
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(Theme.surface2, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Parkolóóra", "Parking timer"))
                    HStack(spacing: 8) {
                        ForEach(ParkingTimer.presets, id: \.self) { minutes in
                            Button {
                                timer.start(minutes: minutes)
                                Haptics.success()
                            } label: {
                                Text(minutes % 60 == 0 ? tr("\(minutes / 60) óra", "\(minutes / 60) h")
                                                       : tr("\(minutes) p", "\(minutes) min"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
        }
        .animation(Theme.spring, value: timer.end)
    }
}

// MARK: - Havi összesítő

struct MonthlySummaryCard: View {
    @ObservedObject private var phoneDrive = PhoneDriveRecorder.shared
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var month = Date()
    @State private var summary = MonthlySummary(month: Date())
    @State private var previous = MonthlySummary(month: Date())
    @State private var daily: [(day: Int, km: Double)] = []

    private var isCurrentMonth: Bool {
        MonthlySummary.monthStart(month) >= MonthlySummary.monthStart(Date())
    }

    /// Fő költség: a tankolási napló, ha van; különben az utak becsült benzinköltsége.
    private var mainCost: Double { summary.cost > 0 ? summary.cost : summary.tripCost }
    private var previousCost: Double { previous.cost > 0 ? previous.cost : previous.tripCost }

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    stepButton("chevron.left", enabled: true) { shift(-1) }
                    Spacer()
                    Text(MonthlySummary.title(month).capitalized)
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    stepButton("chevron.right", enabled: !isCurrentMonth) { shift(1) }
                }

                if summary.isEmpty {
                    EmptyState(icon: "calendar", title: tr("Ebben a hónapban nincs adat", "No data this month"),
                               message: tr("Az utak és a tankolások maguktól ide kerülnek.",
                                           "Trips and fill-ups appear here automatically."))
                } else {
                    HStack(alignment: .top) {
                        hero(Fmt.km(summary.km), "km", MonthlySummary.change(summary.km, previous.km), higherIsBad: false)
                        Spacer()
                        hero(Fmt.km(mainCost), "Ft", MonthlySummary.change(mainCost, previousCost), higherIsBad: true)
                    }

                    KmBars(daily: daily)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        tile("\(summary.trips)", tr("út", "trips"))
                        tile(Fmt.one(summary.avgL100), "l/100")
                        tile(Fmt.duration(summary.driveSeconds), tr("vezetés", "driving"))
                    }

                    VStack(spacing: 10) {
                        if summary.cost > 0 {
                            row(tr("Tankolások", "Fill-ups"), "\(Fmt.km(summary.cost)) Ft · \(Fmt.one(summary.liters)) l")
                        }
                        if settings.featTripCost, summary.tripCost > 0 {
                            row(tr("Utak becsült költsége", "Estimated trip cost"), "\(Fmt.km(summary.tripCost)) Ft")
                        }
                        if summary.km > 1, mainCost > 0 {
                            row(tr("Költség km-enként", "Cost per km"), "\(Fmt.one(mainCost / summary.km)) Ft")
                        }
                        if summary.workKm > 0 {
                            row(tr("Munka utak", "Work trips"), "\(Fmt.km(summary.workKm)) km")
                        }
                        if settings.featIdle, summary.idleSeconds > 60 {
                            row(tr("Alapjárat", "Idling"),
                                "\(Fmt.duration(summary.idleSeconds)) · \(Fmt.km(summary.idleCost)) Ft")
                        }
                    }

                    if summary.trips > 0 {
                        ShareLink(item: MonthlySummary.csv(for: month),
                                  preview: SharePreview(tr("Útnyilvántartás", "Trip log") + " — " + MonthlySummary.title(month))) {
                            Label(tr("Útnyilvántartás megosztása", "Share trip log"), systemImage: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: monitor.dataVersion) { _ in reload() }
        .onChange(of: phoneDrive.revision) { _ in reload() }
    }

    private func shift(_ by: Int) {
        month = Calendar.current.date(byAdding: .month, value: by, to: month) ?? month
        Haptics.tap()
        reload()
    }

    private func reload() {
        summary = MonthlySummary.compute(for: month)
        let prev = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month
        previous = MonthlySummary.compute(for: prev)
        daily = MonthlySummary.dailyKm(for: month)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 44, height: 36)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    /// Nagy szám, alatta a változás az előző hónaphoz képest.
    @ViewBuilder
    private func hero(_ value: String, _ unit: String, _ change: Double?, higherIsBad: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.number(34, .bold)).tracking(-0.6).contentTransition(.numericText())
                Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text2)
            }
            if let c = change, abs(c) >= 1 {
                Label(tr("\(Int(abs(c).rounded())) % az előző hónaphoz", "\(Int(abs(c).rounded()))% vs last month"),
                      systemImage: c > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle((c > 0) == higherIsBad ? Theme.warn : Theme.ok)
            } else {
                Text(tr("előző hónap: —", "last month: —"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private func tile(_ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(Theme.number(20)).lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.text2)
            Spacer()
            Text(value).font(Theme.number(15))
        }
    }
}

/// Napi km oszlopok; a mai nap kiemelve.
private struct KmBars: View {
    let daily: [(day: Int, km: Double)]

    var body: some View {
        let today = Calendar.current.component(.day, from: Date())
        Chart {
            ForEach(daily, id: \.day) { d in
                BarMark(x: .value("nap", d.day), y: .value("km", d.km), width: .ratio(0.6))
                    .foregroundStyle(d.day == today ? Theme.accent : Theme.accent.opacity(0.45))
                    .cornerRadius(2)
            }
        }
        .chartXAxis {
            AxisMarks(values: [1, 10, 20, max(21, daily.count)]) { _ in
                AxisValueLabel().foregroundStyle(Theme.text3)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.stroke)
                AxisValueLabel().foregroundStyle(Theme.text3)
            }
        }
        .frame(height: 110)
    }
}

// MARK: - Akku egészség

struct BatteryHealthCard: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var samples: [BatterySample] = []

    private var last: BatterySample? { samples.last }
    private var grade: BatteryHealth.Grade { BatteryHealth.grade(rest: last?.restV, crank: last?.crankV) }

    private var gradeText: String {
        switch grade {
        case .unknown: return tr("Még nincs mérés", "No measurement yet")
        case .good: return tr("Jó állapotban", "Good")
        case .fair: return tr("Közepes", "Fair")
        case .weak: return tr("Gyenge — érdemes bevizsgáltatni", "Weak — get it tested")
        }
    }

    private var gradeColor: Color {
        switch grade {
        case .unknown: return Theme.text3
        case .good: return Theme.ok
        case .fair: return Theme.warn
        case .weak: return Theme.bad
        }
    }

    /// Trend a nyugalmi feszültségekből: mikor gyengülhet el az akku.
    private var forecastText: (String, Color)? {
        switch BatteryForecast.forecast(samples) {
        case .notEnoughData: return nil
        case .stable: return (tr("Stabil, nem gyengül", "Stable, not weakening"), Theme.ok)
        case .weakening(let days):
            if days <= 30 { return (tr("Hamarosan cserére szorulhat", "May need replacing soon"), Theme.bad) }
            let months = max(1, days / 30)
            return (tr("Gyengül: kb. \(months) hónap múlva lehet gond", "Weakening: trouble likely in about \(months) months"), Theme.warn)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle().fill(gradeColor).frame(width: 10, height: 10)
                    Text(gradeText).font(.system(size: 17, weight: .semibold))
                }
                if let forecast = forecastText {
                    Label(forecast.0, systemImage: "chart.line.downtrend.xyaxis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(forecast.1)
                }

                HStack(alignment: .top) {
                    stat(tr("Nyugalmi", "Resting"), last?.restV)
                    Spacer()
                    stat(tr("Indításkor", "Cranking"), last?.crankV)
                    Spacer()
                    stat(tr("Töltés", "Charging"), last?.chargeV)
                }

                let rest = samples.filter { $0.restV != nil }
                if rest.count > 1 {
                    Chart(rest) { s in
                        LineMark(x: .value("t", s.date), y: .value("V", s.restV ?? 0))
                            .foregroundStyle(Theme.accent)
                        PointMark(x: .value("t", s.date), y: .value("V", s.restV ?? 0))
                            .foregroundStyle(Theme.accent)
                            .symbolSize(18)
                    }
                    .chartYScale(domain: 11.5...13.2)
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine().foregroundStyle(Theme.stroke)
                            AxisValueLabel().foregroundStyle(Theme.text3)
                        }
                    }
                    .frame(height: 130)
                }
            }
        }
        .onAppear { samples = BatteryHealth.recent() }
        .onChange(of: monitor.dataVersion) { _ in samples = BatteryHealth.recent() }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.text3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Fmt.one(value)).font(Theme.number(24))
                Text("V").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
            }
        }
    }
}

// MARK: - Funkció kapcsolók (Beállítások)

struct FeatureToggles: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section(tr("Funkciók", "Features")) {
            toggle(tr("Eltérésfigyelő a saját utakhoz képest", "Deviation monitoring against your trips"), "chart.xyaxis.line", $settings.featBaseline)
            toggle(tr("Parkolóóra", "Parking timer"), "parkingsign.circle", $settings.featParkingTimer)
            toggle(tr("Járva maradt motor jelzés", "Engine left running alert"), "exclamationmark.triangle", $settings.featLeftRunning)
            toggle(tr("Havi összesítő", "Monthly summary"), "chart.bar", $settings.featMonthly)
            toggle(tr("Hatótáv becslés", "Range estimate"), "fuelpump", $settings.featRange)
            toggle(tr("Akku egészség", "Battery health"), "bolt.heart", $settings.featBatteryHealth)
            toggle(tr("Alapjárati idő számláló", "Idle time counter"), "hourglass", $settings.featIdle)
            toggle(tr("Út költsége forintban", "Trip cost"), "banknote", $settings.featTripCost)
            toggle(tr("Induláskor kérdezze az autót", "Ask for the car on launch"), "car.2", $settings.askCarOnLaunch)
            toggle(tr("Tankolás észlelése", "Fill-up detection"), "fuelpump.fill", $settings.featAutoFill)
            toggle(tr("Élő tevékenység a zárolási képernyőn", "Lock screen live activity"), "lock.iphone", $settings.featLiveActivity)
            toggle(tr("Korai túlmelegedés jelzés", "Early overheat warning"), "thermometer.high", $settings.featOverheatEarly)
            toggle(tr("Generátor figyelő", "Alternator monitor"), "bolt.badge.clock", $settings.featAlternator)
            toggle(tr("Okos olajcsere (valós használat)", "Smart oil change (real usage)"), "drop.triangle", $settings.featSmartOil)
            toggle(tr("Fagyriasztás gyengülő akkunál", "Frost alert for a weak battery"), "snowflake", $settings.featFrost)
        }
    }

    private func toggle(_ title: String, _ icon: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Label(title, systemImage: icon)
        }
        .tint(Theme.ok)
    }
}
