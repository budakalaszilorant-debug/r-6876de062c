import SwiftUI

struct ServiceView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var statuses: [ServiceStatus] = []
    @State private var kmPerDay: Double?
    @State private var editing: ServiceItem?

    private func group(_ level: ServiceStatus.Level) -> [ServiceStatus] {
        statuses.filter { $0.level == level }
            .sorted { ($0.remainingKm ?? .infinity) < ($1.remainingKm ?? .infinity) }
    }

    private var next: ServiceStatus? {
        statuses.filter { $0.remainingKm != nil }.min { ($0.remainingKm ?? 0) < ($1.remainingKm ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if !settings.odometerSet {
                    Label(tr("Add meg a km óra állását (Beállítások → Autó), különben nem tudom, mikor esedékes a szerviz.",
                             "Set the odometer (Settings → Car), otherwise service dates can't be calculated."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.warn)
                }

                if let next, settings.odometerSet {
                    NextServiceCard(status: next, kmPerDay: kmPerDay) { editing = next.item }
                }

                section(tr("Lejárt", "Overdue"), group(.overdue))
                section(tr("Hamarosan esedékes", "Due soon"), group(.soon))
                section(tr("Rendben", "OK"), group(.ok))
                section(tr("Még nincs rögzítve", "Not recorded yet"), group(.unknown),
                        hint: tr("Koppints egy tételre, és add meg, mikor cserélték utoljára.",
                                 "Tap an item and enter when it was last done."))

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Lejáratok", "Expiry dates"))
                    RemindersCard()
                }
            }
            .padding(16)
        }
        .onAppear(perform: reload)
        .onChange(of: settings.odometerKm) { _ in reload() }
        .sheet(item: $editing) { item in
            ServiceDoneSheet(item: item) { reload() }
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: tr("Km óra", "Odometer"))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(settings.odometerSet ? Fmt.km(settings.odometerKm) : "—")
                                .font(Theme.number(32, .bold))
                                .contentTransition(.numericText())
                            Text("km").foregroundStyle(Theme.text2)
                        }
                    }
                    Spacer()
                    if let kmPerDay {
                        VStack(alignment: .trailing, spacing: 4) {
                            SectionLabel(text: tr("Napi átlag", "Daily avg"))
                            Text("\(Int(kmPerDay.rounded())) km").font(Theme.number(18))
                        }
                    }
                }
                HStack(spacing: 8) {
                    chip(group(.overdue).count, tr("lejárt", "overdue"), Theme.bad)
                    chip(group(.soon).count, tr("hamarosan", "soon"), Theme.warn)
                    chip(group(.ok).count, tr("rendben", "OK"), Theme.ok)
                }
            }
        }
    }

    private func chip(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(n > 0 ? color : Theme.text3).frame(width: 7, height: 7)
            Text("\(n) \(label)").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(n > 0 ? Theme.text : Theme.text3)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Theme.surface2, in: Capsule())
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ServiceStatus], hint: String? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: title)
                if let hint {
                    Text(hint).font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(items) { s in
                            Button { editing = s.item } label: {
                                ServiceRow(status: s, kmPerDay: kmPerDay)
                            }
                            .buttonStyle(PressableStyle())
                            if s.id != items.last?.id {
                                Divider().overlay(Theme.stroke).padding(.leading, 70)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        statuses = ServiceStore.statuses(odometer: settings.odometerKm)
        kmPerDay = ServiceStore.kmPerDay()
    }
}

extension ServiceStatus {
    var tint: Color {
        switch level {
        case .unknown: return Theme.text3
        case .ok: return Theme.ok
        case .soon: return Theme.warn
        case .overdue: return Theme.bad
        }
    }

    var remainingText: String {
        guard let r = remainingKm else { return tr("Nincs rögzítve", "Not recorded") }
        return r < 0 ? tr("\(Fmt.km(-r)) km-rel lejárt", "Overdue by \(Fmt.km(-r)) km")
                     : tr("\(Fmt.km(r)) km múlva", "In \(Fmt.km(r)) km")
    }

    /// Várható dátum a napi átlagos km alapján.
    func dueDate(kmPerDay: Double?) -> Date? {
        guard let r = remainingKm, r > 0, let kmPerDay, kmPerDay > 1 else { return nil }
        return Date().addingTimeInterval(r / kmPerDay * 86400)
    }

    var icon: String {
        switch item.id {
        case "oil", "oil_filter": return "drop.fill"
        case "air_filter", "cabin_filter": return "wind"
        case "fuel_filter": return "fuelpump"
        case "spark": return "bolt.fill"
        case "timing", "aux_belt": return "gearshape.2.fill"
        case "brake_fluid": return "exclamationmark.octagon"
        case "coolant": return "thermometer.snowflake"
        default: return "wrench.and.screwdriver.fill"
        }
    }
}

/// Gyűrű: mennyi telt el a csereperiódusból.
private struct ServiceRing: View {
    let status: ServiceStatus
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().stroke(Theme.surface2, lineWidth: 4)
            Circle()
                .trim(from: 0, to: status.remainingKm == nil ? 0 : max(0.03, status.progress))
                .stroke(status.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: status.icon)
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundStyle(status.tint)
        }
        .frame(width: size, height: size)
    }
}

struct ServiceRow: View {
    let status: ServiceStatus
    let kmPerDay: Double?

    var body: some View {
        HStack(spacing: 14) {
            ServiceRing(status: status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(status.item.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if status.item.critical {
                        Text(tr("KRITIKUS", "CRITICAL"))
                            .font(.system(size: 9, weight: .bold)).tracking(0.5)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.bad.opacity(0.2), in: Capsule())
                            .foregroundStyle(Theme.bad)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(status.remainingText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status.tint)
                if let d = status.dueDate(kmPerDay: kmPerDay) {
                    Text(dateText(d)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var s = status.item.intervalKm > 0
            ? tr("\(Fmt.km(status.item.intervalKm)) km-enként", "Every \(Fmt.km(status.item.intervalKm)) km")
            : tr("Csereperiódus nincs megadva", "Interval not set")
        if let km = status.lastKm {
            s += tr(" · utoljára \(Fmt.km(km)) km", " · last at \(Fmt.km(km)) km")
        }
        if status.wearFactor >= 1.1 {
            s += tr(" · valós kopás ×\(Fmt.one(status.wearFactor))", " · real wear ×\(Fmt.one(status.wearFactor))")
        }
        return s
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: AppSettings.shared.language == .hu ? "hu_HU" : "en_GB")
        f.dateFormat = AppSettings.shared.language == .hu ? "kb. yyyy. MMM" : "~MMM yyyy"
        return f.string(from: d)
    }
}

/// A legközelebbi esedékes tétel kiemelve.
private struct NextServiceCard: View {
    let status: ServiceStatus
    let kmPerDay: Double?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Card(padding: 18) {
                HStack(spacing: 16) {
                    ServiceRing(status: status, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: tr("Következő", "Up next"))
                        Text(status.item.name)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(detail)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(status.tint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var detail: String {
        var s = status.remainingText
        if let d = status.dueDate(kmPerDay: kmPerDay) {
            let days = Int(d.timeIntervalSinceNow / 86400)
            s += days < 60 ? tr(", kb. \(days) nap", ", about \(days) days")
                           : tr(", kb. \(days / 30) hónap", ", about \(days / 30) months")
        }
        return s
    }
}
