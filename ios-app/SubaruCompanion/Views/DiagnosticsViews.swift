import SwiftUI

/// Egy hibakód kártyán / listában megjelenő adatai.
struct DTCEntry: Identifiable {
    enum Kind { case stored, pending, permanent, history }
    let code: String
    let kind: Kind
    var record: DTCRecord?
    var id: String { "\(kind)-\(code)" }
}

struct DiagnosticsView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @EnvironmentObject var settings: AppSettings
    @State private var history: [DTCRecord] = []
    @State private var showCheck = UserDefaults.standard.bool(forKey: "uiHealth")  // képernyőképekhez
    @State private var detail: DTCEntry?
    @State private var showAllHistory = false
    @State private var showRepair = false

    private var p: VehiclePacket? { monitor.packet }
    private var stored: [String] { p?.faultCodes ?? [] }
    private var pending: [String] { (p?.pendingCodes ?? []).filter { !stored.contains($0) } }
    private var permanent: [String] { (p?.permanentCodes ?? []).filter { !stored.contains($0) } }
    private var milOn: Bool? { Readiness(bytes: p?.mon)?.milOn }
    private var record: [String: DTCRecord] {
        Dictionary(history.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHero
                Button { showRepair = true } label: {
                    Card {
                        Label(tr("Javítás követése és hibakódtörlés", "Repair follow-up and fault clearing"), systemImage: "wrench.and.screwdriver")
                            .foregroundStyle(Theme.accent)
                    }
                }.buttonStyle(.plain)

                Button { showCheck = true } label: {
                    Card {
                        HStack(spacing: 14) {
                            Image(systemName: "stethoscope")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("Átvilágítás", "Health check")).font(.system(size: 16, weight: .semibold))
                                Text(lastCheckText).font(.system(size: 13)).foregroundStyle(Theme.text2)
                            }
                            .foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                        }
                    }
                }
                .buttonStyle(PressableStyle())

                codeSection(tr("Tárolt hibák", "Stored faults"), stored.map { DTCEntry(code: $0, kind: .stored, record: record[$0]) },
                            hint: nil)
                codeSection(tr("Kialakulóban", "Developing"), pending.map { DTCEntry(code: $0, kind: .pending, record: record[$0]) },
                            hint: tr("Egyszer már észlelte az autó, de még nem erősítette meg. Ha visszatér, tárolt hiba lesz belőle.",
                                     "The car has seen it once but not confirmed it yet. If it returns, it becomes a stored fault."))
                codeSection(tr("Állandó", "Permanent"), permanent.map { DTCEntry(code: $0, kind: .permanent, record: record[$0]) },
                            hint: tr("Ezeket törléssel sem lehet eltüntetni: csak akkor mennek el, ha az autó maga ellenőrzi, hogy a hiba megszűnt.",
                                     "These can't be cleared: they go away only after the car verifies the fault is fixed."))

                historySection
            }
            .padding(16)
        }
        .sheet(isPresented: $showRepair) { RepairClearView() }
        .sheet(isPresented: $showCheck) { HealthCheckView() }
        .sheet(item: $detail) { DTCDetailSheet(entry: $0) }
        .onAppear { history = DTC.history() }
        .onChange(of: monitor.dataVersion) { _ in history = DTC.history() }
    }

    // MARK: Részek

    private var statusHero: some View {
        let count = stored.count
        let known = p != nil && monitor.isLive
        let color: Color = !known ? Theme.text3 : (count > 0 || milOn == true ? Theme.bad : (pending.isEmpty ? Theme.ok : Theme.warn))
        let title: String = {
            guard known else { return tr("Nincs élő kapcsolat", "Not connected") }
            if count > 0 { return tr("\(count) hibakód", "\(count) fault code\(count == 1 ? "" : "s")") }
            if !pending.isEmpty { return tr("Kialakulóban lévő hiba", "Developing fault") }
            return tr("Nincs hibakód", "No fault codes")
        }()
        return Card(padding: 18) {
            HStack(spacing: 16) {
                Image(systemName: !known ? "antenna.radiowaves.left.and.right.slash"
                                         : (count > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 56, height: 56)
                    .background(color.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 21, weight: .semibold))
                    if known {
                        HStack(spacing: 6) {
                            Image(systemName: "engine.combustion")
                            Text(milText)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(milOn == true ? Theme.bad : Theme.text2)
                    } else {
                        Text(tr("Az utolsó ismert állapot lent látható.", "The last known state is shown below."))
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var milText: String {
        switch milOn {
        case .some(true): return tr("Motorhiba lámpa ég", "Check-engine light on")
        case .some(false): return tr("Motorhiba lámpa nem ég", "Check-engine light off")
        case .none: return tr("Lámpa állapota: —", "Lamp status: —")
        }
    }

    private var lastCheckText: String {
        if let last = HealthCheck.lastSaved() {
            return tr("Legutóbb: \(last.score) pont · \(Fmt.date(last.date))", "Last: \(last.score) points · \(Fmt.date(last.date))")
        }
        return tr("Vásárlás, műszaki vagy szerelő előtt", "Before buying, inspection or the mechanic")
    }

    @ViewBuilder
    private func codeSection(_ title: String, _ entries: [DTCEntry], hint: String?) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: title)
                ForEach(entries) { e in
                    Button { detail = e } label: { DTCCard(entry: e) }
                        .buttonStyle(PressableStyle())
                }
                if let hint {
                    Text(hint).font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let past = history.filter { !$0.active }
        if !past.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: tr("Korábbi hibák", "Past faults"))
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        let shown = showAllHistory ? past : Array(past.prefix(5))
                        ForEach(shown) { r in
                            Button { detail = DTCEntry(code: r.code, kind: .history, record: r) } label: {
                                HStack(spacing: 12) {
                                    Text(r.code).font(Theme.number(15, .bold)).frame(width: 62, alignment: .leading)
                                    Text(DTC.describe(r.code)).font(.system(size: 14)).foregroundStyle(Theme.text2)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(Fmt.date(r.lastSeen)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                                }
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 16).frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            if r.id != shown.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 16) }
                        }
                    }
                }
                if past.count > 5 {
                    Button(showAllHistory ? tr("Kevesebb", "Show less") : tr("Mind a \(past.count) mutatása", "Show all \(past.count)")) {
                        withAnimation(Theme.spring) { showAllHistory.toggle() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }
}

/// Hibakód kártya: kód, rendszer, leírás, súlyosság.
private struct DTCCard: View {
    let entry: DTCEntry

    private var severity: DTCSeverity { DTC.severity(entry.code) }
    private var tint: Color {
        if entry.kind == .pending { return Theme.warn }
        switch severity {
        case .stop: return Theme.bad
        case .soon: return Theme.warn
        case .minor: return Theme.accent
        }
    }

    var body: some View {
        let sys = DTC.system(entry.code)
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: sys.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.code).font(Theme.number(17, .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(entry.kind == .pending ? tr("Figyelendő", "Watch") : severity.label)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(tint)
                    }
                    Text(DTC.describe(entry.code)).font(.system(size: 15)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                    Text(sys.name).font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
        }
    }
}

/// Egy hibakód részletei: mit jelent, mennyire sürgős, mit érdemes tenni, mikor jött.
struct DTCDetailSheet: View {
    let entry: DTCEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sys = DTC.system(entry.code)
        let sev = DTC.severity(entry.code)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.code).font(Theme.number(40, .bold)).tracking(-0.8)
                        Text(DTC.describe(entry.code)).font(.system(size: 19, weight: .semibold))
                        Label(sys.name, systemImage: sys.icon).font(.system(size: 14)).foregroundStyle(Theme.text2)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: tr("Mennyire sürgős", "How urgent"))
                            Text(entry.kind == .pending ? tr("Figyelendő: még nem megerősített hiba.", "Watch: not yet confirmed.")
                                                        : sev.label)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(sev == .stop ? Theme.bad : Theme.warn)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: tr("Mit érdemes tenni", "What to do"))
                            Text(DTC.advice(entry.code)).font(.system(size: 15)).foregroundStyle(Theme.text)
                        }
                    }

                    if let snap = entry.record?.snapshot {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(text: snap.fromEcu ? tr("A hiba pillanatában", "When it occurred")
                                                                : tr("Az észleléskor", "When detected"))
                                HStack {
                                    value(snap.rpm.map { "\(Int($0))" }, tr("ford/p", "rpm"))
                                    value(snap.speed.map { "\(Int($0))" }, "km/h")
                                    value(snap.coolant.map { "\(Int($0))" }, "°C")
                                    value(snap.load.map { "\(Int($0))" }, "%")
                                }
                            }
                        }
                    }

                    if let r = entry.record {
                        Card {
                            VStack(spacing: 10) {
                                row(tr("Első észlelés", "First seen"), Fmt.date(r.firstSeen))
                                row(tr("Utoljára", "Last seen"), Fmt.date(r.lastSeen))
                                row(tr("Állapot", "Status"), r.active ? tr("Aktív", "Active") : tr("Megszűnt", "Gone"))
                            }
                        }
                    }

                    if let url = searchURL {
                        Link(destination: url) {
                            Label(tr("Keresés a neten", "Search the web"), systemImage: "magnifyingglass")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private var searchURL: URL? {
        let q = "\(entry.code) \(AppSettings.shared.carName)"
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: q)]
        return c?.url
    }

    private func value(_ v: String?, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(v ?? "—").font(Theme.number(20))
            Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
        }
        .font(.system(size: 15))
    }
}
