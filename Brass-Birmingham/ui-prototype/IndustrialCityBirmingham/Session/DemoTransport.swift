#if DEBUG
nonisolated protocol DemoTransport: Sendable {
    func loadLobby(mode: ConnectionMode, playerCount: Int) async throws -> LobbyState
    func loadMatch(playerCount: Int) async throws -> DemoMatchState
    func submit(intent: DemoIntent, state: DemoMatchState) async throws -> DemoEvent
}
#endif
