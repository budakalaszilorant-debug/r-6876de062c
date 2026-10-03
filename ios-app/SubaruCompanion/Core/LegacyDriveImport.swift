import Foundation
import UIKit
import GoogleSignIn

/// Migration only. Never uploads, deletes, or changes the old Google Drive backup.
@MainActor
final class LegacyDriveImport: ObservableObject {
    static let shared = LegacyDriveImport()
    @Published private(set) var busy = false
    @Published var file: URL?
    @Published var message: String?
    private var clientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              value.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return value
    }
    var isConfigured: Bool { clientID != nil }
    func handle(_ url: URL) { _ = GIDSignIn.sharedInstance.handle(url) }

    func download() {
        guard !busy, let clientID else { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        guard let controller else { return }
        busy = true
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: controller, hint: nil,
                                       additionalScopes: ["https://www.googleapis.com/auth/drive.appdata"]) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.busy = false }
                guard let user = result?.user else {
                    if (error as NSError?)?.code != GIDSignInError.canceled.rawValue {
                        self.message = tr("A Google-bejelentkezés nem sikerült.", "Google sign-in failed.")
                    }
                    return
                }
                do {
                    let token = user.accessToken.tokenString
                    var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                    components.queryItems = [
                        .init(name: "spaces", value: "appDataFolder"),
                        .init(name: "q", value: "name='garazs-mentes.json' and trashed=false"),
                        .init(name: "orderBy", value: "modifiedTime desc"), .init(name: "fields", value: "files(id)")]
                    let listing = try await self.get(components.url!, token: token)
                    struct List: Decodable { struct File: Decodable { let id: String }; let files: [File] }
                    guard let id = try JSONDecoder().decode(List.self, from: listing).files.first?.id,
                          let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media") else {
                        self.message = tr("Ebben a Google-fiókban nincs korábbi mentés.", "No previous backup in this Google account.")
                        return
                    }
                    let data = try await self.get(url, token: token)
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Backups", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent("drive-import-\(UUID()).json")
                    try data.write(to: target, options: .atomic)
                    self.file = target
                } catch { self.message = tr("A Drive-mentés letöltése nem sikerült. Az eredeti mentés megmaradt.", "Drive download failed. The original backup is unchanged.") }
            }
        }
    }

    func restore() {
        guard !CloudSync.shared.busy, let file, CloudSync.shared.canRestore else { return }
        do {
            _ = try Backup.writeSafetyCopy()
            _ = try Backup.restore(from: file)
            VehicleMonitor.shared.reloadAfterRestore()
            self.file = nil
            message = tr("A Drive-mentés visszaállítva a telefonra. A Supabase-fiókodnál válaszd a telefon garázsának mentését.", "Drive backup restored locally. Choose to save this phone's garage in your Supabase account.")
        } catch { message = tr("A mentés nem olvasható. A telefon korábbi adatai megmaradtak.", "Backup could not be restored. Previous local data is preserved.") }
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
