import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var odometerText = ""
    @FocusState private var odometerFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Nyelv", "Language")) {
                    Picker(tr("Nyelv", "Language"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        Text(tr("Km óra állás", "Odometer"))
                        Spacer()
                        TextField("0", text: $odometerText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(Theme.number(17))
                            .focused($odometerFocused)
                        Text("km").foregroundStyle(Theme.text2)
                    }
                    if odometerFocused {
                        Button(tr("Mentés", "Save")) {
                            if let v = Double(odometerText), v > 0 {
                                settings.odometerKm = v
                                settings.odometerSet = true
                                Haptics.success()
                            }
                            odometerFocused = false
                        }
                    }
                } header: {
                    Text(tr("Autó", "Car"))
                }

                Section {
                    NavigationLink(tr("Műszerfal testreszabása", "Customise dashboard")) { DashboardEditor() }
                }

                FeatureToggles()

                CloudSection()

                BackupSection()

                Section(tr("Jármű", "Vehicle")) {
                    NavigationLink {
                        GarageView()
                    } label: {
                        HStack {
                            Text(tr("Garázs", "Garage"))
                            Spacer()
                            Text(settings.carName).foregroundStyle(Theme.text2)
                        }
                    }
                    row("VIN", settings.vin ?? "—")
                    row(tr("Kapcsolat", "Connection"), connectionText)
                    if let src = monitor.packet?.voltageSrc {
                        row(tr("Feszültség forrás", "Voltage source"),
                            src == "pid" ? tr("Motorvezérlő", "ECU") : tr("OBD adapter", "OBD adapter"))
                    }
                }

                Section {
                    Toggle(tr("Demo mód", "Demo mode"),
                           isOn: Binding(get: { monitor.demoActive }, set: { monitor.setDemo($0) }))
                        .tint(Theme.ok)
                }

                Section(tr("Diagnosztika", "Diagnostics")) {
                    row(tr("Eszköz", "Device"), deviceText)
                    row(tr("Fogadott csomagok", "Packets received"), "\(ble.receivedCount)")
                    row(tr("Hibás csomagok", "Bad packets"), "\(ble.failedCount)")
                    row(tr("OBD adapter", "OBD adapter"), adapterText)
                    row(tr("Motorvezérlő", "ECU"), ecuText)
                    Button(tr("Eszköz elfelejtése, új keresése", "Forget device and search again")) { ble.forgetDevice() }
                }

                Section {
                    row(tr("Adatkezelés", "Data"), CloudSync.shared.signedIn ? tr("Telefon + saját Google Drive", "Phone + your Google Drive")
                                                                     : tr("Csak a telefonon", "On this phone only"))
                    row(tr("Autó vezérlése", "Car control"), tr("Nincs — csak olvasás", "None — read-only"))
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(tr("Beállítások", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if settings.odometerSet { odometerText = String(Int(settings.odometerKm)) }
            }
        }
    }

    private var deviceText: String {
        let name = ble.deviceName.map { " (\($0))" } ?? ""
        switch ble.device {
        case .esp32: return tr("ESP32 modul", "ESP32 module") + name
        case .dongle: return tr("OBD dugó", "OBD dongle") + name
        case .none: return "—"
        }
    }

    private var adapterText: String {
        guard monitor.isLive, !monitor.demoActive, let elm = monitor.packet?.elm else { return "—" }
        return elm ? tr("Rendben", "OK") : tr("Nem válaszol", "Not responding")
    }

    private var ecuText: String {
        guard monitor.isLive, !monitor.demoActive, let p = monitor.packet else { return "—" }
        return p.ecu ? tr("Válaszol", "Responding") : tr("Gyújtás levéve", "Ignition off")
    }

    private var connectionText: String {
        switch ble.state {
        case .connected: return tr("Csatlakozva", "Connected")
        case .connecting: return tr("Csatlakozás…", "Connecting…")
        case .scanning: return tr("Keresés…", "Scanning…")
        case .unauthorized: return tr("Nincs engedély", "No permission")
        case .off: return tr("Bluetooth ki", "Bluetooth off")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Theme.text2).multilineTextAlignment(.trailing)
        }
    }
}
