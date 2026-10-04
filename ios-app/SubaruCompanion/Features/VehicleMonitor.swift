import Foundation
import Combine
import WidgetKit

struct WarmUpState: Equatable {
    var coldStart = false
    var startTemp: Double?
    var etaMinutes: Double?
    var isWarm = false
}

enum VoltageLevel { case unknown, ok, caution, low, high }

/// Az app „agya”: fogadja a csomagokat, és ebből vezérli az értesítéseket, az út rögzítést
/// és a km-számlálót. Az autó felé semmit nem küld.
final class VehicleMonitor: ObservableObject {
    static let shared = VehicleMonitor()

    @Published private(set) var packet: VehiclePacket?
    @Published private(set) var isLive = false           // érkezik friss adat
    @Published private(set) var warmUp = WarmUpState()
    @Published private(set) var trip: Trip?
    @Published private(set) var parking: ParkingSpot?
    @Published private(set) var dataVersion = 0          // nő, ha a DB-ben változott valami
    /// Demo mód: szimulált adatok az autó nélkül. Nem ír az adatbázisba és a km órába.
    @Published private(set) var demoActive = false
    /// Becsült hatótáv km-ben (csak ha az autó kiadja a tankszintet)
    @Published private(set) var rangeKm: Double?
    /// Észlelt tankolás becsült litere, amíg a felhasználó nem rögzíti vagy el nem veti
    @Published private(set) var suggestedFill: Double?

