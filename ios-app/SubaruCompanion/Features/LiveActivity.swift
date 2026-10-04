import ActivityKit
import Foundation
import UIKit

/// Élő tevékenység kezelése. Megkötés: az iOS csak akkor engedi elindítani, amikor az app elöl van,
/// ezért út közben az app megnyitásakor indul; utána a háttérből is frissül.
final class DriveActivity {
    static let shared = DriveActivity()

    private var activity: Activity<DriveActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: DriveActivityAttributes.ContentState?

    private init() {
        // Előző futásból megmaradt tevékenység átvétele
        activity = Activity<DriveActivityAttributes>.activities.first
    }

    var isActive: Bool { activity != nil }

    func start(tripStart: Date, state: DriveActivityAttributes.ContentState) {
        if let current = activity, current.activityState == .ended || current.activityState == .dismissed { activity = nil }
        if let current = activity, current.content.state.carID != state.carID { end() }
        if activity != nil { update(state, force: true); return }
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: state.parkingEnd ?? Date().addingTimeInterval(state.mode == "parked" ? 600 : 45))
        activity = try? Activity.request(attributes: DriveActivityAttributes(started: tripStart),
                                         content: content, pushType: nil)
        lastState = state
        lastUpdate = Date()
    }

    func update(_ state: DriveActivityAttributes.ContentState, force: Bool = false) {
        guard let activity, activity.content.state.carID == state.carID else { return }
        let age = Date().timeIntervalSince(lastUpdate)
        guard force || (age >= 3 && (state != lastState || age >= 25)) else { return }
        lastState = state
        lastUpdate = Date()
        let content = ActivityContent(state: state, staleDate: state.parkingEnd ?? Date().addingTimeInterval(state.mode == "parked" ? 600 : 45))
        Task { await activity.update(content) }
    }

    func parking(until end: Date) {
        let s = AppSettings.shared
        guard s.featLiveActivity, end > Date() else { return }
        let state = DriveActivityAttributes.ContentState(speed: 0, coolant: nil, warm: false,
            tripKm: 0, consumption: nil, carID: s.activeCarId, carName: s.carName,
            mode: "parking", parkingEnd: end, hu: s.language == .hu)
        start(tripStart: Date(), state: state)
    }

    /// Keep the existing activity available for a parking-timer action from a notification.
    /// Starting a new one in the background is not permitted by iOS.
    func parked() {
        guard let activity else { return }
        var state = activity.content.state
        state.mode = "parked"
        state.speed = nil
        state.coolant = nil
        state.etaMinutes = nil
        update(state, force: true)
    }

    func endParking() {
        if ["parking", "parked"].contains(activity?.content.state.mode ?? "") { end() }
    }

    func end() {
        let ending = Activity<DriveActivityAttributes>.activities
        activity = nil
        lastState = nil
        Task {
            for a in ending {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
