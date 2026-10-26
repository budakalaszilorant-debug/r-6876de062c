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
            if settings.activeCarId == 0 {
                NavigationStack {
                    List {
                        Section {
                            Label(tr("Üres a garázsod", "Your garage is empty"), systemImage: "car.2")
                            Text(tr("Jelentkezz be a saját autóidhoz, vagy add hozzá az első autódat.", "Sign in to access your cars, or add your first car."))
                            Button(tr("Autó hozzáadása", "Add car")) { showGarage = true }
                        }
                        NavigationLink(tr("Családi garázs", "Family garage")) { FamilyGarageView() }
                        CloudSection()
                    }.navigationTitle(tr("Garázs", "Garage"))
                }
            } else if vSize == .compact && tab == 0 && monitor.isLive {
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
                        OverviewView()
                            .tabItem { Label(tr("Áttekintés", "Overview"), systemImage: "square.grid.2x2") }
                            .tag(0)
                        TripsView()
                            .tabItem { Label(tr("Utak", "Trips"), systemImage: "map") }
                            .tag(2)
                        GarageHubView()
                            .tabItem { Label(tr("Garázs", "Garage"), systemImage: "car.2") }
                            .tag(3)
                        SettingsView()
                            .tabItem { Label(tr("Profil", "Profile"), systemImage: "person.crop.circle") }
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
        .fullScreenCover(isPresented: Binding(get: { !settings.onboarded && settings.activeCarId > 0 }, set: { _ in })) {
            OnboardingView()
                .preferredColorScheme(.dark)
        }
    }
}
