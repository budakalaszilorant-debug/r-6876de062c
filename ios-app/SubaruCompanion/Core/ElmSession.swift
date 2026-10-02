import Foundation
import CoreBluetooth

/// Közvetlen kapcsolat egy bolti Bluetooth LE OBD dugóval (ELM327 kompatibilis, pl. Vgate iCar Pro BLE).
/// Ugyanazt csinálja, mint az ESP32 firmware: sorban lekérdezi az autót, és `VehiclePacket`-et ad ki,
/// így az app többi része nem tudja, melyik eszköz van csatlakoztatva.
///
/// Csak olvas: minden parancs átmegy az `Elm.isAllowed` szűrőn, a tiltott parancs ki sem megy.
/// Minden hívás a főszálon történik (a CoreBluetooth is a főszálon hív vissza).
final class ElmSession {
    typealias Step = (_ done: @escaping () -> Void) -> Void

    private weak var peripheral: CBPeripheral?
    private let writeChar: CBCharacteristic
    private let onPacket: (VehiclePacket) -> Void
    private(set) var running = false

    // Parancs-válasz
    private var rx = ""
    private var pending: ((String) -> Void)?
    private var timeoutItem: DispatchWorkItem?
    private var lastReply = Date.distantPast

    // Adapter és autó állapota
    private var elmReady = false
    private var isCan = true
    private var ecuOnline = false
    private var ecuFails = 0
    private var supported = Set<UInt8>()
    private var vin: String?
    private var engineRunning = false
    private var engineStoppedAt: Date?
    private var startId: Int {
        get { UserDefaults.standard.integer(forKey: "elmStartId") }
        set { UserDefaults.standard.set(newValue, forKey: "elmStartId") }
    }
    private var packet = VehiclePacket()
    private var dtcs: [String] = []
    private var tripKm = 0.0
    private var lastSpeedAt: Date?
    private var lastOffV: Double?
    private var voltWindow: [Double] = []
    private var freezeValid = false
    /// Frissen online lett az ECU: a következő ciklus elején protokoll, PID lista, VIN
    private var needsOnlineSetup = false
    /// Időtúllépés után a késve érkező válasz ('>' promptig) eldobandó
    private var dropNextPrompt = false
    private let started = Date()

    // Időzítés (mint a firmware-ben)
    private var tCycle = Date.distantPast
    private var tVoltage = Date.distantPast, tMedium = Date.distantPast, tCoolant = Date.distantPast
    private var tSlow = Date.distantPast, tDist = Date.distantPast, tDtc = Date.distantPast
    private var tProbe = Date.distantPast, tVin = Date.distantPast, tInit = Date.distantPast

    private static let cycle: TimeInterval = 0.25
    private static let rpmRunning = 400.0

    init(peripheral: CBPeripheral, write: CBCharacteristic, onPacket: @escaping (VehiclePacket) -> Void) {
        self.peripheral = peripheral
        self.writeChar = write
        self.onPacket = onPacket
    }

    func start() {
        guard !running else { return }
        running = true
        packet.startId = startId
        nextCycle()
    }

    func stop() {
        running = false
        timeoutItem?.cancel()
        let p = pending
        pending = nil
        p?("STOPPED")
    }

    /// A dugótól érkező adat. A válasz végét a '>' prompt jelzi.
    func receive(_ data: Data) {
        rx += String(decoding: data, as: UTF8.self)
        guard let end = rx.firstIndex(of: ">") else {
            if rx.count > 4096 { rx = "" }
            return
        }
        let text = String(rx[..<end])
        rx = String(rx[rx.index(after: end)...])
        if dropNextPrompt {
            dropNextPrompt = false
            return
        }
        finish(text)
    }

    // MARK: Parancsok

    private func send(_ cmd: String, timeout: TimeInterval = 1.5, _ handle: @escaping (String) -> Void) {
        guard running, let peripheral else { handle("STOPPED"); return }
        // Csak olvasó parancs mehet ki az autó felé.
        guard Elm.isAllowed(cmd) else { handle("BLOCKED"); return }
        rx = ""
        pending = handle
        let item = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)

