import SwiftUI

private func familyError(_ error: Error) -> String {
    error is FamilyGarageError || error is JourneyError ? error.localizedDescription : FamilyGarageError.unavailable.localizedDescription
}

struct FamilyGarageView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @State private var cars: [FamilyCar] = []
    @State private var name = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        List {
            if !cloud.signedIn { Text(tr("A meghívásokhoz jelentkezz be a Profil oldalon.", "Sign in on the Profile tab to use invitations.")) }
            ForEach(cars) { car in NavigationLink { FamilyCarView(car: car) } label: { VStack(alignment: .leading) { Text(car.name); Text(car.owned ? tr("Te kezeled", "You manage this") : tr("Megosztva veled", "Shared with you")).font(.caption).foregroundStyle(.secondary) } } }
            if cloud.signedIn {
                Section(tr("Új közös autó", "New shared car")) {
                    TextField(tr("Autó neve", "Car name"),text: $name)
                    Button(tr("Közös garázs létrehozása", "Create shared garage")) { perform { _ = try await cloud.family("create",data: ["name":name]); name = "" } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section(tr("Meghívást kaptál?", "Have an invitation?")) {
                    TextField(tr("Meghívókód", "Invitation code"),text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(tr("Csatlakozás", "Join")) { perform { _ = try await cloud.family("join",data: ["token":token.trimmingCharacters(in: .whitespacesAndNewlines)]); token = "" } }.disabled(token.isEmpty)
                }
                Text(tr("Csak a külön megosztott adatokat látják a meghívottak. A privát garázsod és az útvonal-koordináták nem kerülnek át automatikusan.", "Invitees see only separately shared records. Your private garage and route coordinates are never copied automatically.")).font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(tr("Családi garázs", "Family garage")).disabled(busy)
        .task { await reload() }.refreshable { await reload() }
    }
    @MainActor private func reload() async {
        guard cloud.signedIn else { cars = []; return }
        do { cars = try JSONDecoder().decode([FamilyCar].self,from: await cloud.family("list")); error = nil }
        catch { self.error = familyError(error) }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in defer { busy = false }; do { try await operation(); await reload() } catch { self.error = familyError(error) } }
    }
}

struct FamilyCarView: View {
    let car: FamilyCar
    @State private var content: [FamilyContent] = []
    @State private var error: String?
    @State private var busy = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(content) { section in
                NavigationLink { FamilyRecordsView(car: car,content: section) } label: {
                    HStack { Text(FamilySection(rawValue: section.section)?.title ?? section.section); Spacer(); Text("\(section.records.count)").foregroundStyle(.secondary) }
                }
            }
            if car.owned { NavigationLink(tr("Meghívások és jogosultságok", "Invitations and permissions")) { FamilyPermissionsView(car: car) } }
            Button(car.owned ? tr("Közös garázs törlése", "Delete shared garage") : tr("Kilépés a közös garázsból", "Leave shared garage"),role: .destructive) { confirmDelete = true }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(car.name).task { await reload() }.refreshable { await reload() }
        .confirmationDialog(tr("A privát autók megmaradnak. Folytatod?", "Private cars will be kept. Continue?"),isPresented: $confirmDelete) {
            Button(tr("Folytatás", "Continue"),role: .destructive) { Task { @MainActor in do { _ = try await CloudSync.shared.family(car.owned ? "delete" : "leave",garage: car.id); dismiss() } catch { self.error = familyError(error) } } }
        }
    }
    @MainActor private func reload() async { busy = true; defer { busy = false }; do { content = try JSONDecoder().decode([FamilyContent].self,from: await CloudSync.shared.family("read",garage: car.id)); error = nil } catch { content = []; self.error = familyError(error) } }
}

struct FamilyRecordsView: View {
    let car: FamilyCar
    @State var content: FamilyContent
    @State private var editing: FamilyRecord?
    @State private var export: [FamilyRecord]?
    @State private var error: String?
    @State private var busy = false
    @State private var deleting: FamilyRecord?
    @Environment(\.scenePhase) private var scenePhase
    @State private var verifiedWrite = false
    private var writable: Bool { verifiedWrite }
    var body: some View {
        List {
            ForEach(content.records.sorted { $0.date > $1.date }) { record in
                Button { if writable { editing = record } } label: {
                    VStack(alignment: .leading,spacing: 5) {
                        Text(record.title).font(.headline)
                        Text(Date(timeIntervalSince1970: record.date),style: .date).font(.caption)
                        if let amount = record.amount { Text("\(Fmt.km(amount)) Ft") }
                        if let km = record.km { Text("\(Fmt.one(km)) km") }
                        Text(record.note).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).swipeActions { if writable { Button(role: .destructive) { deleting = record } label: { Image(systemName: "trash") } } }
            }
            if writable {
                Button(tr("Új közös bejegyzés", "New shared record")) { editing = FamilyRecord() }
                if car.owned && CarStore.activeId > 0 {
                    Button(tr("Átvétel a kiválasztott saját autóból", "Import from selected private car")) { if let section = FamilySection(rawValue: content.section) { export = FamilyExport.records(section) } }
                }
            }
            Text(tr("Ez a közös napló. A saját garázs adatait nem írja felül.", "This is the shared journal. It does not overwrite your private garage.")).font(.footnote).foregroundStyle(.secondary)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red); Button(tr("Frissítés", "Reload")) { Task { await reload() } } }
        }.navigationTitle(FamilySection(rawValue: content.section)?.title ?? car.name).disabled(busy)
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await reload() } } }
        .sheet(item: $editing) { value in FamilyRecordEditor(record: value,section: content.section) { value in
            var records = content.records.filter { $0.id != value.id }; records.append(value); try await save(records)
        } }
        .sheet(isPresented: Binding(get: { export != nil },set: { if !$0 { export = nil } })) {
            NavigationStack {
                List {
                    Text(tr("Forrás: \(AppSettings.shared.carName). A következő adatok hozzáadódnak a közös naplóhoz. Már átvett bejegyzéseknél a közös változat marad meg.", "Source: \(AppSettings.shared.carName). These records will be added. Existing shared versions are preserved."))
                    ForEach(export ?? []) { record in VStack(alignment: .leading) { Text(record.title); Text(record.note).font(.caption); if let amount = record.amount { Text("\(Fmt.km(amount)) Ft") }; if let km = record.km { Text("\(Fmt.one(km)) km") } } }
                }.navigationTitle(tr("Megosztás előnézete", "Sharing preview"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { export = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button(tr("Megosztás", "Share")) {
                        let additions = (export ?? []).filter { item in !content.records.contains { $0.id == item.id } }
                        Task { @MainActor in do { try await save(content.records + additions); export = nil } catch { self.error = familyError(error); export = nil } }
                    }.disabled(busy) }
                }
            }
        }
        .confirmationDialog(tr("Törlöd a közös bejegyzést?", "Delete the shared record?"),isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } })) {
            Button(tr("Törlés", "Delete"),role: .destructive) { let id = deleting?.id; Task { @MainActor in do { try await save(content.records.filter { $0.id != id }) } catch { self.error = familyError(error) } } }
        }
    }
    @MainActor private func save(_ records: [FamilyRecord]) async throws {
        guard !busy, verifiedWrite else { throw FamilyGarageError.permission }; busy = true; defer { busy = false }
        let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
        let response = try await CloudSync.shared.family("write",garage: car.id,data: ["section":content.section,"revision":content.revision,"records":data])
        struct Revision: Decodable { var revision: Int }
        content.revision = try JSONDecoder().decode(Revision.self,from: response).revision; content.records = records; error = nil
    }
    @MainActor private func reload() async {
        guard !busy else { return }
        busy = true; verifiedWrite = false
        defer { busy = false }
        do {
            let garages = try JSONDecoder().decode([FamilyCar].self,from: await CloudSync.shared.family("list"))
            guard let current = garages.first(where: { $0.id == car.id }), current.reads.contains(content.section) else {
                content.records = []; throw FamilyGarageError.permission
            }
            let values = try JSONDecoder().decode([FamilyContent].self,from: await CloudSync.shared.family("read",garage: car.id))
            guard let value = values.first(where: { $0.section == content.section }) else { content.records = []; throw FamilyGarageError.permission }
            content = value; verifiedWrite = current.writes.contains(content.section); error = nil
        } catch {
            if let failure = error as? FamilyGarageError, failure == .permission { content.records = []; editing = nil; export = nil }
            self.error = familyError(error)
        }
    }
}

