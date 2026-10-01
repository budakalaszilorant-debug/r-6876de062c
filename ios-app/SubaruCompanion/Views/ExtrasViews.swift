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
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var month = Date()
    @State private var summary = MonthlySummary(month: Date())

    private var isCurrentMonth: Bool {
        MonthlySummary.monthStart(month) >= MonthlySummary.monthStart(Date())
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(MonthlySummary.title(month))
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    stepButton("chevron.left", enabled: true) { shift(-1) }
                    stepButton("chevron.right", enabled: !isCurrentMonth) { shift(1) }
                }

                HStack(alignment: .top) {
                    stat(Fmt.km(summary.km), "km")
                    Spacer()
                    stat("\(summary.trips)", tr("út", "trips"))
                    Spacer()
                    stat(Fmt.one(summary.avgL100), "l/100")
                }

                Divider().overlay(Theme.stroke)

                row(tr("Benzinköltség", "Fuel cost"), "\(Fmt.km(summary.cost)) Ft")
                row(tr("Vezetési idő", "Driving time"), Fmt.duration(summary.driveSeconds))
                if settings.featIdle {
                    row(tr("Alapjárat", "Idling"),
                        "\(Fmt.duration(summary.idleSeconds)) · \(Fmt.one(summary.idleFuelL)) l · \(Fmt.km(summary.idleCost)) Ft")
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: monitor.dataVersion) { _ in reload() }
    }

    private func shift(_ by: Int) {
        month = Calendar.current.date(byAdding: .month, value: by, to: month) ?? month
        Haptics.tap()
        reload()
    }

    private func reload() { summary = MonthlySummary.compute(for: month) }

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

    private func stat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.number(26)).contentTransition(.numericText())
            Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.text2)
            Spacer()
            Text(value).font(Theme.number(15))
        }
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

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle().fill(gradeColor).frame(width: 10, height: 10)
                    Text(gradeText).font(.system(size: 17, weight: .semibold))
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
            toggle(tr("Parkolóóra", "Parking timer"), "parkingsign.circle", $settings.featParkingTimer)
            toggle(tr("Járva maradt motor jelzés", "Engine left running alert"), "exclamationmark.triangle", $settings.featLeftRunning)
            toggle(tr("Havi összesítő", "Monthly summary"), "chart.bar", $settings.featMonthly)
            toggle(tr("Hatótáv becslés", "Range estimate"), "fuelpump", $settings.featRange)
            toggle(tr("Akku egészség", "Battery health"), "bolt.heart", $settings.featBatteryHealth)
            toggle(tr("Alapjárati idő számláló", "Idle time counter"), "hourglass", $settings.featIdle)
        }
    }

    private func toggle(_ title: String, _ icon: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Label(title, systemImage: icon)
        }
        .tint(Theme.ok)
    }
}
