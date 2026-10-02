import Foundation

/// Milyen körülmények között jött a hibakód.
struct DTCSnapshot: Codable, Equatable {
    /// true: az ECU saját rögzítése a hiba pillanatából; false: az app mérése az észleléskor
    var fromEcu: Bool
    var rpm: Double?
    var speed: Double?
    var coolant: Double?
    var load: Double?
}

struct DTCRecord: Identifiable, Equatable {
    let code: String
    let firstSeen: Date
    let lastSeen: Date
    let active: Bool
    var snapshot: DTCSnapshot?
    var id: String { code }
}

enum DTCSeverity {
    case stop, soon, minor

    var label: String {
        switch self {
        case .stop: return tr("Kíméld, azonnal szerviz", "Go easy, service now")
        case .soon: return tr("Mielőbb szerviz", "Service soon")
        case .minor: return tr("Ráér, de nézesd meg", "Not urgent, get it checked")
        }
    }
}

enum DTC {
    /// Gyakori kódok leírása (benzines és dízel motorokra). Ismeretlen kódnál a rendszer szerinti szöveg.
    private static let known: [String: (hu: String, en: String)] = [
        "P0011": ("Szívó vezérműtengely-állítás hiba – 1. sor", "Intake cam timing – bank 1"),
        "P0016": ("Főtengely és vezérműtengely helyzete nem egyezik", "Crank/cam position correlation"),
        "P0021": ("Szívó vezérműtengely-állítás hiba – 2. sor", "Intake cam timing – bank 2"),
        "P0031": ("Lambdaszonda fűtés áramkör alacsony", "O2 sensor heater circuit low"),
        "P0045": ("Turbó nyomásszabályzó szelep áramkör", "Turbo boost control solenoid circuit"),
        "P0087": ("Üzemanyag-nyomás a csőben túl alacsony", "Fuel rail pressure too low"),
        "P0088": ("Üzemanyag-nyomás a csőben túl magas", "Fuel rail pressure too high"),
        "P0089": ("Üzemanyag-nyomás szabályzó hiba", "Fuel pressure regulator performance"),
        "P0093": ("Üzemanyag-szivárgás észlelve", "Fuel system leak detected"),
        "P0100": ("Légtömegmérő (MAF) áramkör", "MAF sensor circuit"),
        "P0101": ("Légtömegmérő (MAF) jel nem hihető", "MAF sensor range/performance"),
        "P0102": ("Légtömegmérő (MAF) jel alacsony", "MAF sensor low"),
        "P0103": ("Légtömegmérő (MAF) jel magas", "MAF sensor high"),
        "P0106": ("Szívócső nyomásérzékelő (MAP) jel nem hihető", "MAP sensor range/performance"),
        "P0107": ("Szívócső nyomásérzékelő (MAP) jel alacsony", "MAP sensor low"),
        "P0108": ("Szívócső nyomásérzékelő (MAP) jel magas", "MAP sensor high"),
        "P0112": ("Szívott levegő hőmérő jel alacsony", "Intake air temp sensor low"),
        "P0113": ("Szívott levegő hőmérő jel magas", "Intake air temp sensor high"),
        "P0115": ("Hűtővíz hőmérő áramkör", "Coolant temp sensor circuit"),
        "P0116": ("Hűtővíz hőmérő jel nem hihető", "Coolant temp sensor range/performance"),
        "P0117": ("Hűtővíz hőmérő jel alacsony", "Coolant temp sensor low"),
        "P0118": ("Hűtővíz hőmérő jel magas", "Coolant temp sensor high"),
        "P0122": ("Fojtószelep-helyzet érzékelő jel alacsony", "Throttle position sensor low"),
        "P0123": ("Fojtószelep-helyzet érzékelő jel magas", "Throttle position sensor high"),
        "P0125": ("Motor nem melegszik fel időben", "Insufficient coolant temp for closed loop"),
        "P0128": ("Termosztát: a motor túl lassan melegszik", "Thermostat: coolant below regulating temp"),
        "P0130": ("Első lambdaszonda áramkör", "Front O2 sensor circuit"),
        "P0131": ("Első lambdaszonda jel alacsony", "Front O2 sensor low voltage"),
        "P0133": ("Első lambdaszonda lassan reagál", "Front O2 sensor slow response"),
        "P0134": ("Első lambdaszonda nem ad jelet", "Front O2 sensor no activity"),
        "P0135": ("Első lambdaszonda fűtés hiba", "Front O2 sensor heater"),
        "P0136": ("Hátsó lambdaszonda áramkör", "Rear O2 sensor circuit"),
        "P0137": ("Hátsó lambdaszonda jel alacsony", "Rear O2 sensor low voltage"),
        "P0141": ("Hátsó lambdaszonda fűtés hiba", "Rear O2 sensor heater"),
        "P0171": ("Szegény keverék", "System too lean"),
        "P0172": ("Dús keverék", "System too rich"),
        "P0174": ("Szegény keverék – 2. sor", "System too lean – bank 2"),
        "P0175": ("Dús keverék – 2. sor", "System too rich – bank 2"),
        "P0190": ("Üzemanyag-nyomás érzékelő áramkör", "Fuel rail pressure sensor circuit"),
        "P0191": ("Üzemanyag-nyomás érzékelő jel nem hihető", "Fuel rail pressure sensor range"),
        "P0201": ("Befecskendező áramkör – 1. henger", "Injector circuit – cylinder 1"),
        "P0202": ("Befecskendező áramkör – 2. henger", "Injector circuit – cylinder 2"),
        "P0203": ("Befecskendező áramkör – 3. henger", "Injector circuit – cylinder 3"),
        "P0204": ("Befecskendező áramkör – 4. henger", "Injector circuit – cylinder 4"),
        "P0217": ("Motor túlmelegedés", "Engine overheat condition"),
        "P0234": ("Turbó túltöltés", "Turbo overboost"),
        "P0299": ("Turbó alultöltés (kevés a töltőnyomás)", "Turbo underboost"),
        "P0300": ("Véletlenszerű égéskimaradás", "Random misfire"),
        "P0301": ("Égéskimaradás – 1. henger", "Misfire – cylinder 1"),
        "P0302": ("Égéskimaradás – 2. henger", "Misfire – cylinder 2"),
        "P0303": ("Égéskimaradás – 3. henger", "Misfire – cylinder 3"),
        "P0304": ("Égéskimaradás – 4. henger", "Misfire – cylinder 4"),
        "P0325": ("Kopogásérzékelő áramkör", "Knock sensor circuit"),
        "P0327": ("Kopogásérzékelő jel alacsony", "Knock sensor low input"),
        "P0335": ("Főtengely jeladó hiba", "Crankshaft position sensor"),
        "P0340": ("Vezérműtengely jeladó hiba", "Camshaft position sensor"),
        "P0351": ("Gyújtótekercs áramkör – 1. henger", "Ignition coil circuit – cylinder 1"),
        "P0352": ("Gyújtótekercs áramkör – 2. henger", "Ignition coil circuit – cylinder 2"),
        "P0353": ("Gyújtótekercs áramkör – 3. henger", "Ignition coil circuit – cylinder 3"),
        "P0354": ("Gyújtótekercs áramkör – 4. henger", "Ignition coil circuit – cylinder 4"),
        "P0380": ("Izzítógyertya áramkör", "Glow plug circuit"),
        "P0400": ("Kipufogógáz-visszavezetés (EGR) hiba", "EGR flow"),
        "P0401": ("EGR áramlás elégtelen", "EGR flow insufficient"),
        "P0403": ("EGR szelep áramkör", "EGR valve circuit"),
        "P0404": ("EGR szelep helyzete nem hihető", "EGR valve range/performance"),
        "P0420": ("Katalizátor hatásfok alacsony", "Catalyst efficiency below threshold"),
        "P0441": ("EVAP öblítés hibás", "EVAP purge flow incorrect"),
        "P0442": ("EVAP rendszer kis szivárgás", "EVAP small leak"),
        "P0455": ("EVAP rendszer nagy szivárgás", "EVAP large leak"),
        "P0456": ("EVAP rendszer nagyon kis szivárgás (tanksapka?)", "EVAP very small leak (fuel cap?)"),
        "P0457": ("Tanksapka laza vagy hiányzik", "Fuel cap loose/off"),
        "P0480": ("Hűtőventilátor áramkör", "Cooling fan circuit"),
        "P0500": ("Sebességjeladó hiba", "Vehicle speed sensor"),
        "P0504": ("Fékkapcsoló jelei nem egyeznek", "Brake switch correlation"),
        "P0505": ("Alapjárat-szabályzó hiba", "Idle control system"),
        "P0506": ("Alapjárat túl alacsony", "Idle RPM lower than expected"),
        "P0507": ("Alapjárat túl magas", "Idle RPM higher than expected"),
        "P0560": ("Rendszerfeszültség hiba", "System voltage"),
        "P0562": ("Rendszerfeszültség alacsony", "System voltage low"),
        "P0563": ("Rendszerfeszültség magas", "System voltage high"),
        "P0601": ("Motorvezérlő memória hiba", "ECU memory checksum"),
        "P0603": ("Motorvezérlő belső memória hiba", "ECU keep-alive memory"),
        "P0606": ("Motorvezérlő processzor hiba", "ECU processor fault"),
        "P0627": ("Üzemanyag-szivattyú áramkör", "Fuel pump control circuit"),
        "P0670": ("Izzítás vezérlő modul áramkör", "Glow plug control module circuit"),
        "P0700": ("Váltó vezérlő hibát jelez", "Transmission control system"),
        "P2002": ("Részecskeszűrő (DPF) hatásfok alacsony", "DPF efficiency below threshold"),
        "P2096": ("Katalizátor utáni keverék túl szegény", "Post-catalyst fuel trim too lean"),
        "P2135": ("Fojtószelep-érzékelők jelei nem egyeznek", "Throttle position sensor correlation"),
        "P2138": ("Gázpedál-érzékelők jelei nem egyeznek", "Accelerator pedal sensor correlation"),
        "P2263": ("Turbó töltőnyomás rendszer hiba", "Turbo boost system performance"),
        "P242F": ("Részecskeszűrő (DPF) hamuval telített", "DPF ash restriction"),
        "P2463": ("Részecskeszűrő (DPF) korommal telített", "DPF soot accumulation"),
        "U0100": ("Nincs kapcsolat a motorvezérlővel", "Lost communication with ECM"),
        "U0121": ("Nincs kapcsolat az ABS vezérlővel", "Lost communication with ABS"),
        "U0155": ("Nincs kapcsolat a műszerfallal", "Lost communication with instrument cluster"),
    ]

