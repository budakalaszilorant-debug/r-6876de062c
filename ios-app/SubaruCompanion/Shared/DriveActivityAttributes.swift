import ActivityKit
import Foundation

/// Élő tevékenység (zárolási képernyő / Dynamic Island) adatai menet közben.
struct DriveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speed: Int
        var coolant: Int?
        var warm: Bool
        var tripKm: Double
        var consumption: Double?
    }

    var started: Date
}
