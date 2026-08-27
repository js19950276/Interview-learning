#if DEBUG
actor FakeTransport: DemoTransport {
    private let matchEra: String

    init(matchEra: String = "运河时代") {
        self.matchEra = matchEra
    }

    func loadLobby(mode: ConnectionMode, playerCount: Int) async throws -> LobbyState {
        LobbyState(mode: mode, roomCode: mode == .online ? "BRASS7" : "NEARBY", players: DemoFixture.players(count: playerCount))
    }

    func loadMatch(playerCount: Int) async throws -> DemoMatchState {
        DemoFixture.match(playerCount: playerCount, era: matchEra)
    }

    func submit(intent: DemoIntent, state: DemoMatchState) async throws -> DemoEvent {
        try DemoEventFixture.event(for: intent, state: state)
    }
}
#endif
