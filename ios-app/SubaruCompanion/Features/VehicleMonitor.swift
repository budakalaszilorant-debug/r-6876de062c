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
    private var pendingHealth: (startId: Int, since: Date)?
    private var lastStopAt: Double {
        get { UserDefaults.standard.double(forKey: "lastStopAt") }
        set { UserDefaults.standard.set(newValue, forKey: "lastStopAt") }
    }
    private var lowRangeNotified: Bool {
        get { UserDefaults.standard.bool(forKey: "lowRangeNotified") }
        set { UserDefaults.standard.set(newValue, forKey: "lowRangeNotified") }
    }
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var started = false

    private var lastPacketAt: Date?
    private var coolantSamples: [(t: Date, temp: Double)] = []
    private var warmNotifiedStartId: Int {
        get { UserDefaults.standard.integer(forKey: "warmStartId") }
        set { UserDefaults.standard.set(newValue, forKey: "warmStartId") }
    }
    private var seenStartId: Int {
        get { UserDefaults.standard.integer(forKey: "seenStartId") }
        set { UserDefaults.standard.set(newValue, forKey: "seenStartId") }
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

        BLEManager.shared.packets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &bag)

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
        demoActive = on
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
        let now = Date()
        let dt = min(2, lastPacketAt.map { now.timeIntervalSince($0) } ?? 0)
        lastPacketAt = now
        packet = p
        isLive = true
        leftRunningNotified = false
        updateRange(p, notify: !demo)

        // Sorrend: előbb az indítási ciklus (ez nullázza a bemelegedés állapotát), utána a bemelegedés.
        if !demo {
            if let vin = p.vin, vin != settings.vin { settings.vin = vin }
            updateOdometer(p, dt: dt)
            updateEngineCycle(p, now: now)
        }
        updateWarmUp(p, now: now)
        updateVoltage(p, now: now, log: !demo)
        updateOverheat(p)
        guard !demo else { return }

        updateFaultCodes(p)
        updateBatteryHealth(p, now: now)
        updateWidget(p, now: now)

        if recorder.active != nil {
            recorder.update(packet: p, dt: dt)
            trip = recorder.active
        }
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
            ServiceStore.checkAndNotify(odometer: settings.odometerKm)
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
                let cold = (p.coolantTemp ?? 99) < EJ20.coldStartTemp
                warmUp = WarmUpState(coldStart: cold, startTemp: p.coolantTemp)
                if cold, let t = p.coolantTemp {
                    db.execute("INSERT INTO events(t, kind, value) VALUES(?,?,?)",
                               [now.timeIntervalSince1970, "cold_start", t])
                }
                // Már melegen indult: nem kell értesítés erre a ciklusra.
                if (p.coolantTemp ?? 0) >= EJ20.warmTemp { warmNotifiedStartId = p.startId }
                if settings.featBatteryHealth { pendingHealth = (p.startId, now) }
            }
            if recorder.active == nil {
                recorder.ensureStarted(startId: p.startId, odometer: settings.odometerKm)
                trip = recorder.active
            }
        } else if wasRunning {
            // 5 mp-ig áll a motor = tényleges leállítás (nem lefulladás utáni újraindítás)
            if stoppedSince == nil { stoppedSince = now }
            if let s = stoppedSince, now.timeIntervalSince(s) >= 5 {
                wasRunning = false
                lastStopAt = now.timeIntervalSince1970
                logVoltage(p.batteryVoltage, event: "stop")
                endTrip(promptParking: true)
            }
        }
    }

    private func endTrip(promptParking: Bool = false) {
        let spot = recorder.finish()
        if let spot { parking = spot }
        trip = nil
        wasRunning = false
        dataVersion += 1
        refreshAverages()

        // Leparkolás után felajánljuk a parkolóórát; az értesítés gombjaival az app megnyitása nélkül indítható.
        if promptParking, spot != nil, settings.featParkingTimer, !ParkingTimer.shared.isRunning {
            notify.send(key: "parked", title: tr("🅿️ Leparkoltál", "🅿️ Parked"),
                        body: tr("A hely elmentve. Tartsd nyomva parkolóóra indításához.",
                                 "Spot saved. Press and hold to start a parking timer."),
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

    /// Indítás után 15 mp-cel rögzíti a nyugalmi, az indítási és a töltőfeszültséget.
    private func updateBatteryHealth(_ p: VehiclePacket, now: Date) {
        guard let pending = pendingHealth, p.engineRunning, now.timeIntervalSince(pending.since) >= 15 else { return }
        pendingHealth = nil
        // A nyugalmi érték csak legalább 1 óra állás után mond valamit az akkuról.
        let rested = lastStopAt == 0 || pending.since.timeIntervalSince1970 - lastStopAt >= 3600
        BatteryHealth.record(startId: pending.startId, rest: rested ? p.restV : nil,
                             crank: p.crankMinV, charge: p.batteryVoltage)
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

        let warm = c >= EJ20.warmTemp
        var eta: Double?
        if !warm, let first = coolantSamples.first, now.timeIntervalSince(first.t) >= 30 {
            let rate = (c - first.temp) / now.timeIntervalSince(first.t) * 60  // °C / perc
            if rate > 0.3 { eta = (EJ20.warmTemp - c) / rate }
        }
        if warmUp.isWarm != warm { warmUp.isWarm = warm }
        if warmUp.etaMinutes.map({ Int($0 * 2) }) != eta.map({ Int($0 * 2) }) { warmUp.etaMinutes = eta }

        if warm, warmNotifiedStartId != p.startId {
            warmNotifiedStartId = p.startId   // indítási ciklusonként egyszer
            notify.send(key: "warm", title: "Subaru Impreza",
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
        db.execute("INSERT INTO voltage_log(t, voltage, event) VALUES(?,?,?)",
                   [Date().timeIntervalSince1970, v, event])
        db.execute("DELETE FROM voltage_log WHERE t < ?", [Date().timeIntervalSince1970 - 90 * 86400])
        dataVersion += 1
    }

    // MARK: - Hibakódok

    private func updateFaultCodes(_ p: VehiclePacket) {
        guard p.ecu, p.faultCodes != lastCodes else { return }
        lastCodes = p.faultCodes
        let fresh = DTC.update(active: p.faultCodes)
        dataVersion += 1
        for code in fresh {
            notify.send(key: "dtc-\(code)", title: tr("🚗 Hibakód: \(code)", "🚗 Fault code: \(code)"),
                        body: DTC.describe(code), level: .timeSensitive)
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
        let warm = (p.coolantTemp ?? 0) >= EJ20.warmTemp
        let state = "\(p.engineRunning)-\(level)-\(warm)"
        if state != lastWidgetState || now.timeIntervalSince(lastWidgetReload) >= 900 {
            lastWidgetState = state
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Lekérdezések a nézeteknek

    func voltageLog(days: Int) -> [(t: Date, v: Double)] {
        db.query("SELECT t, voltage FROM voltage_log WHERE t >= ? ORDER BY t",
                 [Date().timeIntervalSince1970 - Double(days) * 86400]) {
            (Date(timeIntervalSince1970: $0.double(0)), $0.double(1))
        }
    }
}
