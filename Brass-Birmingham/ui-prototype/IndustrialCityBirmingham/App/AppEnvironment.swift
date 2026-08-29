import Foundation

nonisolated struct AppEnvironment: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case production
#if DEBUG
        case fixture
        case localHarness(LocalHarness)
        case localUIFixture
        case localRecoveryUIFixture
#endif
    }
#if DEBUG
    struct LocalHarness: Equatable, Sendable {
        let role: SessionRole
        let roomID: GameCore.RoomID
        let port: UInt16?
    }
#endif

#if DEBUG
    let localHarness: LocalHarness?
    let localUIFixturePresentationEraOverride: GameCore.Era?
#endif
    let mode: Mode
    let runsLocalScriptHarness: Bool
    let usesFixtureSession: Bool
    let nearbyCatalogSource: NearbyCatalogSource

    init(arguments: [String]) {
#if DEBUG
        nearbyCatalogSource = .debugFixture
        localUIFixturePresentationEraOverride = arguments.contains("-rail-fixture") ? .rail : nil
        usesFixtureSession = arguments.contains("-ui-testing")
            || arguments.contains("-snapshot-testing")
            || arguments.contains("-fixture")
            || arguments.contains("-demo-ui")
            || arguments.contains("-rail-fixture")
        guard let roleText = Self.value(after: "-local-role", in: arguments),
              let role = SessionRole(rawValue: roleText),
              let room = Self.value(after: "-local-room", in: arguments), !room.isEmpty else {
            localHarness = nil
            if arguments.contains("-local-recovery-ui-fixture") {
                mode = .localRecoveryUIFixture
            } else {
                mode = arguments.contains("-local-ui-fixture") ? .localUIFixture : .fixture
            }
            runsLocalScriptHarness = false
            return
        }
        let port = Self.value(after: "-local-port", in: arguments).flatMap(UInt16.init)
        let harness = LocalHarness(role: role, roomID: .init(rawValue: room), port: port)
        localHarness = harness
        mode = .localHarness(harness)
        runsLocalScriptHarness = arguments.contains("-local-script-harness")
#else
        mode = .production
        runsLocalScriptHarness = false
        usesFixtureSession = false
        nearbyCatalogSource = .packagedRules
#endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
