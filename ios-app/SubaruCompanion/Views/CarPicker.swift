import SwiftUI

/// „Melyik autóval mész?” – nagy kártyás autóválasztó. Induláskor és a fejléc autó gombjáról nyílik.
/// Ha közben az app csatlakozik egy autóhoz, a VIN alapján magától vált, és a választó bezárul.
struct CarPickerSheet: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var cars: [CarProfile] = []
    @State private var showGarage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tr("Melyik autóval mész?", "Which car are you taking?"))
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.4)
                        .padding(.top, 4)

                    if !monitor.canManageGarage {
                        Label(tr("Csatlakozás közben az autó a VIN alapján választódik ki.",
                                 "While connected the car is chosen from its VIN."), systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                    }

                    ForEach(cars) { car in
                        Button { choose(car) } label: { CarCard(car: car, active: car.id == settings.activeCarId) }
                            .buttonStyle(PressableStyle())
                            .disabled(!monitor.canManageGarage && car.id != settings.activeCarId)
                    }

                    Button { showGarage = true } label: {
                        Label(tr("Autók kezelése", "Manage cars"), systemImage: "car.2")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(16)
            }
            .screenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Bezár", "Close")) { dismiss() } }
            }
            .navigationDestination(isPresented: $showGarage) { GarageView() }
        }
        .onAppear { cars = CarStore.all() }
        .onChange(of: monitor.dataVersion) { _ in cars = CarStore.all() }
        .onChange(of: monitor.isLive) { live in
            // Kapcsolódott egy autóhoz: a VIN eldönti, nem kell kézzel választani.
            if live, !monitor.needsCarSelection { dismiss() }
        }
    }

    private func choose(_ car: CarProfile) {
        if car.id != settings.activeCarId, monitor.canManageGarage {
            monitor.switchCar(to: car.id, announce: false)
        }
        Haptics.success()
        dismiss()
    }
}

private struct CarCard: View {
    let car: CarProfile
    let active: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: car.fuel == .diesel ? "car.side.fill" : "car.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(active ? .white : Theme.accent)
                .frame(width: 58, height: 58)
                .background(active ? Theme.accent : Theme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(car.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text2)
            }
            Spacer()
            if active {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.ok)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(active ? Theme.accent : Theme.stroke, lineWidth: active ? 1.5 : 1))
    }

    private var subtitle: String {
        var parts = [car.fuel.label]
        if car.odometerSet { parts.append("\(Fmt.km(car.odometerKm)) km") }
        if car.vin == nil { parts.append(tr("még nem párosítva", "not paired yet")) }
        return parts.joined(separator: " · ")
    }
}

/// Fejléc gomb: az aktív autó neve, koppintásra autóválasztó.
struct CarSwitcherButton: View {
    @EnvironmentObject var settings: AppSettings
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: settings.fuelType == .diesel ? "car.side.fill" : "car.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(settings.carName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.surface2, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(tr("Autó: \(settings.carName). Váltás", "Car: \(settings.carName). Switch"))
    }
}
