import SwiftUI

struct CloudSection: View {
    @ObservedObject private var cloud = CloudSync.shared
    @State private var login = false
    @State private var account = false
    var body: some View {
        Section(tr("Fiók és felhő", "Account and cloud")) {
            if cloud.signedIn {
                Button { account = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(Theme.accent)
                        Text(cloud.email ?? tr("Saját fiók", "My account"))
                            .font(.headline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if cloud.busy { ProgressView() }
                        else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text2) }
                    }.padding(.vertical, 4)
                }
                if cloud.conflict {
                    Label(tr("A garázs egyeztetésre vár", "Garage needs reconciliation"), systemImage: "exclamationmark.icloud")
                        .foregroundStyle(Theme.warn)
                }
            } else {
                Button { login = true } label: {
                    Label(tr("Bejelentkezés vagy regisztráció", "Sign in or create account"), systemImage: "person.crop.circle.badge.plus")
                }.disabled(!cloud.isConfigured)
            }
        }
        .sheet(isPresented: $login) { CloudLoginView() }
        .sheet(isPresented: $account) { AccountDetailsView() }
    }
}

struct AccountDetailsView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var passwordSheet = false
    @State private var confirmLocal = false
    @State private var confirmRemote = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(cloud.email ?? "", systemImage: "person.crop.circle").textSelection(.enabled)
                }
                if cloud.conflict {
                    Section(tr("Garázs egyeztetése", "Resolve garage changes")) {
                        Text(tr("Mindkét eszközön változott a garázs. Válaszd ki, melyiket tartod meg.", "The garage changed on both devices. Choose the copy to keep."))
                        Button(tr("Az iPhone adatait tartom meg", "Keep this iPhone's data")) { confirmLocal = true }
                        Button(tr("A felhő adatait tartom meg", "Keep cloud data")) { confirmRemote = true }
                    }.disabled(cloud.busy || !cloud.canRestore)
                }
                if !cloud.status.isEmpty && cloud.status != tr("Szinkronizálva", "Synced") {
                    Text(cloud.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(tr("Jelszó módosítása", "Change password")) { passwordSheet = true }
                    Button(tr("Kijelentkezés", "Sign out")) { Task { await cloud.signOut(); if !cloud.signedIn { dismiss() } } }
                }.disabled(cloud.busy || !cloud.canRestore)
                Section {
                    Button(tr("Fiók törlése", "Delete account"), role: .destructive) { confirmDelete = true }
                }.disabled(cloud.busy || !cloud.canRestore)
            }
            .navigationTitle(tr("Saját fiók", "My account"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Kész", "Done")) { dismiss() } } }
            .task { if cloud.conflict { await cloud.refreshRemoteInfo() } }
            .sheet(isPresented: $passwordSheet) { CloudPasswordView() }
            .alert(tr("Törlöd a fiókot?", "Delete account?"), isPresented: $confirmDelete) {
                Button(tr("Végleges törlés", "Delete permanently"), role: .destructive) { Task { await cloud.deleteAccount() } }
                Button(tr("Mégse", "Cancel"), role: .cancel) {}
            } message: { Text(tr("A fiók és a hozzá tartozó felhőadatok végleg törlődnek.", "Your account and its cloud data will be permanently deleted.")) }
            .alert(tr("Az iPhone adatait tartod meg?", "Keep iPhone data?"), isPresented: $confirmLocal) {
                Button(tr("Megtartás", "Keep")) { Task { await cloud.useLocalGarage() } }
                Button(tr("Mégse", "Cancel"), role: .cancel) {}
            }
            .alert(tr("A felhő adatait tartod meg?", "Keep cloud data?"), isPresented: $confirmRemote) {
                Button(tr("Megtartás", "Keep")) { Task { await cloud.restoreFromCloud() } }
                Button(tr("Mégse", "Cancel"), role: .cancel) {}
            }
            .alert(cloud.message ?? "", isPresented: Binding(get: { cloud.message != nil }, set: { if !$0 { cloud.message = nil } })) {
                Button("OK", role: .cancel) { cloud.message = nil }
            }
        }
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
                    Button(tr("Folytatás Google-fiókkal", "Continue with Google")) {
                        Task { await cloud.signInWithGoogle(); if cloud.signedIn { dismiss() } }
                    }.disabled(cloud.busy || !cloud.googleEnabled || !cloud.canRestore)
                    if !cloud.googleEnabled { Text(tr("A Google-belépés jelenleg nem érhető el.", "Google sign-in is currently unavailable.")).font(.footnote).foregroundStyle(.secondary) }
                }
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
                    }.disabled(!cloud.canRestore || cloud.busy || !emailValid || password.isEmpty || (register && (password.count < 8 || password != repeatPassword)))
                    if !register {
                        Button(tr("Elfelejtett jelszó", "Forgot password")) { Task { await cloud.resetPassword(email: email) } }
                            .disabled(cloud.busy || !emailValid)
                    }
                    if cloud.busy { ProgressView() }
                } footer: { Text(tr("Belépés után a saját garázsod automatikusan szinkronizálódik. Minden fiók külön garázst használ.", "Your garage syncs automatically after sign-in. Each account has its own garage.")) }
            }
            .task { await cloud.loadProviders() }
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
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cloud = CloudSync.shared
    @State private var password = ""
    @State private var repeated = ""
    var body: some View {
        NavigationStack {
            Form {
                SecureField(tr("Új jelszó (legalább 8 karakter)", "New password (at least 8 characters)"), text: $password).textContentType(.newPassword)
                SecureField(tr("Jelszó még egyszer", "Repeat password"), text: $repeated).textContentType(.newPassword)
                Button(tr("Jelszó mentése", "Save password")) { Task { if await cloud.changePassword(password) { dismiss() } } }
                    .disabled(cloud.busy || password.count < 8 || password != repeated)
                if cloud.busy { ProgressView() }
                if !cloud.status.isEmpty { Text(cloud.status).font(.footnote) }
            }
            .navigationTitle(tr("Új jelszó", "New password"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Bezárás", "Close")) { cloud.passwordRecovery = false; dismiss() }.disabled(cloud.busy) } }
            .interactiveDismissDisabled(cloud.busy)
        }.preferredColorScheme(.dark)
    }
}
