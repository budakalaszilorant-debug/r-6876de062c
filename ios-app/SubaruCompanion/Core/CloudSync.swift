import Foundation
import UIKit
import GoogleSignIn

/// Felhő mentés Google-fiókkal: a teljes mentés (minden autó, út, tankolás, szerviz) a felhasználó
/// saját Google Drive-jának rejtett app-mappájába kerül. Ezt a mappát csak ez az app látja,
/// a Drive felületén nem jelenik meg, és nem foglal helyet a látható fájlok között.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    static let scope = "https://www.googleapis.com/auth/drive.appdata"
    private let fileName = "garazs-mentes.json"

    @Published private(set) var email: String?
    @Published private(set) var busy = false
    @Published private(set) var lastUpload: Date?
    @Published private(set) var remoteDate: Date?
    @Published var message: String?

    var autoBackup: Bool {
        get { (UserDefaults.standard.object(forKey: "cloudAuto") as? Bool) ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "cloudAuto")
        }
    }

    enum CloudError: Error { case notConfigured, notSignedIn, http(Int), noBackup }

    private init() {
        let t = UserDefaults.standard.double(forKey: "cloudLastUpload")
        if t > 0 { lastUpload = Date(timeIntervalSince1970: t) }
    }

    /// Az iOS OAuth kliens azonosító az Info.plist-ből (a project.yml GOOGLE_CLIENT_ID értéke).
    private var clientID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return id
    }

    var isConfigured: Bool { clientID != nil }
    var signedIn: Bool { email != nil }

    // MARK: Bejelentkezés

    func restoreSignIn() {
        guard let clientID else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, _ in
            Task { @MainActor in
                self?.email = user?.profile?.email
                if user != nil { await self?.refreshRemoteInfo() }
            }
        }
    }

    func handle(_ url: URL) {
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    func signIn() {
        guard let clientID else { message = tr("A Google bejelentkezés nincs beállítva.", "Google sign-in is not configured."); return }
        guard let root = Self.topViewController() else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: root, hint: nil, additionalScopes: [Self.scope]) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let user = result?.user {
                    self.email = user.profile?.email
                    await self.refreshRemoteInfo()
                    // Ha a felhőben még nincs mentés, rögtön feltöltjük a mostani adatokat.
                    if self.remoteDate == nil { await self.upload() }
                } else if let error, (error as NSError).code != GIDSignInError.canceled.rawValue {
                    self.message = tr("A bejelentkezés nem sikerült.", "Sign-in failed.")
                }
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        email = nil
        remoteDate = nil
    }

    // MARK: Feltöltés / letöltés

    /// Automatikus mentés (út végén, háttérbe lépéskor), legfeljebb óránként egyszer.
    func autoBackupIfNeeded() async {
        guard autoBackup, signedIn, !busy else { return }
        if let last = lastUpload, Date().timeIntervalSince(last) < 3600 { return }
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask { app.endBackgroundTask(task) }
        await upload(silent: true)
        if task != .invalid { app.endBackgroundTask(task) }
    }

    func upload(silent: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let data = Backup.makeData() else { throw CloudError.noBackup }
            let token = try await accessToken()
            let existing = try await findFile(token: token)
            if let id = existing {
                var req = request("https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media", token: token)
                req.httpMethod = "PATCH"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                try await send(req)
            } else {
                let boundary = "garazs-\(UUID().uuidString)"
                var body = Data()
                let meta = #"{"name":"\#(fileName)","parents":["appDataFolder"]}"#
                body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(meta)\r\n".data(using: .utf8)!)
                body.append("--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
                body.append(data)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                var req = request("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart", token: token)
                req.httpMethod = "POST"
                req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req.httpBody = body
                try await send(req)
            }
            lastUpload = Date()
            remoteDate = lastUpload
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cloudLastUpload")
            if !silent { message = tr("Mentve a felhőbe.", "Saved to the cloud.") }
        } catch {
            if !silent { message = describe(error) }
        }
    }

    /// A felhőben lévő mentés visszaállítása (a mostani adatok helyére kerül).
    func restoreFromCloud() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let token = try await accessToken()
            let existing = try await findFile(token: token)
            guard let id = existing else { throw CloudError.noBackup }
            let req = request("https://www.googleapis.com/drive/v3/files/\(id)?alt=media", token: token)
            let data = try await send(req)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("felho-mentes.json")
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            let rows = try Backup.restore(from: url)
            VehicleMonitor.shared.reloadAfterRestore()
            message = tr("Visszaállítva a felhőből: \(rows) sor.", "Restored from the cloud: \(rows) rows.")
        } catch {
            message = describe(error)
        }
    }

    func refreshRemoteInfo() async {
        guard let token = try? await accessToken() else { return }
        _ = try? await findFile(token: token)
    }

    // MARK: Drive API

    /// A mentés fájl azonosítója az app-mappában (és közben frissíti a felhőbeli dátumot).
    private func findFile(token: String) async throws -> String? {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name='\(fileName)'"),
            URLQueryItem(name: "fields", value: "files(id,modifiedTime)"),
        ]
        let data = try await send(request(c.url!.absoluteString, token: token))
        struct List: Decodable { struct F: Decodable { let id: String; let modifiedTime: String? }; let files: [F] }
        let file = try JSONDecoder().decode(List.self, from: data).files.first
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        remoteDate = file?.modifiedTime.flatMap { f.date(from: $0) }
        return file?.id
    }

    private func request(_ url: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CloudError.http(code) }
        return data
    }

    private func accessToken() async throws -> String {
        guard isConfigured else { throw CloudError.notConfigured }
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw CloudError.notSignedIn }
        return try await withCheckedThrowingContinuation { cont in
            user.refreshTokensIfNeeded { user, error in
                if let token = user?.accessToken.tokenString {
                    cont.resume(returning: token)
                } else {
                    cont.resume(throwing: error ?? CloudError.notSignedIn)
                }
            }
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case CloudError.notConfigured: return tr("A Google bejelentkezés nincs beállítva.", "Google sign-in is not configured.")
        case CloudError.notSignedIn: return tr("Jelentkezz be újra.", "Please sign in again.")
        case CloudError.noBackup: return tr("A felhőben még nincs mentés.", "There is no backup in the cloud yet.")
        case CloudError.http(let code): return tr("A Google hibát jelzett (\(code)).", "Google returned an error (\(code)).")
        case is Backup.RestoreError: return tr("A felhőben lévő mentés nem olvasható.", "The cloud backup can't be read.")
        default: return tr("Nincs internetkapcsolat, vagy a Google nem érhető el.", "No internet connection, or Google is unreachable.")
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
