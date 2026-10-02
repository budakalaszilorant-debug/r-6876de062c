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

/// A műszerfal átrendezhető részei (a nagy tárcsa mindig felül van).
enum DashSection: String, CaseIterable, Identifiable {
    case status, engine, trip, faults
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return tr("Hűtővíz és akku", "Coolant and battery")
        case .engine: return tr("Motor adatok", "Engine data")
        case .trip: return tr("Jelenlegi út", "Current trip")
        case .faults: return tr("Hibakódok", "Fault codes")
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var language: AppLanguage = .hu { didSet { d.set(language.rawValue, forKey: "lang") } }

    // Üzemanyag ár (Ft/l), a töltés űrlap előtöltéséhez és az utak költségéhez
    @Published var lastFuelPrice: Double = 620 { didSet { d.set(lastFuelPrice, forKey: "fuelPrice") } }

    /// Kilométeróra: kezdőérték (kézzel) + OBD sebességből integrált táv.
    @Published var odometerKm: Double = 0 { didSet { d.set(odometerKm, forKey: "odo") } }
    @Published var odometerSet = false { didSet { d.set(odometerSet, forKey: "odoSet") } }

    @Published var vin: String? { didSet { d.set(vin, forKey: "vin") } }

    // Az autó adatai (a Beállításokban szerkeszthetők)
    @Published var carName = "Subaru Impreza RS" { didSet { d.set(carName, forKey: "carName") } }
    @Published var tankLiters = 60.0 { didSet { d.set(tankLiters, forKey: "tankLiters") } }
    @Published var warmTemp = 88.0 { didSet { d.set(warmTemp, forKey: "warmTemp") } }
    @Published var redline = 6500.0 { didSet { d.set(redline, forKey: "redline") } }

    // Kapcsolható funkciók
    @Published var featParkingTimer = true { didSet { d.set(featParkingTimer, forKey: "featParkingTimer") } }
    @Published var featLeftRunning = true { didSet { d.set(featLeftRunning, forKey: "featLeftRunning") } }
    @Published var featMonthly = true { didSet { d.set(featMonthly, forKey: "featMonthly") } }
    @Published var featRange = true { didSet { d.set(featRange, forKey: "featRange") } }
    @Published var featBatteryHealth = true { didSet { d.set(featBatteryHealth, forKey: "featBatteryHealth") } }
    @Published var featIdle = true { didSet { d.set(featIdle, forKey: "featIdle") } }
    @Published var featLiveActivity = true { didSet { d.set(featLiveActivity, forKey: "featLiveActivity") } }
    @Published var featAutoFill = true { didSet { d.set(featAutoFill, forKey: "featAutoFill") } }
    @Published var featOverheatEarly = true { didSet { d.set(featOverheatEarly, forKey: "featOverheatEarly") } }
    @Published var featAlternator = true { didSet { d.set(featAlternator, forKey: "featAlternator") } }
    @Published var featDrain = true { didSet { d.set(featDrain, forKey: "featDrain") } }
    @Published var featTripCost = true { didSet { d.set(featTripCost, forKey: "featTripCost") } }

    /// Műszerfal: a részek sorrendje és az elrejtettek
    @Published var dashOrder: [DashSection] = DashSection.allCases {
        didSet { d.set(dashOrder.map(\.rawValue), forKey: "dashOrder") }
    }
    @Published var dashHidden: Set<DashSection> = [] {
        didSet { d.set(dashHidden.map(\.rawValue), forKey: "dashHidden") }
    }
    var dashVisible: [DashSection] { dashOrder.filter { !dashHidden.contains($0) } }

    /// Első indítás beállítása megtörtént
    @Published var onboarded = false { didSet { d.set(onboarded, forKey: "onboarded") } }

    /// Mentésbe kerülő beállítás kulcsok
    static let backupKeys = [
        "carName", "tankLiters", "warmTemp", "redline", "lang", "fuelPrice", "odo", "odoSet", "vin", "onboarded", "dashOrder", "dashHidden",
        "featParkingTimer", "featLeftRunning", "featMonthly", "featRange", "featBatteryHealth", "featIdle",
        "featLiveActivity", "featAutoFill", "featOverheatEarly", "featAlternator", "featDrain", "featTripCost"
    ]

    private init() {
        d.register(defaults: [
            "carName": "Subaru Impreza RS", "tankLiters": 60.0, "warmTemp": 88.0, "redline": 6500.0,
            "lang": "hu", "fuelPrice": 620.0, "odo": 0.0, "odoSet": false,
            "featParkingTimer": true, "featLeftRunning": true, "featMonthly": true,
            "featRange": true, "featBatteryHealth": true, "featIdle": true,
            "featLiveActivity": true, "featAutoFill": true, "featOverheatEarly": true,
            "featAlternator": true, "featDrain": true, "featTripCost": true
        ])
        load()
    }

    /// Beolvasás a tárolóból (indításkor és mentés visszaállítása után).
    func load() {
        language = AppLanguage(rawValue: d.string(forKey: "lang") ?? "hu") ?? .hu
        lastFuelPrice = d.double(forKey: "fuelPrice")
        odometerKm = d.double(forKey: "odo")
        odometerSet = d.bool(forKey: "odoSet")
        vin = d.string(forKey: "vin")
        carName = d.string(forKey: "carName") ?? "Subaru Impreza RS"
        tankLiters = d.double(forKey: "tankLiters")
        warmTemp = d.double(forKey: "warmTemp")
        redline = d.double(forKey: "redline")
        onboarded = d.bool(forKey: "onboarded")
        featParkingTimer = d.bool(forKey: "featParkingTimer")
        featLeftRunning = d.bool(forKey: "featLeftRunning")
        featMonthly = d.bool(forKey: "featMonthly")
        featRange = d.bool(forKey: "featRange")
        featBatteryHealth = d.bool(forKey: "featBatteryHealth")
        featIdle = d.bool(forKey: "featIdle")
        featLiveActivity = d.bool(forKey: "featLiveActivity")
        featAutoFill = d.bool(forKey: "featAutoFill")
        featOverheatEarly = d.bool(forKey: "featOverheatEarly")
        featAlternator = d.bool(forKey: "featAlternator")
        featDrain = d.bool(forKey: "featDrain")
        featTripCost = d.bool(forKey: "featTripCost")

        let hidden = Set((d.stringArray(forKey: "dashHidden") ?? []).compactMap(DashSection.init(rawValue:)))
        var order = (d.stringArray(forKey: "dashOrder") ?? []).compactMap(DashSection.init(rawValue:))
        for s in DashSection.allCases where !order.contains(s) { order.append(s) }  // új rész egy frissítés után
        dashOrder = order
        dashHidden = hidden
    }
}
