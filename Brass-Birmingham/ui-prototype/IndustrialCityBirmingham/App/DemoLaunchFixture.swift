import Foundation

#if DEBUG
enum DemoLaunchFixture: String, CaseIterable {
    case players2
    case players3
    case players4
    case wirelessOff
    case versionMismatch
    case rejectedAction
    case disconnected

    var playerCount: Int {
        switch self {
        case .players2: 2
        case .players3: 3
        case .players4, .wirelessOff, .versionMismatch, .rejectedAction, .disconnected: 4
        }
    }

    var initialRoute: AppRoute {
        switch self {
        case .wirelessOff: .nearby
        case .versionMismatch: .online
        case .players2, .players3, .players4, .rejectedAction, .disconnected:
            .match(playerCount: playerCount)
        }
    }

}

struct DemoMatchInitialState: Equatable {
    let selectedCardID: String?
    let selectedAction: GameAction?
    let buildLocationID: String?
    let rejection: RejectedIntent?
    let disconnectedPlayerID: String?

    static let standard = DemoMatchInitialState(
        selectedCardID: nil,
        selectedAction: nil,
        buildLocationID: nil,
        rejection: nil,
        disconnectedPlayerID: nil
    )

    init(fixture: DemoLaunchFixture?) {
        switch fixture {
        case .rejectedAction:
            selectedCardID = "card-birmingham"
            selectedAction = .build
            buildLocationID = "birmingham"
            rejection = RejectedIntent(
                reason: "invalid-target · fixture",
                recoverySuggestion: "请选择高亮地点后重试；当前草稿已保留。"
            )
            disconnectedPlayerID = nil
        case .disconnected:
            selectedCardID = nil
            selectedAction = nil
            buildLocationID = nil
            rejection = nil
            disconnectedPlayerID = "player-crimson"
        case .players2, .players3, .players4, .wirelessOff, .versionMismatch, .none:
            self = .standard
        }
    }

    private init(
        selectedCardID: String?,
        selectedAction: GameAction?,
        buildLocationID: String?,
        rejection: RejectedIntent?,
        disconnectedPlayerID: String?
    ) {
        self.selectedCardID = selectedCardID
        self.selectedAction = selectedAction
        self.buildLocationID = buildLocationID
        self.rejection = rejection
        self.disconnectedPlayerID = disconnectedPlayerID
    }
}

struct DemoLaunchConfiguration {
    let fixture: DemoLaunchFixture?
    let reduceMotion: Bool
    let colorAssist: Bool
    let matchInitialState: DemoMatchInitialState

    static let standard = DemoLaunchConfiguration(
        fixture: nil,
        reduceMotion: false,
        colorAssist: true,
        matchInitialState: .standard
    )

    init(arguments: [String]) {
        let fixture = Self.fixture(in: arguments)
        self.fixture = fixture
        reduceMotion = Self.booleanValue(for: "-reduce-motion", in: arguments) ?? false
        colorAssist = Self.booleanValue(for: "-color-assist", in: arguments) ?? true
        matchInitialState = DemoMatchInitialState(fixture: fixture)
    }

    private init(
        fixture: DemoLaunchFixture?,
        reduceMotion: Bool,
        colorAssist: Bool,
        matchInitialState: DemoMatchInitialState
    ) {
        self.fixture = fixture
        self.reduceMotion = reduceMotion
        self.colorAssist = colorAssist
        self.matchInitialState = matchInitialState
    }

    private static func fixture(in arguments: [String]) -> DemoLaunchFixture? {
        guard let index = arguments.firstIndex(of: "-fixture"),
              arguments.indices.contains(index + 1) else { return nil }
        return DemoLaunchFixture(rawValue: arguments[index + 1])
    }

    private static func booleanValue(for flag: String, in arguments: [String]) -> Bool? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1) else { return true }
        return switch arguments[index + 1].uppercased() {
        case "YES", "TRUE", "1": true
        case "NO", "FALSE", "0": false
        default: true
        }
    }
}
#else
struct DemoLaunchConfiguration {
    let reduceMotion: Bool
    let colorAssist: Bool

    static let standard = DemoLaunchConfiguration(
        reduceMotion: false,
        colorAssist: true
    )

    init(arguments: [String]) {
        reduceMotion = Self.booleanValue(for: "-reduce-motion", in: arguments) ?? false
        colorAssist = Self.booleanValue(for: "-color-assist", in: arguments) ?? true
    }

    private init(reduceMotion: Bool, colorAssist: Bool) {
        self.reduceMotion = reduceMotion
        self.colorAssist = colorAssist
    }

    private static func booleanValue(for flag: String, in arguments: [String]) -> Bool? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1) else { return true }
        return switch arguments[index + 1].uppercased() {
        case "YES", "TRUE", "1": true
        case "NO", "FALSE", "0": false
        default: true
        }
    }
}
#endif
