import Foundation

struct GarageDocument: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var category = "receipt"
    var note = ""
    var date = Date()
    var filename: String?
    var data: Data?
}

struct JournalEntry: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var date = Date()
    var km: Double?
    var parts = ""
    var workshop = ""
    var amount = 0.0
    var documents: [UUID] = []
    var expenseID: Int?
}

enum GarageLibrary {
    static func documents() -> [GarageDocument] {
        (GaragePlus.load([GarageDocument].self, key: "documents") ?? []).sorted { $0.date > $1.date }
    }
    static func journal() -> [JournalEntry] {
        (GaragePlus.load([JournalEntry].self, key: "service-journal") ?? []).sorted { $0.date > $1.date }
    }
    static func save(_ document: GarageDocument) throws {
        guard !document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.title.count <= 200, document.note.count <= 10000 else { throw JourneyError.invalid }
        var values = documents().filter { $0.id != document.id }; values.append(document)
        guard (document.data?.count ?? 0) <= 2_000_000,
              values.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= 6_000_000 else { throw JourneyError.tooLarge }
        try Database.shared.transaction {
            try GaragePlus.save(values, key: "documents")
            guard let backup = Backup.makeData(), backup.count < 18_000_000 else { throw JourneyError.tooLarge }
        }
    }
    static func removeDocument(_ id: UUID) throws {
        try Database.shared.transaction {
            try GaragePlus.save(documents().filter { $0.id != id }, key: "documents")
            var entries = journal()
            for i in entries.indices { entries[i].documents.removeAll { $0 == id } }
            try GaragePlus.save(entries, key: "service-journal")
        }
    }
    static func save(_ entry: JournalEntry, completedItem: String? = nil) throws {
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.title.count <= 200, entry.amount.isFinite, entry.amount >= 0,
              entry.km == nil || (entry.km!.isFinite && entry.km! >= 0),
              Set(entry.documents).isSubset(of: Set(documents().map(\.id))) else { throw JourneyError.invalid }
        try Database.shared.transaction {
            if let completedItem {
                try Database.shared.checkedExecute("INSERT OR REPLACE INTO service_done(car_id,item,last_km,last_date) VALUES(?,?,?,?)", [CarStore.activeId,completedItem,entry.km,entry.date.timeIntervalSince1970])
            }
            var values = journal()
            var saved = entry
            // The stored association is authoritative, never an incoming expense ID.
            saved.expenseID = values.first(where: { $0.id == entry.id })?.expenseID
            let db = Database.shared
            if let id = saved.expenseID {
                try db.checkedExecute("UPDATE expenses SET date=?,amount=?,note=? WHERE id=? AND car_id=?",
                    [entry.date.timeIntervalSince1970, entry.amount, entry.title, id, CarStore.activeId])
            } else if entry.amount > 0 {
                try db.checkedExecute("INSERT INTO expenses(car_id,date,category,amount,note) VALUES(?,?,'service',?,?)",
                    [CarStore.activeId, entry.date.timeIntervalSince1970, entry.amount, entry.title])
                saved.expenseID = db.query("SELECT last_insert_rowid()") { $0.int(0) }.first
            }
            values.removeAll { $0.id == entry.id }; values.append(saved)
            try GaragePlus.save(values, key: "service-journal")
        }
    }
    static func importLegacy() throws {
        guard GaragePlus.load(Bool.self,key: "journal-legacy-imported") != true else { return }
        try Database.shared.transaction {
            var values = journal()
            let rows = Database.shared.query("SELECT p.hu,p.en,d.last_km,d.last_date FROM service_done d JOIN service_plan p ON p.car_id=d.car_id AND p.item=d.item WHERE d.car_id=?",[CarStore.activeId]) { (tr($0.string(0),$0.string(1)),$0.double(2),$0.double(3)) }
            for (title,km,time) in rows where !values.contains(where: { $0.title == title && $0.date.timeIntervalSince1970 == time }) {
                values.append(JournalEntry(title: title,date: Date(timeIntervalSince1970: time),km: km,parts: tr("Korábbi szervizbejegyzés", "Earlier service record")))
            }
            try GaragePlus.save(values,key: "service-journal")
            try GaragePlus.save(true,key: "journal-legacy-imported")
        }
    }
    static func removeEntry(_ id: UUID) throws {
        try Database.shared.transaction {
            if let expense = journal().first(where: { $0.id == id })?.expenseID {
                try Database.shared.checkedExecute("DELETE FROM expenses WHERE id=? AND car_id=?", [expense,CarStore.activeId])
            }
            try GaragePlus.save(journal().filter { $0.id != id }, key: "service-journal")
        }
    }
}
