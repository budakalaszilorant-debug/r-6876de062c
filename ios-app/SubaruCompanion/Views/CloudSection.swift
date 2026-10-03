import SwiftUI

struct CloudSection: View {
    @ObservedObject private var cloud = CloudSync.shared
    @ObservedObject private var legacy = LegacyDriveImport.shared
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var login = false
    @State private var confirmLocal = false
    @State private var confirmDelete = false
    @State private var restoring: CloudVersion?
    @State private var confirmLegacy = false

    var body: some View {
        Section {
            if !cloud.isConfigured {
                Label(tr("A felhő ebben a változatban még nincs beállítva.", "Cloud is not configured in this build."), systemImage: "icloud.slash")
                    .foregroundStyle(Theme.text2)
                Text(tr("Az autók és utak továbbra is a telefonra mentődnek.", "Cars and trips are still saved on this phone."))
                    .font(.footnote).foregroundStyle(Theme.text2)
            } else if cloud.signedIn {
                account
            } else {
                Button { login = true } label: {
                    Label(tr("Bejelentkezés vagy regisztráció", "Sign in or create account"), systemImage: "person.crop.circle.badge.plus")
                }
                Text(tr("A fiók opcionális. Belépve másik telefonra is átviheted a garázsodat.", "An account is optional. Sign in to move your garage to another phone."))
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            if legacy.isConfigured {
                Button { legacy.download() } label: {
                    Label(tr("Korábbi Google Drive-mentés letöltése", "Download previous Google Drive backup"), systemImage: "arrow.down.doc")
                }.disabled(legacy.busy || cloud.busy)
                if legacy.busy { ProgressView() }
                if legacy.file != nil {
                    Button(tr("Letöltött Drive-mentés importálása", "Import downloaded Drive backup")) { confirmLegacy = true }
                        .disabled(!canRestore || cloud.busy)
                }
            }
        } header: { Text(tr("Fiók és felhő", "Account and cloud")) } footer: {
            Text(tr("A szinkronizálás bekapcsolásával az autók, utak (helyadatokkal), költségek és beállítások a saját fiókodba kerülnek. A legutóbbi 20 felhőváltozat állítható vissza. Fájlmentés külön is készíthető.",
                    "Enabling sync uploads cars, trips (including locations), costs and settings to your account. The latest 20 cloud versions can be restored. File export is also available."))
        }
        .sheet(isPresented: $login) { CloudLoginView() }
        .task { if cloud.signedIn { await cloud.refreshRemoteInfo() } }
        .alert(tr("A telefon garázsát használod?", "Use this phone's garage?"), isPresented: $confirmLocal) {
            Button(tr("Telefon garázsának mentése", "Save phone garage")) { Task { await cloud.useLocalGarage() } }
            Button(tr("Mégse", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("A helyi adatokat ehhez a fiókhoz kapcsoljuk. Ha van felhőmentés, az korábbi változatként megmarad. A két garázst nem vonjuk össze.",
                    "Local data will be linked to this account. Any cloud backup remains as a previous version. The two garages are not merged."))
        }
        .alert(tr("Visszaállítod ezt a változatot?", "Restore this version?"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button(tr("Visszaállítás", "Restore"), role: .destructive) {
                if let selected = restoring { Task { await cloud.restoreFromCloud(version: selected) } }
                restoring = nil
            }
            Button(tr("Mégse", "Cancel"), role: .cancel) { restoring = nil }
        } message: {
            Text(tr("A helyi garázst lecseréljük, előtte biztonsági másolat készül a Fájlok / Backups / SafetyCopies mappába.",
                    "The local garage will be replaced after saving a safety copy in Files / Backups / SafetyCopies."))
        }
        .alert(tr("Törlöd a fiókot?", "Delete account?"), isPresented: $confirmDelete) {
            Button(tr("Fiók és felhőadatok törlése", "Delete account and cloud data"), role: .destructive) { Task { await cloud.deleteAccount() } }
            Button(tr("Mégse", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("A fiók és minden felhőmentése végleg törlődik. A telefonon lévő adatok megmaradnak.", "The account and all its cloud backups will be permanently deleted. Data on this phone is preserved."))
        }
        .alert(tr("Importálod a Drive-mentést?", "Import Drive backup?"), isPresented: $confirmLegacy) {
            Button(tr("Importálás", "Import"), role: .destructive) { legacy.restore() }
            Button(tr("Mégse", "Cancel"), role: .cancel) {}
        } message: { Text(tr("A telefon adatairól biztonsági másolat készül, majd a letöltött mentés kerül a helyükre.", "A safety copy is saved before replacing local data with the downloaded backup.")) }
        .alert(cloud.message ?? legacy.message ?? "", isPresented: Binding(
            get: { (cloud.message != nil || legacy.message != nil) && !login },
            set: { if !$0 { cloud.message = nil; legacy.message = nil } })) {
                Button("OK", role: .cancel) { cloud.message = nil; legacy.message = nil }
            }
    }

    private var canRestore: Bool { monitor.canManageGarage && !monitor.demoActive }

    @ViewBuilder private var account: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(cloud.email ?? tr("Saját fiók", "My account")).font(.headline)
                if let date = cloud.lastUpload { Text(tr("Utolsó szinkron: ", "Last sync: ") + Fmt.date(date)).font(.caption).foregroundStyle(Theme.text2) }
            }
            Spacer()
            if cloud.busy { ProgressView() }
        }
        if !cloud.status.isEmpty { Text(cloud.status).font(.footnote).foregroundStyle(Theme.text2) }
        if cloud.needsLink || cloud.conflict {
            Label(cloud.conflict ? tr("Két eltérő változat", "Two different versions") : tr("Garázs összekapcsolása", "Link your garage"), systemImage: "arrow.triangle.branch")
            Button(tr("A telefon garázsát használom", "Use this phone's garage")) { confirmLocal = true }
                .disabled(cloud.busy || !canRestore)
            if let head = cloud.versions.first {
                Button(tr("A felhő garázsát használom", "Use the cloud garage")) { restoring = head }
                    .disabled(cloud.busy || !canRestore)
            }
        } else {
            Toggle(tr("Automatikus szinkronizálás", "Automatic sync"), isOn: Binding(get: { cloud.autoBackup }, set: { cloud.autoBackup = $0 })).tint(Theme.ok)
            Button(tr("Szinkronizálás most", "Sync now")) { Task { await cloud.upload() } }.disabled(cloud.busy || !canRestore)
        }
        if !canRestore {
            Text(tr("A szinkronizálás az OBD-kapcsolat és a demó leállítása után érhető el.", "Sync is available after disconnecting OBD and stopping demo mode."))
                .font(.footnote).foregroundStyle(Theme.text2)
        }
        DisclosureGroup(tr("Korábbi mentések (\(cloud.versions.count))", "Previous backups (\(cloud.versions.count))")) {
            ForEach(cloud.versions) { version in
                Button { restoring = version } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("#\(version.revision) · \(Fmt.date(version.created_at))")
                        Text(tr("\(version.car_count) autó · \(version.trip_count) út", "\(version.car_count) cars · \(version.trip_count) trips"))
                            .font(.caption).foregroundStyle(Theme.text2)
                    }
                }.disabled(cloud.busy || !canRestore)
            }
        }
        Button(tr("Mentések listájának frissítése", "Refresh backup list")) { Task { await cloud.refreshRemoteInfo() } }.disabled(cloud.busy)
        Button(tr("Jelszó módosítása", "Change password")) { cloud.passwordRecovery = true }.disabled(cloud.busy)
        Button(tr("Kijelentkezés", "Sign out")) { Task { await cloud.signOut() } }.disabled(cloud.busy)
        Button(tr("Fiók törlése", "Delete account"), role: .destructive) { confirmDelete = true }.disabled(cloud.busy)
    }
}

