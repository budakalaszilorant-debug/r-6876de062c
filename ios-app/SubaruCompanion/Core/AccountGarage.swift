import Foundation
import CryptoKit

/// Inactive garages never enter exports or queries against the active car tables.
/// Swapping the active tables and recording their owner is one SQLite transaction.
enum AccountGarage {
    static let personalEmail = "balazskiss01@proton.me"
    static var generation = UUID()
    static var current: String? {
        Database.shared.query("SELECT owner FROM account_state WHERE id=1") { $0.string(0) }.first
    }
    static var exportNamespace: String {
        SHA256.hash(data: Data((current ?? "legacy").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func activate(owner: String?, verifiedEmail: String?) throws {
        let db = Database.shared
        let destination = owner ?? "guest"
        guard current != destination else { return }
        let source = current ?? "legacy"
        guard let outgoing = Backup.makeData() else { throw Backup.RestoreError.unreadable }
        let existing = db.query("SELECT payload FROM account_garages WHERE owner=?", [destination]) { $0.string(0) }.first
        let personal = owner != nil && verifiedEmail?.lowercased() == personalEmail
        let claimed = db.query("SELECT owner FROM account_legacy_claim LIMIT 1") { $0.string(0) }.first
        var claimLegacy = false
        var incoming: Data
        if let existing {
            incoming = Data(existing.utf8)
        } else if personal && claimed == nil {
            if source == "legacy" { incoming = outgoing; claimLegacy = true }
            else if let legacy = db.query("SELECT payload FROM account_garages WHERE owner='legacy'", map: { $0.string(0) }).first {
                incoming = Data(legacy.utf8); claimLegacy = true
            } else { incoming = try empty() }
        } else { incoming = try empty() }
        _ = try Backup.restore(data: incoming, beforeCommit: {
            try db.checkedExecute("INSERT INTO account_garages(owner,payload) VALUES(?,?) ON CONFLICT(owner) DO UPDATE SET payload=excluded.payload", [source, String(decoding: outgoing, as: UTF8.self)])
            try db.checkedExecute("INSERT OR REPLACE INTO account_state(id,owner) VALUES(1,?)", [destination])
            if claimLegacy { try db.checkedExecute("INSERT INTO account_legacy_claim(owner) VALUES(?)", [destination]) }
        })
        generation = UUID()
    }

    static func seedPersonalCars(verifiedEmail: String?) {
        guard verifiedEmail?.lowercased() == personalEmail, CarStore.all().isEmpty,
              current != "guest", current != nil else { return }
        let first = CarStore.create(from: .fiesta)
        _ = CarStore.create(from: .combo)
        AppSettings.shared.activate(first)
    }

    private static func empty() throws -> Data {
        let tables = Dictionary(uniqueKeysWithValues: Backup.tables.map { ($0, [[String: Any]]()) })
        return try JSONSerialization.data(withJSONObject: ["version": 2, "tables": tables,
            "settings": ["onboarded": true, "activeCarId": 0, "lang": UserDefaults.standard.string(forKey: "lang") ?? "hu"], "carState": [:]])
    }
}
