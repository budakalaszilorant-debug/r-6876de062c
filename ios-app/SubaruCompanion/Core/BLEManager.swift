import Foundation
import CoreBluetooth
import Combine

/// BLE kapcsolat az ESP32-vel. Csak olvas és feliratkozik, semmit nem ír a modulra.
final class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let liveUUID    = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let restoreId = "hu.kocsi.subaru.central"
    private static let savedPeripheralKey = "blePeripheral"

    enum State: Equatable { case off, unauthorized, scanning, connecting, connected }

    @Published private(set) var state: State = .off
    let packets = PassthroughSubject<VehiclePacket, Never>()
    /// Diagnosztika: hány csomag jött, és hányat nem sikerült értelmezni
    private(set) var receivedCount = 0
    private(set) var failedCount = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var buffer = Data()
    private let decoder = JSONDecoder()

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreId]
        )
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
        // Háttérben csak service UUID szűrővel lehet keresni.
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
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
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startScanOrReconnect()
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
        central.stopScan()
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)
        buffer.removeAll()
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        state = .connecting
        central.connect(p, options: nil)  // automatikus újracsatlakozás
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        startScanOrReconnect()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        p.discoverCharacteristics([Self.liveUUID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.liveUUID }) else { return }
        p.setNotifyValue(true, for: ch)
        state = .connected
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        handle(chunk: data)
    }
}
