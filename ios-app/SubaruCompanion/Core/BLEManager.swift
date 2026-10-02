import Foundation
import CoreBluetooth
import Combine

/// Bluetooth LE kapcsolat az autóval. Kétféle eszközt kezel:
/// - saját ESP32 modul: kész JSON csomagokat küld, az app csak feliratkozik rá;
/// - bolti BLE OBD dugó (ELM327, pl. Vgate iCar Pro BLE): az app maga kérdezi le az autót (`ElmSession`).
/// Mindkét esetben csak olvasás történik.
final class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let liveUUID    = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    /// Bolti dugók gyakori soros szolgáltatásai (Vgate / Veepeak: FFF0, sok klón: FFE0, OBDLink / LELink: 18F0 és saját)
    static let dongleServices = [
        CBUUID(string: "FFF0"), CBUUID(string: "FFE0"), CBUUID(string: "18F0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
    ]
    /// Név alapján is felismerjük a dugót, ha nem hirdeti a szolgáltatását.
    private static let dongleNames = ["OBD", "VLINK", "V-LINK", "VGATE", "IOS-", "VEEPEAK", "LELINK", "ELM", "ICAR", "KONNWEI"]
    private static let restoreId = "hu.kocsi.subaru.central"
    private static let savedPeripheralKey = "blePeripheral"

    enum State: Equatable { case off, unauthorized, scanning, connecting, connected }
    enum Device: Equatable { case esp32, dongle }

    @Published private(set) var state: State = .off
    @Published private(set) var device: Device?
    @Published private(set) var deviceName: String?
    let packets = PassthroughSubject<VehiclePacket, Never>()
    /// Diagnosztika: hány csomag jött, és hányat nem sikerült értelmezni
    private(set) var receivedCount = 0
    private(set) var failedCount = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var buffer = Data()
    private let decoder = JSONDecoder()
    private var session: ElmSession?
    private var dongleNotify: CBCharacteristic?
    private var dongleWrite: CBCharacteristic?
    private var pendingServiceScans = 0
    /// Nem OBD eszközök, amikhez véletlenül csatlakoztunk (pl. hasonló nevű fülhallgató)
    private var rejected = Set<UUID>()

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreId]
        )
    }

    /// A mentett eszköz elfelejtése (pl. másik dugóra váltáskor); utána újra keres.
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        teardown()
        peripheral = nil
        startScanOrReconnect()
    }

    private func startScanOrReconnect() {
        guard central.state == .poweredOn else { return }

        // Ismert eszköz: függő connect, az iOS akkor köt rá, amikor hatótávba ér (háttérben is).
        if let idString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
           let id = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }
        state = .scanning
        // Szűrő nélkül keresünk, mert sok dugó nem hirdeti a szolgáltatását; a találatot név vagy
        // szolgáltatás alapján fogadjuk el. (Háttérben az iOS ilyenkor nem keres, de az első
        // párosítás úgyis előtérben történik, utána a mentett azonosítóval csatlakozunk.)
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
    }

    private func isCandidate(_ p: CBPeripheral, _ adv: [String: Any]) -> Bool {
        let services = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if services.contains(Self.serviceUUID) { return true }
        if services.contains(where: { Self.dongleServices.contains($0) }) { return true }
        let name = ((adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "").uppercased()
        return Self.dongleNames.contains { name.contains($0) }
    }

    private func teardown() {
        session?.stop()
        session = nil
        dongleNotify = nil
        dongleWrite = nil
        device = nil
        buffer.removeAll()
    }

    private func handle(chunk: Data) {
        buffer.append(chunk)
        // Csomagvég: '\n'
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            if let packet = try? decoder.decode(VehiclePacket.self, from: Data(line)) {
                receivedCount += 1
                packets.send(packet)
            } else {
                failedCount += 1
            }
        }
        if buffer.count > 4096 { buffer.removeAll() }  // sérült adatfolyam
    }

    /// Dugó: ha megvan az írható és az értesítő karakterisztika, indul a lekérdezés.
    private func startDongleIfReady(_ p: CBPeripheral) {
        guard session == nil, let write = dongleWrite, let notify = dongleNotify else { return }
        p.setNotifyValue(true, for: notify)
        device = .dongle
        state = .connected
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)
        let s = ElmSession(peripheral: p, write: write) { [weak self] packet in
            self?.receivedCount += 1
            self?.packets.send(packet)
        }
        session = s
        s.start()
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Visszaállított, már csatlakozott eszköz: újra feltérképezzük
            if let p = peripheral, p.state == .connected {
                p.discoverServices(nil)
            } else {
                startScanOrReconnect()
            }
        case .unauthorized: state = .unauthorized
        default: state = .off
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !rejected.contains(p.identifier), isCandidate(p, advertisementData) else { return }
        central.stopScan()
        deviceName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        teardown()
        deviceName = p.name ?? deviceName
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        teardown()
        if rejected.contains(p.identifier) {
            peripheral = nil
            startScanOrReconnect()
            return
        }
        state = .connecting
        central.connect(p, options: nil)  // automatikus újracsatlakozás
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        startScanOrReconnect()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        // Saját ESP32 modul
        if let esp = services.first(where: { $0.uuid == Self.serviceUUID }) {
            p.discoverCharacteristics([Self.liveUUID], for: esp)
            return
        }
        // Bolti dugó: az ismert soros szolgáltatások előre, de minden szolgáltatást megnézünk
        let ordered = services.filter { Self.dongleServices.contains($0.uuid) }
            + services.filter { !Self.dongleServices.contains($0.uuid) }
        pendingServiceScans = ordered.count
        if ordered.isEmpty { reject(p) }
        for s in ordered { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        if service.uuid == Self.serviceUUID {
            guard let ch = chars.first(where: { $0.uuid == Self.liveUUID }) else { return }
            p.setNotifyValue(true, for: ch)
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)
            device = .esp32
            state = .connected
            return
        }

        pendingServiceScans -= 1
        // Ugyanabban a szolgáltatásban keresünk egy értesítő és egy írható karakterisztikát.
        if dongleNotify == nil || dongleWrite == nil {
            let notify = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            let write = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            if let notify, let write {
                dongleNotify = notify
                dongleWrite = write
            }
        }
        startDongleIfReady(p)
        // Egyik szolgáltatás sem jó: nem OBD dugó, keresünk tovább.
        if pendingServiceScans <= 0, session == nil, device == nil { reject(p) }
    }

    private func reject(_ p: CBPeripheral) {
        rejected.insert(p.identifier)
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        central.cancelPeripheralConnection(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        if device == .dongle {
            session?.receive(data)
        } else {
            handle(chunk: data)
        }
    }
}