        let type: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        let bytes = Array((cmd + "\r").utf8)
        let chunk = max(20, peripheral.maximumWriteValueLength(for: type))
        var i = 0
        while i < bytes.count {
            peripheral.writeValue(Data(bytes[i..<min(bytes.count, i + chunk)]), for: writeChar, type: type)
            i += chunk
        }
    }

    /// Válasz lezárása (nil = időtúllépés, ilyenkor az eddig jött szöveg számít).
    private func finish(_ text: String?) {
        guard let handle = pending else { return }
        pending = nil
        timeoutItem?.cancel()
        if text != nil { lastReply = Date() } else { dropNextPrompt = true }
        let r = (text ?? rx).replacingOccurrences(of: "SEARCHING...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        handle(text == nil && r.isEmpty ? "" : r)
    }

    private func query(_ cmd: String, timeout: TimeInterval = 1.5, _ handle: @escaping (String) -> Void) -> Step {
        { [weak self] done in
            guard let self else { return }
            self.send(cmd, timeout: timeout) { r in handle(r); done() }
        }
    }

    private func pid(_ p: UInt8, _ count: Int, timeout: TimeInterval = 1.5, _ handle: @escaping ([UInt8]?) -> Void) -> Step {
        query("01" + Elm.hex2(p), timeout: timeout) { r in handle(Elm.pid(r, p, count: count)) }
    }

    private func when(_ condition: @escaping () -> Bool, _ step: @escaping Step) -> Step {
        { done in condition() ? step(done) : done() }
    }

    private func run(_ steps: [Step], then: @escaping () -> Void) {
        guard running else { return }
        guard let first = steps.first else { then(); return }
        first { [weak self] in
            DispatchQueue.main.async { self?.run(Array(steps.dropFirst()), then: then) }
        }
    }

    // MARK: Ciklus

    private func nextCycle() {
        guard running else { return }
        let wait = max(0, Self.cycle - Date().timeIntervalSince(tCycle))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.running else { return }
            self.tCycle = Date()
            self.run(self.plan()) { [weak self] in
                self?.emit()
                self?.nextCycle()
            }
        }
    }

    private func due(_ t: inout Date, _ interval: TimeInterval) -> Bool {
        guard Date().timeIntervalSince(t) >= interval else { return false }
        t = Date()
        return true
    }

    private func plan() -> [Step] {
        if !elmReady {
            guard due(&tInit, 5) else { return [] }
            return initSteps()
        }
        // Ha a dugó sokáig nem válaszol, újrainicializálás.
        if Date().timeIntervalSince(lastReply) > 20 {
            elmReady = false
            setOffline()
            return []
        }

        var steps: [Step] = []
        if needsOnlineSetup {
            needsOnlineSetup = false
            steps += onlineSetupSteps()
        }
        if ecuOnline {
            steps += fastSteps()
        } else if due(&tProbe, 10) {
            steps.append(pid(0x00, 4, timeout: 12) { [weak self] b in self?.markEcu(b != nil) })
        }

        if due(&tVoltage, 2) {
            steps.append({ [weak self] done in
                guard let self else { return }
                if self.ecuOnline && self.supported.contains(0x42) {
                    self.send("0142") { r in
                        if let b = Elm.pid(r, 0x42, count: 2) {
                            self.packet.batteryVoltage = Double(Int(b[0]) * 256 + Int(b[1])) / 1000
                            self.packet.voltageSrc = "pid"
                        }
                        done()
                    }
                } else {
                    self.send("ATRV") { r in
                        self.packet.batteryVoltage = Elm.voltage(r)
                        self.packet.voltageSrc = "adapter"
                        if !self.ecuOnline, let v = self.packet.batteryVoltage, v < 13.2 { self.lastOffV = v }
                        done()
                    }
                }
            })
        }
        // Gyújtás rajta, motor áll: sűrű mérés az önindítózás feszültségeséséhez.
        steps.append(when({ [weak self] in (self?.ecuOnline ?? false) && !(self?.engineRunning ?? true) },
                          query("ATRV") { [weak self] r in
                              guard let self, let v = Elm.voltage(r) else { return }
                              self.voltWindow.append(v)
                              if self.voltWindow.count > 16 { self.voltWindow.removeFirst() }
                          }))
        guard ecuOnline else { return steps }

        if due(&tMedium, 1) {
            steps.append(pid(0x04, 1) { [weak self] b in self?.packet.engineLoad = b.map { Double($0[0]) * 100 / 255 } })
            steps.append(pid(0x11, 1) { [weak self] b in self?.packet.throttlePos = b.map { Double($0[0]) * 100 / 255 } })
            steps.append(when({ [weak self] in self?.supported.contains(0x5E) ?? false },
                              pid(0x5E, 2) { [weak self] b in
                                  self?.packet.fuelRate = b.map { Double(Int($0[0]) * 256 + Int($0[1])) * 0.05 }
                              }))
        }
        if due(&tCoolant, 2) {
            steps.append(pid(0x05, 1) { [weak self] b in self?.packet.coolantTemp = b.map { Double($0[0]) - 40 } })
        }
        if due(&tSlow, 5) {
            steps.append(pid(0x0F, 1) { [weak self] b in self?.packet.intakeTemp = b.map { Double($0[0]) - 40 } })
            steps.append(supportedPid(0x2F, 1) { [weak self] b in self?.packet.fuelLevel = b.map { Double($0[0]) * 100 / 255 } })
            steps.append(supportedPid(0x51, 1) { [weak self] b in if let b { self?.packet.fuelType = Int(b[0]) } })
            steps.append(supportedPid(0x06, 1) { [weak self] b in self?.packet.stft = b.map { (Double($0[0]) - 128) * 100 / 128 } })
            steps.append(supportedPid(0x07, 1) { [weak self] b in self?.packet.ltft = b.map { (Double($0[0]) - 128) * 100 / 128 } })
        }
        if due(&tDist, 60) {
            steps.append(supportedPid(0x31, 2) { [weak self] b in self?.packet.distSinceClearKm = b.map { Double(Int($0[0]) * 256 + Int($0[1])) } })
            steps.append(pid(0x01, 4) { [weak self] b in if let b { self?.packet.mon = b.map { Int($0) } } })
            steps.append(supportedPid(0x21, 2) { [weak self] b in self?.packet.distMilKm = b.map { Double(Int($0[0]) * 256 + Int($0[1])) } })
            steps.append(supportedPid(0x4D, 2) { [weak self] b in self?.packet.timeMilMin = b.map { Double(Int($0[0]) * 256 + Int($0[1])) } })
            steps.append(supportedPid(0x4E, 2) { [weak self] b in self?.packet.timeClearMin = b.map { Double(Int($0[0]) * 256 + Int($0[1])) } })
            steps.append(supportedPid(0xA6, 4) { [weak self] b in
                guard let b else { return }
                let raw = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
                self?.packet.odometerKm = Double(raw) / 10
            })
        }
        if due(&tDtc, 30) { steps += dtcSteps() }
        if vin == nil, due(&tVin, 30) { steps.append(vinStep()) }
        return steps
    }

    private func supportedPid(_ p: UInt8, _ count: Int, _ handle: @escaping ([UInt8]?) -> Void) -> Step {
        when({ [weak self] in self?.supported.contains(p) ?? false }, pid(p, count, handle))
    }

    private func initSteps() -> [Step] {
        var ok = true
        let check: (String) -> Void = { r in if !r.contains("OK") { ok = false } }
        return [
            query("ATZ", timeout: 2.5) { _ in },
            query("ATE0", check), query("ATL0", check), query("ATS0", check), query("ATH0", check),
            query("ATAT1", check), query("ATSP0", check),
            { [weak self] done in
                guard let self else { return }
                self.elmReady = ok
                if ok { self.lastReply = Date() }
                done()
            },
            // Első próba protokoll kereséssel (lassú lehet)
            when({ [weak self] in self?.elmReady ?? false },
                 pid(0x00, 4, timeout: 12) { [weak self] b in self?.markEcu(b != nil) }),
        ]
    }

    private func fastSteps() -> [Step] {
        [
            pid(0x0C, 2) { [weak self] b in
                guard let self else { return }
                self.markEcu(b != nil)
                self.packet.rpm = b.map { Double(Int($0[0]) * 256 + Int($0[1])) / 4 }
            },
            when({ [weak self] in self?.ecuOnline ?? false }, pid(0x0D, 1) { [weak self] b in
                guard let self else { return }
                let now = Date()
                if let b {
                    if let last = self.lastSpeedAt, let v = self.packet.vehicleSpeed {
                        self.tripKm += v * now.timeIntervalSince(last) / 3600
                    }
                    self.packet.vehicleSpeed = Double(b[0])
                    self.lastSpeedAt = now
                } else {
                    self.packet.vehicleSpeed = nil
                    self.lastSpeedAt = nil
                }
            }),
            when({ [weak self] in (self?.ecuOnline ?? false) && (self?.supported.contains(0x10) ?? false) },
                 pid(0x10, 2) { [weak self] b in self?.packet.maf = b.map { Double(Int($0[0]) * 256 + Int($0[1])) / 100 } }),
        ]
    }

    private func dtcSteps() -> [Step] {
        [
            query("07", timeout: 3) { [weak self] r in
                guard let self, let c = Elm.dtcs(r, isCan: self.isCan, max: 10, replyPrefix: "47") else { return }
                self.packet.pendingCodes = c
            },
            query("0A", timeout: 3) { [weak self] r in
                guard let self, let c = Elm.dtcs(r, isCan: self.isCan, max: 10, replyPrefix: "4A") else { return }
                self.packet.permanentCodes = c
            },
            query("03", timeout: 3) { [weak self] r in
                guard let self, let c = Elm.dtcs(r, isCan: self.isCan, max: 10) else { return }
                if c != self.dtcs { self.freezeValid = false }
                self.dtcs = c
                if c.isEmpty { self.packet.freeze = nil; self.freezeValid = true }
            },
            when({ [weak self] in !(self?.freezeValid ?? true) }, freezeStep()),
        ]
    }

    /// A hibakód keletkezésekor rögzített adatok (Mode 02).
    private func freezeStep() -> Step {
        { [weak self] done in
            guard let self else { return }
            var f = VehiclePacket.FreezeFrame()
            func fp(_ p: UInt8, _ n: Int, _ h: @escaping ([UInt8]) -> Void) -> Step {
                self.query("02" + Elm.hex2(p) + "00") { r in if let b = Elm.freeze(r, p, count: n) { h(b) } }
            }
            self.run([
                fp(0x02, 2) { b in if b[0] != 0 || b[1] != 0 { f.dtc = Elm.formatDtc(b[0], b[1]) } },
                fp(0x0C, 2) { b in f.rpm = Double(Int(b[0]) * 256 + Int(b[1])) / 4 },
                fp(0x0D, 1) { b in f.speed = Double(b[0]) },
                fp(0x05, 1) { b in f.coolant = Double(b[0]) - 40 },
                fp(0x04, 1) { b in f.load = Double(b[0]) * 100 / 255 },
            ]) { [weak self] in
                self?.packet.freeze = f.dtc == nil ? nil : f
                self?.freezeValid = true
                done()
            }
        }
    }

    private func vinStep() -> Step {
        query("0902", timeout: 3) { [weak self] r in
            if let v = Elm.vin(r) { self?.vin = v }
        }
    }

    // MARK: Állapot

    private func markEcu(_ ok: Bool) {
        if ok {
            ecuFails = 0
            guard !ecuOnline else { return }
            ecuOnline = true
            vin = nil
            needsOnlineSetup = true   // a futó lépéssor mellé nem indíthatunk másikat
        } else {
            ecuFails += 1
            if ecuFails >= 3, ecuOnline { setOffline() }
        }
    }

    /// Frissen online: protokoll, támogatott PID-ek, VIN, és rögtön hibakód olvasás.
    private func onlineSetupSteps() -> [Step] {
        [
            query("ATDPN") { [weak self] r in
                let p = r.trimmingCharacters(in: .whitespacesAndNewlines).last ?? "0"
                self?.isCan = ("6"..."9").contains(p)
            },
            supportedPidsStep(),
            vinStep(),
            { [weak self] done in
                self?.tDtc = .distantPast
                done()
            },
        ]
    }

    private func supportedPidsStep() -> Step {
        { [weak self] done in
            guard let self else { return }
            self.supported.removeAll()
            func page(_ base: UInt8) {
                self.send("01" + Elm.hex2(base)) { r in
                    guard let b = Elm.pid(r, base, count: 4) else { done(); return }
                    for i in 0..<32 where b[i / 8] & (0x80 >> UInt8(i % 8)) != 0 {
                        self.supported.insert(base &+ UInt8(i + 1))
                    }
                    let next = base &+ 0x20
                    if base < 0xA0, self.supported.contains(next) {
                        DispatchQueue.main.async { page(next) }
                    } else {
                        done()
                    }
                }
            }
            page(0x00)
        }
    }

    private func setOffline() {
        ecuOnline = false
        engineRunning = false
        let keepVoltage = packet.batteryVoltage
        let keep = (packet.startId, packet.voltageSrc)
        packet = VehiclePacket()
        packet.startId = keep.0
        packet.voltageSrc = keep.1
        packet.batteryVoltage = keepVoltage
        dtcs = []
        freezeValid = false
        lastSpeedAt = nil
    }

    private func updateEngineState() {
        let running = (packet.rpm ?? 0) >= Self.rpmRunning
        if running && !engineRunning {
            // Új indítási ciklus, ha legalább 5 mp-ig állt
            if engineStoppedAt.map({ Date().timeIntervalSince($0) > 5 }) ?? true {
                startId += 1
                tripKm = 0
                packet.restV = lastOffV
                let low = voltWindow.min()
                packet.crankMinV = (low != nil && lastOffV != nil && low! < lastOffV! - 0.5) ? low : nil
                voltWindow.removeAll()
            }
        }
        if !running && engineRunning { engineStoppedAt = Date() }
        engineRunning = running
    }

    private func emit() {
        updateEngineState()
        packet.seq += 1
        packet.uptimeMs = Int(Date().timeIntervalSince(started) * 1000)
        packet.elm = elmReady
        packet.ecu = ecuOnline
        packet.engineRunning = engineRunning
        packet.startId = startId
        packet.faultCodes = dtcs
        packet.vin = vin
        packet.tripKm = (tripKm * 100).rounded() / 100
        onPacket(packet)
    }
}