    private static let stopCodes: Set<String> = [
        "P0300", "P0301", "P0302", "P0303", "P0304",   // égéskimaradás: tönkreteheti a katalizátort
        "P0335", "P0340", "P0016",                     // jeladó / vezérlés: leállhat a motor
        "P0087", "P0088", "P0093",                     // üzemanyag-nyomás, szivárgás
        "P0217", "P0234", "P0562", "P0601", "P0606", "U0100"
    ]
    private static let minorCodes: Set<String> = [
        "P0420", "P0441", "P0442", "P0455", "P0456", "P0457", "P0128", "P0031", "P0135", "P0137",
        "P0141", "P0506", "P0507", "P0112", "P0113", "P0504"
    ]

    static func severity(_ code: String) -> DTCSeverity {
        if stopCodes.contains(code) { return .stop }
        if minorCodes.contains(code) { return .minor }
        return .soon
    }

    /// Melyik rendszerhez tartozik a kód (szabványos SAE számtartományok szerint).
    static func system(_ code: String) -> (name: String, icon: String) {
        let chars = Array(code)
        guard chars.count == 5 else { return (tr("Ismeretlen", "Unknown"), "questionmark.circle") }
        switch chars[0] {
        case "C": return (tr("Futómű, fék", "Chassis, brakes"), "steeringwheel")
        case "B": return (tr("Karosszéria", "Body"), "car.side")
        case "U": return (tr("Vezérlők közti hálózat", "Network"), "point.3.connected.trianglepath.dotted")
        default: break
        }
        if chars[1] != "0" && chars[1] != "2" { return (tr("Gyártóspecifikus", "Manufacturer specific"), "wrench.and.screwdriver") }
        switch chars[2] {
        case "0", "1", "2": return (tr("Keverékképzés, levegő, üzemanyag", "Fuel and air metering"), "fuelpump")
        case "3": return (tr("Gyújtás, égéskimaradás", "Ignition, misfire"), "bolt.fill")
        case "4": return (tr("Károsanyag-kibocsátás", "Emissions"), "aqi.medium")
        case "5": return (tr("Sebesség, alapjárat", "Speed, idle"), "speedometer")
        case "6": return (tr("Motorvezérlő, tápellátás", "ECU, power supply"), "cpu")
        case "7", "8", "9": return (tr("Váltó", "Transmission"), "gearshape.2")
        default: return (tr("Hajtáslánc", "Powertrain"), "engine.combustion")
        }
    }

