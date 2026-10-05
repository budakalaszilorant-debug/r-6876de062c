import SwiftUI
import Charts
import QuickLook

// MARK: - Eszközök kártya (műszerfal)

struct ToolsCard: View {
    enum Tool: String, Identifiable, CaseIterable {
        case trip, costs, mechanic, sale, baseline, handover
        var id: String { rawValue }
        var title: String {
            switch self {
            case .trip: return tr("Út előtti ellenőrzés", "Pre-trip check")
            case .costs: return tr("Költségek", "Costs")
            case .mechanic: return tr("Üzenet szerelőnek", "Message a mechanic")
            case .sale: return tr("Eladási adatlap", "Sale sheet")
            case .baseline: return tr("Eltérésfigyelő", "Deviation monitor")
            case .handover: return tr("Autóátadás", "Car handover")
            }
        }
        var icon: String {
            switch self {
            case .trip: return "checklist"
            case .costs: return "banknote"
            case .mechanic: return "wrench.and.screwdriver"
            case .sale: return "doc.text"
            case .baseline: return "chart.xyaxis.line"
            case .handover: return "key.horizontal"
            }
        }
    }

    @State private var open: Tool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: tr("Eszközök", "Tools"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Tool.allCases) { t in
                    Button { open = t } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: t.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 36, height: 36)
                                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(t.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .sheet(item: $open) { tool in
            switch tool {
            case .trip: TripCheckView()
            case .costs: CostsView()
            case .mechanic: MechanicMessageView()
            case .sale: SaleSheetView()
            case .baseline: BaselineView()
            case .handover: HandoverView()
            }
        }
    }
}

private struct SheetFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(16)
            }
            .screenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } }
            }
        }
    }
}

private func levelIcon(_ l: TripCheckItem.Level) -> (String, Color) {
    switch l {
    case .ok: return ("checkmark.circle.fill", Theme.ok)
    case .warn: return ("exclamationmark.triangle.fill", Theme.warn)
    case .bad: return ("xmark.octagon.fill", Theme.bad)
    }
}

// MARK: - Út előtti ellenőrzés

struct TripCheckView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var tripKm = 300.0
    @State private var days = 3
    @State private var checked = Set<String>()

    var body: some View {
        let items = TripReadiness.check(tripKm: tripKm, days: days,
                                        packet: monitor.isLive ? monitor.packet : nil, range: monitor.rangeKm)
        let bad = items.contains { $0.level == .bad }
        let warn = items.contains { $0.level == .warn }
        SheetFrame(title: tr("Út előtti ellenőrzés", "Pre-trip check")) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(tr("Az út hossza", "Trip length")).foregroundStyle(Theme.text2)
                        Spacer()
                        Text("\(Int(tripKm)) km").font(Theme.number(18))
                    }
                    Slider(value: $tripKm, in: 50...2000, step: 50)
                    Stepper(tr("Időtartam: \(days) nap", "Duration: \(days) days"), value: $days, in: 1...30)
                }
            }

            Card(padding: 18) {
                HStack(spacing: 14) {
                    let overall = levelIcon(bad ? .bad : (warn ? .warn : .ok))
                    Image(systemName: overall.0).font(.system(size: 30)).foregroundStyle(overall.1)
                    Text(bad ? tr("Előbb nézd meg ezeket", "Check these first")
                             : (warn ? tr("Indulhatsz, de figyelj ezekre", "Good to go, but note these")
                                     : tr("Nyugodtan indulhatsz", "You're good to go")))
                        .font(.system(size: 19, weight: .semibold))
                }
            }

            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        let look = levelIcon(item.level)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: look.0).foregroundStyle(look.1).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.system(size: 15, weight: .semibold))
                                Text(item.detail).font(.system(size: 14)).foregroundStyle(Theme.text2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        if item.id != items.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 48) }
                    }
                }
            }

            SectionLabel(text: tr("Nézd meg te is", "Check yourself"))
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(TripReadiness.manualChecks, id: \.self) { c in
                        Button {
                            if checked.contains(c) { checked.remove(c) } else { checked.insert(c) }
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: checked.contains(c) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(checked.contains(c) ? Theme.ok : Theme.text3)
                                Text(c).foregroundStyle(Theme.text)
                                Spacer()
                            }
                            .padding(.horizontal, 14).frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        if c != TripReadiness.manualChecks.last { Divider().overlay(Theme.stroke).padding(.leading, 46) }
                    }
                }
            }
        }
    }
}

// MARK: - Szerelőnek üzenet

