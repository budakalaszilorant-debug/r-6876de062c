import Foundation
import UIKit
import Network
import Supabase
import AuthenticationServices

/// SQLite works offline; the server checks revisions before accepting any write.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    @Published private(set) var ready = false
    @Published private(set) var accountViewID = UUID()
    @Published private(set) var googleEnabled = false
    @Published private(set) var email: String?
    @Published private(set) var busy = false
    @Published private(set) var versions: [CloudVersion] = []
    @Published private(set) var needsLink = false
    @Published private(set) var conflict = false
    @Published private(set) var lastUpload: Date?
    @Published private(set) var status = ""
    @Published var message: String?
    @Published var passwordRecovery = false
    private let client: SupabaseClient?
    private let server: URL?
    private let publicKey: String
    private var owner: UUID?
    private var authTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private let network = NWPathMonitor()
    private var started = false
    private var checkpoint = CloudCheckpoint()
    private let defaults = UserDefaults.standard
    private static let callback = URL(string: "garazs://auth/callback")!
    private enum Failure: Error { case configuration, accountChanged, conflict, activeTrip, localChanged, invalid, tooLarge, http(Int) }

    var isConfigured: Bool { client != nil }
    var signedIn: Bool { owner != nil }
    var remoteDate: Date? { versions.first?.created_at }
    var canRestore: Bool { VehicleMonitor.shared.canManageGarage && !VehicleMonitor.shared.demoActive }

    private init() {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String) ?? ""
        let key = (Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String) ?? ""
        publicKey = key
        if let url = URL(string: raw), url.scheme == "https", url.host != nil,
           !key.isEmpty, !key.contains("$("), !key.hasPrefix("sb_secret_") {
            server = url
            client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        } else { server = nil; client = nil }
    }

    func restoreSignIn() {
        guard !started else { return }
        started = true
        applySession(client?.auth.currentSession)
        guard let client else { return }
        Task { await loadProviders(); await autoBackupIfNeeded() }
        authTask = Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                self.applySession(session)
                if event == .passwordRecovery { self.passwordRecovery = true }
            }
        }
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.autoBackupIfNeeded() }
        }
        network.start(queue: DispatchQueue(label: "garage.cloud.network"))
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.autoBackupIfNeeded()
            }
        }
    }

    private var accountKey: String? {
        guard let owner, let server else { return nil }
        return "garage-cloud-\(server.host ?? "")-\(owner.uuidString)"
    }

    private func applySession(_ session: Session?) {
        let id = session?.user.id
        guard owner != id || !ready else { email = session?.user.email; return }
        ready = false
        VehicleMonitor.shared.prepareAccountChange()
        let key = id.map { "garage-cloud-\(server?.host ?? "")-\($0.uuidString)" }
        do {
            let verifiedEmail = session?.user.emailConfirmedAt != nil ? session?.user.email : nil
            try AccountGarage.activate(owner: key, verifiedEmail: verifiedEmail)
            owner = id; email = session?.user.email
            versions = []; conflict = false; checkpoint = CloudCheckpoint(); lastUpload = nil
            if let key, let data = defaults.data(forKey: key),
               let saved = try? JSONDecoder().decode(CloudCheckpoint.self, from: data) { checkpoint = saved }
            needsLink = id != nil && defaults.string(forKey: "garage-cloud-owner") != key
            lastUpload = checkpoint.lastSync
            status = ""
            VehicleMonitor.shared.reloadAfterRestore()
            accountViewID = UUID()
            ready = true
            Task { await autoBackupIfNeeded() }
        } catch {
            owner = nil; email = nil
            status = tr("A fiók garázsát nem sikerült megnyitni. Indítsd újra az appot; az adatok megmaradtak.", "Could not open this account's garage. Restart the app; data has been preserved.")
        }
    }

    func loadProviders() async {
        guard let server else { return }
        var request = URLRequest(url: server.appendingPathComponent("auth/v1/settings"))
        request.setValue(publicKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let external = root["external"] as? [String: Bool] else { return }
        googleEnabled = external["google"] == true
    }

    func signInWithGoogle() async {
        guard !busy, canRestore, let client else { return }
        busy = true
        do {
            let session = try await client.auth.signInWithOAuth(provider: .google, redirectTo: Self.callback,
                queryParams: [(name: "prompt", value: "select_account")])
            applySession(session)
        } catch {
            if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue { report(error) }
        }
        busy = false
        await autoBackupIfNeeded()
    }

    func signIn(email: String, password: String, register: Bool) async {
        guard !busy, canRestore, let client else { return }
        busy = true; defer { busy = false; Task { await autoBackupIfNeeded() } }
        do {
            if register {
                let result = try await client.auth.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, redirectTo: Self.callback)
                applySession(result.session)
                if result.session == nil { message = tr("Erősítsd meg az e-mail-címed a kapott levélben, majd jelentkezz be.", "Confirm your email using the message we sent, then sign in.") }
            } else {
                let session = try await client.auth.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                applySession(session)
            }
            if let owner { try await refresh(owner) }
        } catch { report(error) }
    }

    func handle(_ url: URL) {
        guard url.scheme == "garazs", url.host == "auth", url.path == "/callback", let client else { return }
        Task {
            do { applySession(try await client.auth.session(from: url)) }
            catch { report(error) }
        }
    }

    func resetPassword(email: String) async {
        guard !busy, let client else { return }
        busy = true; defer { busy = false }
        do {
            try await client.auth.resetPasswordForEmail(email.trimmingCharacters(in: .whitespacesAndNewlines), redirectTo: Self.callback)
            message = tr("Ha tartozik fiók ehhez a címhez, elküldtük a jelszó-visszaállító levelet. Ezen az iPhone-on nyisd meg.", "If an account exists, a reset email has been sent. Open it on this iPhone.")
        } catch { report(error) }
    }

    func changePassword(_ password: String) async -> Bool {
        guard !busy, let client else { return false }
        busy = true; defer { busy = false }
        do {
            try await client.auth.update(user: UserAttributes(password: password))
            passwordRecovery = false
            message = tr("A jelszó megváltozott.", "Password updated.")
            return true
        } catch { report(error); return false }
    }

    func signOut() async {
        guard !busy, canRestore, let client else { return }
        busy = true; defer { busy = false }
        // Supabase clears the local session before its network logout request.
        try? await client.auth.signOut(scope: .local)
        applySession(nil)
        passwordRecovery = false
    }

    func deleteAccount() async {
        guard !busy, canRestore, let id = owner, let client else { return }
        busy = true; defer { busy = false }
        do {
            let deletedKey = accountKey
            _ = try await request("rpc/garage_delete_account", owner: id, body: [:])
            if let key = accountKey { defaults.removeObject(forKey: key) }
            defaults.removeObject(forKey: "garage-cloud-owner")
            try? await client.auth.signOut(scope: .local)
            applySession(nil)
            if let deletedKey { try Database.shared.checkedExecute("DELETE FROM account_garages WHERE owner=?", [deletedKey]) }
            message = tr("A fiók és a felhőadatai törölve.", "Account and cloud data deleted.")
        } catch { report(error) }
    }

    func refreshRemoteInfo() async {
        guard !busy, let id = owner else { return }
        busy = true; defer { busy = false }
        do { try await refresh(id) } catch { report(error) }
    }

    private func refresh(_ id: UUID) async throws {
        let data = try await request("garage_versions", owner: id, query: [
            .init(name: "select", value: "revision,fingerprint,created_at,device_name,car_count,trip_count"),
            .init(name: "order", value: "revision.desc"), .init(name: "limit", value: "20")])
        versions = try Self.decoder.decode([CloudVersion].self, from: data)
    }

    func autoBackupIfNeeded() async {
        guard ready, signedIn, !busy, !conflict, !VehicleMonitor.shared.demoActive, !BLEManager.shared.clearingFaults else { return }
        if needsLink {
            await connectAccountGarage()
            return
        }
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask {
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
        }
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        }
        await upload(silent: true)
    }

    private func connectAccountGarage() async {
        guard !busy, let id = owner, needsLink, canRestore else { return }
        busy = true; defer { busy = false }
        do {
            try await refresh(id)
            guard owner == id, canRestore else { throw Failure.accountChanged }
            if let head = versions.first {
                try await download(head, owner: id, originalHash: CloudPayload.hash(snapshot()))
            } else {
                let session = try await client?.auth.session
                guard owner == id else { throw Failure.accountChanged }
                AccountGarage.seedPersonalCars(verifiedEmail: session?.user.emailConfirmedAt != nil ? session?.user.email : nil)
                VehicleMonitor.shared.reloadAfterRestore()
                if !CarStore.all().isEmpty {
                    let version = try await commit(snapshot(), expected: 0, owner: id)
                    saveCheckpoint(version)
                } else {
                    needsLink = false
                    defaults.set(accountKey, forKey: "garage-cloud-owner")
                }
            }
            status = tr("Szinkronizálva", "Synced")
        } catch { report(error, silent: true) }
    }

    /// A changed local copy is the durable upload queue. A lost response is safe to retry.
    func upload(silent: Bool = false) async {
        guard !busy, let id = owner, !needsLink, !conflict else { return }
        busy = true; defer { busy = false }
        do {
            guard !VehicleMonitor.shared.demoActive, !BLEManager.shared.clearingFaults else { return }
            let local = try snapshot(), hash = try CloudPayload.hash(local)
            try await refresh(id)
            let head = versions.first
            if CarStore.all().isEmpty {
                if let head, canRestore { try await download(head, owner: id, originalHash: hash) }
                return
            }
            switch CloudDecision.decide(linked: true, base: checkpoint.revision, baseHash: checkpoint.fingerprint,
                                        localHash: hash, remoteRevision: head?.revision, remoteHash: head?.fingerprint) {
            case .upload:
                let version = try await commit(local, expected: head?.revision ?? 0, owner: id)
                saveCheckpoint(version)
                versions = Array(([version] + versions.filter { $0.revision != version.revision }).prefix(20))
            case .download:
                guard canRestore else { return }
                if let head { try await download(head, owner: id, originalHash: hash) }
            case .conflict, .link:
                conflict = true
                status = tr("Mindkét eszközön változtak az adatok. Válassz egy változatot.", "Both copies changed. Choose a version.")
                return
            case .unchanged:
                if let head { saveCheckpoint(head) }
            }
            status = tr("Szinkronizálva", "Synced")
            if !silent { message = status }
        } catch { report(error, silent: silent) }
    }

    /// Only invoked after confirmation of linking or explicitly choosing this phone's copy.
    func useLocalGarage() async {
        guard !busy, let id = owner else { return }
        let reviewedRevision = versions.first?.revision ?? 0
        busy = true; defer { busy = false }
        do {
            guard canRestore else { throw Failure.activeTrip }
            let version = try await commit(snapshot(), expected: reviewedRevision, owner: id)
            saveCheckpoint(version)
            try await refresh(id)
            status = tr("A telefon garázsa mentve. A korábbi felhőváltozat a mentések között marad.", "Phone garage saved. The previous cloud version remains in history.")
        } catch { report(error) }
    }

    func restoreFromCloud(version: CloudVersion? = nil) async {
        guard !busy, let id = owner, let selected = version ?? versions.first else { return }
        busy = true; defer { busy = false }
        do {
            guard canRestore else { throw Failure.activeTrip }
            let originalHash = try CloudPayload.hash(snapshot())
            try await download(selected, owner: id, originalHash: originalHash)
            status = tr("Visszaállítva. A korábbi helyi adatokról biztonsági másolat készült.", "Restored. A safety copy of the previous local data was saved.")
            message = status
        } catch { report(error) }
    }

    private func download(_ version: CloudVersion, owner id: UUID, originalHash: String) async throws {
        let data = try await request("garage_versions", owner: id, query: [
            .init(name: "select", value: "payload"), .init(name: "revision", value: "eq.\(version.revision)")])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count == 1, let payload = rows.first?["payload"] else { throw Failure.invalid }
        let backup = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard try CloudPayload.hash(backup) == version.fingerprint else { throw Failure.invalid }
        guard canRestore else { throw Failure.activeTrip }
        guard try CloudPayload.hash(snapshot()) == originalHash else { throw Failure.localChanged }
        // No suspension between the final checks, safety copy and database replacement.
        _ = try Backup.writeSafetyCopy()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID()).json")
        try backup.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try Backup.restore(from: url)
        VehicleMonitor.shared.reloadAfterRestore()
        // An old restore point is an edit against the observed head, uploaded as a NEW version.
        if version.revision == versions.first?.revision {
            saveCheckpoint(version, fingerprint: try CloudPayload.hash(snapshot()))
        } else {
            saveCheckpoint(versions.first ?? version)
        }
    }

    private func snapshot() throws -> Data {
        guard let data = Backup.makeData() else { throw Failure.invalid }
        guard data.count <= CloudPayload.maximumBytes else { throw Failure.tooLarge }
        return try CloudPayload.canonical(data)
    }

    private func commit(_ data: Data, expected: Int64, owner id: UUID) async throws -> CloudVersion {
        let result = try await request("rpc/garage_commit", owner: id, body: [
            "p_expected": expected, "p_fingerprint": try CloudPayload.hash(data),
            "p_payload": try JSONSerialization.jsonObject(with: data), "p_device": "iPhone"])
        return try Self.decoder.decode(CloudVersion.self, from: result)
    }

    private func saveCheckpoint(_ version: CloudVersion, fingerprint: String? = nil) {
        checkpoint = CloudCheckpoint(revision: version.revision, fingerprint: fingerprint ?? version.fingerprint, lastSync: Date())
        needsLink = false; conflict = false; lastUpload = checkpoint.lastSync
        defaults.set(accountKey, forKey: "garage-cloud-owner")
        if let key = accountKey, let data = try? JSONEncoder().encode(checkpoint) { defaults.set(data, forKey: key) }
    }

    private func request(_ path: String, owner id: UUID, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        guard let client, let server else { throw Failure.configuration }
        let session = try await client.auth.session
        guard owner == id, session.user.id == id else { throw Failure.accountChanged }
        var components = URLComponents(url: server.appendingPathComponent("rest/v1/" + path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 45
        req.setValue(publicKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard owner == id else { throw Failure.accountChanged }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 409 { throw Failure.conflict }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return data
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let value = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: value) { return date }
            f.formatOptions = [.withInternetDateTime]
            guard let date = f.date(from: value) else { throw Failure.invalid }
            return date
        }
        return decoder
    }

    private func report(_ error: Error, silent: Bool = false) {
        switch error {
        case Failure.conflict:
            conflict = true
            status = tr("Két eszközön változott a garázs. Nyisd meg a fiókodat az egyeztetéshez.", "Both devices changed the garage. Open your account to resolve it.")
        case Failure.activeTrip: status = tr("Állítsd le a demót és bontsd az OBD-kapcsolatot a szinkronizáláshoz.", "Stop demo mode and disconnect OBD before syncing.")
        case Failure.localChanged: status = tr("Közben változtak a helyi adatok. Nem írtuk felül őket; próbáld újra.", "Local data changed. Nothing was replaced; please retry.")
        case Failure.tooLarge: status = tr("A mentés nagyobb 20 MB-nál. Készíts fájlmentést; a felhőmásolat nem változott.", "Backup exceeds 20 MB. Export a file; the cloud copy is unchanged.")
        case Failure.invalid, is Backup.RestoreError: status = tr("A mentés sérült vagy nem támogatott. A helyi adatok megmaradtak.", "Backup is invalid or unsupported. Local data is preserved.")
        case Failure.http(401), Failure.http(403): status = tr("Jelentkezz be újra, vagy ellenőrizd a felhő jogosultságait.", "Sign in again or check cloud permissions.")
        case Failure.http(404): status = tr("A felhő adatbázisa még nincs telepítve.", "The cloud database has not been installed yet.")
        case is AuthError: status = tr("A bejelentkezési művelet nem sikerült. Ellenőrizd az adatokat és az e-mail-megerősítést; túl sok kérés után várj pár percet.", "Authentication failed. Check credentials and email confirmation; after too many requests, wait a few minutes.")
        default: status = tr("A felhő nem érhető el. A helyi adatok megvannak; később újrapróbáljuk.", "Cloud unavailable. Local data is safe; we will retry later.")
        }
        if !silent { message = status }
    }
}
