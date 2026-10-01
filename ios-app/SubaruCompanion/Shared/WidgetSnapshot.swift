import Foundation

/// Az app és a widget közös adata (App Group-on keresztül). A widget csak ezt olvassa.
struct WidgetSnapshot: Codable {
    var voltage: Double?
    var coolant: Double?
    var engineRunning: Bool
    var updated: Date

    static let appGroup = "group.hu.kocsi.subaru"
    private static let key = "widgetSnapshot"

    private static var store: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot? {
        guard let data = store?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.store?.set(data, forKey: Self.key)
    }
}
