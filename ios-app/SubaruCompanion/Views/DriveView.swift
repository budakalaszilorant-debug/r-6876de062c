import SwiftUI
import Charts

struct DriveView: View {
    var body: some View {
        GForceView()
            .screenBackground()
    }
}

// MARK: - G-erő

struct GForceView: View {
    @ObservedObject private var motion = MotionManager.shared
    /// A kör skálája: 0,5 g városban bőven elég, 1,0 g pályán
    @State private var scale: Double = 0.5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(padding: 18) {
                    VStack(spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(String(format: "%.2f", motion.total))
                                    .font(Theme.number(48, .bold))
                                    .tracking(-1.2)
                                    .foregroundStyle(color(for: motion.total))
                                    .contentTransition(.numericText())
                                Text("g").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            Text(direction)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text2)
                        }

                        FrictionCircle(motion: motion, scale: scale)
                            .frame(maxWidth: 320)
                            .frame(maxWidth: .infinity)

                        Picker("", selection: $scale) {
                            Text("0,5 g").tag(0.5)
                            Text("1,0 g").tag(1.0)
                            Text("1,5 g").tag(1.5)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                HStack(spacing: 12) {
                    AxisMeter(label: tr("Hossz", "Long."), value: motion.longitudinal, scale: scale,
                              negative: tr("Fék", "Brake"), positive: tr("Gyorsít", "Accel"))
                    AxisMeter(label: tr("Oldal", "Lateral"), value: motion.lateral, scale: scale,
                              negative: tr("Bal", "Left"), positive: tr("Jobb", "Right"))
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Csúcsértékek", "Peaks"))
                    Card {
                        VStack(spacing: 12) {
                            HStack {
                                peak(tr("Gyorsítás", "Acceleration"), motion.peakAccel, "arrow.up")
                                Spacer()
                                peak(tr("Fékezés", "Braking"), motion.peakBrake, "arrow.down")
                            }
                            Divider().overlay(Theme.stroke)
                            HStack {
                                peak(tr("Bal kanyar", "Left turn"), motion.peakLeft, "arrow.left")
                                Spacer()
                                peak(tr("Jobb kanyar", "Right turn"), motion.peakRight, "arrow.right")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: tr("Utolsó 30 másodperc", "Last 30 seconds"))
                    Card { GTimeline(samples: motion.timeline) }
                }

                PrimaryButton(title: tr("Nullázás álló autóban", "Zero while stationary"), icon: "scope") {
                    motion.zero()
                    Haptics.success()
                }

                if !motion.available {
                    Text(tr("Ezen az eszközön nincs mozgásérzékelő.", "Motion sensors are unavailable on this device."))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                } else if motion.flatMount {
                    Label(tr("Vízszintesen fekvő telefon: előre a telefon teteje mutat.",
                             "Phone lying flat: the top of the phone points forward."), systemImage: "iphone")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                }
            }
            .padding(16)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    private var direction: String {
        let lon = motion.longitudinal, lat = motion.lateral
        guard motion.total >= 0.05 else { return tr("Egyenletes", "Steady") }
        if abs(lon) >= abs(lat) { return lon > 0 ? tr("Gyorsítás", "Accelerating") : tr("Fékezés", "Braking") }
        return lat > 0 ? tr("Jobb kanyar", "Right turn") : tr("Bal kanyar", "Left turn")
    }

    private func color(for g: Double) -> Color {
        if g >= 0.6 { return Theme.bad }
        if g >= 0.3 { return Theme.warn }
        return Theme.text
    }

    private func peak(_ label: String, _ value: Double, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color(for: value) == Theme.text ? Theme.accent : color(for: value))
                .frame(width: 28, height: 28)
                .background(Theme.surface2, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                Text(String(format: "%.2f g", value))
                    .font(Theme.number(20))
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tapadási kör: koncentrikus gyűrűk, nyomvonal, csúcsjelzők és az élő pont.
private struct FrictionCircle: View {
    @ObservedObject var motion: MotionManager
    let scale: Double

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                // Gyűrűk 25 %-onként, címkével
                ForEach(1...4, id: \.self) { i in
                    let rr = r * CGFloat(i) / 4
                    Circle()
                        .stroke(i == 4 ? Theme.text3.opacity(0.5) : Theme.stroke, lineWidth: 1)
                        .frame(width: rr * 2, height: rr * 2)
                        .position(c)
                    Text(String(format: "%.2g", scale * Double(i) / 4))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text3)
                        .position(x: c.x + rr * 0.72 + 8, y: c.y - rr * 0.72 - 6)
                }
                Path { p in
                    p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
                    p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                }
                .stroke(Theme.stroke, lineWidth: 1)

                // Irányonkénti csúcsok halvány „burka”
                Path { p in
                    let pts = [
                        point(0, motion.peakAccel, c, r), point(motion.peakRight, 0, c, r),
                        point(0, -motion.peakBrake, c, r), point(-motion.peakLeft, 0, c, r)
                    ]
                    p.addLines(pts + [pts[0]])
                }
                .fill(Theme.accent.opacity(0.10))
                .overlay(
                    Path { p in
                        let pts = [
                            point(0, motion.peakAccel, c, r), point(motion.peakRight, 0, c, r),
                            point(0, -motion.peakBrake, c, r), point(-motion.peakLeft, 0, c, r)
                        ]
                        p.addLines(pts + [pts[0]])
                    }
                    .stroke(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )

                // Nyomvonal: a régebbi pontok halványabbak és kisebbek
                ForEach(Array(motion.trail.enumerated()), id: \.offset) { i, s in
                    let k = Double(i + 1) / Double(max(1, motion.trail.count))
                    Circle()
                        .fill(Theme.accent.opacity(0.08 + 0.35 * k))
                        .frame(width: 4 + 6 * k, height: 4 + 6 * k)
                        .position(point(s.x, s.y, c, r))
                }

                // Élő pont: animáció nélkül követi a mérést
                let live = point(motion.lateral, motion.longitudinal, c, r)
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(liveColor, lineWidth: 5))
                    .shadow(color: liveColor.opacity(0.6), radius: 10)
                    .position(live)

                axisLabel(tr("GYORSÍTÁS", "ACCEL")).position(x: c.x, y: c.y - r - 10)
                axisLabel(tr("FÉK", "BRAKE")).position(x: c.x, y: c.y + r + 10)
                axisLabel(tr("B", "L")).position(x: c.x - r - 10, y: c.y)
                axisLabel(tr("J", "R")).position(x: c.x + r + 10, y: c.y)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%.2f g", motion.total))
    }

    private var liveColor: Color {
        let g = motion.total
        if g >= 0.6 { return Theme.bad }
        return g >= 0.3 ? Theme.warn : Theme.accent
    }

    /// g értékből képpont; a skálán túli értékek a kör szélére kerülnek.
    private func point(_ lat: Double, _ lon: Double, _ c: CGPoint, _ r: CGFloat) -> CGPoint {
        var x = lat / scale, y = lon / scale
        let len = hypot(x, y)
        if len > 1 { x /= len; y /= len }
        return CGPoint(x: c.x + CGFloat(x) * r, y: c.y - CGFloat(y) * r)
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold)).tracking(0.8)
            .foregroundStyle(Theme.text3)
    }
}