    private let settings = AppSettings.shared
    private let notify = NotificationManager.shared
    private let db = Database.shared
    private let recorder = TripRecorder()
    private let demo = DemoSource()
    private var lastWidgetSave = Date.distantPast
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetState = ""
    private var avgL100 = RangeEstimator.fallbackL100
    private var leftRunningNotified = false
    /// A megszokott üzemi hűtővíz hőfok (lassan tanult átlag) a korai túlmelegedés jelzéshez
    private var normCoolant = 90.0
    private var chargeSum = 0.0
    private var chargeCount = 0
    private var lastStopFuel: Double {
        get { UserDefaults.standard.object(forKey: CarStore.key("lastStopFuel")) as? Double ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: CarStore.key("lastStopFuel")) }
    }
    private var pendingHealth: (startId: Int, since: Date)?
    private var lastStopAt: Double {
        get { UserDefaults.standard.double(forKey: CarStore.key("lastStopAt")) }
        set { UserDefaults.standard.set(newValue, forKey: CarStore.key("lastStopAt")) }
    }
    private var lowRangeNotified: Bool {
        get { UserDefaults.standard.bool(forKey: CarStore.key("lowRangeNotified")) }
        set { UserDefaults.standard.set(newValue, forKey: CarStore.key("lowRangeNotified")) }
    }
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var started = false

    private var lastPacketAt: Date?
    private var coolantSamples: [(t: Date, temp: Double)] = []
    private var warmNotifiedStartId: Int {
        get { UserDefaults.standard.integer(forKey: CarStore.key("warmStartId")) }
        set { UserDefaults.standard.set(newValue, forKey: CarStore.key("warmStartId")) }
    }
    @Published private(set) var needsCarSelection = false
    @Published private(set) var pendingVIN: String?
    private var selectedForConnection = false
    private var latestUnassignedPacket: VehiclePacket?
    var canManageGarage: Bool { demoActive || (!isLive && recorder.active == nil && BLEManager.shared.state != .connected) }

    private var seenStartId: Int {
        get { UserDefaults.standard.integer(forKey: CarStore.key("seenStartId")) }
        set { UserDefaults.standard.set(newValue, forKey: CarStore.key("seenStartId")) }
    }
    private var pendingKm = 0.0
    private var lowVoltageSince: Date?
    private var highVoltageSince: Date?
    private var lastVoltageLog = Date.distantPast
    private var lastCodes: [String]?
    private var stoppedSince: Date?
    private var wasRunning = false
    private var lastServiceCheck = Date.distantPast

    func start() {
        guard !started else { return }
        started = true
        parking = TripStore.latestParking()
        TripStore.closeStale(except: seenStartId)
        refreshAverages()
        MonthlySummary.notifyIfNewMonth()
        Reminders.reschedule()
        Backup.autoBackupIfDue()
        let savedNorm = UserDefaults.standard.double(forKey: CarStore.key("normCoolant"))
        if savedNorm > 80 { normCoolant = savedNorm }
        let savedFill = UserDefaults.standard.double(forKey: CarStore.key("suggestedFill"))
        if savedFill > 0 { suggestedFill = savedFill }

        BLEManager.shared.$state.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard state != .connected else { return }
                self?.selectedForConnection = false
                self?.needsCarSelection = false
                self?.pendingVIN = nil
                self?.latestUnassignedPacket = nil
            }.store(in: &bag)

        BLEManager.shared.packets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &bag)

        settings.$featLiveActivity.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?.startLiveActivityIfNeeded() }
                else { DriveActivity.shared.end() }
            }.store(in: &bag)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: - Csomag feldolgozás

    private func handle(_ p: VehiclePacket) {
        guard !demoActive else { return }
        process(p, demo: false)
    }

    func setDemo(_ on: Bool) {
        guard on != demoActive else { return }
        if on, recorder.active != nil { endTrip() }
        demoActive = on
        selectedForConnection = false
        needsCarSelection = false
        pendingVIN = nil
        coolantSamples.removeAll()
        lowVoltageSince = nil
        highVoltageSince = nil
        if on {
            warmUp = WarmUpState(coldStart: true, startTemp: DemoSource.startTemp)
            demo.start { [weak self] in self?.process($0, demo: true) }
        } else {
            demo.stop()
            warmUp = WarmUpState()
            packet = nil
            isLive = false
            lastPacketAt = nil
        }
    }

    private func process(_ p: VehiclePacket, demo: Bool) {
        if !demo {
            if !p.ecu && !selectedForConnection {
                packet = nil
                isLive = false
                return
            }
            let vin = p.vin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let vin, CarStore.validVIN(vin), let car = CarStore.find(vin: vin) {
                switchCar(to: car.id, announce: false)
                selectedForConnection = true
                needsCarSelection = false
                pendingVIN = nil
                latestUnassignedPacket = nil
            } else if !selectedForConnection || (vin.map(CarStore.validVIN) == true && vin != settings.vin) {
                if recorder.active != nil { endTrip() }
                latestUnassignedPacket = p
                pendingVIN = vin.flatMap { CarStore.validVIN($0) ? $0 : nil }
                needsCarSelection = true
                packet = nil
                isLive = false
                lastPacketAt = nil
                return
            }
        }
        let now = Date()
        let dt = max(0, min(2, lastPacketAt.map { now.timeIntervalSince($0) } ?? 0))
        lastPacketAt = now
        packet = p
        isLive = true
        leftRunningNotified = false
        updateRange(p, notify: !demo)

        // Sorrend: előbb az indítási ciklus (ez nullázza a bemelegedés állapotát), utána a bemelegedés.
        if !demo {
            updateOdometer(p, dt: dt)
            updateEngineCycle(p, now: now)
        }
        updateWarmUp(p, now: now)
        guard !demo else { return }
        updateVoltage(p, now: now, log: true)
        updateOverheat(p)

        updateFaultCodes(p)
        RepairStore.observe(p.faultCodes + p.pendingCodes)
        afterStartChecks(p, now: now)
        updateInsights(p, now: now)
        updateWidget(p, now: now)

        if recorder.active != nil {
            recorder.update(packet: p, dt: dt)
            trip = recorder.active
            if settings.featLiveActivity { DriveActivity.shared.update(activityState(p)) }
        }
    }

    // MARK: - Élő tevékenység

    private func activityState(_ p: VehiclePacket) -> DriveActivityAttributes.ContentState {
        let t = recorder.active
        return .init(speed: p.vehicleSpeed.map { Int($0) },
                     coolant: p.coolantTemp.map { Int($0) },
                     warm: (p.coolantTemp ?? 0) >= CarSpec.warmTemp,
                     tripKm: ((t?.distanceKm ?? 0) * 10).rounded() / 10,
                     consumption: t?.avgConsumption.map { ($0 * 10).rounded() / 10 },
                     carID: settings.activeCarId, carName: settings.carName,
                     mode: warmUp.isWarm ? "drive" : "warmup",
                     progress: min(1, max(0, (p.coolantTemp ?? 0) / settings.warmTemp)),
                     etaMinutes: warmUp.etaMinutes.map { Int(ceil($0)) },
                     parkingEnd: nil, hu: settings.language == .hu)
    }

    /// Az iOS csak előtérben lévő appnak engedi elindítani: az app megnyitásakor hívjuk.
    func startLiveActivityIfNeeded() {
        guard settings.featLiveActivity, !demoActive else { return }
        if recorder.active == nil, let end = ParkingTimer.shared.end, end > Date() {
            DriveActivity.shared.parking(until: end)
            return
        }
        guard let t = recorder.active, let p = packet, isLive else { return }
        DriveActivity.shared.start(tripStart: t.start, state: activityState(p))
    }

    // MARK: - Megelőző figyelések

    private func updateInsights(_ p: VehiclePacket, now: Date) {
        guard p.engineRunning else { return }

        if let c = p.coolantTemp {
            // A megszokott üzemi hőfok lassú tanulása (csak meleg motornál, menet közben).
            if c >= 84, c <= 100, (p.vehicleSpeed ?? 0) > 20 { normCoolant += (c - normCoolant) * 0.0002 }
            // Korai jelzés: a megszokott fölé kúszik, de még a túlmelegedési határ alatt van.
            if settings.featOverheatEarly, c >= normCoolant + 7, c >= 97, c < 108 {
                notify.send(key: "overheatEarly", title: tr("🌡 Melegszik a motor", "🌡 Engine running hot"),
                            body: tr("Hűtővíz \(Int(c))°C, a megszokott \(Int(normCoolant))°C. Vedd vissza, és figyeld.",
                                     "Coolant \(Int(c))°C, usually \(Int(normCoolant))°C. Ease off and keep an eye on it."),
                            level: .timeSensitive, throttle: 900)
            }
        }

        // Töltőfeszültség átlaga az útra (generátor figyelés): az első perc után, terhelt fordulaton.
        if let v = p.batteryVoltage, (p.rpm ?? 0) > 1200,
           let t = recorder.active, now.timeIntervalSince(t.start) > 60 {
            chargeSum += v
            chargeCount += 1
        }
    }

    /// Két egymást követő úton alacsony átlagos töltőfeszültség = gyengülő generátor vagy szíj.
    private func checkAlternator() {
        defer { chargeSum = 0; chargeCount = 0 }
        guard chargeCount >= 240 else { return }  // legalább kb. 1 percnyi minta
        let avg = chargeSum / Double(chargeCount)
        let d = UserDefaults.standard
        let previous = d.double(forKey: CarStore.key("lastChargeAvg"))
        d.set(avg, forKey: CarStore.key("lastChargeAvg"))
        db.execute("INSERT INTO events(t, kind, value, car_id) VALUES(?,?,?,?)",
                   [Date().timeIntervalSince1970, "charge_avg", avg, CarStore.activeId])

        guard settings.featAlternator, avg < 13.5, previous > 0, previous < 13.5 else { return }
        let now = Date().timeIntervalSince1970
        guard now - d.double(forKey: CarStore.key("alternatorNotified")) > 3 * 86400 else { return }
        d.set(now, forKey: CarStore.key("alternatorNotified"))
        notify.send(key: "alternator", title: tr("⚠️ Gyenge töltés", "⚠️ Weak charging"),
                    body: tr("Az átlagos töltőfeszültség \(String(format: "%.1f", avg)) V volt. Nézesd meg a generátort és a szíjat.",
                             "Average charging voltage was \(String(format: "%.1f", avg)) V. Have the alternator and belt checked."),
                    level: .timeSensitive)
    }

    /// Mentés visszaállítása után minden nézet újratölt.
    func reloadAfterRestore() {
        packet = nil
        isLive = false
        lastPacketAt = nil
        selectedForConnection = false
        lastCodes = nil
        pendingHealth = nil
        chargeSum = 0
        chargeCount = 0
        warmUp = WarmUpState()
        coolantSamples.removeAll()
        pendingKm = 0
        rangeKm = nil
        suggestedFill = nil
        parking = TripStore.latestParking()
        refreshAverages()
        ParkingTimer.shared.reload()
        Reminders.reschedule()
        dataVersion += 1
    }

    func dismissSuggestedFill() {
        suggestedFill = nil
        UserDefaults.standard.removeObject(forKey: CarStore.key("suggestedFill"))
    }

    private func updateOverheat(_ p: VehiclePacket) {
        if let c = p.coolantTemp, c >= 108 {
            notify.send(key: "overheat", title: tr("🌡 Túlmelegedés", "🌡 Overheating"),
                        body: tr("Hűtővíz \(Int(c))°C — állj meg és állítsd le a motort!",
                                 "Coolant \(Int(c))°C — pull over and stop the engine!"),
                        level: .timeSensitive, throttle: 300)
        }
    }

    private func tick() {
        guard let last = lastPacketAt else { return }
        let age = Date().timeIntervalSince(last)
        if age > 3, isLive { isLive = false }
        // Járó motor mellett szakadt meg a kapcsolat: lehet, hogy járva maradt az autó.
        if settings.featLeftRunning, !demoActive, age > 20, !leftRunningNotified, packet?.engineRunning == true {
            leftRunningNotified = true
            notify.send(key: "leftRunning", title: tr("⚠️ Jár a motor?", "⚠️ Engine still running?"),
                        body: tr("Megszakadt a kapcsolat az autóval, miközben járt a motor.",
                                 "Lost connection to the car while the engine was running."),
                        level: .timeSensitive, throttle: 600)
        }
        // Kapcsolat megszakadt út közben (pl. kiszálltál a telefonnal): 90 mp után az út lezárul.
        if age > 90, recorder.active != nil { endTrip() }
    }

    // MARK: - Garázs

    /// Unknown VINs are associated only after an explicit choice. With no VIN the choice lasts one BLE connection.
    func confirmCar(_ id: Int) {
        guard needsCarSelection, let car = CarStore.get(id), let p = latestUnassignedPacket else { return }
        if let pendingVIN, let existing = car.vin, existing != pendingVIN { return }
        switchCar(to: id, announce: false)
        if let pendingVIN { settings.vin = pendingVIN }
        selectedForConnection = true
        needsCarSelection = false
        pendingVIN = nil
        latestUnassignedPacket = nil
        process(p, demo: false)
    }

    /// Átvált egy másik autóra: a folyamatban lévő út lezárul, minden autófüggő állapot újraindul.
    func switchCar(to id: Int, announce: Bool) {
        guard id != settings.activeCarId, CarStore.get(id) != nil else { return }
        if recorder.active != nil { endTrip() }
        settings.activate(id)

        parking = TripStore.latestParking()
        refreshAverages()
        lastCodes = nil
        coolantSamples.removeAll()
        warmUp = WarmUpState()
        pendingKm = 0
        rangeKm = nil
        chargeSum = 0
        chargeCount = 0
        let savedNorm = UserDefaults.standard.double(forKey: CarStore.key("normCoolant"))
        normCoolant = savedNorm > 0 ? savedNorm : settings.warmTemp + 2
        suggestedFill = UserDefaults.standard.object(forKey: CarStore.key("suggestedFill")) as? Double
        pendingHealth = nil
        stoppedSince = nil
        wasRunning = false
        lastPacketAt = nil
        packet = nil
        isLive = false
        lowVoltageSince = nil
        highVoltageSince = nil
        lastVoltageLog = .distantPast
        lastWidgetSave = .distantPast
        lastWidgetState = ""
        WidgetSnapshot(voltage: nil, coolant: nil, engineRunning: false, updated: Date()).save()
        WidgetCenter.shared.reloadAllTimelines()
        ParkingTimer.shared.reload()
        MonthlySummary.notifyIfNewMonth()
        dataVersion += 1

        if announce {
            notify.send(key: "carSwitch", title: settings.carName,
                        body: tr("Csatlakozva ehhez az autóhoz.", "Connected to this car."), throttle: 60)
        }
    }

    // MARK: - Kilométer

    private func updateOdometer(_ p: VehiclePacket, dt: TimeInterval) {
        if let odo = p.odometerKm, odo > 0 {
            if abs(odo - settings.odometerKm) >= 0.1 { settings.odometerKm = odo }
            if !settings.odometerSet { settings.odometerSet = true }
        } else if let v = p.vehicleSpeed, settings.odometerSet {
            pendingKm += v * dt / 3600
            if pendingKm >= 0.1 {
                settings.odometerKm += pendingKm
                pendingKm = 0
            }
        }
        if Date().timeIntervalSince(lastServiceCheck) > 3600 {
            lastServiceCheck = Date()
            ServiceStore.checkAndNotify()
        }
    }

    // MARK: - Indítás / leállítás

    private func updateEngineCycle(_ p: VehiclePacket, now: Date) {
        if p.engineRunning {
            stoppedSince = nil
            if !wasRunning {
                wasRunning = true
                logVoltage(p.batteryVoltage, event: "start")
            }
            if p.startId != seenStartId {
                seenStartId = p.startId
                coolantSamples.removeAll()
                let cold = (p.coolantTemp ?? 99) < CarSpec.coldStartTemp
                warmUp = WarmUpState(coldStart: cold, startTemp: p.coolantTemp)
                if cold, let t = p.coolantTemp {
                    db.execute("INSERT INTO events(t, kind, value, car_id) VALUES(?,?,?,?)",
                               [now.timeIntervalSince1970, "cold_start", t, CarStore.activeId])
                }
                // Már melegen indult: nem kell értesítés erre a ciklusra.
                if (p.coolantTemp ?? 0) >= CarSpec.warmTemp { warmNotifiedStartId = p.startId }
                pendingHealth = (p.startId, now)
            }
            if recorder.active == nil {
                recorder.ensureStarted(startId: p.startId, odometer: settings.odometerKm)
                trip = recorder.active
                startLiveActivityIfNeeded()
            }
        } else if wasRunning {
            // 5 mp-ig áll a motor = tényleges leállítás (nem lefulladás utáni újraindítás)
            if stoppedSince == nil { stoppedSince = now }
            if let s = stoppedSince, now.timeIntervalSince(s) >= 5 {
                wasRunning = false
                lastStopAt = now.timeIntervalSince1970
                lastStopFuel = p.fuelLevel ?? -1
                logVoltage(p.batteryVoltage, event: "stop")
                endTrip(promptParking: true)
            }
        }
    }

    private func endTrip(promptParking: Bool = false) {
        let (spot, finished) = recorder.finish()
        if let spot { parking = spot }
        trip = nil
        wasRunning = false
        dataVersion += 1
        refreshAverages()
        if finished != nil { Task { @MainActor in await CloudSync.shared.autoBackupIfNeeded() } }
        checkAlternator()
        if promptParking, settings.featParkingTimer, settings.featLiveActivity {
            DriveActivity.shared.parked()
        } else {
            DriveActivity.shared.end()
        }
        UserDefaults.standard.set(normCoolant, forKey: CarStore.key("normCoolant"))

        // Leparkolás után felajánljuk a parkolóórát; az értesítés gombjaival az app megnyitása nélkül indítható.
        if promptParking, spot != nil, settings.featParkingTimer, !ParkingTimer.shared.isRunning {
            var summary = ""
            if settings.featTripCost, let t = finished {
                summary = "\(Fmt.one(t.distanceKm)) km"
                if let cost = t.cost { summary += " · \(Fmt.km(cost)) Ft" }
                summary += ". "
            }
            notify.send(key: "parked", title: tr("🅿️ Leparkoltál", "🅿️ Parked"),
                        body: summary + tr("Tartsd nyomva parkolóóra indításához.",
                                           "Press and hold to start a parking timer."),
                        category: NotificationManager.parkedCategory)
        }
    }

    // MARK: - Hatótáv

    /// Az átlagfogyasztás újraszámolása (út vége, új tankolás után).
    func refreshAverages() {
        avgL100 = RangeEstimator.averageL100()
    }

    private func updateRange(_ p: VehiclePacket, notify shouldNotify: Bool) {
        guard settings.featRange, let level = p.fuelLevel else {
            if rangeKm != nil { rangeKm = nil }
            return
        }
        // 5 km-re kerekítve, hogy ne ugráljon a kijelzés
        let km = (RangeEstimator.rangeKm(fuelLevel: level, avgL100: avgL100) / 5).rounded() * 5
        if km != rangeKm { rangeKm = km }

        guard shouldNotify else { return }
        if km > 120 { if lowRangeNotified { lowRangeNotified = false } }
        else if km < 50, !lowRangeNotified, p.engineRunning {
            lowRangeNotified = true
            notify.send(key: "lowRange", title: tr("⛽ Kevés a benzin", "⛽ Low fuel"),
                        body: tr("Becsült hatótáv: kb. \(Int(km)) km", "Estimated range: about \(Int(km)) km"))
        }
    }

    // MARK: - Akku egészség

    /// Indítás után 15 mp-cel: akku mérések rögzítése, rejtett fogyasztó és tankolás észlelése.
    private func afterStartChecks(_ p: VehiclePacket, now: Date) {
        guard let pending = pendingHealth, p.engineRunning, now.timeIntervalSince(pending.since) >= 15 else { return }
        pendingHealth = nil

        if settings.featBatteryHealth {
            // A nyugalmi érték csak legalább 1 óra állás után mond valamit az akkuról.
            let rested = lastStopAt == 0 || pending.since.timeIntervalSince1970 - lastStopAt >= 3600
            BatteryHealth.record(startId: pending.startId, rest: rested ? p.restV : nil,
                                 crank: p.crankMinV, charge: p.batteryVoltage)
        }

        // Tankolás észlelése: a tankszint legalább 8 %-kal nőtt a leállítás óta.
        if settings.featAutoFill, let level = p.fuelLevel, lastStopFuel >= 0, level - lastStopFuel >= 8 {
            let liters = ((level - lastStopFuel) / 100 * RangeEstimator.tankLiters).rounded()
            suggestedFill = liters
            UserDefaults.standard.set(liters, forKey: CarStore.key("suggestedFill"))
            lastStopFuel = level
            notify.send(key: "autoFill", title: tr("⛽ Tankoltál?", "⛽ Did you fill up?"),
                        body: tr("Kb. \(Int(liters)) liter került a tankba. Rögzítsd az árát az appban.",
                                 "About \(Int(liters)) litres went in. Log the price in the app."))
        }
        dataVersion += 1
    }

    // MARK: - Bemelegedés

    private func updateWarmUp(_ p: VehiclePacket, now: Date) {
        guard p.engineRunning, let c = p.coolantTemp else { return }
        if warmUp.startTemp == nil { warmUp.startTemp = c }

        if coolantSamples.last.map({ now.timeIntervalSince($0.t) >= 2 }) ?? true {
            coolantSamples.append((now, c))
            coolantSamples.removeAll { now.timeIntervalSince($0.t) > 150 }
        }

        let warm = c >= CarSpec.warmTemp
        var eta: Double?
        if !warm, let first = coolantSamples.first, now.timeIntervalSince(first.t) >= 30 {
            let rate = (c - first.temp) / now.timeIntervalSince(first.t) * 60  // °C / perc
            if rate > 0.3 { eta = (CarSpec.warmTemp - c) / rate }
        }
        if warmUp.isWarm != warm { warmUp.isWarm = warm }
        if warmUp.etaMinutes.map({ Int($0 * 2) }) != eta.map({ Int($0 * 2) }) { warmUp.etaMinutes = eta }

        if !demoActive, warm, warmNotifiedStartId != p.startId {
            warmNotifiedStartId = p.startId   // indítási ciklusonként egyszer
            notify.send(key: "warm", title: settings.carName,
                        body: tr("Motor felmelegedett ✓ (\(Int(c))°C)", "Engine warmed up ✓ (\(Int(c))°C)"))
            Haptics.success()
        }
    }

    // MARK: - Akkumulátor

    static func level(for v: Double?, running: Bool) -> VoltageLevel {
        guard let v else { return .unknown }
        if v > 15.0 { return .high }
        if running {
            if v >= 13.8 { return .ok }
            return v >= 12.4 ? .caution : .low
        }
        // Álló motornál nincs töltés: 12.4 V felett egészséges a nyugalmi feszültség.
        if v >= 12.4 { return .ok }
        return v >= 11.8 ? .caution : .low
    }

    private func updateVoltage(_ p: VehiclePacket, now: Date, log: Bool) {
        guard let v = p.batteryVoltage else { return }
        let level = Self.level(for: v, running: p.engineRunning)

        // 5 mp-ig fennálló érték kell, hogy az önindítózás feszültségesése ne riasszon.
        lowVoltageSince = level == .low ? (lowVoltageSince ?? now) : nil
        highVoltageSince = level == .high ? (highVoltageSince ?? now) : nil
        let volts = String(format: "%.1f", v)

        if let s = lowVoltageSince, now.timeIntervalSince(s) >= 5 {
            notify.send(key: "lowV", title: tr("⚠️ Akkumulátor", "⚠️ Battery"),
                        body: tr("Feszültség alacsony: \(volts)V", "Voltage low: \(volts)V"),
                        level: .timeSensitive, throttle: 300)
        }
        if let s = highVoltageSince, now.timeIntervalSince(s) >= 5 {
            notify.send(key: "highV", title: tr("⚠️ Töltő hiba", "⚠️ Charging fault"),
                        body: tr("Feszültség túl magas: \(volts)V — Ellenőrizd az alternátort",
                                 "Voltage too high: \(volts)V — check the alternator"),
                        level: .timeSensitive, throttle: 300)
        }
        if log, now.timeIntervalSince(lastVoltageLog) >= 600 { logVoltage(v, event: "periodic") }
    }

    private func logVoltage(_ v: Double?, event: String) {
        guard let v else { return }
        lastVoltageLog = Date()
        db.execute("INSERT INTO voltage_log(t, voltage, event, car_id) VALUES(?,?,?,?)",
                   [Date().timeIntervalSince1970, v, event, CarStore.activeId])
        db.execute("DELETE FROM voltage_log WHERE t < ?", [Date().timeIntervalSince1970 - 90 * 86400])
        dataVersion += 1
    }

    // MARK: - Hibakódok

    /// Kialakulóban lévő hiba: egyszer szól róla autónként, amíg el nem tűnik.
    private func updatePendingCodes(_ p: VehiclePacket) {
        guard p.ecu else { return }
        let key = CarStore.key("pendingNotified")
        let notified = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let current = Set(p.pendingCodes).subtracting(p.faultCodes)
        for code in current.subtracting(notified).sorted() {
            notify.send(key: "pending-\(code)",
                        title: tr("🟡 Kialakulóban lévő hiba: \(code)", "🟡 Developing fault: \(code)"),
                        body: tr("\(DTC.describe(code)). A motorhiba lámpa még nem ég, de érdemes figyelni.",
                                 "\(DTC.describe(code)). The check-engine light isn't on yet, but keep an eye on it."))
        }
        if current != notified { UserDefaults.standard.set(Array(current), forKey: key) }
    }

    private func updateFaultCodes(_ p: VehiclePacket) {
        updatePendingCodes(p)
        guard p.ecu, p.faultCodes != lastCodes else { return }
        lastCodes = p.faultCodes
        let fresh = DTC.update(active: p.faultCodes)
        dataVersion += 1
        for code in fresh {
            // Ha az ECU rögzítette a hiba pillanatát, azt mentjük; különben a mostani mért értékeket.
            let snap: DTCSnapshot
            if let f = p.freeze, f.dtc == code {
                snap = DTCSnapshot(fromEcu: true, rpm: f.rpm, speed: f.speed, coolant: f.coolant, load: f.load)
            } else {
                snap = DTCSnapshot(fromEcu: false, rpm: p.rpm, speed: p.vehicleSpeed,
                                   coolant: p.coolantTemp, load: p.engineLoad)
            }
            DTC.saveSnapshot(code, snap)
            notify.send(key: "dtc-\(code)", title: tr("🚗 Hibakód: \(code)", "🚗 Fault code: \(code)"),
                        body: "\(DTC.describe(code)) — \(DTC.severity(code).label)", level: .timeSensitive)
        }
        if !fresh.isEmpty { Haptics.error() }
    }

    // MARK: - Widget

    /// A widget nem tud élő adatot olvasni: az app menti a legutóbbi értékeket, és ritkán
    /// (állapotváltáskor vagy 15 percenként) kér frissítést, mert az iOS korlátozza a darabszámot.
    private func updateWidget(_ p: VehiclePacket, now: Date) {
        guard now.timeIntervalSince(lastWidgetSave) >= 30 else { return }
        lastWidgetSave = now
        WidgetSnapshot(voltage: p.batteryVoltage, coolant: p.coolantTemp,
                       engineRunning: p.engineRunning, updated: now).save()

        let level = Self.level(for: p.batteryVoltage, running: p.engineRunning)
        let warm = (p.coolantTemp ?? 0) >= CarSpec.warmTemp
        let state = "\(p.engineRunning)-\(level)-\(warm)"
        if state != lastWidgetState || now.timeIntervalSince(lastWidgetReload) >= 900 {
            lastWidgetState = state
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Lekérdezések a nézeteknek

    func voltageLog(days: Int) -> [(t: Date, v: Double)] {
        db.query("SELECT t, voltage FROM voltage_log WHERE t >= ? AND car_id = ? ORDER BY t",
                 [Date().timeIntervalSince1970 - Double(days) * 86400, CarStore.activeId]) {
            (Date(timeIntervalSince1970: $0.double(0)), $0.double(1))
        }
    }
}
