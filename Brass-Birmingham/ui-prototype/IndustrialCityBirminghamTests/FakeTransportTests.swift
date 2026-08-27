import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct FakeTransportTests {
    @Test func loadsFourPlayerLobbyAndMatch() async throws {
        let transport = FakeTransport()
        let lobby = try await transport.loadLobby(mode: .nearby, playerCount: 4)
        let match = try await transport.loadMatch(playerCount: 4)
        #expect(lobby.players.count == 4)
        #expect(match.players.count == 4)
        #expect(lobby.mode == .nearby)
    }

    @Test @MainActor func invalidPlayerCountIsRejectedWithoutChangingTheDefault() async {
        let store = DemoSessionStore()

        #expect(store.setPlayerCount(1) == false)
        #expect(store.playerCount == 4)
        #expect(store.errorMessage?.contains("2") == true)

        await store.loadMatch()
        #expect(store.match?.players.count == 4)
    }

    @Test @MainActor func validPlayerCountLoadsTwoPlayerStates() async {
        let store = DemoSessionStore()

        #expect(store.setPlayerCount(2))
        await store.loadLobby(mode: .nearby)
        await store.loadMatch()

        #expect(store.playerCount == 2)
        #expect(store.lobby?.players.count == 2)
        #expect(store.match?.players.count == 2)
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor func changingPlayerCountInvalidatesAnInFlightLobbyRequest() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let request = Task { await store.loadLobby(mode: .online) }
        await transport.waitForLobbyRequestCount(1)

        #expect(store.setPlayerCount(2))
        await transport.succeedLobby(at: 0)
        _ = await request.value

        #expect(store.playerCount == 2)
        #expect(store.lobby == nil)
        #expect(store.selectedMode == nil)
    }

    @Test @MainActor func latestLobbyRequestWins() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let firstRequest = Task { await store.loadLobby(mode: .online) }
        await transport.waitForLobbyRequestCount(1)
        let latestRequest = Task { await store.loadLobby(mode: .nearby) }
        await transport.waitForLobbyRequestCount(2)

        await transport.succeedLobby(at: 1)
        let latestResult = await latestRequest.value
        await transport.succeedLobby(at: 0)
        let staleResult = await firstRequest.value

        #expect(latestResult == LobbyState(mode: .nearby, roomCode: "NEARBY", players: DemoFixture.players(count: 4)))
        #expect(staleResult == nil)
        #expect(store.lobby?.mode == .nearby)
        #expect(store.selectedMode == .nearby)
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor func cancelledLobbyRequestReturnsNilWithoutMutatingState() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let request = Task { await store.loadLobby(mode: .online) }
        await transport.waitForLobbyRequestCount(1)

        request.cancel()
        await transport.succeedLobby(at: 0)
        let result = await request.value

        #expect(result == nil)
        #expect(store.lobby == nil)
        #expect(store.selectedMode == nil)
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor func latestMatchRequestWinsAndStaleRequestReturnsNil() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let firstRequest = Task { await store.loadMatch() }
        await transport.waitForMatchRequestCount(1)
        let latestRequest = Task { await store.loadMatch() }
        await transport.waitForMatchRequestCount(2)

        await transport.succeedMatch(at: 1)
        let latestResult = await latestRequest.value
        await transport.succeedMatch(at: 0)
        let staleResult = await firstRequest.value

        #expect(latestResult == DemoFixture.match(playerCount: 4))
        #expect(staleResult == nil)
        #expect(store.match == latestResult)
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor func cancelledMatchRequestReturnsNilWithoutMutatingState() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let request = Task { await store.loadMatch() }
        await transport.waitForMatchRequestCount(1)

        request.cancel()
        await transport.succeedMatch(at: 0)
        let result = await request.value

        #expect(result == nil)
        #expect(store.match == nil)
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor func latestLobbyFailureClearsOldLobbyAndReportsError() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let initialRequest = Task { await store.loadLobby(mode: .online) }
        await transport.waitForLobbyRequestCount(1)
        await transport.succeedLobby(at: 0)
        _ = await initialRequest.value
        #expect(store.lobby?.mode == .online)

        let failingRequest = Task { await store.loadLobby(mode: .nearby) }
        await transport.waitForLobbyRequestCount(2)
        await transport.failLobby(at: 1)
        _ = await failingRequest.value

        #expect(store.lobby == nil)
        #expect(store.selectedMode == nil)
        #expect(store.errorMessage == ControlledTransport.failureDescription)
    }

    @Test @MainActor func latestMatchFailureClearsOldMatchAndReportsError() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let initialRequest = Task { await store.loadMatch() }
        await transport.waitForMatchRequestCount(1)
        await transport.succeedMatch(at: 0)
        _ = await initialRequest.value
        #expect(store.match != nil)

        let failingRequest = Task { await store.loadMatch() }
        await transport.waitForMatchRequestCount(2)
        await transport.failMatch(at: 1)
        _ = await failingRequest.value

        #expect(store.match == nil)
        #expect(store.errorMessage == ControlledTransport.failureDescription)
    }

    @Test @MainActor func latestSubmissionWinsAndStaleResultReturnsNil() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let state = DemoFixture.match(playerCount: 4)
        let intent = DemoIntent(
            action: .build,
            selectedCardID: "card-birmingham",
            targetIDs: ["birmingham"]
        )
        let staleEvent = DemoEvent(version: 2, title: "stale", effects: [])
        let latestEvent = DemoEvent(version: 2, title: "latest", effects: [])

        let staleRequest = Task { await store.submit(intent: intent, state: state) }
        await transport.waitForSubmissionRequestCount(1)
        let latestRequest = Task { await store.submit(intent: intent, state: state) }
        await transport.waitForSubmissionRequestCount(2)

        await transport.succeedSubmission(at: 1, event: latestEvent)
        let latestResult = await latestRequest.value
        await transport.succeedSubmission(at: 0, event: staleEvent)
        let staleResult = await staleRequest.value

        #expect(latestResult == .accepted(latestEvent))
        #expect(staleResult == nil)
    }

    @Test @MainActor func cancelledSubmissionReturnsNilWithoutSurfacingFeedback() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let state = DemoFixture.match(playerCount: 4)
        let intent = DemoIntent(
            action: .pass,
            selectedCardID: "card-birmingham",
            targetIDs: []
        )
        let request = Task { await store.submit(intent: intent, state: state) }
        await transport.waitForSubmissionRequestCount(1)

        request.cancel()
        await transport.succeedSubmission(
            at: 0,
            event: DemoEvent(version: 2, title: "cancelled", effects: [])
        )
        let result = await request.value

        #expect(result == nil)
    }

    @Test @MainActor func cancelledViewSnapshotCannotApplyWhenTransportResumes() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let state = DemoFixture.match(playerCount: 4)
        let intent = DemoIntent(
            action: .build,
            selectedCardID: "card-birmingham",
            targetIDs: ["birmingham"]
        )
        var gate = DemoSubmissionGate()
        let snapshot = gate.begin(intent: intent, actionNumber: state.actionNumber)
        let request = Task { await store.submit(intent: intent, state: state) }
        await transport.waitForSubmissionRequestCount(1)

        gate.invalidate()
        store.cancelSubmission()
        await transport.succeedSubmission(
            at: 0,
            event: DemoEvent(version: 2, title: "stale", effects: [])
        )
        let result = await request.value

        #expect(result == nil)
        #expect(gate.shouldApply(
            snapshot: snapshot,
            currentIntent: intent,
            currentActionNumber: state.actionNumber,
            eventVersion: 2
        ) == false)
    }

    @Test @MainActor func technicalSubmissionFailureKeepsExactDiagnosticSeparateFromRejection() async {
        let transport = ControlledTransport()
        let store = DemoSessionStore(transport: transport)
        let state = DemoFixture.match(playerCount: 4)
        let request = Task {
            await store.submit(
                intent: DemoIntent(
                    action: .pass,
                    selectedCardID: "card-birmingham",
                    targetIDs: []
                ),
                state: state
            )
        }
        await transport.waitForSubmissionRequestCount(1)

        await transport.failSubmission(at: 0)
        let result = await request.value

        guard case .technicalFailure(let failure) = result else {
            Issue.record("Expected a technical failure, got \(String(describing: result))")
            return
        }
        #expect(failure.diagnostic == ControlledTransport.failureDescription)
        #expect(failure.retrySuggestion.isEmpty == false)
    }
}

