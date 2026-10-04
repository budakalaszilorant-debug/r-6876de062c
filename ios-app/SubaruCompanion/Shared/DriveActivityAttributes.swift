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
        var carID: Int = 0
        var carName: String = "Garázs"
        var mode: String = "drive"
        var progress: Double = 0
        var etaMinutes: Int?
        var parkingEnd: Date?
        var hu: Bool = true
    }

    var started: Date
}
