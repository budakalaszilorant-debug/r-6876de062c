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
    @Published var lastFuelPrice: Double = 620 { didSet { d.set(lastFuelPrice, forKey: CarStore.key("fuelPrice", car: activeCarId)) } }

    // MARK: Az aktív autó adatai (a `cars` táblában tárolva, autónként külön)

    @Published private(set) var activeCarId = 0
    @Published var carName = "" { didSet { saveCar() } }
    @Published var fuelType: FuelType = .petrol { didSet { saveCar() } }
    @Published var tankLiters = 50.0 { didSet { saveCar() } }
    @Published var warmTemp = 88.0 { didSet { saveCar() } }
    @Published var redline = 6000.0 { didSet { saveCar() } }
    /// Kilométeróra: kezdőérték (kézzel) + OBD sebességből integrált táv.
    @Published var odometerKm: Double = 0 { didSet { saveCar() } }
    @Published var odometerSet = false { didSet { saveCar() } }
    @Published var vin: String? { didSet { saveCar() } }
    private var loadingCar = false

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
    @Published var featTripCost = true { didSet { d.set(featTripCost, forKey: "featTripCost") } }
    /// Több autónál induláskor megkérdezi, melyikkel mész
    @Published var askCarOnLaunch = true { didSet { d.set(askCarOnLaunch, forKey: "askCarOnLaunch") } }

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

    /// Mentésbe kerülő beállítás kulcsok (az autók adatai az adatbázisban vannak)
    static let backupKeys = [
        "activeCarId", "lang", "fuelPrice", "onboarded", "dashOrder", "dashHidden",
        "featParkingTimer", "featLeftRunning", "featMonthly", "featRange", "featBatteryHealth", "featIdle",
        "featLiveActivity", "featAutoFill", "featOverheatEarly", "featAlternator", "featTripCost", "askCarOnLaunch"
    ]

    private init() {
        d.register(defaults: [
            "lang": "hu", "fuelPrice": 620.0,
            "featParkingTimer": true, "featLeftRunning": true, "featMonthly": true,
            "featRange": true, "featBatteryHealth": true, "featIdle": true,
            "featLiveActivity": true, "featAutoFill": true, "featOverheatEarly": true,
            "featAlternator": true, "featTripCost": true, "askCarOnLaunch": true
        ])
        load()
    }

    /// Beolvasás a tárolóból (indításkor és mentés visszaállítása után).
    func load() {
        _ = Database.shared  // a migráció előbb lefusson, mert az állítja be az első autót
        language = AppLanguage(rawValue: d.string(forKey: "lang") ?? "hu") ?? .hu
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
        featTripCost = d.bool(forKey: "featTripCost")
        askCarOnLaunch = d.bool(forKey: "askCarOnLaunch")

        let hidden = Set((d.stringArray(forKey: "dashHidden") ?? []).compactMap(DashSection.init(rawValue:)))
        var order = (d.stringArray(forKey: "dashOrder") ?? []).compactMap(DashSection.init(rawValue:))
        for s in DashSection.allCases where !order.contains(s) { order.append(s) }  // új rész egy frissítés után
        dashOrder = order
        dashHidden = hidden

        activate(d.integer(forKey: "activeCarId"))
    }

    /// Átvált a megadott autóra (ha nem létezik, az elsőre).
    func activate(_ id: Int) {
        guard let car = CarStore.get(id) ?? CarStore.all().first else { return }
        loadingCar = true
        activeCarId = car.id
        d.set(car.id, forKey: "activeCarId")
        carName = car.name
        fuelType = car.fuel
        tankLiters = car.tankL
        warmTemp = car.warmTemp
        redline = car.redline
        odometerKm = car.odometerKm
        odometerSet = car.odometerSet
        vin = car.vin
        loadingCar = false
        lastFuelPrice = (d.object(forKey: CarStore.key("fuelPrice", car: car.id)) as? Double) ?? 620
    }

    /// Az aktív autó adatai visszaíródnak a `cars` táblába.
    private func saveCar() {
        guard !loadingCar, activeCarId > 0 else { return }
        CarStore.save(CarProfile(id: activeCarId, name: carName, vin: vin, fuel: fuelType,
                                 tankL: tankLiters, warmTemp: warmTemp, redline: redline,
                                 odometerKm: odometerKm, odometerSet: odometerSet, template: ""))
    }
}