    /// Rövid teendő a kód csoportja alapján (nem helyettesíti a szerelőt).
    static func advice(_ code: String) -> String {
        if (code.hasPrefix("P030") && code != "P0300") || code == "P0300" {
            return tr("Ha villog a motorhiba lámpa, ne terheld a motort. Gyakori ok: gyertya, gyújtótekercs, befecskendező. Sokáig hagyva a katalizátor is tönkremehet.",
                      "If the check-engine light flashes, don't load the engine. Common causes: spark plug, coil, injector. Left too long it can destroy the catalyst.")
        }
        switch code {
        case "P0171", "P0174":
            return tr("Fals levegő (szívócső szivárgás), szennyezett légtömegmérő vagy gyenge üzemanyag-szivattyú. A Keverékkorrekció érték az átvilágításban segít.",
                      "Vacuum leak, dirty MAF sensor or weak fuel pump. The fuel trim value in the health check helps.")
        case "P0172", "P0175":
            return tr("Szivárgó befecskendező, hibás lambdaszonda vagy eltömődött légszűrő.", "Leaking injector, faulty O2 sensor or clogged air filter.")
        case "P0420":
            return tr("Előbb a lambdaszondákat érdemes ellenőriztetni; ha azok jók, a katalizátor fáradt. Műszaki vizsgán gond lehet.",
                      "Check the O2 sensors first; if they're fine the catalyst is worn. Can fail an emissions test.")
        case "P0128", "P0125":
            return tr("Valószínűleg beragadt nyitva a termosztát. Olcsó csere, de növeli a fogyasztást.", "Thermostat probably stuck open. Cheap fix, but it raises fuel use.")
        case "P0456", "P0457", "P0455", "P0442":
            return tr("Először nézd meg, jól zár-e a tanksapka. Ha igen, az EVAP rendszert kell átnézni.", "First check the fuel cap seals properly. If it does, the EVAP system needs checking.")
        case "P0562", "P0563", "P0560":
            return tr("Mérd meg az akkut és a töltést (Autó → Akku). Gyenge akku vagy generátor okozhatja.", "Check the battery and charging (Car → Battery). A weak battery or alternator can cause it.")
        case "P0087", "P0088", "P0093", "P0190", "P0191":
            return tr("Üzemanyag-ellátási hiba: a motor leállhat. Dízelnél gyakran üzemanyagszűrő vagy nagynyomású szivattyú.",
                      "Fuel supply fault: the engine may stall. On diesels often the fuel filter or the high-pressure pump.")
        case "P2002", "P2463", "P242F":
            return tr("A részecskeszűrő telített. Egy hosszabb, egyenletes autópályás út sokszor kitisztítja; ha nem, szerviz kell.",
                      "The DPF is loaded. A longer steady motorway drive often cleans it; if not, it needs a service.")
        case "P0299", "P0234", "P2263", "P0045":
            return tr("Töltőnyomás hiba: gyakran repedt cső, szivárgó intercooler vagy turbó szelep.", "Boost fault: often a split hose, leaking intercooler or turbo valve.")
        case "P0380", "P0670":
            return tr("Izzító hiba: hidegben nehéz indulás. Ellenőriztesd az izzítógyertyákat.", "Glow plug fault: hard cold starts. Have the glow plugs checked.")
        case "P0217":
            return tr("Állj meg, és állítsd le a motort. Ellenőrizd a hűtőfolyadékot, ha már lehűlt.", "Pull over and stop the engine. Check the coolant once it has cooled.")
        default:
            break
        }
        switch system(code).icon {
        case "aqi.medium": return tr("Kipufogórendszer vagy károsanyag-szabályozás. Általában nem sürgős, de műszakin gond lehet.", "Exhaust or emissions control. Usually not urgent, but can fail an inspection.")
        case "bolt.fill": return tr("Gyújtási rendszer. Ellenőriztesd a gyertyákat és a tekercseket.", "Ignition system. Have the plugs and coils checked.")
        case "fuelpump": return tr("Érzékelő vagy keverékképzés. Gyakran csatlakozó- vagy szenzorhiba.", "Sensor or mixture control. Often a connector or sensor fault.")
        default: return tr("Olvastasd ki szerelővel; a jelentés megosztható neki az Átvilágításból.", "Have a mechanic read it; you can share the report from the Health check.")
        }
    }

