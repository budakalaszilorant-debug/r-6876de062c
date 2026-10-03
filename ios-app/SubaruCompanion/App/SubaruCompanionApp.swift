import SwiftUI
import BackgroundTasks

@main
struct SubaruCompanionApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var ble = BLEManager.shared
    @StateObject private var monitor = VehicleMonitor.shared
    @StateObject private var location = LocationManager.shared
    @StateObject private var cloud = CloudSync.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ServiceScheduler.registerBackgroundTask()
        // Ha az iOS a háttérben indítja el az appot (BLE esemény), nincs ablak és nem fut a .task:
        // a kapcsolatot és a feldolgozást ezért itt indítjuk.
        _ = BLEManager.shared
        VehicleMonitor.shared.start()
        // Képernyőkép-készítéshez (CI): "-uiDemo YES" indítási paraméterrel rögtön demo módban indul.
        if Self.screenshotMode { VehicleMonitor.shared.setDemo(true) }
    }

    static var screenshotMode: Bool { UserDefaults.standard.bool(forKey: "uiDemo") }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(ble)
                .environmentObject(monitor)
                .environmentObject(location)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    CloudSync.shared.handle(url)
                    LegacyDriveImport.shared.handle(url)
                }
                .sheet(isPresented: $cloud.passwordRecovery) {
                    CloudPasswordView()
                }
                .task {
                    CloudSync.shared.restoreSignIn()
                    guard !Self.screenshotMode else { return }  // ne takarja engedélykérő ablak a képet
                    await NotificationManager.shared.requestPermission()
                    location.requestPermission()
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                ServiceScheduler.schedule()
                Task { await CloudSync.shared.autoBackupIfNeeded() }
            }
            if phase == .active {
                NotificationManager.shared.clearBadge()
                VehicleMonitor.shared.startLiveActivityIfNeeded()
                Task { await FrostCheck.runIfDue() }
                Task { await CloudSync.shared.autoBackupIfNeeded() }
            }
        }
    }
}
