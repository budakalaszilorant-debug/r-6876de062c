import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case hu, en
    var id: String { rawValue }
    var label: String { self == .hu ? "Magyar" : "English" }
}

/// Kétnyelvű szöveg. Magyar az alapértelmezett.
func tr(_ hu: String, _ en: String) -> String {
    AppSettings.shared.language == .hu ? hu : en
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var language: AppLanguage {
        didSet { d.set(language.rawValue, forKey: "lang") }
    }

    // Üzemanyag ár (Ft/l), a töltés űrlap előtöltéséhez
    @Published var lastFuelPrice: Double { didSet { d.set(lastFuelPrice, forKey: "fuelPrice") } }

    /// Kilométeróra: kezdőérték (kézzel) + OBD sebességből integrált táv.
    @Published var odometerKm: Double { didSet { d.set(odometerKm, forKey: "odo") } }
    @Published var odometerSet: Bool { didSet { d.set(odometerSet, forKey: "odoSet") } }

    @Published var vin: String? { didSet { d.set(vin, forKey: "vin") } }

    /// Első indítás beállítása megtörtént
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    private init() {
        d.register(defaults: [
            "lang": "hu", "fuelPrice": 620.0, "odo": 0.0, "odoSet": false
        ])
        language = AppLanguage(rawValue: d.string(forKey: "lang") ?? "hu") ?? .hu
        lastFuelPrice = d.double(forKey: "fuelPrice")
        odometerKm = d.double(forKey: "odo")
        odometerSet = d.bool(forKey: "odoSet")
        vin = d.string(forKey: "vin")
        onboarded = d.bool(forKey: "onboarded")
    }
}
