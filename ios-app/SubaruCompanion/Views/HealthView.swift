import SwiftUI

/// Átvilágítás: 20 mp-es mérés élő adatokból, pontszám, csoportosított eredmény, megosztható jelentés.
struct HealthCheckView: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    enum Phase { case idle, measuring, done }
    @State private var phase: Phase = .idle
    @State private var samples = HealthSamples()
    @State private var started = Date()
    @State private var progress = 0.0
    @State private var report: HealthReport?
    @State private var timer: Timer?

    private var canRun: Bool { monitor.isLive && monitor.packet?.ecu == true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .idle: intro
                    case .measuring: measuring
                    case .done: if let report { result(report) }
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle(tr("Átvilágítás", "Health check"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } }
            }
            .onReceive(monitor.$packet) { p in
                guard phase == .measuring, let p else { return }
                samples.add(p)
            }
            .onAppear {
                // Képernyőképhez: a mérés magától indul
                if UserDefaults.standard.bool(forKey: "uiHealth"), phase == .idle {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if phase == .idle { start() } }
                }
            }
            .onDisappear { timer?.invalidate() }
        }
    }

    // MARK: Kezdő képernyő

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tr("20 másodperces mérés", "20-second test"))
                        .font(.system(size: 20, weight: .semibold))
                    ForEach(HealthSection.allCases) { s in
                        HStack(spacing: 12) {
                            Image(systemName: s.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 32, height: 32)
                                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(s.title).font(.system(size: 15))
                        }
                    }
                }
            }

            if let last = HealthCheck.lastSaved() {
                Card {
                    HStack {
                        Text(tr("Legutóbbi eredmény", "Last result")).foregroundStyle(Theme.text2)
                        Spacer()
                        Text("\(last.score)").font(Theme.number(20)).foregroundStyle(scoreColor(last.score))
                        Text("· \(Fmt.date(last.date))").font(.system(size: 13)).foregroundStyle(Theme.text3)
                    }
                }
            }

            PrimaryButton(title: tr("Mérés indítása", "Start test"), icon: "stethoscope") { start() }
                .opacity(canRun ? 1 : 0.4)
                .disabled(!canRun)

            Text(canRun ? tr("Legjobb járó motorral, álló autóban. A motor méréseihez alapjárat kell.",
                             "Best with the engine running and the car stationary; engine tests need idle.")
                        : tr("Csatlakozz az autóhoz, és add rá a gyújtást.", "Connect to the car and switch the ignition on."))
                .font(.system(size: 14))
                .foregroundStyle(canRun ? Theme.text3 : Theme.warn)
        }
    }

    // MARK: Mérés közben

    private var measuring: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(Theme.surface2, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                VStack(spacing: 2) {
                    Text("\(max(0, Int((1 - progress) * HealthCheck.duration + 0.99)))")
                        .font(Theme.number(56, .bold))
                        .contentTransition(.numericText())
                    Text(tr("másodperc", "seconds")).font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
            }
            .frame(width: 210, height: 210)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            Text(tr("Mérés… ne mozdítsd az autót.", "Measuring… keep the car still."))
                .font(.system(size: 16, weight: .semibold))

            HStack {
                live(Fmt.int(monitor.packet?.rpm), tr("ford/p", "rpm"))
                live(Fmt.one(monitor.packet?.batteryVoltage), "V")
                live(Fmt.int(monitor.packet?.coolantTemp), "°C")
            }
        }
    }

    private func live(_ v: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(Theme.number(22)).contentTransition(.numericText())
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Eredmény

    @ViewBuilder
    private func result(_ r: HealthReport) -> some View {
        Card(padding: 18) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Theme.surface2, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: Double(r.score) / 100)
                        .stroke(scoreColor(r.score), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(r.score)").font(Theme.number(30, .bold))
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.verdict).font(.system(size: 20, weight: .semibold))
                    Text(r.carName).font(.system(size: 14)).foregroundStyle(Theme.text2)
                    Text(Fmt.date(r.date)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
            }
        }

        ForEach(HealthSection.allCases) { section in
            let list = r.items(in: section)
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(section.title, systemImage: section.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(list) { item in
                                row(item)
                                if item.id != list.last?.id {
                                    Divider().overlay(Theme.stroke).padding(.leading, 48)
                                }
                            }
                            if section == .inspection, !r.monitors.isEmpty {
                                Divider().overlay(Theme.stroke)
                                monitorsGrid(r.monitors).padding(16)
                            }
                        }
                    }
                }
            }
        }

        ShareLink(item: r.text) {
            Label(tr("Jelentés megosztása", "Share report"), systemImage: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())

        PrimaryButton(title: tr("Újra mérés", "Test again"), icon: "arrow.clockwise") { start() }
            .opacity(canRun ? 1 : 0.4)
            .disabled(!canRun)
    }

    private func monitorsGrid(_ monitors: [Readiness.Monitor]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            ForEach(Array(monitors.enumerated()), id: \.offset) { _, m in
                HStack(spacing: 6) {
                    Image(systemName: m.complete ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(m.complete ? Theme.ok : Theme.warn)
                    Text(m.name).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
        }
    }

    private func row(_ item: HealthItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item.level))
                .font(.system(size: 17))
                .foregroundStyle(color(item.level))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .semibold))
                Text(item.detail).font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // MARK: Folyamat

    private func start() {
        guard canRun else { return }
        samples = HealthSamples()
        if let p = monitor.packet { samples.add(p) }
        started = Date()
        progress = 0
        phase = .measuring
        Haptics.tap()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            progress = min(1, Date().timeIntervalSince(started) / HealthCheck.duration)
            if progress >= 1 {
                t.invalidate()
                finish()
            }
        }
    }

    private func finish() {
        guard let p = monitor.packet else { phase = .idle; return }
        let r = HealthCheck.build(from: p, samples: samples, carName: settings.carName)
        HealthCheck.save(r)
        report = r
        withAnimation(Theme.spring) { phase = .done }
        if r.score >= 85 { Haptics.success() } else { Haptics.warning() }
    }

    // MARK: Színek

    private func scoreColor(_ s: Int) -> Color {
        s >= 85 ? Theme.ok : (s >= 60 ? Theme.warn : Theme.bad)
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
}
