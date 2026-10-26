import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import QuickLook

struct GarageLibraryView: View {
    @State private var documents: [GarageDocument] = []
    @State private var search = ""
    @State private var editing: GarageDocument?
    @State private var error: String?
    var body: some View {
        List {
            if documents.isEmpty { Text(tr("Számlák, garanciák, alkatrészszámok és saját feljegyzések egy helyen.", "Receipts, warranties, part numbers and notes in one place.")) }
            ForEach(documents.filter { search.isEmpty || ($0.title + $0.note + $0.category).localizedCaseInsensitiveContains(search) }) { document in
                Button { editing = document } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(document.title, systemImage: document.data == nil ? "note.text" : "doc.richtext")
                        Text(document.note).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                        Text(document.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }.swipeActions { Button(role: .destructive) { run { try GarageLibrary.removeDocument(document.id) } } label: { Label(tr("Törlés", "Delete"),systemImage: "trash") } }
            }
        }.searchable(text: $search).navigationTitle(tr("Dokumentumtár", "Documents"))
        .toolbar { Button { editing = GarageDocument() } label: { Image(systemName: "plus") }.accessibilityLabel(tr("Dokumentum hozzáadása", "Add document")) }
        .onAppear { documents = GarageLibrary.documents() }
        .sheet(item: $editing, onDismiss: { documents = GarageLibrary.documents() }) { DocumentEditor(document: $0) }
        .alert(tr("Nem sikerült", "Could not complete"), isPresented: Binding(get: { error != nil },set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func run(_ action: () throws -> Void) { do { try action(); documents = GarageLibrary.documents() } catch { self.error = error.localizedDescription } }
}

struct DocumentEditor: View {
    @State var document: GarageDocument
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var preview: URL?
    @State private var error: String?
    @State private var loading = false
    private let generation = AccountGarage.generation
    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("Megnevezés", "Title"), text: $document.title)
                Picker(tr("Típus", "Type"), selection: $document.category) {
                    Text(tr("Számla", "Receipt")).tag("receipt")
                    Text(tr("Garancia", "Warranty")).tag("warranty")
                    Text(tr("Alkatrész / specifikáció", "Part / specification")).tag("spec")
                    Text(tr("Egyéb", "Other")).tag("other")
                }
                DatePicker(tr("Dátum", "Date"), selection: $document.date, displayedComponents: .date)
                Section(tr("Feljegyzés, cikkszám, feltételek", "Notes, part number, terms")) { TextEditor(text: $document.note).frame(minHeight: 110) }
                Section {
                    Button(tr("PDF vagy kép kiválasztása", "Choose PDF or image")) { importing = true }
                    PhotosPicker(selection: $photo, matching: .images) { Text(tr("Fotó hozzáadása", "Add photo")) }
                    if let filename = document.filename {
                        Button(filename) { previewAttachment() }
                        Button(tr("Melléklet eltávolítása", "Remove attachment"),role: .destructive) { document.data = nil; document.filename = nil }
                    }
                } footer: { Text(tr("Fájlonként legfeljebb 2 MB; autónként összesen 6 MB. A mellékletek a mentés részei.", "Up to 2 MB per file and 6 MB per car. Attachments are included in backups.")) }
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(tr("Dokumentum", "Document"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(tr("Mentés", "Save")) {
                    do { guard generation == AccountGarage.generation else { return }; try GarageLibrary.save(document); dismiss() } catch { self.error = error.localizedDescription }
                }.disabled(loading || document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf,.jpeg,.png]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 2_000_000 else { throw JourneyError.tooLarge }
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000 else { throw JourneyError.tooLarge }
                document.data = data; document.filename = url.lastPathComponent
            } catch { self.error = error.localizedDescription }
        }.onChange(of: photo) { value in
            Task { @MainActor in
                loading = true; defer { loading = false }
                do {
                    guard let data = try await value?.loadTransferable(type: Data.self), let image = UIImage(data: data), generation == AccountGarage.generation else { return }
                    let scale = min(1,1600 / max(image.size.width,image.size.height))
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let compressed = UIGraphicsImageRenderer(size: CGSize(width: image.size.width*scale,height: image.size.height*scale),format: format).image { _ in image.draw(in: CGRect(x: 0,y: 0,width: image.size.width*scale,height: image.size.height*scale)) }.jpegData(compressionQuality: 0.8)
                    guard let compressed, compressed.count <= 2_000_000 else { throw JourneyError.tooLarge }
                    document.data = compressed; document.filename = "photo.jpg"
                } catch { self.error = error.localizedDescription }
            }
        }.quickLookPreview($preview)
        .onDisappear { if let preview { try? FileManager.default.removeItem(at: preview) } }
    }
    private func previewAttachment() {
        guard let data = document.data, let name = document.filename else { return }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["pdf","png","jpg","jpeg"].contains(ext) else { return }
        do {
            if let preview { try? FileManager.default.removeItem(at: preview) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try data.write(to: url,options: [.atomic,.completeFileProtection]); preview = url
        } catch { self.error = error.localizedDescription }
    }
}

struct ServiceJournalView: View {
    @State private var entries: [JournalEntry] = []
    @State private var search = ""
    @State private var editing: JournalEntry?
    @State private var deleting: JournalEntry?
    @State private var error: String?
    var body: some View {
        List {
            if entries.isEmpty { Text(tr("Rögzítsd a javítást, alkatrészeket, műhelyt és csatold a számlát.", "Record repairs, parts, workshop and attach the receipt.")) }
            ForEach(entries.filter { search.isEmpty || ($0.title + $0.parts + $0.workshop).localizedCaseInsensitiveContains(search) }) { entry in
                Button { editing = entry } label: {
                    VStack(alignment: .leading,spacing: 6) {
                        Text(entry.title).font(.headline)
                        Text("\(Fmt.date(entry.date)) · \(entry.km.map(Fmt.km) ?? "—") km").font(.caption).foregroundStyle(.secondary)
                        Text(entry.workshop + (entry.amount > 0 ? " · \(Fmt.km(entry.amount)) Ft" : "")).font(.subheadline)
                        if !entry.documents.isEmpty { Label("\(entry.documents.count)",systemImage: "paperclip").font(.caption) }
                    }
                }.swipeActions { Button(role: .destructive) { deleting = entry } label: { Image(systemName: "trash") } }
            }
            Section { NavigationLink(tr("Szervizterv és esedékességek", "Schedule and due dates")) { ServiceView() } }
        }.navigationTitle(tr("Szervizkönyv", "Service book")).searchable(text: $search)
        .toolbar { Button { editing = JournalEntry() } label: { Image(systemName: "plus") } }
        .onAppear { do { try GarageLibrary.importLegacy(); entries = GarageLibrary.journal() } catch { self.error = error.localizedDescription } }
        .sheet(item: $editing,onDismiss: { entries = GarageLibrary.journal() }) { JournalEditor(entry: $0) }
        .confirmationDialog(tr("A szerviz és a hozzá kapcsolt költség törlése?", "Delete this service and its linked expense?"),isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } })) {
            Button(tr("Törlés", "Delete"),role: .destructive) { do { if let deleting { try GarageLibrary.removeEntry(deleting.id) }; entries = GarageLibrary.journal() } catch { self.error = error.localizedDescription } }
        }
        .alert(tr("Nem sikerült", "Could not complete"),isPresented: Binding(get: { error != nil },set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
}

struct JournalEditor: View {
    @State var entry: JournalEntry
    @State private var error: String?
    @State private var addDocument = false
    @State private var documents = GarageLibrary.documents()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("Elvégzett munka", "Work performed"),text: $entry.title)
                DatePicker(tr("Dátum", "Date"),selection: $entry.date,displayedComponents: .date)
                TextField(tr("Kilométeróra", "Odometer"),value: $entry.km,format: .number).keyboardType(.decimalPad)
                TextField(tr("Műhely / szerelő", "Workshop / mechanic"),text: $entry.workshop)
                Section(tr("Alkatrészek és megjegyzések", "Parts and notes")) { TextEditor(text: $entry.parts).frame(minHeight: 100) }
                Section { TextField(tr("Összeg (Ft)", "Amount (Ft)"),value: $entry.amount,format: .number).keyboardType(.decimalPad) } footer: { Text(tr("A kiadásokba egyszer kerül be, és szerkesztéskor együtt frissül.", "Added once to expenses and updated together when edited.")) }
                Section(tr("Mellékletek", "Attachments")) {
                    ForEach(documents) { document in
                        Toggle(document.title,isOn: Binding(get: { entry.documents.contains(document.id) },set: { value in entry.documents.removeAll { $0 == document.id }; if value { entry.documents.append(document.id) } }))
                    }
                    Button(tr("Új dokumentum", "New document")) { addDocument = true }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(tr("Szerviz", "Service"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(tr("Mentés", "Save")) { do { try GarageLibrary.save(entry); dismiss() } catch { self.error = error.localizedDescription } }.disabled(entry.title.isEmpty) }
            }
        }.sheet(isPresented: $addDocument,onDismiss: { documents = GarageLibrary.documents() }) { DocumentEditor(document: GarageDocument()) }
    }
}
