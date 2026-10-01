import SwiftUI

struct DriveView: View {
    var body: some View {
        GForceView()
            .screenBackground()
    }
}

// MARK: - G-erő

struct GForceView: View {
    @ObservedObject private var motion = MotionManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(spacing: 14) {
                        GeometryReader { geo in
                            let r = min(geo.size.width, geo.size.height) / 2
                            let mag = min(1, hypot(motion.lateral, motion.longitudinal))
                            let scale = hypot(motion.lateral, motion.longitudinal) > 1 ? 1 / hypot(motion.lateral, motion.longitudinal) : 1
                            ZStack {
                                Circle().stroke(Theme.stroke, lineWidth: 1)
                                Circle().stroke(Theme.stroke, lineWidth: 1).frame(width: r, height: r)
                                Rectangle().fill(Theme.stroke).frame(width: 1)
                                Rectangle().fill(Theme.stroke).frame(height: 1)
                                // 1:1 követés, animáció nélkül: a pont maga a mérés
                                Circle()
                                    .fill(mag > 0.6 ? Theme.bad : (mag > 0.3 ? Theme.warn : Theme.accent))
                                    .frame(width: 22, height: 22)
                                    .shadow(color: Theme.accent.opacity(0.5), radius: 8)
                                    .offset(x: motion.lateral * scale * r, y: -motion.longitudinal * scale * r)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) { axisLabel(tr("GYORSÍTÁS", "ACCEL")) }
                        .overlay(alignment: .bottom) { axisLabel(tr("FÉKEZÉS", "BRAKE")) }

                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.2f", hypot(motion.lateral, motion.longitudinal)))
                                .font(Theme.number(44, .bold))
                                .tracking(-1)
                            Text("g").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.text2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 12) {
                    StatTile(label: tr("Max gyorsítás", "Peak accel"), value: Fmt.two(motion.peakAccel), unit: "g")
                    StatTile(label: tr("Max fékezés", "Peak brake"), value: Fmt.two(motion.peakBrake), unit: "g")
                }
                StatTile(label: tr("Max oldalirányú", "Peak lateral"), value: Fmt.two(motion.peakLateral), unit: "g")

                PrimaryButton(title: tr("Nullázás (álló autóban)", "Zero (while stationary)"), icon: "scope") {
                    motion.zero()
                    Haptics.tap()
                }

                Text(motion.available
                     ? tr("A telefon legyen rögzített tartóban, kijelzővel feléd. A csúcsértékek nullázáskor törlődnek.",
                          "Keep the phone in a fixed mount, screen facing you. Peaks reset when you zero.")
                     : tr("Ezen az eszközön nincs mozgásérzékelő.", "Motion sensors are unavailable on this device."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
            }
            .padding(16)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Theme.text3)
            .offset(y: 0)
    }
}
