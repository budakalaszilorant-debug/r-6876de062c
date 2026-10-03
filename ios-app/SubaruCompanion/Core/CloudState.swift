import Foundation
import CryptoKit

/// Pure sync decisions, shared with the command-line regression tests.
enum CloudDecision: Equatable {
    case link, upload, download, conflict, unchanged

    static func decide(linked: Bool, base: Int64, baseHash: String?, localHash: String,
                       remoteRevision: Int64?, remoteHash: String?) -> Self {
        guard linked else { return .link }
        guard let remoteRevision else { return base == 0 ? .upload : .conflict }
        guard remoteRevision >= base else { return .conflict }
        if localHash == remoteHash { return .unchanged }
        if base == remoteRevision { return .upload }
        if baseHash == localHash { return .download }
        return .conflict
    }
}

enum CloudPayload {
    static let maximumBytes = 20 * 1024 * 1024

    /// Device selection and generation time are not edits to the garage.
    static func canonical(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["tables"] is [String: Any] else { throw Backup.RestoreError.wrongFormat }
        root["created"] = 0
        if var settings = root["settings"] as? [String: Any] {
            settings.removeValue(forKey: "activeCarId")
            settings.removeValue(forKey: "onboarded")
            root["settings"] = settings
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func hash(_ data: Data) throws -> String {
        SHA256.hash(data: try canonical(data)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudVersion: Decodable, Identifiable {
    let revision: Int64
    let fingerprint: String
    let created_at: Date
    let device_name: String
    let car_count: Int
    let trip_count: Int
    var id: Int64 { revision }
}

/// One checkpoint per account AND server; never shared between accounts or included in exports.
struct CloudCheckpoint: Codable {
    var revision: Int64 = 0
    var fingerprint: String?
    var lastSync: Date?
}