struct MechanicMessageView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var text = ""

    var body: some View {
        SheetFrame(title: tr("Üzenet szerelőnek", "Message a mechanic")) {
            Text(tr("Átírhatod, mielőtt elküldöd. Küldd el több szerelőnek is, és vesd össze az ajánlatokat.",
                    "Edit it before sending. Send it to several mechanics and compare the quotes."))
                .font(.system(size: 14)).foregroundStyle(Theme.text2)
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 340)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            ShareLink(item: text) {
                Label(tr("Küldés…", "Send…"), systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .onAppear { if text.isEmpty { text = MechanicMessage.text(packet: monitor.isLive ? monitor.packet : nil) } }
    }
}

// MARK: - Eladási adatlap

struct SaleSheetView: View {
    @State private var data = SaleSheetData.build()
    @State private var pdf: URL?
    @State private var preview: URL?
    @State private var exportError: String?

    var body: some View {
        SheetFrame(title: tr("Eladási adatlap", "Sale sheet")) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(data.carName).font(.system(size: 22, weight: .bold))
                    Text(data.fuel + (data.vin.map { " · \($0)" } ?? ""))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text2)
                }
            }
            HStack(spacing: 12) {
                StatTile(label: tr("Km óra", "Odometer"), value: data.odometer.map(Fmt.km) ?? "—", unit: "km")
                StatTile(label: tr("Rögzített utak", "Recorded trips"), value: "\(data.trips)", unit: tr("út", "trips"))
            }
            HStack(spacing: 12) {
                StatTile(label: tr("Rögzített km", "Logged km"), value: Fmt.km(data.totalKm), unit: "km")
                StatTile(label: tr("Fogyasztás", "Consumption"), value: Fmt.one(data.avgL100), unit: "l/100")
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Szerviztörténet", "Service history"))
                    if data.services.isEmpty {
                        Text(tr("Még nincs rögzített szerviz.", "No service recorded yet.")).foregroundStyle(Theme.text3)
                    }
                    ForEach(Array(data.services.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(s.name).font(.system(size: 15))
                            Spacer()
                            Text("\(Fmt.km(s.km)) km").font(Theme.number(14)).foregroundStyle(Theme.text2)
                        }
                    }
                }
            }
            if let reading = data.diagnostic {
                Label(reading.codes.isEmpty ? tr("A mentett leolvasásban nincs tárolt kód", "No stored codes in the saved reading") : reading.codes.joined(separator: ", "), systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(Theme.text2)
                Text(Fmt.date(reading.date)).font(.caption).foregroundStyle(Theme.text3)
            } else {
                Label(tr("Nincs mentett OBD-leolvasás", "No saved OBD reading"), systemImage: "questionmark.circle").foregroundStyle(Theme.text2)
            }
            if let pdf {
                Button { preview = pdf } label: { Label(tr("PDF megtekintése", "Preview PDF"), systemImage: "doc.richtext") }
                ShareLink(item: pdf) {
                    Label(tr("PDF-adatlap megosztása", "Share PDF report"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(PressableStyle())
            }
            if let exportError { Text(exportError).foregroundStyle(Theme.bad) }
            Text(tr("A PDF a saját naplódból készül; nem független állapotigazolás.", "The PDF comes from your own records; it is not an independent inspection."))
                .font(.footnote).foregroundStyle(Theme.text3)
        }
        .quickLookPreview($preview)
        .onAppear {
            data = SaleSheetData.build()
            do { pdf = try SaleReport.create(data) }
            catch { exportError = tr("Nem sikerült a PDF készítése.", "Could not create the PDF.") }
        }
    }
}

// MARK: - Költségek

struct CostsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var period = 1        // 0: idén, 1: 12 hónap, 2: teljes idő
    @State private var expenses: [Expense] = []
    @State private var summary = CostSummary()
    @State private var compare: [(name: String, perKm: Double?)] = []
    @State private var adding = false

    private var since: Date? {
        switch period {
        case 0: return Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date()))
        case 1: return Calendar.current.date(byAdding: .month, value: -12, to: Date())
        default: return nil
        }
    }

    var body: some View {
        SheetFrame(title: tr("Költségek", "Costs")) {
            Picker("", selection: $period) {
                Text(tr("Idén", "This year")).tag(0)
                Text(tr("12 hónap", "12 months")).tag(1)
                Text(tr("Összes", "All time")).tag(2)
            }
            .pickerStyle(.segmented)
            .onChange(of: period) { _ in reload() }

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.km(summary.total)).font(Theme.number(36, .bold)).tracking(-0.6)
                        Text("Ft").foregroundStyle(Theme.text2)
                        Spacer()
                        if let perKm = summary.perKm {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Fmt.one(perKm)) Ft").font(Theme.number(20))
                                Text(tr("km-enként", "per km")).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                    breakdown
                }
            }

            if compare.count > 1 {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: tr("Autók összevetése", "Car comparison"))
                        ForEach(Array(compare.enumerated()), id: \.offset) { _, c in
                            HStack {
                                Text(c.name)
                                Spacer()
                                Text(c.perKm.map { "\(Fmt.one($0)) Ft/km" } ?? "—").font(Theme.number(15))
                            }
                        }
                    }
                }
            }

            PrimaryButton(title: tr("Költség rögzítése", "Add expense"), icon: "plus") { adding = true }

            if !expenses.isEmpty {
                SectionLabel(text: tr("Napló", "Log"))
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(expenses) { e in
                            HStack(spacing: 12) {
                                Image(systemName: e.category.icon).foregroundStyle(Theme.accent).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.note.isEmpty ? e.category.label : e.note).font(.system(size: 15))
                                    Text(Fmt.date(e.date)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                                }
                                Spacer()
                                Text("\(Fmt.km(e.amount)) Ft").font(Theme.number(15))
                            }
                            .padding(.horizontal, 14).frame(minHeight: 54)
                            .contextMenu {
                                Button(role: .destructive) { ExpenseStore.delete(e.id); reload() } label: {
                                    Label(tr("Törlés", "Delete"), systemImage: "trash")
                                }
                            }
                            if e.id != expenses.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 50) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $adding) { AddExpenseSheet { reload() }.presentationDetents([.medium, .large]) }
    }

    /// Kategóriánkénti sáv: üzemanyag + rögzített költségek.
    private var breakdown: some View {
        let rows: [(String, Double, Color)] =
            [(tr("Üzemanyag", "Fuel"), summary.fuel, Theme.accent)] +
            ExpenseCategory.allCases.compactMap { c -> (String, Double, Color)? in
                guard let v = summary.byCategory[c], v > 0 else { return nil }
                return (c.label, v, c == .service ? Theme.warn : Theme.text3)
            }
        let total = max(1, summary.total)
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.0).font(.system(size: 14)).foregroundStyle(Theme.text2)
                        Spacer()
                        Text("\(Fmt.km(r.1)) Ft").font(Theme.number(14))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surface2)
                            Capsule().fill(r.2).frame(width: max(4, geo.size.width * r.1 / total))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
    }

    private func reload() {
        expenses = ExpenseStore.all()
        summary = ExpenseStore.summary(since: since)
        compare = CarStore.all().map { ($0.name, ExpenseStore.summary(car: $0.id, since: since).perKm) }
    }
}

