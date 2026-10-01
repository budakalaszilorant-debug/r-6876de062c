import ActivityKit
import Foundation

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
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        activity = try? Activity.request(attributes: DriveActivityAttributes(started: tripStart),
                                         content: content, pushType: nil)
        lastState = state
        lastUpdate = Date()
    }

    func update(_ state: DriveActivityAttributes.ContentState) {
        guard let activity, state != lastState, Date().timeIntervalSince(lastUpdate) >= 3 else { return }
        lastState = state
        lastUpdate = Date()
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        Task { await activity.update(content) }
    }

    func end() {
        activity = nil
        lastState = nil
        Task {
            for a in Activity<DriveActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