struct CloudLoginView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var register = false
    private var emailValid: Bool { email.contains("@") && email.contains(".") }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(tr("Fiók", "Account"), selection: $register) {
                        Text(tr("Belépés", "Sign in")).tag(false)
                        Text(tr("Regisztráció", "Register")).tag(true)
                    }.pickerStyle(.segmented)
                    TextField(tr("E-mail-cím", "Email"), text: $email).keyboardType(.emailAddress)
                        .textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(tr("Jelszó", "Password"), text: $password).textContentType(register ? .newPassword : .password)
                    if register {
                        SecureField(tr("Jelszó még egyszer", "Repeat password"), text: $repeatPassword).textContentType(.newPassword)
                        Text(tr("Legalább 8 karakter. A regisztrációhoz e-mail-megerősítés szükséges.", "At least 8 characters. Registration requires email confirmation."))
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                    Button(register ? tr("Fiók létrehozása", "Create account") : tr("Bejelentkezés", "Sign in")) {
                        Task {
                            await cloud.signIn(email: email, password: password, register: register)
                            password = ""; repeatPassword = ""
                            if cloud.signedIn { dismiss() }
                        }
                    }.disabled(cloud.busy || !emailValid || password.isEmpty || (register && (password.count < 8 || password != repeatPassword)))
                    if !register {
                        Button(tr("Elfelejtett jelszó", "Forgot password")) { Task { await cloud.resetPassword(email: email) } }
                            .disabled(cloud.busy || !emailValid)
                    }
                    if cloud.busy { ProgressView() }
                } footer: { Text(tr("A regisztráció még nem tölti fel az adataidat. Belépés után választhatsz helyi és felhőgarázs között.", "Registration does not upload your data. After signing in, choose the phone or cloud garage.")) }
            }
            .navigationTitle(tr("Garázs-fiók", "Garage account"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Bezárás", "Close")) { dismiss() }.disabled(cloud.busy) } }
            .interactiveDismissDisabled(cloud.busy)
            .alert(cloud.message ?? "", isPresented: Binding(get: { cloud.message != nil }, set: { if !$0 { cloud.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }.preferredColorScheme(.dark)
    }
}

struct CloudPasswordView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @State private var password = ""
    @State private var repeated = ""
    var body: some View {
        NavigationStack {
            Form {
                SecureField(tr("Új jelszó (legalább 8 karakter)", "New password (at least 8 characters)"), text: $password).textContentType(.newPassword)
                SecureField(tr("Jelszó még egyszer", "Repeat password"), text: $repeated).textContentType(.newPassword)
                Button(tr("Jelszó mentése", "Save password")) { Task { await cloud.changePassword(password) } }
                    .disabled(cloud.busy || password.count < 8 || password != repeated)
                if cloud.busy { ProgressView() }
                if !cloud.status.isEmpty { Text(cloud.status).font(.footnote) }
            }
            .navigationTitle(tr("Új jelszó", "New password"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Bezárás", "Close")) { cloud.passwordRecovery = false }.disabled(cloud.busy) } }
            .interactiveDismissDisabled(cloud.busy)
        }.preferredColorScheme(.dark)
    }
}
