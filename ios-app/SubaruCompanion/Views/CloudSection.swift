import SwiftUI

/// Beállítások → Felhő mentés (Google-fiók, saját Google Drive).
struct CloudSection: View {
    @ObservedObject private var cloud = CloudSync.shared
    @State private var confirmRestore = false

    var body: some View {
        Section {
            if !cloud.isConfigured {
                Label(tr("A Google bejelentkezés még nincs beállítva ebben a változatban.",
                         "Google sign-in is not set up in this build."), systemImage: "icloud.slash")
                    .foregroundStyle(Theme.text2)
            } else if let email = cloud.email {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(email).font(.system(size: 15, weight: .semibold))
                        Text(statusText).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    if cloud.busy { ProgressView() }
                }
                Toggle(tr("Automatikus mentés", "Automatic backup"), isOn: Binding(
                    get: { cloud.autoBackup }, set: { cloud.autoBackup = $0 }))
                    .tint(Theme.ok)
                Button(tr("Mentés most", "Back up now")) { Task { await cloud.upload() } }
                    .disabled(cloud.busy)
                Button(tr("Visszaállítás a felhőből", "Restore from the cloud")) { confirmRestore = true }
                    .disabled(cloud.busy || cloud.remoteDate == nil)
                Button(tr("Kijelentkezés", "Sign out"), role: .destructive) { cloud.signOut() }
            } else {
                Button { cloud.signIn() } label: {
                    HStack(spacing: 10) {
                        Text("G")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Theme.accent, in: Circle())
                        Text(tr("Bejelentkezés Google-fiókkal", "Sign in with Google"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
        } header: {
            Text(tr("Felhő mentés", "Cloud backup"))
        } footer: {
            Text(tr("A mentés a saját Google Drive-od rejtett app-mappájába kerül; más nem látja, és a Drive-ban sem jelenik meg fájlként.",
                    "The backup goes to a hidden app folder in your own Google Drive; nobody else can see it and it doesn't show up as a file."))
        }
        .alert(tr("Visszaállítod a felhőből?", "Restore from the cloud?"), isPresented: $confirmRestore) {
            Button(tr("Visszaállítás", "Restore"), role: .destructive) { Task { await cloud.restoreFromCloud() } }
            Button(tr("Mégse", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("A telefonon lévő adatok helyére a felhőben lévő mentés kerül.",
                    "The data on this phone will be replaced with the cloud backup."))
        }
        .alert(cloud.message ?? "", isPresented: Binding(get: { cloud.message != nil }, set: { if !$0 { cloud.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var statusText: String {
        if let d = cloud.lastUpload { return tr("Utolsó mentés: \(Fmt.date(d))", "Last backup: \(Fmt.date(d))") }
        if let d = cloud.remoteDate { return tr("Felhőben: \(Fmt.date(d))", "In the cloud: \(Fmt.date(d))") }
        return tr("Még nincs mentés", "No backup yet")
    }
}
