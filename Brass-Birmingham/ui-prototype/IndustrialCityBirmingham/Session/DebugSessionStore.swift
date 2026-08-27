#if DEBUG
import Foundation
import Observation

@MainActor
@Observable
final class DemoSessionStore {
    private let transport: any DemoTransport
    private var lobbyRequestGeneration = 0
    private var matchRequestGeneration = 0
    private var submissionRequestGeneration = 0
    var selectedMode: ConnectionMode?
    var lobby: LobbyState?
    var match: DemoMatchState?
    private(set) var playerCount = 4
    var errorMessage: String?

    init(transport: any DemoTransport = FakeTransport()) {
        self.transport = transport
    }

    @discardableResult
    func setPlayerCount(_ count: Int) -> Bool {
        guard (2...4).contains(count) else {
            errorMessage = "Player count must be between 2 and 4."
            return false
        }
        guard count != playerCount else {
            errorMessage = nil
            return true
        }

        playerCount = count
        lobbyRequestGeneration += 1
        matchRequestGeneration += 1
        submissionRequestGeneration += 1
        selectedMode = nil
        lobby = nil
        match = nil
        errorMessage = nil
        return true
    }

    @discardableResult
    func loadLobby(mode: ConnectionMode) async -> LobbyState? {
        lobbyRequestGeneration += 1
        let requestGeneration = lobbyRequestGeneration
        let requestedPlayerCount = playerCount

        do {
            let loadedLobby = try await transport.loadLobby(mode: mode, playerCount: requestedPlayerCount)
            guard !Task.isCancelled,
                  requestGeneration == lobbyRequestGeneration,
                  requestedPlayerCount == playerCount else { return nil }
            lobby = loadedLobby
            selectedMode = loadedLobby.mode
            errorMessage = nil
            return loadedLobby
        } catch {
            guard !Task.isCancelled,
                  requestGeneration == lobbyRequestGeneration,
                  requestedPlayerCount == playerCount else { return nil }
            lobby = nil
            selectedMode = nil
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func loadMatch() async -> DemoMatchState? {
        matchRequestGeneration += 1
        let requestGeneration = matchRequestGeneration
        let requestedPlayerCount = playerCount

        do {
            let loadedMatch = try await transport.loadMatch(playerCount: requestedPlayerCount)
            guard !Task.isCancelled,
                  requestGeneration == matchRequestGeneration,
                  requestedPlayerCount == playerCount else { return nil }
            match = loadedMatch
            errorMessage = nil
            return loadedMatch
        } catch {
            guard !Task.isCancelled,
                  requestGeneration == matchRequestGeneration,
                  requestedPlayerCount == playerCount else { return nil }
            match = nil
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func submit(intent: DemoIntent, state: DemoMatchState) async -> DemoSubmissionOutcome? {
        submissionRequestGeneration += 1
        let requestGeneration = submissionRequestGeneration

        do {
            let event = try await transport.submit(intent: intent, state: state)
            guard !Task.isCancelled,
                  requestGeneration == submissionRequestGeneration else { return nil }
            return .accepted(event)
        } catch let rejection as RejectedIntent {
            guard !Task.isCancelled,
                  requestGeneration == submissionRequestGeneration else { return nil }
            return .rejected(rejection)
        } catch {
            guard !Task.isCancelled,
                  requestGeneration == submissionRequestGeneration else { return nil }
            return .technicalFailure(
                TechnicalSubmissionFailure(
                    diagnostic: error.localizedDescription,
                    retrySuggestion: "请保留当前草稿并重试；若问题持续，请附上诊断信息反馈。"
                )
            )
        }
    }

    func cancelSubmission() {
        submissionRequestGeneration += 1
    }
}
#endif
