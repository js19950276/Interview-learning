import OSLog

@MainActor
enum PrototypeSignpost {
    nonisolated enum Name: String, CaseIterable, Equatable, Sendable {
        case cardResponse = "CardResponse"
        case drawerResponse = "DrawerResponse"
        case mapPanZoom = "MapPanZoom"
        case targetGlow = "TargetGlow"
        case marketUpdate = "MarketUpdate"

        var staticName: StaticString {
            switch self {
            case .cardResponse: "CardResponse"
            case .drawerResponse: "DrawerResponse"
            case .mapPanZoom: "MapPanZoom"
            case .targetGlow: "TargetGlow"
            case .marketUpdate: "MarketUpdate"
            }
        }
    }

    static let log = OSLog(
        subsystem: "com.didi.prototype.IndustrialCityBirmingham",
        category: .pointsOfInterest
    )

    static func begin(_ name: Name) -> Interval {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name.staticName, signpostID: signpostID)
        return Interval(name: name, signpostID: signpostID)
    }

    @MainActor
    final class Interval {
        let name: Name
        private let signpostID: OSSignpostID
        private(set) var hasEnded = false
        private(set) var endCount = 0

        fileprivate init(name: Name, signpostID: OSSignpostID) {
            self.name = name
            self.signpostID = signpostID
        }

        func end() {
            guard !hasEnded else { return }
            hasEnded = true
            endCount += 1
            os_signpost(
                .end,
                log: PrototypeSignpost.log,
                name: name.staticName,
                signpostID: signpostID
            )
        }
    }
}
