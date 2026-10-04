import ActivityKit
import SwiftUI
import WidgetKit

struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(context.state.carName, systemImage: symbol(context.state)).font(.headline)
                    Spacer()
                    Text(title(context)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    mainValue(context).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer()
                    if context.state.mode != "parking" {
                        Text(context.isStale ? "—" : String(format: "%.1f km", context.state.tripKm)).font(.headline)
                    }
                }
                if context.state.mode == "warmup", !context.isStale {
                    ProgressView(value: context.state.progress).tint(.cyan)
                    if let eta = context.state.etaMinutes {
                        Text(context.state.hu ? "Kb. \(eta) perc a beállított hőfokig" : "About \(eta) min to target temperature").font(.caption)
                    }
                }
            }
            .padding(16).activityBackgroundTint(.black.opacity(0.85)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.carName, systemImage: symbol(context.state)).font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) { Text(title(context)).font(.caption).foregroundStyle(.secondary) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        mainValue(context).font(.title2.monospacedDigit())
                        Spacer()
                        if context.state.mode == "warmup", !context.isStale {
                            ProgressView(value: context.state.progress).tint(.cyan).frame(width: 80)
                        } else if context.state.mode == "drive", !context.isStale {
                            Text(String(format: "%.1f km", context.state.tripKm)).font(.callout.monospacedDigit())
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.isStale && context.state.mode != "parking" ? "antenna.radiowaves.left.and.right.slash" : symbol(context.state)).foregroundStyle(.cyan)
            } compactTrailing: {
                mainValue(context, compact: true).font(.caption.monospacedDigit()).frame(maxWidth: 62)
            } minimal: {
                Image(systemName: symbol(context.state)).foregroundStyle(.cyan)
            }
        }
    }

    private func symbol(_ state: DriveActivityAttributes.ContentState) -> String {
        state.mode == "parking" ? "parkingsign.circle.fill" : state.mode == "warmup" ? "thermometer.medium" : "car.fill"
    }

    private func title(_ context: ActivityViewContext<DriveActivityAttributes>) -> String {
        let s = context.state
        if s.mode == "parking" { return s.hu ? "Parkolóóra" : "Parking timer" }
        if context.isStale { return s.hu ? "Nincs friss adat" : "Data unavailable" }
        return s.mode == "warmup" ? (s.hu ? "Bemelegedés" : "Warming up") : (s.hu ? "Úton" : "Driving")
    }

    @ViewBuilder private func mainValue(_ context: ActivityViewContext<DriveActivityAttributes>, compact: Bool = false) -> some View {
        let s = context.state
        if s.mode == "parking", let end = s.parkingEnd {
            if context.isStale { Text(s.hu ? "Lejárt" : "Expired") }
            else { Text(timerInterval: context.attributes.started...max(context.attributes.started, end), countsDown: true) }
        } else if context.isStale {
            Text("—")
        } else if s.mode == "warmup" {
            Text(s.coolant.map { "\($0)°C" } ?? "—")
        } else {
            Text(compact ? "\(s.speed)" : "\(s.speed) km/h")
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
