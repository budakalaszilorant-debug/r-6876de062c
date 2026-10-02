import Foundation

/// Autó átvilágítás (vásárlás előtt, műszaki előtt, szerelőnek). Csak olvasott adatokból dolgozik.
enum HealthSection: Int, CaseIterable, Identifiable {
    case faults, engine, electrical, inspection, history
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .faults: return tr("Hibakódok", "Fault codes")
        case .engine: return tr("Motor", "Engine")
        case .electrical: return tr("Akku és töltés", "Battery and charging")
        case .inspection: return tr("Műszaki vizsga készenlét", "Inspection readiness")
        case .history: return tr("Előélet", "History")
        }
    }

    var icon: String {
        switch self {
        case .faults: return "exclamationmark.triangle"
        case .engine: return "engine.combustion"
        case .electrical: return "bolt.batteryblock"
        case .inspection: return "checkmark.seal"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct HealthItem: Identifiable {
    enum Level { case ok, warn, bad, info }
    let id = UUID()
    let section: HealthSection
    let level: Level
    let title: String
    let detail: String
}

/// A mérés alatt gyűjtött minták (kb. 20 mp).
struct HealthSamples {
    var idleRpm: [Double] = []
    var volts: [Double] = []
    var stft: [Double] = []
    var ltft: [Double] = []
    var coolantMax: Double?
    var runningSeen = false

    mutating func add(_ p: VehiclePacket) {
        if p.engineRunning { runningSeen = true }
        if let v = p.batteryVoltage { volts.append(v) }
        if p.engineRunning, (p.vehicleSpeed ?? 0) < 2, let r = p.rpm, r > 300 { idleRpm.append(r) }
        if let s = p.stft { stft.append(s) }
        if let l = p.ltft { ltft.append(l) }
        if let c = p.coolantTemp { coolantMax = max(coolantMax ?? c, c) }
    }
}

struct HealthReport {
    let date: Date
    let carName: String
    let vin: String?
    let items: [HealthItem]
    let monitors: [Readiness.Monitor]

    /// 100-ból: hibánként −22, figyelmeztetésenként −7 pont.
    var score: Int {
        let bad = items.filter { $0.level == .bad }.count
        let warn = items.filter { $0.level == .warn }.count
        return max(0, min(100, 100 - bad * 22 - warn * 7))
    }

    var verdict: String {
        switch score {
        case 85...: return tr("Jó állapotban van", "In good shape")
        case 60..<85: return tr("Figyelmet érdemel", "Needs attention")
        default: return tr("Problémát találtam", "Problems found")
        }
    }

    func items(in section: HealthSection) -> [HealthItem] { items.filter { $0.section == section } }

    /// Megosztható szöveges jelentés.
    var text: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "\(carName) — \(tr("átvilágítás", "health check"))\n\(f.string(from: date))\n"
        if let vin { out += "VIN: \(vin)\n" }
        out += "\n\(verdict) (\(score)/100)\n"
        for section in HealthSection.allCases {
            let list = items(in: section)
            guard !list.isEmpty else { continue }
            out += "\n\(section.title.uppercased())\n"
            for i in list {
                let mark: String
                switch i.level {
                case .ok: mark = "[OK]"
                case .warn: mark = "[!]"
                case .bad: mark = "[HIBA]"
                case .info: mark = "[i]"
                }
                out += "\(mark) \(i.title): \(i.detail)\n"
            }
        }
        if !monitors.isEmpty {
            out += "\n" + tr("Készenléti tesztek", "Readiness monitors") + ":\n"
            for m in monitors { out += "  \(m.complete ? "✓" : "✗") \(m.name)\n" }
        }
        return out
    }
}

/// A Mode 01 PID 01 négy bájtjának értelmezése.
struct Readiness {
    struct Monitor {
        let name: String
        let complete: Bool
    }

    let milOn: Bool
    let storedCodes: Int
    let monitors: [Monitor]

    var incomplete: [Monitor] { monitors.filter { !$0.complete } }

    init?(bytes: [Int]?) {
        guard let b = bytes, b.count == 4 else { return nil }
        let a = b[0], bb = b[1], c = b[2], d = b[3]
        milOn = a & 0x80 != 0
        storedCodes = a & 0x7F

        var list: [Monitor] = []
        // Folyamatos tesztek: támogatás a B bájt alsó bitjei, "nem kész" a 4-6. bit
        let continuous: [(Int, String)] = [
            (0, tr("Égéskimaradás", "Misfire")),
            (1, tr("Tüzelőanyag-rendszer", "Fuel system")),
            (2, tr("Alkatrész-ellenőrzés", "Components")),
        ]
        for (bit, name) in continuous where bb & (1 << bit) != 0 {
            list.append(Monitor(name: name, complete: bb & (1 << (bit + 4)) == 0))
        }

        // Nem folyamatos tesztek: a bit 3 jelzi a dízelt (kompressziós gyújtás)
        let diesel = bb & 0x08 != 0
        let spark: [Int: String] = [
            0: tr("Katalizátor", "Catalyst"), 1: tr("Fűtött katalizátor", "Heated catalyst"),
            2: tr("Üzemanyag-gőz (EVAP)", "Evaporative system"), 3: tr("Szekunder levegő", "Secondary air"),
            4: tr("Klíma hűtőközeg", "A/C refrigerant"), 5: tr("Lambdaszonda", "Oxygen sensor"),
            6: tr("Lambdaszonda fűtés", "Oxygen sensor heater"), 7: "EGR",
        ]
        let compression: [Int: String] = [
            0: tr("Katalizátor (NMHC)", "NMHC catalyst"), 1: tr("NOx utókezelés", "NOx aftertreatment"),
            3: tr("Feltöltés nyomás", "Boost pressure"), 5: tr("Kipufogógáz-szenzor", "Exhaust gas sensor"),
            6: tr("Részecskeszűrő", "Particulate filter"), 7: "EGR / VVT",
        ]
        let names = diesel ? compression : spark
        for bit in 0..<8 {
            guard c & (1 << bit) != 0, let name = names[bit] else { continue }
            list.append(Monitor(name: name, complete: d & (1 << bit) == 0))
        }
        monitors = list
    }
}

enum HealthCheck {
    static let duration: TimeInterval = 20

    static func build(from p: VehiclePacket, samples s: HealthSamples, carName: String) -> HealthReport {
        var items: [HealthItem] = []
        func add(_ section: HealthSection, _ level: HealthItem.Level, _ title: String, _ detail: String) {
            items.append(HealthItem(section: section, level: level, title: title, detail: detail))
        }
        let readiness = Readiness(bytes: p.mon)

        // ── Hibakódok ──
        if let r = readiness {
            add(.faults, r.milOn ? .bad : .ok, tr("Motorhiba lámpa", "Check-engine light"),
                r.milOn ? tr("Ég.", "On.") : tr("Nem ég.", "Off."))
        }
        if p.faultCodes.isEmpty {
            add(.faults, .ok, tr("Tárolt hibakódok", "Stored codes"), tr("Nincs.", "None."))
        } else {
            add(.faults, .bad, tr("Tárolt hibakódok", "Stored codes"),
                p.faultCodes.map { "\($0) – \(DTC.describe($0))" }.joined(separator: "; "))
        }
        let pending = p.pendingCodes.filter { !p.faultCodes.contains($0) }
        if !pending.isEmpty {
            add(.faults, .warn, tr("Kialakulóban lévő hibák", "Developing faults"),
                pending.map { "\($0) – \(DTC.describe($0))" }.joined(separator: "; "))
        }
        let permanent = p.permanentCodes.filter { !p.faultCodes.contains($0) }
        if !permanent.isEmpty {
            add(.faults, .warn, tr("Állandó hibakódok", "Permanent codes"),
                tr("\(permanent.joined(separator: ", ")) – korábban törölték, de a hiba még fennállhat.",
                   "\(permanent.joined(separator: ", ")) – cleared earlier, but the fault may still be present."))
        }

        // ── Motor ──
        if s.runningSeen {
            if let c = s.coolantMax {
                add(.engine, c >= 105 ? .bad : .ok, tr("Hűtővíz", "Coolant"), "\(Int(c))°C")
            }
            if s.idleRpm.count >= 20 {
                let sd = stdDev(s.idleRpm)
                let avg = s.idleRpm.reduce(0, +) / Double(s.idleRpm.count)
                let level: HealthItem.Level = sd < 40 ? .ok : (sd < 80 ? .warn : .bad)
                add(.engine, level, tr("Alapjárat stabilitása", "Idle stability"),
                    tr("\(Int(avg)) ford/p, ingadozás ±\(Int(sd))", "\(Int(avg)) rpm, variation ±\(Int(sd))")
                    + (level == .ok ? "" : tr(" – égéskimaradásra vagy fals levegőre utalhat.", " – may point to misfire or a vacuum leak.")))
            } else {
                add(.engine, .info, tr("Alapjárat stabilitása", "Idle stability"),
                    tr("Álló autóban, alapjáraton mérhető.", "Measured at idle with the car stationary."))
            }
            if !s.ltft.isEmpty || !s.stft.isEmpty {
                let total = mean(s.stft) + mean(s.ltft)
                let level: HealthItem.Level = abs(total) < 10 ? .ok : (abs(total) < 20 ? .warn : .bad)
                let what = total > 0 ? tr("szegény keveréket pótol", "compensating lean")
                                     : tr("dús keveréket csökkent", "compensating rich")
                add(.engine, level, tr("Keverékkorrekció", "Fuel trim"),
                    String(format: "%+.1f %%", total) + (abs(total) < 5 ? "" : " (\(what))")
                    + (level == .ok ? "" : tr(" – fals levegő, légtömegmérő vagy befecskendező gyanú.",
                                               " – suspect a vacuum leak, MAF sensor or injector.")))
            }
        } else {
            add(.engine, .info, tr("Motor mérések", "Engine tests"),
                tr("Indítsd el a motort, és futtasd újra: alapjárat és keverékkorrekció mérés.",
                   "Start the engine and run again to test idle and fuel trim."))
        }

        // ── Akku és töltés ──
        if !s.volts.isEmpty {
            let lo = s.volts.min() ?? 0, hi = s.volts.max() ?? 0
            let avg = mean(s.volts)
            if s.runningSeen {
                let level: HealthItem.Level = avg > 15 || avg < 13.2 ? .bad : (avg < 13.5 ? .warn : .ok)
                add(.electrical, level, tr("Töltőfeszültség", "Charging voltage"), String(format: "%.1f V", avg)
                    + (level == .ok ? "" : tr(" – nézesd meg a generátort és a szíjat.", " – check the alternator and belt.")))
                if hi - lo > 0.6 {
                    add(.electrical, .warn, tr("Töltés ingadozik", "Charging fluctuates"),
                        String(format: "%.1f–%.1f V", lo, hi))
                }
            } else {
                let level: HealthItem.Level = avg >= 12.4 ? .ok : (avg >= 12.1 ? .warn : .bad)
                add(.electrical, level, tr("Nyugalmi feszültség", "Resting voltage"), String(format: "%.1f V", avg)
                    + (level == .ok ? "" : tr(" – az akku le van merülve vagy gyenge.", " – the battery is low or weak.")))
            }
        }
        if let last = BatteryHealth.recent(limit: 1).last, let crank = last.crankV {
            let level: HealthItem.Level = crank >= 9.6 ? .ok : (crank >= 9.0 ? .warn : .bad)
            add(.electrical, level, tr("Indításkori feszültség", "Cranking voltage"), String(format: "%.1f V", crank))
        }

        // ── Műszaki készenlét ──
        if let r = readiness {
            let pendingMon = r.incomplete
            if r.monitors.isEmpty {
                add(.inspection, .info, tr("Készenléti tesztek", "Readiness monitors"), tr("Az autó nem jelenti.", "Not reported."))
            } else if pendingMon.isEmpty {
                add(.inspection, .ok, tr("Készenléti tesztek", "Readiness monitors"),
                    tr("Mind a \(r.monitors.count) lefutott.", "All \(r.monitors.count) complete."))
            } else {
                add(.inspection, .warn, tr("Készenléti tesztek", "Readiness monitors"),
                    tr("\(pendingMon.count) nem futott le. Hibatörlés vagy akkucsere után egy hétnyi vegyes vezetés kell; addig a vizsgán elutasíthatják.",
                       "\(pendingMon.count) incomplete. After clearing codes or replacing the battery it takes about a week of mixed driving; until then it may fail inspection."))
            }
        } else {
            add(.inspection, .info, tr("Készenléti tesztek", "Readiness monitors"),
                tr("Még nincs adat; járó motornál fél perc után megjelenik.", "No data yet; appears after half a minute with the engine running."))
        }

        // ── Előélet ──
        let kmClear = p.distSinceClearKm
        let minClear = p.timeClearMin
        if kmClear != nil || minClear != nil {
            let recent = (kmClear ?? .infinity) < 100 || (minClear ?? .infinity) < 2 * 24 * 60
            var parts: [String] = []
            if let km = kmClear { parts.append("\(Fmt.km(km)) km") }
            if let m = minClear { parts.append(durationText(minutes: m)) }
            let since = parts.joined(separator: ", ")
            add(.history, recent ? .warn : .ok, tr("Hibatörlés óta", "Since codes were cleared"),
                recent ? tr("Csak \(since). Nemrég törölték a hibákat vagy lecsatlakoztatták az akkut – vásárlásnál kérdezz rá.",
                            "Only \(since). Codes were recently cleared or the battery disconnected – ask the seller why.")
                       : since)
        }
        add(.history, p.vin == nil ? .warn : .info, "VIN", p.vin ?? tr("Nem olvasható ki.", "Cannot be read."))
        if let odo = p.odometerKm {
            add(.history, .info, tr("Km óra (az autótól)", "Odometer (from the car)"), "\(Fmt.km(odo)) km")
        }

        return HealthReport(date: Date(), carName: carName, vin: p.vin, items: items, monitors: readiness?.monitors ?? [])
    }

    // MARK: Utolsó eredmény (autónként)

    static func save(_ r: HealthReport) {
        let d = UserDefaults.standard
        d.set(r.score, forKey: CarStore.key("lastHealthScore"))
        d.set(r.date.timeIntervalSince1970, forKey: CarStore.key("lastHealthDate"))
    }

    static func lastSaved() -> (score: Int, date: Date)? {
        let d = UserDefaults.standard
        let t = d.double(forKey: CarStore.key("lastHealthDate"))
        guard t > 0 else { return nil }
        return (d.integer(forKey: CarStore.key("lastHealthScore")), Date(timeIntervalSince1970: t))
    }

    // MARK: Segédek

    private static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    private static func stdDev(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }

    private static func durationText(minutes: Double) -> String {
        let days = Int(minutes / 1440)
        if days >= 1 { return tr("\(days) napja", "\(days) days ago") }
        let h = Int(minutes / 60)
        return h >= 1 ? tr("\(h) órája", "\(h) h ago") : tr("\(Int(minutes)) perce", "\(Int(minutes)) min ago")
    }
}
