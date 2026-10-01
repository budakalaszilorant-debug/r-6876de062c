import WidgetKit
import SwiftUI

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(voltage: 14.1, coolant: 88, engineRunning: true, updated: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // Az app kér frissítést, amikor új adat van; ez csak tartalék.
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

private enum W {
    static let bg = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let ok = Color(red: 0.24, green: 0.84, blue: 0.47)
    static let warn = Color(red: 1.00, green: 0.76, blue: 0.20)
    static let bad = Color(red: 1.00, green: 0.30, blue: 0.27)
    static let accent = Color(red: 0.25, green: 0.56, blue: 1.00)

    static func voltageColor(_ s: WidgetSnapshot) -> Color {
        guard let v = s.voltage else { return .white }
        if v > 15.0 { return bad }
        if s.engineRunning { return v >= 13.8 ? ok : (v >= 12.4 ? warn : bad) }
        return v >= 12.4 ? ok : (v >= 11.8 ? warn : bad)
    }

    static func coolantColor(_ s: WidgetSnapshot) -> Color {
        guard let c = s.coolant else { return .white }
        if c >= 105 { return bad }
        return c >= 88 ? ok : accent
    }

    static func text(_ v: Double?, _ format: String) -> String {
        v.map { String(format: format, $0) } ?? "—"
    }
}

struct SubaruWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: lockScreen
        default: home
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = entry.snapshot {
                row(icon: "bolt.fill", value: W.text(s.voltage, "%.1f"), unit: "V", color: W.voltageColor(s))
                row(icon: "thermometer.medium", value: W.text(s.coolant, "%.0f"), unit: "°C", color: W.coolantColor(s))
                Spacer(minLength: 0)
                Text(s.updated, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Image(systemName: "car")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                Text("Subaru")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(icon: String, value: String, unit: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 16)
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Subaru").font(.system(size: 13, weight: .semibold))
            if let s = entry.snapshot {
                Text("\(W.text(s.voltage, "%.1f")) V  ·  \(W.text(s.coolant, "%.0f"))°C")
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                Text(s.updated, style: .time).font(.system(size: 11)).opacity(0.7)
            } else {
                Text("—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// iOS 17-től kötelező a containerBackground, előtte sima háttér.
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(for: .widget) { color }
        } else {
            padding(14).background(color)
        }
    }
}

@main
struct SubaruWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SubaruWidget", provider: SnapshotProvider()) { entry in
            SubaruWidgetView(entry: entry)
                .widgetBackground(W.bg)
        }
        .configurationDisplayName("Subaru")
        .description("Akkumulátor feszültség és hűtővíz hőfok.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
