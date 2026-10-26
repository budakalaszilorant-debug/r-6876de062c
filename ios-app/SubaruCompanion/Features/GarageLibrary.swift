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
    var serviceItemID: String?
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
    static func save(_ entry: JournalEntry, completedItem: String? = nil, intervalKm: Double? = nil) throws {
        try linkLegacyServices()
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.title.count <= 200, entry.parts.count <= 10000, entry.workshop.count <= 200,
              entry.date.timeIntervalSince1970.isFinite, entry.amount.isFinite, entry.amount >= 0,
              entry.km == nil || (entry.km!.isFinite && entry.km! >= 0),
              Set(entry.documents).isSubset(of: Set(documents().map(\.id))) else { throw JourneyError.invalid }
        try Database.shared.transaction {
            var values = journal()
            var saved = entry
            // The stored association is authoritative, never an incoming expense ID.
            let previous = values.first(where: { $0.id == entry.id })
            saved.expenseID = previous?.expenseID
            saved.serviceItemID = previous?.serviceItemID ?? completedItem
            if let item = saved.serviceItemID {
                guard entry.km != nil, Database.shared.query("SELECT COUNT(*) FROM service_plan WHERE car_id=? AND item=?",[CarStore.activeId,item],map: { $0.int(0) }).first == 1 else { throw JourneyError.invalid }
                if let intervalKm {
                    guard intervalKm.isFinite, (intervalKm == 0 || intervalKm >= 1000), intervalKm <= 500000 else { throw JourneyError.invalid }
                    try Database.shared.checkedExecute("UPDATE service_plan SET interval_km=? WHERE car_id=? AND item=?",[intervalKm,CarStore.activeId,item])
                }
            }
            let db = Database.shared
            if let id = saved.expenseID, db.query("SELECT COUNT(*) FROM expenses WHERE id=? AND car_id=?",[id,CarStore.activeId],map: { $0.int(0) }).first != 1 { saved.expenseID = nil }
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
            if let item = saved.serviceItemID { try refreshService(item, entries: values) }
        }
    }
    private static func refreshService(_ item: String, entries: [JournalEntry]) throws {
        let latest = entries.filter { $0.serviceItemID == item && $0.km != nil }.max { $0.date < $1.date }
        if let latest {
            try Database.shared.checkedExecute("INSERT OR REPLACE INTO service_done(car_id,item,last_km,last_date) VALUES(?,?,?,?)",[CarStore.activeId,item,latest.km,latest.date.timeIntervalSince1970])
        } else {
            try Database.shared.checkedExecute("DELETE FROM service_done WHERE car_id=? AND item=?",[CarStore.activeId,item])
        }
    }
    /// Recover exact associations from the previous app without guessing from titles alone.
    static func linkLegacyServices() throws {
        guard GaragePlus.load(Bool.self,key: "journal-service-links-v1") != true else { return }
        try Database.shared.transaction {
            var entries = journal()
            let rows = Database.shared.query("SELECT p.item,p.hu,p.en,d.last_km,d.last_date FROM service_done d JOIN service_plan p ON p.car_id=d.car_id AND p.item=d.item WHERE d.car_id=?",[CarStore.activeId]) { ($0.string(0),$0.string(1),$0.string(2),$0.double(3),$0.double(4)) }
            for (item,hu,en,km,date) in rows {
                let matches = entries.indices.filter { entries[$0].serviceItemID == nil && [hu,en].contains(entries[$0].title) && entries[$0].km == km && entries[$0].date.timeIntervalSince1970 == date }
                if matches.count == 1 { entries[matches[0]].serviceItemID = item }
            }
            try GaragePlus.save(entries,key: "service-journal")
            try GaragePlus.save(true,key: "journal-service-links-v1")
        }
    }
    static func importLegacy() throws {
        guard GaragePlus.load(Bool.self,key: "journal-legacy-imported") != true else { return }
        try Database.shared.transaction {
            var values = journal()
            let rows = Database.shared.query("SELECT p.hu,p.en,d.last_km,d.last_date,p.item FROM service_done d JOIN service_plan p ON p.car_id=d.car_id AND p.item=d.item WHERE d.car_id=?",[CarStore.activeId]) { (tr($0.string(0),$0.string(1)),$0.double(2),$0.double(3),$0.string(4)) }
            for (title,km,time,item) in rows where !values.contains(where: { $0.title == title && $0.date.timeIntervalSince1970 == time }) {
                values.append(JournalEntry(title: title,date: Date(timeIntervalSince1970: time),km: km,parts: tr("Korábbi szervizbejegyzés", "Earlier service record"),serviceItemID: item))
            }
            try GaragePlus.save(values,key: "service-journal")
            try GaragePlus.save(true,key: "journal-legacy-imported")
        }
    }
    static func removeEntry(_ id: UUID) throws {
        try linkLegacyServices()
        try Database.shared.transaction {
            let item = journal().first(where: { $0.id == id })?.serviceItemID
            if let expense = journal().first(where: { $0.id == id })?.expenseID {
                try Database.shared.checkedExecute("DELETE FROM expenses WHERE id=? AND car_id=?", [expense,CarStore.activeId])
            }
            let remaining = journal().filter { $0.id != id }
            try GaragePlus.save(remaining, key: "service-journal")
            if let item { try refreshService(item,entries: remaining) }
        }
    }
    static func removeExpense(_ id: Int) throws {
        let db = Database.shared
        guard db.query("SELECT COUNT(*) FROM expenses WHERE id=? AND car_id=?",[id,CarStore.activeId],map: { $0.int(0) }).first == 1 else { throw JourneyError.missing }
        try db.transaction {
            var entries = journal()
            for i in entries.indices where entries[i].expenseID == id {
                entries[i].expenseID = nil; entries[i].amount = 0
            }
            try GaragePlus.save(entries,key: "service-journal")
            try db.checkedExecute("DELETE FROM expenses WHERE id=? AND car_id=?",[id,CarStore.activeId])
        }
    }
}
