import SwiftUI

/// Sötét, autóban olvasható téma. Kevés szín: a szín jelentést hordoz (ok / figyelem / hiba).
enum Theme {
    static let bg        = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let surface   = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let surface2  = Color(red: 0.13, green: 0.14, blue: 0.17)
    static let stroke    = Color.white.opacity(0.07)
    static let text      = Color.white
    static let text2     = Color.white.opacity(0.62)
    static let text3     = Color.white.opacity(0.38)

    static let accent    = Color(red: 0.25, green: 0.56, blue: 1.00)  // Subaru kék
    static let ok        = Color(red: 0.24, green: 0.84, blue: 0.47)
    static let warn      = Color(red: 1.00, green: 0.76, blue: 0.20)
    static let bad       = Color(red: 1.00, green: 0.30, blue: 0.27)

    /// Kritikusan csillapított rugó: alapértelmezett mozgás, túllövés nélkül.
    static let spring       = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Enyhe rugózás: csak lendületből (pl. mutató ugrása) indított mozgáshoz.
    static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.8)

    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.text3)
    }
}

/// Lenyomásra azonnal reagáló gomb stílus (nem felengedéskor).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

extension View {
    func screenBackground() -> some View {
        background(Theme.bg.ignoresSafeArea())
    }
}
