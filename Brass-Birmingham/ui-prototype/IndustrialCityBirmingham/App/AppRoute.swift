import UIKit

enum AppRoute: Hashable {
    case home
    case online
    case nearby
    case lobby(ConnectionMode)
    case rules
    case settings
    case gallery
    case match(playerCount: Int)

    var orientationMask: UIInterfaceOrientationMask {
        switch self {
        case .match:
            .landscape
        default:
            .allButUpsideDown
        }
    }
}

enum OrientationPolicy {
    static func mask(for path: [AppRoute]) -> UIInterfaceOrientationMask {
        path.last?.orientationMask ?? .allButUpsideDown
    }
}
