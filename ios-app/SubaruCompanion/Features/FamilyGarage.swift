import Foundation

enum FamilyGarageError: LocalizedError, Equatable {
    case setup, permission, changed, unavailable
    var errorDescription: String? {
        switch self {
        case .setup: return tr("A családi garázs szerveroldali frissítése még nincs telepítve. A saját garázs mentése ettől függetlenül működik.", "The family garage server update is not installed. Private garage backups are unaffected.")
        case .permission: return tr("Ehhez nincs hozzáférésed, vagy a meghívó lejárt / már felhasználták.", "Access is unavailable, or the invitation has expired / already been used.")
        case .changed: return tr("Közben más is módosította ezt a naplót. Zárd be a szerkesztőt, frissítsd az adatokat, majd add hozzá a változtatásod.", "Someone else changed this journal. Close the editor, reload, then apply your changes.")
        case .unavailable: return tr("Nem sikerült kapcsolódni a közös garázshoz. Az adatok megmaradtak; próbáld újra később.", "Could not access the shared garage. Your records are preserved; try again later.")
        }
    }
}

enum FamilySection: String, CaseIterable, Identifiable, Codable {
    case service, costs, trips
    var id: String { rawValue }
    var title: String { switch self { case .service: return tr("Szervizek", "Services"); case .costs: return tr("Költségek", "Costs"); case .trips: return tr("Utak", "Trips") } }
}
struct FamilyCar: Decodable, Identifiable {
    var id: UUID
    var name: String
    var owned: Bool
    var reads: [String]
    var writes: [String]
}
struct FamilyRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var title = ""
    var date = Date().timeIntervalSince1970
    var amount: Double?
    var km: Double?
    var note = ""
}
struct FamilyContent: Decodable, Identifiable {
    var section: String
    var revision: Int
    var records: [FamilyRecord]
    var id: String { section }
}
struct FamilyMember: Decodable, Identifiable {
    var id: UUID
    var reads: [String]
    var writes: [String]
}

enum FamilyExport {
    /// Explicit export only. No VIN, coordinates, place names, photos or whole backups.
    static func records(_ section: FamilySection) -> [FamilyRecord] {
        // Stable per-car namespace avoids collisions between local numeric IDs.
        let source = GaragePlus.load(String.self,key: "family-export-source") ?? UUID().uuidString
        do { try GaragePlus.save(source,key: "family-export-source") } catch { return [] }
        return exported(section).map { item in var value = item; value.id = source + "-" + value.id; return value }
    }
    private static func exported(_ section: FamilySection) -> [FamilyRecord] {
        switch section {
        case .service:
            return GarageLibrary.journal().map { FamilyRecord(id: $0.id.uuidString,title: $0.title,date: $0.date.timeIntervalSince1970,amount: $0.amount,km: $0.km,note: $0.parts + "\n" + $0.workshop) }
        case .costs:
            return ExpenseStore.all().map { FamilyRecord(id: "expense-\($0.id)",title: $0.category.label,date: $0.date.timeIntervalSince1970,amount: $0.amount,note: $0.note) } + FuelStore.all().map { FamilyRecord(id: "fuel-\($0.id)",title: tr("Tankolás", "Refuelling"),date: $0.date.timeIntervalSince1970,amount: $0.cost,note: "\(Fmt.one($0.liters)) l") }
        case .trips:
            return TripStore.all().map { FamilyRecord(id: "trip-\($0.id)",title: tr("Rögzített út", "Recorded drive"),date: $0.start.timeIntervalSince1970,km: $0.distanceKm,note: DriveReportFormat.duration($0.duration)) }
        }
    }
}