private actor ControlledTransport: DemoTransport {
    static let failureDescription = "Requested transport failure"

    private struct LobbyRequest {
        let mode: ConnectionMode
        let playerCount: Int
        let continuation: CheckedContinuation<LobbyState, any Error>
    }

    private struct MatchRequest {
        let playerCount: Int
        let continuation: CheckedContinuation<DemoMatchState, any Error>
    }

    private struct SubmissionRequest {
        let intent: DemoIntent
        let state: DemoMatchState
        let continuation: CheckedContinuation<DemoEvent, any Error>
    }

    private enum Failure: LocalizedError {
        case requested

        var errorDescription: String? {
            ControlledTransport.failureDescription
        }
    }

    private var lobbyRequests: [LobbyRequest] = []
    private var matchRequests: [MatchRequest] = []
    private var submissionRequests: [SubmissionRequest] = []

    func loadLobby(mode: ConnectionMode, playerCount: Int) async throws -> LobbyState {
        try await withCheckedThrowingContinuation { continuation in
            lobbyRequests.append(LobbyRequest(mode: mode, playerCount: playerCount, continuation: continuation))
        }
    }

    func loadMatch(playerCount: Int) async throws -> DemoMatchState {
        try await withCheckedThrowingContinuation { continuation in
            matchRequests.append(MatchRequest(playerCount: playerCount, continuation: continuation))
        }
    }

    func submit(intent: DemoIntent, state: DemoMatchState) async throws -> DemoEvent {
        try await withCheckedThrowingContinuation { continuation in
            submissionRequests.append(
                SubmissionRequest(intent: intent, state: state, continuation: continuation)
            )
        }
    }

    func waitForLobbyRequestCount(_ expectedCount: Int) async {
        while lobbyRequests.count < expectedCount {
            await Task.yield()
        }
    }

    func waitForMatchRequestCount(_ expectedCount: Int) async {
        while matchRequests.count < expectedCount {
            await Task.yield()
        }
    }

    func waitForSubmissionRequestCount(_ expectedCount: Int) async {
        while submissionRequests.count < expectedCount {
            await Task.yield()
        }
    }

    func succeedLobby(at index: Int) {
        let request = lobbyRequests[index]
        request.continuation.resume(
            returning: LobbyState(
                mode: request.mode,
                roomCode: request.mode == .online ? "BRASS7" : "NEARBY",
                players: DemoFixture.players(count: request.playerCount)
            )
        )
    }

    func failLobby(at index: Int) {
        lobbyRequests[index].continuation.resume(throwing: Failure.requested)
    }

    func succeedMatch(at index: Int) {
        let request = matchRequests[index]
        request.continuation.resume(returning: DemoFixture.match(playerCount: request.playerCount))
    }

    func failMatch(at index: Int) {
        matchRequests[index].continuation.resume(throwing: Failure.requested)
    }

    func succeedSubmission(at index: Int, event: DemoEvent) {
        submissionRequests[index].continuation.resume(returning: event)
    }

    func failSubmission(at index: Int) {
        submissionRequests[index].continuation.resume(throwing: Failure.requested)
    }
}
