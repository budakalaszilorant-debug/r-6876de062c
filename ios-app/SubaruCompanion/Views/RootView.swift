import SwiftUI

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var showGarage = UserDefaults.standard.bool(forKey: "uiGarage")
    @Environment(\.verticalSizeClass) private var vSize
    /// Kezdő fül; a "-uiTab N" indítási paraméter felülírja (képernyőképekhez).
    @State private var tab = UserDefaults.standard.integer(forKey: "uiTab")

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        Group {
            if vSize == .compact {
                // Fekvő telefon: teljes képernyős műszerfal
                LandscapeDashboard()
            } else {
                VStack(spacing: 0) {
                    ConnectionBar()
                    if monitor.needsCarSelection {
                        Button(tr("Válaszd ki a csatlakoztatott autót", "Select the connected car")) { showGarage = true }
                            .padding(10)
                    }
                    TabView(selection: $tab) {
                        DashboardView()
                            .tabItem { Label(tr("Műszerfal", "Dashboard"), systemImage: "speedometer") }
                            .tag(0)
                        DriveView()
                            .tabItem { Label(tr("G-erő", "G-force"), systemImage: "scope") }
                            .tag(1)
                        TripsView()
                            .tabItem { Label(tr("Utak", "Trips"), systemImage: "map") }
                            .tag(2)
                        CarView()
                            .tabItem { Label(tr("Autó", "Car"), systemImage: "car") }
                            .tag(3)
                        SettingsView()
                            .tabItem { Label(tr("Beállítások", "Settings"), systemImage: "gearshape") }
                            .tag(4)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .screenBackground()
        .id("\(settings.language.rawValue)-\(settings.activeCarId)")  // nyelv- vagy autóváltáskor minden frissül
        .sheet(isPresented: $showGarage) {
            NavigationStack {
                GarageView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { showGarage = false } }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !settings.onboarded }, set: { _ in })) {
            OnboardingView()
                .preferredColorScheme(.dark)
        }
    }
}
