import SwiftUI

/// Műszerfal. Hierarchia: elöl a sebesség és a fordulat (nagy tárcsa), alatta a két állapotjelző
/// (hűtővíz, akku), legalul a ritkábban nézett motoradatok és a hibakódok.
struct DashboardView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let live = monitor.isLive
        let p = live ? monitor.packet : nil

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(padding: 18) {
                    VStack(spacing: 6) {
                        RpmDial(rpm: p?.rpm, speed: p?.vehicleSpeed)
                            .frame(maxWidth: 300)
                            .frame(maxWidth: .infinity)
                        if !live {
                            Text(tr("Nincs élő adat", "No live data"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.text3)
                        }
                    }
                }

                // A többi rész sorrendje és láthatósága a Beállításokban állítható.
                ForEach(settings.dashVisible) { section in
                    self.section(section, p: p, live: live)
                }
            }
            .padding(16)
        }
        .screenBackground()
    }

    @ViewBuilder
    private func section(_ kind: DashSection, p: VehiclePacket?, live: Bool) -> some View {
        let running = p?.engineRunning ?? false
        switch kind {
        case .status:
            let level = VehicleMonitor.level(for: p?.batteryVoltage, running: running)
            HStack(spacing: 12) {
                StatusCard(icon: "thermometer.medium", label: tr("Hűtővíz", "Coolant"),
                           value: Fmt.int(p?.coolantTemp), unit: "°C",
                           fraction: fraction(p?.coolantTemp, 0...120),
                           tint: coolantTint(p?.coolantTemp), status: coolantStatus(p?.coolantTemp))
                StatusCard(icon: "bolt.fill", label: tr("Akku", "Battery"),
                           value: Fmt.one(p?.batteryVoltage), unit: "V",
                           fraction: fraction(p?.batteryVoltage, 11...15.5),
                           tint: level.color, status: level.label(running: running))
            }
        case .engine:
            Card {
                VStack(spacing: 14) {
                    HStack(alignment: .top) {
                        inlineStat(tr("Fogyasztás", "Consumption"),
                                   Fmt.one(p?.consumptionL100 ?? p?.fuelRateLph),
                                   (p?.vehicleSpeed ?? 0) > 3 ? "l/100" : "l/h")
                        Spacer()
                        if live, let range = monitor.rangeKm {
                            inlineStat(tr("Hatótáv", "Range"), "~\(Int(range))", "km")
                            Spacer()
                        }
                        inlineStat(tr("Szívott levegő", "Intake air"), Fmt.int(p?.intakeTemp), "°C")
                    }
                    Divider().overlay(Theme.stroke)
                    BarRow(label: tr("Terhelés", "Load"), value: p?.engineLoad, tint: Theme.accent)
                    BarRow(label: tr("Gázpedál", "Throttle"), value: p?.throttlePos, tint: Theme.accent)
                    if p?.fuelLevel != nil {
                        BarRow(label: tr("Tank", "Fuel"), value: p?.fuelLevel,
                               tint: (p?.fuelLevel ?? 100) < 15 ? Theme.warn : Theme.ok)
                    }
                }
            }
        case .trip:
            if let trip = monitor.trip, running {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: tr("Jelenlegi út", "Current trip"))
                        HStack {
                            tripStat(Fmt.one(trip.distanceKm), "km")
                            Spacer()
                            tripStat(Fmt.duration(trip.duration), "")
                            Spacer()
                            if settings.featTripCost, let fuel = trip.fuelL {
                                tripStat(Fmt.km(fuel * settings.lastFuelPrice), "Ft")
                            } else {
                                tripStat(Fmt.one(trip.avgConsumption), "l/100")
                            }
                        }
                    }
                }
            }
        case .faults:
            FaultCodesCard(codes: p?.faultCodes ?? [], known: monitor.packet != nil)
        }
    }

    private func fraction(_ v: Double?, _ range: ClosedRange<Double>) -> Double {
        guard let v else { return 0 }
        return min(1, max(0, (v - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    private func inlineStat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.text3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.number(26))
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text2)
            }
        }
    }

    private func tripStat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.number(22)).foregroundStyle(Theme.text)
            Text(unit).font(.system(size: 13)).foregroundStyle(Theme.text2)
        }
    }

    private func coolantTint(_ c: Double?) -> Color {
        guard let c else { return Theme.text3 }
        if c >= 105 { return Theme.bad }
        return c >= CarSpec.warmTemp ? Theme.ok : Theme.accent
    }

    private func coolantStatus(_ c: Double?) -> String {
        guard let c else { return "—" }
        if c >= 105 { return tr("Túl meleg", "Too hot") }
        if c >= CarSpec.warmTemp { return tr("Üzemi hőfok", "Warmed up") }
        return c < 40 ? tr("Hideg", "Cold") : tr("Melegszik", "Warming up")
    }
}

/// Nagy tárcsa: körben a fordulat (piros sávval a tiltott tartományban), középen a sebesség.
struct RpmDial: View {
    let rpm: Double?
    let speed: Double?

    /// A skála a fordulatszám-határ fölötti első egész ezresig tart (dízel 5000, benzines 7000 körül).
    private var maxRpm: Double { max(4000, ((CarSpec.redline + 500) / 1000).rounded(.up) * 1000) }
    private var steps: Int { Int(maxRpm / 1000) }
    private let line: CGFloat = 14

    private var fraction: Double { min(1, max(0, (rpm ?? 0) / maxRpm)) }
    private var tint: Color { (rpm ?? 0) >= CarSpec.redline - 500 ? Theme.bad : Theme.accent }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let labelRadius = Double(size / 2 - line - 16)