struct AddExpenseSheet: View {
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = ExpenseCategory.service
    @State private var amount = ""
    @State private var note = ""
    @State private var date = Date()

    private var value: Double? { Double(amount.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Kategória", "Category")) {
                    ForEach(ExpenseCategory.allCases) { item in
                        Button { category = item } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: item.icon).frame(width: 26)
                                Text(item.label).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if category == item { Image(systemName: "checkmark.circle.fill") }
                            }.frame(minHeight: 32)
                        }.accessibilityAddTraits(category == item ? .isSelected : [])
                    }
                }
                HStack {
                    Text(tr("Összeg", "Amount"))
                    Spacer()
                    TextField("0", text: $amount).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .font(Theme.number(17))
                    Text("Ft").foregroundStyle(Theme.text2)
                }
                TextField(tr("Megjegyzés (pl. téligumi csere)", "Note (e.g. winter tyre swap)"), text: $note)
                DatePicker(tr("Dátum", "Date"), selection: $date, in: ...Date(), displayedComponents: .date)
            }
            .navigationTitle(tr("Költség", "Expense"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Mentés", "Save")) {
                        guard let v = value, v > 0 else { return }
                        ExpenseStore.add(date: date, category: category, amount: v, note: note)
                        Haptics.success()
                        onSave()
                        dismiss()
                    }
                    .disabled((value ?? 0) <= 0)
                }
            }
        }
    }
}

// MARK: - Kutak (tankolás nézet)

struct StationsCard: View {
    let stats: [StationStat]

    var body: some View {
        let overpaid = StationStats.overpaid(stats)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: tr("Kutak, olcsóbbtól a drágábbig", "Stations, cheapest first"))
                ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Text(s.name).font(.system(size: 15, weight: i == 0 ? .semibold : .regular))
                        if i == 0 {
                            Text(tr("legolcsóbb", "cheapest"))
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.ok.opacity(0.18), in: Capsule())
                                .foregroundStyle(Theme.ok)
                        }
                        Spacer()
                        Text("\(Fmt.int(s.avgPrice)) Ft/l").font(Theme.number(15))
                        Text("· \(s.fills)×").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }
                if overpaid >= 100 {
                    Divider().overlay(Theme.stroke)
                    Text(tr("Ha mindig a legolcsóbb kúton tankoltál volna, kb. \(Fmt.km(overpaid)) Ft-tal kevesebbet fizetsz.",
                            "Filling up at the cheapest station every time would have saved about \(Fmt.km(overpaid)) Ft."))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.warn)
                }
            }
        }
    }
}
