import Foundation
import CoreLocation
import Combine
import CoreMotion

/// Explicitly started GPS recording, owned by the selected account and car.
final class PhoneDriveRecorder: ObservableObject {
    static let shared = PhoneDriveRecorder()
    @Published private(set) var active: Trip?
    @Published private(set) var waitingForPermission = false
    @Published private(set) var track: [TrackPoint] = []
    @Published private(set) var speed: Double?
    @Published private(set) var lastFixDate: Date?
    @Published private(set) var report = PhoneDriveReport()
    @Published private(set) var isMoving = false
    @Published private(set) var revision = 0
    @Published var message: String?
    var isBusy: Bool { active != nil || waitingForPermission }
    private var metrics = PhoneDriveMetrics()
    private var car = 0
    private var generation = UUID()
    private var bag = Set<AnyCancellable>()
    private let location = LocationManager.shared
    private let motion = CMMotionActivityManager()
    private var stationaryHint = false
    private var motionUpdated = Date.distantPast

    private init() {
        location.updates.sink { [weak self] in self?.receive($0) }.store(in: &bag)
        location.$authorization.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self else { return }
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                if self.waitingForPermission {
                    Task { @MainActor in
                        guard self.waitingForPermission else { return }
                        self.waitingForPermission = false; self.start()
                    }
                }
            } else if status == .denied || status == .restricted {
                self.waitingForPermission = false
                if self.active != nil { _ = self.finish(interrupted: true, reason: "permission") }
                self.message = tr("Az út rögzítéséhez engedélyezd a helyhozzáférést az iPhone Beállításaiban.", "Allow location access in iPhone Settings to record your drive.")
            }
        }.store(in: &bag)
    }

    @MainActor func start() {
        guard active == nil, CloudSync.shared.ready, !CloudSync.shared.busy,
              CarStore.activeId > 0, !VehicleMonitor.shared.demoActive,
              VehicleMonitor.shared.trip == nil, !VehicleMonitor.shared.isLive,
              !VehicleMonitor.shared.needsCarSelection else { return }
        switch location.authorization {
        case .notDetermined:
            waitingForPermission = true; location.requestPermission(); return
        case .authorizedAlways, .authorizedWhenInUse: break
        default:
            message = tr("Engedélyezd a helyhozzáférést az iPhone Beállításaiban.", "Allow location access in iPhone Settings."); return
        }
        waitingForPermission = false
        guard location.hasPreciseLocation else {
            message = tr("Kapcsold be a Pontos helyzetet az iPhone Beállítások → Garázs → Helyzet menüjében, hogy ne pontatlan helyadatokból mérjünk.", "Enable Precise Location in iPhone Settings → Garage → Location before recording.")
            return
        }
        let now = Date()
        car = CarStore.activeId; generation = AccountGarage.generation
        metrics = PhoneDriveMetrics(); track = []; speed = nil; lastFixDate = nil; report = metrics.report; isMoving = false
        do {
            let id = try Database.shared.transaction {
                try Database.shared.checkedExecute("INSERT INTO trips(start,distance_km,max_speed,start_id,car_id) VALUES(?,0,0,NULL,?)", [now.timeIntervalSince1970, car])
                let id = Database.shared.query("SELECT last_insert_rowid()") { $0.int(0) }.first!
                try GaragePlus.save(report, key: "phone-drive-\(id)", car: car)
                return id
            }
            active = Trip(id: id, start: now, end: nil, distanceKm: 0, fuelL: nil, maxSpeed: 0)
            location.startTracking()
            stationaryHint = false; motionUpdated = .distantPast
            if CMMotionActivityManager.isActivityAvailable() {
                motion.startActivityUpdates(to: .main) { [weak self] activity in
                    guard let self, let activity, self.active != nil else { return }
                    self.stationaryHint = activity.stationary && activity.confidence == .high
                    self.motionUpdated = Date()
                }
            }
            startLiveActivityIfNeeded()
            Haptics.tap()
        } catch { message = tr("Az út mentése nem indítható. Próbáld újra.", "Could not start saving the drive. Try again.") }
    }

    func cancelPending() { waitingForPermission = false }
    func refreshHistory() { revision += 1 }

    func endForAccountChange() {
        _ = finish(interrupted: true, reason: "account")
        // If disk writes fail, the persisted open trip can still be recovered later.
        active = nil; track = []; speed = nil; lastFixDate = nil; message = nil
        report = PhoneDriveReport(); metrics = PhoneDriveMetrics(); isMoving = false
    }

    private func receive(_ loc: CLLocation) {
        guard var trip = active, generation == AccountGarage.generation, car == CarStore.activeId,
              loc.timestamp >= trip.start else { return }
        var next = metrics
        let fix = DriveFix(time: loc.timestamp.timeIntervalSince1970, latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy,
            speed: loc.speed, speedAccuracy: loc.speedAccuracy)
        let stationary = stationaryHint && Date().timeIntervalSince(motionUpdated) < 30
        guard next.accept(fix, now: Date().timeIntervalSince1970, stationary: stationary) else { return }
        do {
            try Database.shared.transaction {
                for point in next.routeFixes {
                    try Database.shared.checkedExecute("INSERT INTO trip_points(trip_id,t,lat,lon,speed) VALUES(?,?,?,?,?)",
                        [trip.id, point.time, point.latitude, point.longitude, max(0, point.speed * 3.6)])
                }
                try Database.shared.checkedExecute("UPDATE trips SET distance_km=?,max_speed=? WHERE id=? AND car_id=?",
                    [next.distanceKm, next.maxSpeed, trip.id, car])
                try GaragePlus.save(next.report, key: "phone-drive-\(trip.id)", car: car)
            }
            metrics = next; report = next.report; speed = next.speed; lastFixDate = loc.timestamp; isMoving = next.isMoving
            trip.distanceKm = next.distanceKm; trip.maxSpeed = next.maxSpeed; active = trip
            track.append(contentsOf: next.routeFixes.map { point in
                TrackPoint(t: point.time, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), speed: max(0, point.speed * 3.6))
            })
            if track.count > 2000 { track.removeFirst(track.count - 2000) }
            updateLiveActivity()
        } catch {
            _ = finish(interrupted: true, reason: "storage")
            message = tr("A rögzítés mentési hiba miatt megállt. Az eddig mentett pontok megmaradtak.", "Recording stopped because saving failed. Previously saved points are preserved.")
        }
    }

    @discardableResult
    func finish(interrupted: Bool = false, reason: String = "stopped") -> Trip? {
        waitingForPermission = false
        guard var trip = active else { return nil }
        location.stopTracking()
        motion.stopActivityUpdates()
        DriveActivity.shared.endPhoneDrive()
        report.interrupted = interrupted
        report.endReason = reason
        trip.end = interrupted ? (lastFixDate ?? trip.start) : Date()
        do {
            try Database.shared.transaction {
                try Database.shared.checkedExecute("UPDATE trips SET end_t=? WHERE id=? AND car_id=?", [trip.end!.timeIntervalSince1970, trip.id, car])
                try GaragePlus.save(report, key: "phone-drive-\(trip.id)", car: car)
            }
            active = nil; speed = nil; isMoving = false; revision += 1
            Haptics.tap()
            Task { @MainActor in await CloudSync.shared.autoBackupIfNeeded() }
            return trip
        } catch {
            message = tr("Nem sikerült lezárni az utat. Próbáld újra a Mentés gombbal.", "Could not finish the drive. Try Save again.")
            return nil
        }
    }

    private var activityState: DriveActivityAttributes.ContentState {
        let settings = AppSettings.shared
        let fresh = lastFixDate.map { Date().timeIntervalSince($0) < 15 } ?? false
        return DriveActivityAttributes.ContentState(speed: fresh ? speed.map { Int($0.rounded()) } : nil,
            coolant: nil, warm: false, tripKm: active?.distanceKm ?? 0, consumption: nil,
            carID: car, carName: tr("Telefonos út", "Phone drive"), mode: "phone",
            hu: settings.language == .hu)
    }

    func startLiveActivityIfNeeded() {
        guard AppSettings.shared.featLiveActivity, let trip = active else { return }
        DriveActivity.shared.start(tripStart: trip.start, state: activityState)
    }

    private func updateLiveActivity() {
        guard AppSettings.shared.featLiveActivity else { return }
        DriveActivity.shared.update(activityState)
    }
}
