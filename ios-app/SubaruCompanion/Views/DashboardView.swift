import SwiftUI

/// Teljes OBD2 műszerfal: minden élő adat és a hibakódok egy képernyőn.
struct DashboardView: View {
    @EnvironmentObject var monitor: VehicleMonitor

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let p = monitor.packet
        let live = monitor.isLive
        let running = p?.engineRunning ?? false

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !live {
                    Card {
                        EmptyState(icon: "antenna.radiowaves.left.and.right.slash",
                                   title: tr("Nincs élő adat", "No live data"),
                                   message: tr("Az app automatikusan csatlakozik, amikor az autó közelében vagy.",
                                               "The app connects automatically when you are near the car."))
                    }
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    StatTile(label: tr("Fordulat", "RPM"), value: Fmt.int(live ? p?.rpm : nil),
                             unit: tr("ford/p", "rpm"), icon: "gauge")
                    StatTile(label: tr("Sebesség", "Speed"), value: Fmt.int(live ? p?.vehicleSpeed : nil),
                             unit: "km/h", icon: "speedometer")
                    StatTile(label: tr("Hűtővíz", "Coolant"), value: Fmt.int(live ? p?.coolantTemp : nil),
                             unit: "°C", tint: coolantTint(p?.coolantTemp, live: live), icon: "thermometer.medium")
                    StatTile(label: tr("Feszültség", "Voltage"), value: Fmt.one(live ? p?.batteryVoltage : nil),
                             unit: "V", tint: voltageTint(p, live: live), icon: "bolt.fill")
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Motor", "Engine"))
                    LazyVGrid(columns: columns, spacing: 12) {
                        StatTile(label: tr("Fogyasztás", "Consumption"),
                                 value: consumptionValue(p, live: live),
                                 unit: (p?.vehicleSpeed ?? 0) > 3 ? "l/100" : "l/h", icon: "fuelpump")
                        StatTile(label: tr("Terhelés", "Load"), value: Fmt.int(live ? p?.engineLoad : nil), unit: "%")
                        StatTile(label: tr("Gázpedál", "Throttle"), value: Fmt.int(live ? p?.throttlePos : nil), unit: "%")
                        StatTile(label: tr("Szívott levegő", "Intake air"), value: Fmt.int(live ? p?.intakeTemp : nil), unit: "°C")
                        if p?.fuelLevel != nil {
                            StatTile(label: tr("Tank", "Fuel level"), value: Fmt.int(live ? p?.fuelLevel : nil), unit: "%")
                        }
                    }
                }

                if let trip = monitor.trip, running {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: tr("Jelenlegi út", "Current trip"))
                        Card {
                            HStack {
                                tripStat(Fmt.one(trip.distanceKm), "km")
                                Spacer()
                                tripStat(Fmt.duration(trip.duration), "")
                                Spacer()
                                tripStat(Fmt.one(trip.avgConsumption), "l/100")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Hibakódok", "Fault codes"))
                    FaultCodesCard(codes: p?.faultCodes ?? [], known: p != nil)
                }
            }
            .padding(16)
        }
        .screenBackground()
    }

    private func tripStat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.number(22)).foregroundStyle(Theme.text)
            Text(unit).font(.system(size: 13)).foregroundStyle(Theme.text2)
        }
    }

    private func consumptionValue(_ p: VehiclePacket?, live: Bool) -> String {
        guard live, let p else { return "—" }
        return Fmt.one(p.consumptionL100 ?? p.fuelRateLph)
    }

    private func coolantTint(_ c: Double?, live: Bool) -> Color {
        guard live, let c else { return Theme.text }
        if c >= 105 { return Theme.bad }
        return c >= EJ20.warmTemp ? Theme.ok : Theme.accent
    }

    private func voltageTint(_ p: VehiclePacket?, live: Bool) -> Color {
        guard live, let p else { return Theme.text }
        return VehicleMonitor.level(for: p.batteryVoltage, running: p.engineRunning).color
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
                            Text(DTC.describe(code))
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.text)
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
            gauge(value: p?.rpm, range: 0...7000, text: Fmt.int(p?.rpm), unit: tr("ford/p", "rpm"),
                  tint: (p?.rpm ?? 0) > EJ20.redline - 500 ? Theme.bad : Theme.accent)

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
