import Foundation
import CoreBluetooth
import Combine

/// Bluetooth LE kapcsolat egy bolti OBD dugóval (ELM327 kompatibilis, pl. Vgate iCar Pro BLE).
/// Az app maga kérdezi le az autót (`ElmSession`), olvasó parancsokkal és külön jóváhagyott hibakódtörléssel.
final class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

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

    @Published private(set) var state: State = .off
    @Published private(set) var deviceName: String?
    let packets = PassthroughSubject<VehiclePacket, Never>()
    /// Diagnosztika: hány adatcsomag készült a dugó válaszaiból
    private(set) var receivedCount = 0

    @Published private(set) var clearingFaults = false
    func clearFaults(completion: @escaping (String) -> Void) {
        guard !clearingFaults, let session else { completion(tr("Nincs kapcsolat.", "Not connected.")); return }
        clearingFaults = true
        session.requestClear(car: CarStore.activeId, expectedVIN: AppSettings.shared.vin ?? "") { [weak self] result in
            self?.clearingFaults = false
            completion(result)
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
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
        if services.contains(where: { Self.dongleServices.contains($0) }) { return true }
        let name = ((adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "").uppercased()
        return Self.dongleNames.contains { name.contains($0) }
    }

    private func teardown() {
        session?.stop()
        session = nil
        dongleNotify = nil
        dongleWrite = nil
    }

    /// Ha megvan az írható és az értesítő karakterisztika, indul a lekérdezés.
    private func startDongleIfReady(_ p: CBPeripheral) {
        guard session == nil, let write = dongleWrite, let notify = dongleNotify else { return }
        p.setNotifyValue(true, for: notify)
        state = .connected
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)
        let s = ElmSession(peripheral: p, write: write) { [weak self] packet in
            self?.receivedCount += 1
            self?.packets.send(packet)
        }
        session = s
        s.onDesync = { [weak self, weak p] in
            guard let self, let p else { return }
            self.central.cancelPeripheralConnection(p)
        }
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
        // Az ismert soros szolgáltatások előre, de minden szolgáltatást megnézünk
        let ordered = services.filter { Self.dongleServices.contains($0.uuid) }
            + services.filter { !Self.dongleServices.contains($0.uuid) }
        pendingServiceScans = ordered.count
        if ordered.isEmpty { reject(p) }
        for s in ordered { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
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
        if pendingServiceScans <= 0, session == nil { reject(p) }
    }

    private func reject(_ p: CBPeripheral) {
        rejected.insert(p.identifier)
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        central.cancelPeripheralConnection(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        session?.receive(data)
    }
}
