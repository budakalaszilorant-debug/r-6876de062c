import AppIntents
import Foundation

// Siri és a Parancsok app műveletei. Egyik sem küld semmit az autónak: az app saját adataiból válaszolnak.

struct CarStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Autó állapota"
    static var description = IntentDescription("Feszültség, hűtővíz és hibakódok.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = VehicleMonitor.shared
        var parts: [String] = []
        if m.isLive, let p = m.packet {
            if let v = p.batteryVoltage { parts.append(String(format: "%.1f V", v)) }
            if let c = p.coolantTemp { parts.append("\(Int(c))°C") }
            parts.append(p.faultCodes.isEmpty ? tr("nincs hibakód", "no fault codes")
                                              : tr("hibakód: ", "fault codes: ") + p.faultCodes.joined(separator: ", "))
        } else if let s = WidgetSnapshot.load() {
            if let v = s.voltage { parts.append(String(format: "%.1f V", v)) }
            if let c = s.coolant { parts.append("\(Int(c))°C") }
            parts.append(tr("utolsó adat: ", "last update: ") + Fmt.date(s.updated))
        }
        let text = parts.isEmpty ? tr("Még nincs adat az autóból.", "No data from the car yet.")
                                 : parts.joined(separator: ", ")
        return .result(dialog: "\(text)")
    }
}

struct RangeIntent: AppIntent {
    static var title: LocalizedStringResource = "Hatótáv"
    static var description = IntentDescription("Becsült hatótáv a tankszintből.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text: String
        if let km = VehicleMonitor.shared.rangeKm {
            text = tr("Kb. \(Int(km)) km.", "About \(Int(km)) km.")
        } else {
            text = tr("Nincs adat a tankszintről.", "No fuel level data.")
        }
        return .result(dialog: "\(text)")
    }
}

struct ParkingTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Parkolóóra indítása"
    static var description = IntentDescription("Visszaszámlálót indít, és szól, mielőtt lejár.")

    @Parameter(title: "Perc", default: 60)
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = max(5, min(600, minutes))
        ParkingTimer.shared.start(minutes: m)
        let text = tr("Parkolóóra elindítva: \(m) perc.", "Parking timer started: \(m) minutes.")
        return .result(dialog: "\(text)")
    }
}

struct WhereIsCarIntent: AppIntent {
    static var title: LocalizedStringResource = "Hol az autóm?"
    static var description = IntentDescription("Megnyitja a térképet az utolsó parkolóhellyel.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let spot = TripStore.latestParking() else {
            let none = tr("Még nincs mentett parkolóhely.", "No saved parking spot yet.")
            return .result(dialog: "\(none)")
        }
        MapsLauncher.walk(to: spot.coordinate, name: "Subaru Impreza")
        let text = tr("Leparkolva: \(Fmt.date(spot.date)).", "Parked: \(Fmt.date(spot.date)).")
        return .result(dialog: "\(text)")
    }
}

/// A Parancsok appban és a Spotlightban megjelenő kész műveletek.
/// A hangos Siri mondatok angolul vannak, mert a Siri nem tud magyarul.
struct SubaruShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CarStatusIntent(), phrases: ["\(.applicationName) status"])
        AppShortcut(intent: WhereIsCarIntent(), phrases: ["Where is my \(.applicationName)"])
        AppShortcut(intent: RangeIntent(), phrases: ["\(.applicationName) range"])
        AppShortcut(intent: ParkingTimerIntent(), phrases: ["Start \(.applicationName) parking timer"])
    }
}
