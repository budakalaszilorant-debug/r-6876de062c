import UIKit

/// Haptika csak jelentős pillanatokra: figyelmeztetés, siker, kapcsolás.
enum Haptics {
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error()   { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func tap()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