struct FamilyRecordEditor: View {
    @State var record: FamilyRecord
    let section: String
    let save: (FamilyRecord) async throws -> Void
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("Megnevezés", "Title"),text: $record.title)
                DatePicker(tr("Dátum", "Date"),selection: Binding(get: { Date(timeIntervalSince1970: record.date) },set: { record.date = $0.timeIntervalSince1970 }),displayedComponents: .date)
                if section != "trips" { TextField(tr("Összeg (Ft)", "Amount (Ft)"),value: $record.amount,format: .number).keyboardType(.decimalPad) }
                if section != "costs" { TextField("km",value: $record.km,format: .number).keyboardType(.decimalPad) }
                TextEditor(text: $record.note).frame(minHeight: 120)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(tr("Közös bejegyzés", "Shared record")).disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(tr("Mentés", "Save")) {
                    Task { @MainActor in busy = true; defer { busy = false }; do {
                        guard record.title.count <= 200, record.amount.map({ $0.isFinite && $0 >= 0 }) ?? true, record.km.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw JourneyError.invalid }
                        try await save(record); dismiss()
                    } catch { self.error = familyError(error) } }
                }.disabled(busy || record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.interactiveDismissDisabled(busy)
        }
    }
}

struct FamilyPermissionsView: View {
    let car: FamilyCar
    @State private var reads: Set<String> = ["service"]
    @State private var writes: Set<String> = []
    @State private var token: String?
    @State private var members: [FamilyMember] = []
    @State private var busy = false
    @State private var error: String?
    @State private var revoke: FamilyMember?
    var body: some View {
        List {
            Section(tr("Új meghívó jogosultságai", "New invitation permissions")) {
                ForEach(FamilySection.allCases) { section in
                    Toggle(section.title,isOn: Binding(get: { reads.contains(section.rawValue) },set: { on in if on { reads.insert(section.rawValue) } else { reads.remove(section.rawValue); writes.remove(section.rawValue) } }))
                    if reads.contains(section.rawValue) { Toggle(tr("Szerkesztheti is", "Can also edit"),isOn: Binding(get: { writes.contains(section.rawValue) },set: { if $0 { writes.insert(section.rawValue) } else { writes.remove(section.rawValue) } })) }
                }
                Button(tr("Meghívókód készítése", "Create invitation code")) { action("invite",data: ["reads":Array(reads),"writes":Array(writes)]) }.disabled(reads.isEmpty)
                if let token { Text(token).textSelection(.enabled).font(.caption.monospaced()); ShareLink(item: token) { Text(tr("Kód megosztása", "Share code")) }; Text(tr("Egyszer használható, 7 napig érvényes. Csak a meghívott személynek küldd el.", "Single use, valid for 7 days. Send only to the intended person.")).font(.caption) }
                Button(tr("Függő meghívók visszavonása", "Cancel pending invitations"),role: .destructive) { action("cancel_invites") }
            }
            Section(tr("Tagok", "Members")) {
                ForEach(members) { member in
                    VStack(alignment: .leading,spacing: 8) {
                        Text(tr("Tag: ", "Member: ") + member.id.uuidString.prefix(8)).font(.headline)
                        ForEach(FamilySection.allCases) { section in
                            Picker(section.title,selection: Binding(get: { member.writes.contains(section.rawValue) ? 2 : member.reads.contains(section.rawValue) ? 1 : 0 },set: { level in
                                var r = Set(member.reads),w = Set(member.writes)
                                r.remove(section.rawValue); w.remove(section.rawValue)
                                if level > 0 { r.insert(section.rawValue) }; if level == 2 { w.insert(section.rawValue) }
                                if r.isEmpty { revoke = member } else { action("permissions",data: ["member":member.id.uuidString,"reads":Array(r),"writes":Array(w)]) }
                            })) { Text(tr("Rejtett", "Hidden")).tag(0); Text(tr("Olvasás", "Read")).tag(1); Text(tr("Szerkesztés", "Edit")).tag(2) }
                        }
                        Button(tr("Hozzáférés visszavonása", "Revoke access"),role: .destructive) { revoke = member }
                    }
                }
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(tr("Jogosultságok", "Permissions")).disabled(busy).task { await reload() }
        .confirmationDialog(tr("Visszavonod a tag hozzáférését?", "Revoke this member's access?"),isPresented: Binding(get: { revoke != nil },set: { if !$0 { revoke = nil } })) { Button(tr("Visszavonás", "Revoke"),role: .destructive) { if let revoke { action("revoke",data: ["member":revoke.id.uuidString]) } } }
    }
    @MainActor private func reload() async { do { members = try JSONDecoder().decode([FamilyMember].self,from: await CloudSync.shared.family("members",garage: car.id)) } catch { self.error = familyError(error) } }
    private func action(_ name: String,data: [String:Any] = [:]) {
        busy = true
        Task { @MainActor in defer { busy = false }; do {
            let response = try await CloudSync.shared.family(name,garage: car.id,data: data)
            if name == "invite" { struct Invite: Decodable { let token: String }; token = try JSONDecoder().decode(Invite.self,from: response).token }
            if name == "cancel_invites" { token = nil }
            error = nil; await reload()
        } catch { self.error = familyError(error) } }
    }
}