            ZStack {
                arc(from: 0, to: 1, color: Theme.surface2)
                arc(from: CarSpec.redline / maxRpm, to: 1, color: Theme.bad.opacity(0.45))
                arc(from: 0, to: fraction, color: tint)
                    .animation(Theme.spring, value: rpm)

                // Számozás ezres fordulatonként
                ForEach(0...steps, id: \.self) { i in
                    let angle = (135.0 + 270.0 * Double(i) / Double(steps)) * Double.pi / 180.0
                    Text("\(i)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Double(i) * 1000 >= CarSpec.redline ? Theme.bad : Theme.text3)
                        .position(x: CGFloat(Double(size) / 2 + cos(angle) * labelRadius),
                                  y: CGFloat(Double(size) / 2 + sin(angle) * labelRadius))
                }

                VStack(spacing: -2) {
                    Text(Fmt.int(speed))
                        .font(Theme.number(76, .bold))
                        .tracking(-2)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("km/h")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 60)
            }
            .frame(width: size, height: size)
            // A körív alsó nyílásában a fordulat számmal
            .overlay(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.int(rpm))
                        .font(Theme.number(22))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                    Text(tr("ford/p", "rpm"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.int(speed)) km/h, \(Fmt.int(rpm)) \(tr("fordulat", "rpm"))")
    }

    /// A 270°-os ív egy szakasza, 0...1 arányban megadva.
    private func arc(from: Double, to: Double, color: Color) -> some View {
        Circle()
            .trim(from: from * 0.75, to: to * 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .rotationEffect(.degrees(135))
            .padding(line / 2)
    }
}

/// Állapotjelző kártya: érték, sáv és egy szavas állapot, mind ugyanazzal a jelentést hordozó színnel.
struct StatusCard: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    let fraction: Double
    let tint: Color
    let status: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                }
                .foregroundStyle(Theme.text3)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(Theme.number(34))
                        .tracking(-0.5)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }

                MiniBar(fraction: fraction, tint: tint)

                Text(status)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MiniBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                Capsule().fill(tint)
                    .frame(width: max(5, geo.size.width * fraction))
                    .animation(Theme.spring, value: fraction)
            }
        }
        .frame(height: 5)
    }
}

/// Százalékos sor: címke, sáv, érték.
struct BarRow: View {
    let label: String
    let value: Double?
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 84, alignment: .leading)
            MiniBar(fraction: min(1, max(0, (value ?? 0) / 100)), tint: value == nil ? Theme.surface2 : tint)
            Text(value.map { "\(Int($0.rounded())) %" } ?? "—")
                .font(Theme.number(15))
                .foregroundStyle(Theme.text)
                .frame(width: 52, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

extension VoltageLevel {
    func label(running: Bool) -> String {
        switch self {
        case .unknown: return "—"
        case .ok: return running ? tr("Töltés normális", "Charging") : tr("Rendben", "Healthy")
        case .caution: return tr("Figyelem", "Caution")
        case .low: return tr("Alacsony", "Low")
        case .high: return tr("Túltöltés", "Overcharging")
        }
    }
}

extension VoltageLevel {
    var color: Color {
        switch self {
        case .unknown: return Theme.text
        case .ok: return Theme.ok
        case .caution: return Theme.warn
        case .low, .high: return Theme.bad
        }
    }
}

struct FaultCodesCard: View {
    let codes: [String]
    let known: Bool

    var body: some View {
        Card {
            if codes.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: known ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(known ? Theme.ok : Theme.text3)
                    Text(known ? tr("Nincs tárolt hibakód", "No stored fault codes")
                               : tr("Még nincs adat az autóból", "No data from the car yet"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(codes, id: \.self) { code in
                        HStack(alignment: .top, spacing: 12) {
                            Text(code)
                                .font(Theme.number(16, .bold))
                                .foregroundStyle(Theme.bad)
                                .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(DTC.describe(code))
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.text)
                                Text(DTC.severity(code).label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DTC.severity(code) == .stop ? Theme.bad : Theme.warn)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Fekvő nézet: két nagy mutató és a legfontosabb értékek, vezetés közben egy pillantással olvasható.
struct LandscapeDashboard: View {
    @EnvironmentObject var monitor: VehicleMonitor

    var body: some View {
        let p = monitor.isLive ? monitor.packet : nil

        HStack(spacing: 24) {
            gauge(value: p?.rpm, range: 0...max(4000, ((CarSpec.redline + 500) / 1000).rounded(.up) * 1000), text: Fmt.int(p?.rpm), unit: tr("ford/p", "rpm"),
                  tint: (p?.rpm ?? 0) > CarSpec.redline - 500 ? Theme.bad : Theme.accent)

            VStack(spacing: 14) {
                mini(tr("Hűtővíz", "Coolant"), Fmt.int(p?.coolantTemp), "°C")
                mini(tr("Feszültség", "Voltage"), Fmt.one(p?.batteryVoltage), "V")
                mini(tr("Fogyasztás", "Cons."), Fmt.one(p?.consumptionL100 ?? p?.fuelRateLph),
                     (p?.vehicleSpeed ?? 0) > 3 ? "l/100" : "l/h")
            }
            .frame(width: 150)

            gauge(value: p?.vehicleSpeed, range: 0...220, text: Fmt.int(p?.vehicleSpeed), unit: "km/h",
                  tint: Theme.text)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }

    private func gauge(value: Double?, range: ClosedRange<Double>, text: String, unit: String, tint: Color) -> some View {
        ZStack {
            ArcGauge(value: value, range: range, tint: tint, lineWidth: 14)
            VStack(spacing: 0) {
                Text(text)
                    .font(Theme.number(54, .bold))
                    .tracking(-1)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text2)
            }
        }
    }

    private func mini(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.text3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.number(26))
                Text(unit).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
    }
}
