import SwiftUI

/// Első indítás: egyetlen dolgot kérünk, a km óra állását. Minden más magától megy.
struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var odometer = ""
    @FocusState private var focused: Bool

    private var value: Double? {
        Double(odometer.replacingOccurrences(of: " ", with: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "car.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 10) {
                Text("Subaru Impreza RS")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                Text(tr("Az app magától csatlakozik az autóhoz, amikor a közelében vagy. Egy adatot kell megadnod: a km óra állását, mert ez az autó nem adja ki OBD2-n.",
                        "The app connects to the car by itself when you are nearby. It needs one thing from you: the odometer reading, because this car does not report it over OBD2."))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text2)
            }

            Card {
                HStack(alignment: .firstTextBaseline) {
                    TextField("0", text: $odometer)
                        .keyboardType(.numberPad)
                        .font(Theme.number(34))
                        .focused($focused)
                    Text("km")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                PrimaryButton(title: tr("Kész", "Done")) {
                    if let v = value, v > 0 {
                        settings.odometerKm = v
                        settings.odometerSet = true
                    }
                    Haptics.success()
                    settings.onboarded = true
                }
                .opacity((value ?? 0) > 0 ? 1 : 0.4)
                .disabled((value ?? 0) <= 0)

                Button(tr("Később adom meg", "I'll set it later")) { settings.onboarded = true }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, minHeight: 44)

                Button(tr("Kipróbálom autó nélkül (demo)", "Try it without the car (demo)")) {
                    monitor.setDemo(true)
                    settings.onboarded = true
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(24)
        .screenBackground()
        .onAppear { focused = true }
    }
}
