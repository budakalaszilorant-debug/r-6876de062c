import Foundation
import SQLite3

// The same Foundation/SQLite production sources run on the macOS CI host.
// Only the UI-facing service item is supplied here; storage and migrations are not mocked.
struct ServiceItem {
    let id: String
    let hu: String
    let en: String
    let intervalKm: Double
    var critical = false
}

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError("FAIL: \(message)") }
}
let defaults = UserDefaults.standard
for key in ["onboarded", "odoSet", "odo", "vin", "activeCarId"] { defaults.removeObject(forKey: key) }
let settings = AppSettings.shared
let db = Database.shared
let cars = CarStore.all()
expect(cars.count == 2, "clean install has exactly two profiles")
let fiesta = cars.first { $0.template == "ford_fiesta_14" }!
let combo = cars.first { $0.template == "opel_combo_16cdti" }!
expect(fiesta.fuel == .petrol && combo.fuel == .diesel, "correct fuel types")
expect(CarStore.validVIN("WF012345678901234"), "valid VIN")
expect(!CarStore.validVIN("WF0INVALID"), "invalid VIN")
settings.activate(fiesta.id)
settings.odometerKm = 123456
settings.odometerSet = true
settings.lastFuelPrice = 610
FuelStore.add(date: Date(), liters: 30, cost: 18300, odometer: 123456, full: true)
expect(DTC.update(active: ["P0300"]) == ["P0300"], "first car code added")
settings.activate(combo.id)
settings.lastFuelPrice = 650
expect(settings.odometerKm == 0 && !settings.odometerSet, "odometer isolation")
expect(FuelStore.all().isEmpty && DTC.history().isEmpty, "fuel and DTC isolation")
expect(DTC.update(active: ["P0300"]) == ["P0300"], "same code on different cars")
_ = DTC.update(active: [])
expect(DTC.history().first?.active == false, "second car code cleared in local history")
settings.activate(fiesta.id)
expect(settings.odometerKm == 123456 && settings.lastFuelPrice == 610, "profile survives switching")
expect(DTC.history().first?.active == true, "first car code unaffected")
expect(FuelStore.all().count == 1, "first car fill preserved")
var packet = VehiclePacket()
packet.engineRunning = true; packet.maf = 10
expect(packet.fuelRateLph != nil, "petrol MAF estimate")
settings.activate(combo.id)
expect(packet.fuelRateLph == nil, "diesel never uses petrol MAF formula")
packet.fuelRate = 1.25
expect(packet.fuelRateLph == 1.25, "diesel direct consumption supported")
let version = db.query("PRAGMA user_version") { $0.int(0) }.first
expect(version == 2, "garage schema committed")
expect(db.query("SELECT interval_km FROM service_plan WHERE car_id = ?", [combo.id]) { $0.double(0) }.allSatisfy { $0 == 0 }, "unverified schedules require user intervals")

// Full backup round trip, followed by a late SQL failure to exercise rollback.
let backup = Backup.makeData()!
let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
defer { try? FileManager.default.removeItem(at: file) }
try backup.write(to: file)
db.execute("DELETE FROM fills")
_ = try Backup.restore(from: file)
settings.activate(fiesta.id)
expect(FuelStore.all().count == 1, "round-trip restores car-owned records")
expect(settings.lastFuelPrice == 610, "round-trip restores per-car preferences")
var corrupt = try JSONSerialization.jsonObject(with: backup) as! [String: Any]
var tables = corrupt["tables"] as! [String: [[String: Any]]]
tables["dtc_hist"]![0]["nonexistent_column"] = "invalid"
corrupt["tables"] = tables
try JSONSerialization.data(withJSONObject: corrupt).write(to: file)
do {
    _ = try Backup.restore(from: file)
    fatalError("invalid SQL backup should fail")
} catch { expect(FuelStore.all().count == 1 && CarStore.all().count == 2, "late failure rolls all writes back") }
tables = (try JSONSerialization.jsonObject(with: backup) as! [String: Any])["tables"] as! [String: [[String: Any]]]
tables["fills"]![0]["car_id"] = 99999
corrupt["tables"] = tables
try JSONSerialization.data(withJSONObject: corrupt).write(to: file)
do { _ = try Backup.restore(from: file); fatalError("orphan backup should fail") }
catch { expect(FuelStore.all().count == 1, "orphan rejected without deleting data") }