/// Egy tengely kétirányú sávja: középről indul a negatív vagy pozitív irányba.
private struct AxisMeter: View {
    let label: String
    let value: Double
    let scale: Double
    let negative: String
    let positive: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Text(String(format: "%+.2f", value))
                        .font(Theme.number(17))
                        .contentTransition(.numericText())
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    let f = min(1, abs(value) / scale)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Rectangle().fill(Theme.stroke).frame(width: 1).offset(x: w / 2)
                        Capsule()
                            .fill(value >= 0 ? Theme.ok : Theme.bad)
                            .frame(width: max(4, w / 2 * f))
                            .offset(x: value >= 0 ? w / 2 : w / 2 - max(4, w / 2 * f))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(negative); Spacer(); Text(positive)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
            }
        }
    }
}

private struct GTimeline: View {
    let samples: [GSample]

    var body: some View {
        Chart {
            RuleMark(y: .value("0", 0)).foregroundStyle(Theme.stroke)
            ForEach(samples) { s in
                LineMark(x: .value("t", s.t), y: .value("g", s.lon), series: .value("s", "lon"))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.t), y: .value("g", s.lat), series: .value("s", "lat"))
                    .foregroundStyle(Theme.warn)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: -1...1)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [-1, -0.5, 0, 0.5, 1]) { _ in
                AxisGridLine().foregroundStyle(Theme.stroke)
                AxisValueLabel().foregroundStyle(Theme.text3)
            }
        }
        .frame(height: 140)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                legend(tr("Hossz", "Long."), Theme.accent)
                legend(tr("Oldal", "Lateral"), Theme.warn)
            }
        }
        .overlay {
            if samples.isEmpty {
                Text(tr("Nincs adat", "No data")).font(.system(size: 14)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
        }
    }
}
