import SwiftUI

/// Átvilágítás képernyő: egy gombnyomásra jelentés az autó állapotáról, megosztható szövegként.
struct HealthCheckView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var report: HealthReport?

    private var canRun: Bool { monitor.isLive && monitor.packet?.ecu == true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report {
                        verdictCard(report)
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(report.items) { item in
                                    row(item)
                                    if item.id != report.items.last?.id {
                                        Divider().overlay(Theme.stroke).padding(.leading, 44)
                                    }
                                }
                            }
                        }
                        ShareLink(item: report.text) {
                            Label(tr("Jelentés megosztása", "Share report"), systemImage: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }

                    PrimaryButton(title: report == nil ? tr("Átvilágítás indítása", "Start check")
                                                       : tr("Újra futtatás", "Run again"),
                                  icon: "stethoscope") { run() }
                        .opacity(canRun ? 1 : 0.4)
                        .disabled(!canRun)

                    if !canRun {
                        Text(tr("Csatlakozz az autóhoz, és kapcsold rá a gyújtást (jobb, ha jár a motor).",
                                "Connect to the car and switch the ignition on (the engine running is best)."))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.warn)
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .onAppear {
                // Képernyőképhez: a jelentés magától lefut
                if UserDefaults.standard.bool(forKey: "uiHealth"), report == nil { run() }
            }
            .navigationTitle(tr("Átvilágítás", "Health check"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } }
            }
        }
    }

    private func run() {
        guard let p = monitor.packet else { return }
        report = HealthCheck.build(from: p, carName: settings.carName)
        Haptics.success()
    }

    private func color(_ level: HealthItem.Level) -> Color {
        switch level {
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        case .info: return Theme.text3
        }
    }

    private func icon(_ level: HealthItem.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func verdictCard(_ r: HealthReport) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: icon(r.worst))
                    .font(.system(size: 28))
                    .foregroundStyle(color(r.worst))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.verdict).font(.system(size: 20, weight: .semibold))
                    Text(r.carName).font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
            }
        }
    }

    private func row(_ item: HealthItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item.level))
                .font(.system(size: 16))
                .foregroundStyle(color(item.level))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .semibold))
                Text(item.detail).font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