    static func saveSnapshot(_ code: String, _ snap: DTCSnapshot) {
        guard let data = try? JSONEncoder().encode(snap), let json = String(data: data, encoding: .utf8) else { return }
        Database.shared.execute("UPDATE dtc_hist SET snap = ? WHERE code = ? AND car_id = ?", [json, code, CarStore.activeId])
    }

    static func describe(_ code: String) -> String {
        if let d = known[code] { return tr(d.hu, d.en) }
        switch code.first {
        case "P": return tr("Hajtáslánc hibakód", "Powertrain fault")
        case "C": return tr("Futómű hibakód", "Chassis fault")
        case "B": return tr("Karosszéria hibakód", "Body fault")
        default:  return tr("Hálózati hibakód", "Network fault")
        }
    }

    static func history() -> [DTCRecord] {
        Database.shared.query("SELECT code, first_seen, last_seen, active, snap FROM dtc_hist WHERE car_id = ? ORDER BY active DESC, last_seen DESC",
                              [CarStore.activeId]) {
            DTCRecord(code: $0.string(0), firstSeen: Date(timeIntervalSince1970: $0.double(1)),
                      lastSeen: Date(timeIntervalSince1970: $0.double(2)), active: $0.int(3) == 1,
                      snapshot: $0.string(4).data(using: .utf8).flatMap { try? JSONDecoder().decode(DTCSnapshot.self, from: $0) })
        }
    }

    /// Frissíti a naplót és visszaadja az újonnan megjelent kódokat.
    static func update(active codes: [String]) -> [String] {
        let db = Database.shared
        let now = Date().timeIntervalSince1970
        let car = CarStore.activeId
        let previouslyActive = Set(db.query("SELECT code FROM dtc_hist WHERE active = 1 AND car_id = ?", [car]) { $0.string(0) })
        let current = Set(codes)

        for code in current {
            db.execute("""
            INSERT INTO dtc_hist(car_id, code, first_seen, last_seen, active) VALUES(?,?,?,?,1)
            ON CONFLICT(car_id, code) DO UPDATE SET last_seen = excluded.last_seen, active = 1
            """, [car, code, now, now])
        }
        for code in previouslyActive.subtracting(current) {
            db.execute("UPDATE dtc_hist SET active = 0 WHERE code = ? AND car_id = ?", [code, car])
        }
        return Array(current.subtracting(previouslyActive)).sorted()
    }
}
