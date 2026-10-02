import SwiftUI

/// 270°-os ívmutató. A változás rugóval, túllövés nélkül követi az értéket.
struct ArcGauge: View {
    let value: Double?
    let range: ClosedRange<Double>
    var tint: Color = Theme.accent
    var lineWidth: CGFloat = 12

    private func fraction(_ v: Double) -> Double {
        min(1, max(0, (v - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Theme.surface2, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: fraction(value ?? range.lowerBound) * 0.75)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(Theme.spring, value: value)
        }
        .rotationEffect(.degrees(135))
        .padding(lineWidth / 2)
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Élő érték csempe: címke, nagy szám, mértékegység.
struct StatTile: View {
    let label: String
    let value: String
    let unit: String
    var tint: Color = Theme.text
    var icon: String? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    }
                    Text(label.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.6)
                }
                .foregroundStyle(Theme.text3)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(Theme.number(36))
                        .tracking(-0.5)
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value) \(unit)")
    }
}

/// Kapcsolat állapot a képernyő tetején.
struct ConnectionBar: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var monitor: VehicleMonitor

    private var connected: Bool { monitor.demoActive || (ble.state == .connected && monitor.isLive) }

    /// Az ESP32 él, de az ELM327 adapter nem válaszol neki (bekötés / baud hiba).
    private var adapterFault: Bool { connected && monitor.packet?.elm == false }

    private var text: String {
        if monitor.demoActive { return tr("Demo mód — szimulált adatok", "Demo mode — simulated data") }
        if adapterFault { return tr("Az OBD adapter nem válaszol", "OBD adapter not responding") }
        if connected {
            let name = AppSettings.shared.carName
            return tr("Csatlakozva — \(name)", "Connected — \(name)")
        }
        switch ble.state {
        case .off: return tr("Bluetooth kikapcsolva", "Bluetooth is off")
        case .unauthorized: return tr("Bluetooth engedély hiányzik", "Bluetooth permission missing")
        default: return tr("Nincs kapcsolat", "Not connected")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor.demoActive || adapterFault ? Theme.warn : (connected ? Theme.ok : Theme.bad))
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text2)
            Spacer()
            if connected, !adapterFault, monitor.packet?.ecu == false {
                Text(tr("Gyújtás levéve", "Ignition off"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .animation(Theme.spring, value: connected)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Theme.text3)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

enum Fmt {
    static func int(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "—" }
    static func one(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    static func two(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }

    static func km(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60) \(tr("ó", "h")) \(m % 60) \(tr("p", "min"))" : "\(m) \(tr("perc", "min"))"
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: AppSettings.shared.language == .hu ? "hu_HU" : "en_GB")
        f.dateFormat = AppSettings.shared.language == .hu ? "MMM d. HH:mm" : "d MMM HH:mm"
        return f.string(from: d)
    }
}