// Migrate an actual old SQLite file, including service-only history and repeated launch.
let oldPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
defer { try? FileManager.default.removeItem(atPath: oldPath) }
var old: OpaquePointer?
sqlite3_open(oldPath, &old)
sqlite3_exec(old, "CREATE TABLE service(item TEXT PRIMARY KEY,last_km REAL,last_date REAL); INSERT INTO service VALUES('oil',100000,1700000000);", nil, nil, nil)
sqlite3_close(old)
defaults.set(false, forKey: "odoSet")
defaults.set(false, forKey: "onboarded")
do {
    let migrated = Database(path: oldPath)
    expect(migrated.query("SELECT COUNT(*) FROM cars") { $0.int(0) }.first == 3, "service-only history preserved in legacy profile")
    expect(migrated.query("SELECT last_km FROM service_done WHERE item='oil'") { $0.double(0) }.first == 100000, "legacy service migrated")
}
do {
    let reopened = Database(path: oldPath)
    expect(reopened.query("SELECT COUNT(*) FROM cars") { $0.int(0) }.first == 3, "migration idempotent")
}

// Old JSON backups must retain service/reminder/DTC histories, not silently ignore them.
let legacy: [String: Any] = ["version": 1, "settings": ["carName": "Old car", "odo": 100000.0], "tables": [
    "trips": [], "trip_points": [], "fills": [], "parking": [], "voltage_log": [], "events": [], "battery_health": [],
    "service": [["item": "oil", "last_km": 90000.0, "last_date": 1700000000.0]],
    "reminders": [["id": "insurance", "date": 1900000000.0]],
    "dtc_log": [["code": "P0300", "first_seen": 1.0, "last_seen": 2.0, "active": 1, "snap": NSNull()]]
]]
try JSONSerialization.data(withJSONObject: legacy).write(to: file)
_ = try Backup.restore(from: file)
expect(CarStore.all().count == 1 && CarStore.all()[0].name == "Old car", "legacy JSON creates one preserved profile")
expect(db.query("SELECT COUNT(*) FROM service_done") { $0.int(0) }.first == 1, "legacy JSON services")
expect(db.query("SELECT COUNT(*) FROM reminder_dates") { $0.int(0) }.first == 1, "legacy JSON reminders")
expect(DTC.history().count == 1, "legacy JSON fault history")
CarStore.delete(CarStore.activeId)
expect(CarStore.all().count == 1, "last or active car cannot be deleted")
// Cloud state regression: new phones, concurrent edits, offline retry and remote rollback.
expect(CloudDecision.decide(linked: false, base: 0, baseHash: nil, localHash: "empty", remoteRevision: 5, remoteHash: "data") == .link, "new phone must not upload before link consent")
expect(CloudDecision.decide(linked: true, base: 0, baseHash: nil, localHash: "a", remoteRevision: nil, remoteHash: nil) == .upload, "first linked upload")
expect(CloudDecision.decide(linked: true, base: 2, baseHash: "a", localHash: "b", remoteRevision: 2, remoteHash: "a") == .upload, "offline local edit uploads")
expect(CloudDecision.decide(linked: true, base: 2, baseHash: "a", localHash: "a", remoteRevision: 3, remoteHash: "b") == .download, "unchanged phone pulls remote edit")
expect(CloudDecision.decide(linked: true, base: 2, baseHash: "a", localHash: "c", remoteRevision: 3, remoteHash: "b") == .conflict, "concurrent edits cannot overwrite")
expect(CloudDecision.decide(linked: true, base: 2, baseHash: "a", localHash: "b", remoteRevision: 3, remoteHash: "b") == .unchanged, "lost upload response reconciles safely")
expect(CloudDecision.decide(linked: true, base: 2, baseHash: "a", localHash: "a", remoteRevision: nil, remoteHash: nil) == .conflict, "missing cloud data is not overwritten automatically")
expect(CloudDecision.decide(linked: true, base: 4, baseHash: "b", localHash: "b", remoteRevision: 2, remoteHash: "a") == .conflict, "server rollback cannot silently replace newer local data")
let canonicalSource = Backup.makeData()!
let firstHash = try CloudPayload.hash(canonicalSource)
var generatedLater = try JSONSerialization.jsonObject(with: canonicalSource) as! [String: Any]
generatedLater["created"] = 9999999999.0
var changedSettings = generatedLater["settings"] as! [String: Any]
changedSettings["activeCarId"] = 987
changedSettings["onboarded"] = true
generatedLater["settings"] = changedSettings
let laterHash = try CloudPayload.hash(JSONSerialization.data(withJSONObject: generatedLater))
expect(firstHash == laterHash, "timestamps and device selection do not trigger uploads")
changedSettings["lang"] = "changed-language"
generatedLater["settings"] = changedSettings
let editedHash = try CloudPayload.hash(JSONSerialization.data(withJSONObject: generatedLater))
expect(firstHash != editedHash, "actual setting edits do trigger uploads")
let safety = try Backup.writeSafetyCopy()
defer { try? FileManager.default.removeItem(at: safety) }
let safetyData = try Data(contentsOf: safety)
let safetyHash = try CloudPayload.hash(safetyData)
expect(safetyHash == firstHash, "safety copy contains the complete pre-restore garage")
// Per-car extras survive full backup/restore and remain isolated.
let extrasCar = CarStore.activeId
let style = CarStyle(accent: "mint", photo: "photo-test", order: ["trip", "status"], hidden: ["tools"])
try GaragePlus.save(style, key: "style")
var handover = Handover(person: "Test", startKm: 100, startFuel: 50, note: "Before")
handover.endKm = 125; handover.end = Date(); handover.endFuel = 40
try GaragePlus.save([handover], key: "handovers")
expect(handover.distance == 25, "handover distance")
var repair = RepairReport(vin: "WF012345678901234")
repair.originalCodes = ["P0300"]; repair.status = "verified"
try RepairStore.save(repair, car: extrasCar)
RepairStore.observe(["P0300", "P0420"])
expect(RepairStore.all().first?.returnedCodes == ["P0300"], "only original faults count as recurrence")
let extrasBackup = Backup.makeData()!
try db.checkedExecute("DELETE FROM garage_plus")
try extrasBackup.write(to: file)
_ = try Backup.restore(from: file)
expect(GaragePlus.load(CarStyle.self, key: "style")?.accent == "mint", "style restored")
expect(GaragePlus.load([Handover].self, key: "handovers")?.first?.distance == 25, "handover restored")
expect(RepairStore.all().first?.returnedCodes == ["P0300"], "repair report restored")
expect(GaragePlus.load(CarStyle.self, key: "style", car: -1) == nil, "extras car isolation")
settings.activate(extrasCar)
expect(settings.carAccent == "mint" && settings.dashOrder.first == .trip, "per-car appearance activated")

var samples: [DrivingSample] = (0..<6).map { n in
    DrivingSample(id: n, date: Date(timeIntervalSince1970: Double(n)*1000), km: 10, speed: 35,
        idleFraction: 0.1, consumption: n == 5 ? 9 : 6, startTemp: 15,
        warmSeconds: n == 5 ? 700 : 400, coverage: 0.98, source: "pid")
}
expect(DrivingBaseline.compare(samples, warmup: false)?.elevated == true, "consumption deviation with sufficient peers")
expect(DrivingBaseline.compare(samples, warmup: true)?.count == 5, "warm-up comparison")
expect(DrivingBaseline.compare(Array(samples.suffix(5)), warmup: false) == nil, "insufficient history suppressed")
samples[5].source = "maf"
expect(DrivingBaseline.compare(samples, warmup: false) == nil, "mixed measurement sources suppressed")
samples[5].source = "pid"; samples[5].coverage = 0.4
expect(DrivingBaseline.compare(samples, warmup: false) == nil, "partial telemetry suppressed")
samples[5].coverage = 1; samples[5].startTemp = 60
expect(DrivingBaseline.compare(samples, warmup: true) == nil, "different starting temperature suppressed")

print("Garage integration checks passed: \(checks)")
