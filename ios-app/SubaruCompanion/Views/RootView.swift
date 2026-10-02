import SwiftUI

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var showGarage = UserDefaults.standard.bool(forKey: "uiGarage")
    @State private var showPicker = false
    /// Csak az app indulásakor kérdez egyszer (nem minden nézetfrissítéskor)
    private static var askedThisLaunch = false
    @Environment(\.verticalSizeClass) private var vSize
    /// Kezdő fül; a "-uiTab N" indítási paraméter felülírja (képernyőképekhez).
    @State private var tab = UserDefaults.standard.integer(forKey: "uiTab")

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    /// Több autó esetén induláskor rákérdez, melyikkel mész, hacsak az app már nem csatlakozott egyhez.
    private func askForCarIfNeeded() {
        guard !Self.askedThisLaunch, settings.onboarded, settings.askCarOnLaunch,
              !monitor.demoActive, !monitor.isLive, !monitor.needsCarSelection,
              CarStore.all().count > 1, !UserDefaults.standard.bool(forKey: "uiDemo") else { return }
        Self.askedThisLaunch = true
        showPicker = true
    }

    var body: some View {
        Group {
            if vSize == .compact {
                // Fekvő telefon: teljes képernyős műszerfal
                LandscapeDashboard()
            } else {
                VStack(spacing: 0) {
                    ConnectionBar(onCarTap: { showPicker = true })
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
        .onChange(of: monitor.needsCarSelection) { needed in
            if needed && settings.onboarded { showGarage = true }
        }
        .sheet(isPresented: $showPicker) {
            CarPickerSheet().presentationDetents([.medium, .large])
        }
        .onAppear(perform: askForCarIfNeeded)
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
