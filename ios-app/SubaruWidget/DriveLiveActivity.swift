import ActivityKit
import SwiftUI
import WidgetKit

/// Menet közbeni élő tevékenység: zárolási képernyő és Dynamic Island.
struct DriveLiveActivity: Widget {
    private let accent = Color(red: 0.25, green: 0.56, blue: 1.00)
    private let ok = Color(red: 0.24, green: 0.84, blue: 0.47)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            lockScreen(context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    value("\(context.state.speed)", "km/h", .white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    value(context.state.coolant.map { "\($0)" } ?? "—", "°C", context.state.warm ? ok : accent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(bottomLine(context.state))
                        .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            } compactLeading: {
                Text("\(context.state.speed)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            } compactTrailing: {
                Text(context.state.coolant.map { "\($0)°" } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(context.state.warm ? ok : accent)
            } minimal: {
                Text("\(context.state.speed)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
    }

    private func bottomLine(_ s: DriveActivityAttributes.ContentState) -> String {
        let km = String(format: "%.1f km", s.tripKm)
        guard let c = s.consumption else { return km }
        return km + String(format: "  ·  %.1f l/100", c)
    }

    private func lockScreen(_ s: DriveActivityAttributes.ContentState) -> some View {
        HStack(alignment: .center) {
            value("\(s.speed)", "km/h", .white)
            Spacer()
            VStack(spacing: 2) {
                Text("Subaru")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(bottomLine(s))
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            value(s.coolant.map { "\($0)" } ?? "—", "°C", s.warm ? ok : accent)
        }
    }

    private func value(_ text: String, _ unit: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(text)
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

@main
struct SubaruWidgets: WidgetBundle {
    var body: some Widget {
        SubaruWidget()
        DriveLiveActivity()
    }
}
