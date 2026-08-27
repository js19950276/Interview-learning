# Industrial City Birmingham Friends-Playable Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the approved iPhone/iPad prototype into a rules-correct, recoverable 2–4 player friends-test build that works between two simulators during development and between nearby physical devices without internet or infrastructure Wi-Fi.

**Architecture:** Keep `GameCore` deterministic and pure Swift: versioned data, `PlayerIntent` validation, authoritative events, event reduction, projection and scoring. A host-authoritative `SessionCoordinator` exposes recipient-specific `GameViewState` through one `Transport` boundary; `LocalNetworkTransport` supports repeatable simulator development and `NearbyTransport` uses Network.framework Bonjour TCP with peer-to-peer inclusion. Every accepted action is persisted atomically, and reconnect catches up from a per-seat event window before falling back to a recipient-specific snapshot.

**Tech Stack:** Swift 6, SwiftUI, Observation, SpriteKit, Network.framework, CryptoKit, OSLog, Swift Testing, XCTest/XCUITest, JSON resources and `Codable`; iOS/iPadOS 17.0 minimum; no third-party packages and no server.

---

## Scope and non-goals

- In scope: official `v2018.11` rules from `RULES.md`, verified full map/card/merchant/industry data, deterministic 2/3/4-player setup, all seven actions, resources, turn/era/scoring, two-simulator rooms, nearby offline 2–4-device rooms, UI integration, autosave/reconnect/version recovery, accessibility and performance verification.
- Out of scope: online/WebSocket/server, accounts, friends/chat, matchmaking, public release, AI, anti-cheat, payments, rankings and host migration.
- Host loss pauses everyone. A non-host seat is retained across a temporary disconnect and may reconnect using its room token.
- Numeric component values must come from legally held components or authorized source material, never screenshots, guesses or prototype fixtures.
- Preserve the accepted UI. Replace fixture decisions with `GameViewState` queries; do not redesign its layout.
- Each task follows red → green → focused regression → commit. Do not combine task commits.

## Definition of done

- Deterministic seeds start and complete rules-correct games for 2, 3 and 4 players without UI/network imports in `GameCore`.
- Tests cover all actions, every `RULES.md` section 12 risk, resource priority, era transition, scoring and tie-breaks.
- One simulator creates, another joins, both ready/start and act; public state/version converge and each sees only its own hand.
- Two and four physical devices complete the flow with internet unavailable and no router; host disconnect pauses every client.
- Host relaunch restores the authoritative save; stale guests catch up or receive their own safe snapshot.
- Version/recipient/checksum mismatches block input and recover or produce a precise error without private-data leakage.
- Existing snapshot tolerance, VoiceOver journey and Task 16 performance budgets pass.

## Hard content gate

`RULES.md` section 14 says the repository lacks authoritative numeric component data. Before Task 3 is complete, obtain a legally held source, record provenance and have a second person compare every row. If unavailable, stop after schema/loader tests; never claim a complete playable game or substitute `DemoFixture` values.

## Planned file structure

```text
IndustrialCityBirmingham/
  GameCore/
    Model/       # Identifiers, state and versioned component definitions
    Data/        # Catalog loading, hashes and referential validation
    Rules/       # Setup, topology, resources, actions, turns and scoring
    Events/      # Intents, rejection, authoritative events and reduction
  GameData/v2018.11/  # Verified JSON plus manifest and provenance
  Session/       # Recipient projection, room state, sync, save and recovery
  Transport/     # Loopback, framed TCP, simulator LAN and nearby peer transport
  Features/      # Existing accepted lobby/match/map UI, adapted to GameViewState
IndustrialCityBirminghamTests/    # Pure rules, protocol and transport tests
IndustrialCityBirminghamUITests/  # Friends journey and accessibility tests
scripts/                        # Data, simulator, device and final gates
docs/testing/                   # Device matrix and completion evidence
```

## Shared verification commands

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests

xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamUITests

bash scripts/verify_friends_playable.sh
```

The final gate exits `0` and prints `FRIENDS PLAYABLE VERIFICATION PASSED`.

### Task 1: Protect the prototype baseline and add a verification entry point

**Files:**
- Create: `scripts/verify_friends_playable.sh`
- Create: `docs/testing/friends-playable-verification.md`
- Modify: `scripts/test_verify_ui_prototype.sh`

- [ ] Run the existing prototype verification and full phone tests; record commit SHA, Xcode/runtime and test counts under `Baseline`.
- [ ] Add a failing shell assertion that the new final script invokes, in order: data gate, unit tests, two-simulator test, UI tests, snapshots and `git diff --check`.
- [ ] Run `bash scripts/test_verify_ui_prototype.sh`; expect FAIL because the new script is absent.
- [ ] Add an executable script with `set -euo pipefail`, repository-root resolution and no masked failures.
- [ ] Run the shell test; expect PASS.
- [ ] Commit:

```bash
git add scripts/verify_friends_playable.sh scripts/test_verify_ui_prototype.sh docs/testing/friends-playable-verification.md
git commit -m "test: establish friends playable verification gate"
```

### Task 2: Establish pure Swift GameCore contracts

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Model/GameIdentifiers.swift`
- Create: `IndustrialCityBirmingham/GameCore/Model/GameState.swift`
- Create: `IndustrialCityBirmingham/GameCore/Events/PlayerIntent.swift`
- Create: `IndustrialCityBirmingham/GameCore/Events/AuthoritativeGameEvent.swift`
- Create: `IndustrialCityBirmingham/GameCore/Events/RejectedIntent.swift`
- Create: `IndustrialCityBirmingham/GameCore/Events/GameEventReducer.swift`
- Create: `IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift`
- Test: `IndustrialCityBirminghamTests/GameRulesEngineTests.swift`

- [ ] Write a failing compile-time contract test:

```swift
let intent = PlayerIntent(
    id: IntentID("i1"), roomID: RoomID("r1"), playerID: PlayerID("p1"),
    expectedVersion: 0, action: .pass(cardID: CardID("c1"))
)
let events = try GameRulesEngine().resolve(intent, in: state).get()
#expect(events.first == .cardDiscarded(playerID: PlayerID("p1"), cardID: CardID("c1")))
#expect(GameEventReducer.reduce(events, into: state).authoritativeVersion == 1)
```

- [ ] Add a source test rejecting SwiftUI, SpriteKit or Network imports under `GameCore/`; run unit tests and expect compile failure.
- [ ] Implement string-backed `Codable`, `Hashable`, `Sendable` IDs. State includes versions, seed, era/round/order/current actor/actions, decks, board, markets and players.
- [ ] Validate room/player/version/current actor before action rules; return events without mutating input and reduce accepted batches atomically with one version increment.
- [ ] Add canonical-JSON equality proving rejection leaves state unchanged; run tests and expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore IndustrialCityBirminghamTests/GameRulesEngineTests.swift
git commit -m "feat: establish deterministic game core contracts"
```

### Task 3: Add versioned full-game data and provenance validation

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Model/BoardDefinition.swift`
- Create: `IndustrialCityBirmingham/GameCore/Model/IndustryDefinition.swift`
- Create: `IndustrialCityBirmingham/GameCore/Model/CardDefinition.swift`
- Create: `IndustrialCityBirmingham/GameCore/Model/MerchantDefinition.swift`
- Create: `IndustrialCityBirmingham/GameCore/Model/IncomeTrack.swift`
- Create: `IndustrialCityBirmingham/GameCore/Data/GameDataCatalog.swift`
- Create: `IndustrialCityBirmingham/GameCore/Data/GameDataLoader.swift`
- Create: `IndustrialCityBirmingham/GameCore/Data/GameDataValidator.swift`
- Create: `IndustrialCityBirmingham/GameData/v2018.11/manifest.json`
- Create: `IndustrialCityBirmingham/GameData/v2018.11/map.json`
- Create: `IndustrialCityBirmingham/GameData/v2018.11/industries.json`
- Create: `IndustrialCityBirmingham/GameData/v2018.11/cards.json`
- Create: `IndustrialCityBirmingham/GameData/v2018.11/merchants.json`
- Create: `IndustrialCityBirmingham/GameData/v2018.11/provenance.md`
- Create: `scripts/verify_game_data.sh`
- Test: `IndustrialCityBirminghamTests/GameDataTests.swift`

- [ ] Write failing decode/completeness tests for ruleset `v2018.11`, masks `[2,3,4]`, 45 industry tiles per color, 64 standard cards, 4+4 wilds, 9 merchants and zero validator errors.
- [ ] Validator errors identify duplicate IDs, missing endpoints, invalid levels/masks/references, route/slot inconsistencies and hash mismatch.
- [ ] Run unit tests and `bash scripts/verify_game_data.sh`; expect FAIL.
- [ ] Implement explicit schema, stable lowercase IDs, SHA-256 manifest validation and provenance fields for source/version/component/page/transcriber/date/checker/date.
- [ ] Transcribe every value from legal material; a second person checks every row and signs provenance. Never use `DemoFixture` as source.
- [ ] Alter one card count, expect data validation FAIL, restore and expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore/Model IndustrialCityBirmingham/GameCore/Data IndustrialCityBirmingham/GameData IndustrialCityBirminghamTests/GameDataTests.swift scripts/verify_game_data.sh
git commit -m "feat: add verified versioned game data"
```

### Task 4: Implement deterministic 2/3/4-player setup

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Rules/SetupRules.swift`
- Modify: `IndustrialCityBirmingham/GameCore/Model/GameState.swift`
- Test: `IndustrialCityBirminghamTests/GameSetupTests.swift`

- [ ] For seeds `2001/3001/4001`, write failing tests for £17, income position 10, VP 0, eight-card hands, bottom discard, market openings, player-count exclusions, merchant beer, deterministic order and round counts `10/9/8`.
- [ ] Run unit tests; expect missing `SetupRules.makeGame` failure.
- [ ] Implement a stored seeded RNG; setup consumes catalog data and emits replayable creation/shuffle/deal/order events.
- [ ] Run twice and assert identical canonical hashes; expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore/Rules/SetupRules.swift IndustrialCityBirmingham/GameCore/Model/GameState.swift IndustrialCityBirminghamTests/GameSetupTests.swift
git commit -m "feat: implement deterministic game setup"
```

### Task 5: Separate player network from route connectivity

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Rules/TopologyRules.swift`
- Test: `IndustrialCityBirminghamTests/TopologyRulesTests.swift`

- [ ] Write failing tests for owned network membership, opponent-link exclusion, any-player route traversal/distance, disconnected cases, the three-location Kidderminster–Worcester edge and first-link exception.
- [ ] Run tests; expect missing `TopologyRules` failure.
- [ ] Implement distinct `isInPlayerNetwork`, `hasRoute`, `routeDistance`, `adjacentLocations` and `legalNetworkOrigins`; sort equal-distance IDs.
- [ ] Run tests; expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore/Rules/TopologyRules.swift IndustrialCityBirminghamTests/TopologyRulesTests.swift
git commit -m "feat: implement board topology rules"
```

### Task 6: Implement coal, iron, beer and market resolution

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Rules/ResourceRules.swift`
- Modify: `IndustrialCityBirmingham/GameCore/Events/AuthoritativeGameEvent.swift`
- Test: `IndustrialCityBirminghamTests/ResourceRulesTests.swift`

- [ ] Write failing table tests for nearest connected coal/ties, edge-connected market coal, unlimited coal £8, any map iron before market, unlimited iron £6, own/opponent/merchant beer, immediate coal/iron market delivery, payment and flip/income.
- [ ] Run unit tests; expect missing `legalResourceSources`/`resolveResourcePlan` failure.
- [ ] Implement an ordered `ResourcePlan` with sources, quantities, market cost and events; validate the full plan against one state/version before emission.
- [ ] Add atomicity tests: insufficient second coal or illegal beer emits no partial consumption; exhaustion removes resource before flip/income.
- [ ] Run unit tests; expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore/Rules/ResourceRules.swift IndustrialCityBirmingham/GameCore/Events/AuthoritativeGameEvent.swift IndustrialCityBirminghamTests/ResourceRulesTests.swift
git commit -m "feat: implement resource and market rules"
```

### Task 7: Implement build and network actions

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Rules/BuildRules.swift`
- Create: `IndustrialCityBirmingham/GameCore/Rules/NetworkRules.swift`
- Modify: `IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift`
- Test: `IndustrialCityBirminghamTests/BuildAndNetworkRulesTests.swift`

- [ ] Write failing build cases for location/industry/wild cards, first build, slot priority, farms, lowest tile, era restriction, own/opponent overbuild, costs, production and market delivery.
- [ ] Write failing network cases for canal £3, rail £5+coal, double rail £15+two coal+non-merchant beer, ordered placement, new connectivity and first-link exception.
- [ ] Run tests; expect missing resolvers.
- [ ] Implement `legalBuildTargets`, `resolveBuild`, `legalNetworkRoutes`, `resolveNetwork` using topology/resource query APIs and atomic batches.
- [ ] Run the high-risk matrix; `RULES.md` risks 1, 2, 3, 7 and 8 pass.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore/Rules/BuildRules.swift IndustrialCityBirmingham/GameCore/Rules/NetworkRules.swift IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift IndustrialCityBirminghamTests/BuildAndNetworkRulesTests.swift
git commit -m "feat: implement build and network actions"
```

### Task 8: Implement develop, sell, loan, scout and pass

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Rules/DevelopRules.swift`
- Create: `IndustrialCityBirmingham/GameCore/Rules/SellRules.swift`
- Create: `IndustrialCityBirmingham/GameCore/Rules/SimpleActionRules.swift`
- Modify: `IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift`
- Test: `IndustrialCityBirminghamTests/DevelopSellSimpleActionTests.swift`

- [ ] Write failing develop/sell tests for one/two lowest tiles, iron, bulb pottery, multi-sell, concrete merchant, one merchant beer maximum, beer connectivity, flip/income and all merchant rewards/blank rejection.
- [ ] Write failing loan/scout/pass tests for £30, three income levels and -10 floor; three normal-card discards and both wilds only when none held; pass discards one.
- [ ] Run tests; expect missing resolvers.
- [ ] Implement ordered multi-step intents with complete prevalidation. Model income track by position and derive displayed level.
- [ ] Run tests; expect `RULES.md` risks 5, 6, 10 and 11 PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore/Rules/DevelopRules.swift IndustrialCityBirmingham/GameCore/Rules/SellRules.swift IndustrialCityBirmingham/GameCore/Rules/SimpleActionRules.swift IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift IndustrialCityBirminghamTests/DevelopSellSimpleActionTests.swift
git commit -m "feat: implement remaining player actions"
```

### Task 9: Implement turns, era transitions, scoring and winner resolution

**Files:**
- Create: `IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift`
- Create: `IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift`
- Modify: `IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift`
- Test: `IndustrialCityBirminghamTests/TurnScoringRulesTests.swift`

- [ ] Write failing tests for first canal round one action, otherwise two, refill, stable spending order, reset, positive/negative income, forced half-price industry sale, VP debt and no final income.
- [ ] Write failing tests for link adjacency scoring/removal, flipped industry scoring, canal cleanup/refill/redeal/preservation, repeat level-2 scoring and VP→income-position→cash→draw winner order.
- [ ] Run tests; expect missing transition/scoring functions.
- [ ] Implement `resolveRoundEnd`, `scoreEra`, `prepareRailEra`, `resolveWinner` as explicit replayable events.
- [ ] Run the complete rule suite; expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift IndustrialCityBirminghamTests/TurnScoringRulesTests.swift
git commit -m "feat: implement turn flow and scoring"
```

### Task 10: Prove complete deterministic games and rule coverage

**Files:**
- Modify: `IndustrialCityBirminghamTests/GameRulesEngineTests.swift`
- Create: `IndustrialCityBirminghamTests/RulesCoverageTests.swift`
- Modify: `scripts/verify_game_data.sh`
- Modify: `docs/testing/friends-playable-verification.md`

- [ ] Add legal seeded intent scripts for 2/3/4 players through rail scoring; assert version equals accepted intents, repeat hashes match and event replay reproduces final state.
- [ ] Add one named test per `RULES.md` section 12 item and a manifest covering setup/resources/all actions/turns/scoring; validation fails for unmatched names.
- [ ] Run the shared unit command twice with separate `.xcresult` bundles; expect PASS and identical final hashes.
- [ ] Record evidence and commit:

```bash
git add IndustrialCityBirminghamTests/GameRulesEngineTests.swift IndustrialCityBirminghamTests/RulesCoverageTests.swift scripts/verify_game_data.sh docs/testing/friends-playable-verification.md
git commit -m "test: prove complete deterministic game rules"
```

### Task 11: Define recipient-safe session protocol and view projection

**Files:**
- Create: `IndustrialCityBirmingham/Session/SessionEnvelope.swift`
- Create: `IndustrialCityBirmingham/Session/SessionMessage.swift`
- Create: `IndustrialCityBirmingham/Session/GameViewState.swift`
- Create: `IndustrialCityBirmingham/Session/ViewProjector.swift`
- Create: `IndustrialCityBirmingham/Session/ViewChecksum.swift`
- Create: `IndustrialCityBirmingham/Session/EventWindow.swift`
- Create: `IndustrialCityBirmingham/Session/RoomState.swift`
- Test: `IndustrialCityBirminghamTests/SessionProtocolTests.swift`
- Test: `IndustrialCityBirminghamTests/ViewProjectionTests.swift`

- [ ] Write failing round-trip tests for hello/create/join/ready/start/intent/client-event/catch-up/view-snapshot/pause/rejection/version-incompatible messages. Every envelope includes protocol/rules/data version, room/message/sender/recipient IDs and authoritative version.
- [ ] Search encoded recipient event/snapshot/view bytes and assert no opponent card ID/title. Assert stable canonical SHA-256 view checksum.
- [ ] Run tests; expect missing types.
- [ ] Implement strict Codable envelopes; reject version, room, sender, recipient, future-version or room-token mismatch before action decode. Store separate bounded 128-event windows per seat.
- [ ] Run tests; expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/Session IndustrialCityBirminghamTests/SessionProtocolTests.swift IndustrialCityBirminghamTests/ViewProjectionTests.swift
git commit -m "feat: add recipient safe session protocol"
```

### Task 12: Build a two-simulator local development room

**Files:**
- Create: `IndustrialCityBirmingham/Transport/Transport.swift`
- Create: `IndustrialCityBirmingham/Transport/LoopbackTransport.swift`
- Create: `IndustrialCityBirmingham/Transport/FramedConnection.swift`
- Create: `IndustrialCityBirmingham/Transport/LocalNetworkTransport.swift`
- Create: `IndustrialCityBirmingham/Session/SessionCoordinator.swift`
- Create: `IndustrialCityBirmingham/App/AppEnvironment.swift`
- Modify: `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift`
- Test: `IndustrialCityBirminghamTests/LocalNetworkTransportTests.swift`
- Test: `IndustrialCityBirminghamTests/SessionCoordinatorTests.swift`
- Create: `scripts/run_two_simulator_room_test.sh`

- [ ] Write failing tests for 4-byte big-endian framing, split/coalesced reads, 1 MiB maximum, malformed shutdown, duplicate-message suppression and ordered delivery.
- [ ] With paired loopback transports, test host create → guest join → ready → start → guest intent → host resolve → recipient projections → equal public checksum/version.
- [ ] Run tests; expect missing transport/coordinator failure.
- [ ] Implement `AsyncStream<TransportEvent>` plus `startHosting`, `browse`, `connect`, `send(to:)`, `disconnect`; only `SessionCoordinator` calls GameCore.
- [ ] Implement simulator `NWListener`/`NWBrowser`/TCP `NWConnection` using `_industrialcity-dev._tcp`; bind room/reconnect token during hello and reject fifth seats/version mismatch before lobby mutation.
- [ ] Create the smoke script: boot/install/launch host phone and join iPad using `-local-role`/`-local-room TEST42`, wait at most 30 seconds, and collect both device logs on failure.
- [ ] Run `bash scripts/run_two_simulator_room_test.sh` plus unit tests; expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/Transport IndustrialCityBirmingham/Session/SessionCoordinator.swift IndustrialCityBirmingham/App/AppEnvironment.swift IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift IndustrialCityBirminghamTests/LocalNetworkTransportTests.swift IndustrialCityBirminghamTests/SessionCoordinatorTests.swift scripts/run_two_simulator_room_test.sh
git commit -m "feat: add two simulator local rooms"
```

### Task 13: Integrate real lobby, rule queries and match state into the accepted UI

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Lobby/LobbyView.swift`
- Modify: `IndustrialCityBirmingham/Features/Nearby/NearbyRoomView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchInteractionReducer.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ActionFlowView.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapScene.swift`
- Modify: `IndustrialCityBirmingham/App/RootView.swift`
- Modify: `IndustrialCityBirmingham/Session/DemoSessionStore.swift`
- Test: `IndustrialCityBirminghamTests/SessionCoordinatorTests.swift`
- Create: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`

- [ ] Write failing UI journeys for create/join/ready/host-only start, legal highlights, accepted build on both clients, direct rejection+recovery, out-of-turn disabled, current-actor pause and host-loss pause.
- [ ] Run phone UI tests; expect FAIL because views still use `DemoSessionStore`, `FakeTransport` and `ActionFixture.standard`.
- [ ] Adapt recipient `GameViewState` to existing visual models. Supply available actions, legal targets/resources and confirmation deltas from GameCore.
- [ ] UI emits only `PlayerIntent`; local drafts may preview but must not alter authoritative cash/market/board/turn/hand until matching client event.
- [ ] Keep deterministic fixture assembly only behind `AppEnvironment.fixture` for snapshot tests. No production nearby button instantiates `FakeTransport`.
- [ ] Run the two-simulator script, snapshot capture and full phone tests; expect journeys PASS and existing snapshot thresholds unchanged.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/App IndustrialCityBirmingham/Features IndustrialCityBirmingham/Session/DemoSessionStore.swift IndustrialCityBirminghamTests/SessionCoordinatorTests.swift IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift Tests/Snapshots
git commit -m "feat: connect game sessions to match UI"
```

### Task 14: Implement nearby peer-to-peer discovery for airplane use

**Files:**
- Create: `IndustrialCityBirmingham/Transport/BonjourPeerBrowser.swift`
- Create: `IndustrialCityBirmingham/Transport/NearbyPreflight.swift`
- Create: `IndustrialCityBirmingham/Transport/NearbyTransport.swift`
- Modify: `IndustrialCityBirmingham/Transport/LocalNetworkTransport.swift`
- Modify: `IndustrialCityBirmingham/Features/Nearby/NearbyRoomView.swift`
- Modify: `IndustrialCityBirmingham.xcodeproj/project.pbxproj`
- Test: `IndustrialCityBirminghamTests/NearbyTransportTests.swift`

- [ ] Write failing injected-adapter tests for discover/add/remove, duplicate suppression, room-name sanitization, cancellation, permission/wireless/no-room errors, 2–4 seat limit and reconnect-token reuse.
- [ ] Assert the nearby parameter factory sets `NWParameters.includePeerToPeer = true`; run tests and expect missing adapter failure.
- [ ] Implement `_industrialcity._tcp` with `NWBrowser`, `NWListener`, TCP `NWConnection`, peer-to-peer inclusion and the existing frame/protocol/session layers.
- [ ] Add exact `_industrialcity._tcp` to `NSBonjourServices` and a clear `NSLocalNetworkUsageDescription`. Do not request multicast entitlement for fixed Bonjour browsing and do not import MultipeerConnectivity.
- [ ] Connect real scanning/found/empty/permission/wireless/join/retry states. Explain that airplane mode may remain enabled while Wi-Fi must be re-enabled if the OS turned it off.
- [ ] Run simulator tests; expect state-machine PASS. Record that simulator does not prove Local Network privacy or physical peer-to-peer connectivity. Wi-Fi Aware is optional iOS 26+/supported-hardware enhancement, not the iOS 17 baseline.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/Transport IndustrialCityBirmingham/Features/Nearby/NearbyRoomView.swift IndustrialCityBirmingham.xcodeproj/project.pbxproj IndustrialCityBirminghamTests/NearbyTransportTests.swift
git commit -m "feat: add nearby peer to peer transport"
```

### Task 15: Add autosave, reconnect, event catch-up and snapshot recovery

**Files:**
- Create: `IndustrialCityBirmingham/Session/RoomTokenStore.swift`
- Create: `IndustrialCityBirmingham/Session/SnapshotStore.swift`
- Create: `IndustrialCityBirmingham/Session/RecoveryCoordinator.swift`
- Modify: `IndustrialCityBirmingham/Session/SessionCoordinator.swift`
- Modify: `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift`
- Test: `IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift`
- Modify: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`

- [ ] Write failing persistence tests: host saves authoritative snapshot plus per-seat windows after accepted action/round/era/background; guests save only own view/token/window; interrupted temp writes preserve last committed file; opponent hands never encode.
- [ ] Write failing recovery tests: continuous catch-up, history-too-old snapshot, version gap, checksum/recipient/version mismatch, actor/host pause, seat retention and three failed snapshot checks returning to lobby with diagnostics.
- [ ] Run tests; expect missing stores/recovery failure.
- [ ] Implement canonical bytes to sibling temp, synchronize/close and atomic replace. Authenticate room/player/token before catch-up; otherwise send only that recipient's snapshot.
- [ ] Disable new intents during recovery while keeping map pan/zoom; add host relaunch, guest background and mismatch recovery UI journeys.
- [ ] Run full phone tests and two-simulator script; expect PASS.
- [ ] Commit:

```bash
git add IndustrialCityBirmingham/Session IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift
git commit -m "feat: add session persistence and recovery"
```

### Task 16: Validate physical devices, accessibility and performance

**Files:**
- Create: `docs/testing/friends-playable-device-matrix.md`
- Modify: `docs/testing/friends-playable-verification.md`
- Create: `scripts/capture_physical_device_metrics.sh`
- Create: `IndustrialCityBirminghamUITests/AccessibilityJourneyUITests.swift`
- Modify: `scripts/verify_friends_playable.sh`

- [ ] Create a matrix with model/OS/role/evidence for two-device iPhone↔iPad and four mixed devices. Scenarios: internet unavailable/no router, airplane mode with Wi-Fi re-enabled, create/discover/join/start, one action per seat, guest background/lock/reconnect, actor disconnect, host disconnect and host relaunch.
- [ ] Add an accessibility journey for create/join/ready/start, turn/resources/hand, card/action/target, confirmation, rejection, recovery and paused/syncing. Manually VoiceOver-swipe smallest iPhone and one iPad; require no unlabeled/duplicate/color-only/unreachable controls.
- [ ] Create a UDID/result-path metrics script that refuses PASS when measurements are absent. Capture a 30-minute four-seat trace.
- [ ] Pass budgets: local preview p95 <100 ms; nearby accepted-event p95 <250 ms; map ≥55 FPS on oldest device; peak RSS <350 MB and growth <25 MB/30 min; zero crashes/hangs/leaked coordinator/connections; 10-second background reconnect <5 seconds.
- [ ] Run `bash scripts/verify_friends_playable.sh`; expect final PASS, all tests/snapshots green and no generated dirty files.
- [ ] Link `.xcresult`, logs, device matrix, Instruments and VoiceOver evidence; explicitly list deferred online/accounts/AI/anti-cheat/host migration.
- [ ] Commit:

```bash
git add IndustrialCityBirminghamUITests/AccessibilityJourneyUITests.swift scripts/capture_physical_device_metrics.sh scripts/verify_friends_playable.sh docs/testing/friends-playable-device-matrix.md docs/testing/friends-playable-verification.md
git commit -m "test: verify friends playable release candidate"
```

## Requirement traceability

| Requirement | Tasks | Proof |
| --- | --- | --- |
| Full official rules and component data | 2–10 | Catalog gate, high-risk manifest, complete-game replay tests |
| Two-simulator room and synchronization | 11–13 | Protocol/coordinator tests and simulator smoke script |
| Accepted UI uses real rules/state | 13 | UI journeys plus unchanged snapshot gate |
| Nearby 2–4-device airplane play | 14, 16 | Adapter tests plus signed physical-device matrix |
| Save/reconnect/version recovery | 11, 15 | Fault injection and relaunch/recovery journeys |
| Accessibility/performance | 16 | VoiceOver, matrix and Instruments evidence |

## Risks and mitigations

- **Missing authoritative data:** Hard-stop Task 3 until legally sourced data is independently checked; no fixture substitution.
- **Peer-to-peer differs by OS/device:** Keep Network.framework behind `Transport`; simulator tests cover logic, while 2/4-device airplane tests gate completion. MultipeerConnectivity is deprecated and excluded.
- **Hidden-hand leakage:** Recipient projection, per-seat windows, encoded-byte searches and recipient-bound envelopes gate transport work.
- **Retry divergence:** Expected versions, message-ID deduplication, canonical checksums, atomic batches and snapshot fallback prevent silent drift.
- **Rules combinatorics:** Table tests, section-12 traceability, seeded complete games and replay tests precede UI/network work.
- **UI becomes a second engine:** `GameViewState` supplies all legal options/deltas; UI owns only disposable drafts.
- **Host migration absent:** Accepted non-goal; host loss pauses and recovery requires the same host/save.

## Stop rules

- Stop Task 3 without complete legal data and independent verification.
- Stop nearby acceptance if two physical devices cannot connect with internet unavailable/no router; simulator success is not a substitute.
- Stop on red baseline, hash mismatch, private-data leak, non-deterministic replay or unexplained divergence.
- Do not start online/WebSocket, accounts, public release, AI, anti-cheat or host migration under this plan.
- Completion requires Task 16 evidence; unit tests alone are insufficient.

## Execution handoff

Use `superpowers:subagent-driven-development`, one fresh implementation worker per task with spec review then quality review. Tasks 2–10 are sequential. Begin session work after Task 10 is green; Tasks 12–15 are sequential around the shared protocol. Task 16 requires physical devices and cannot be replaced by paper review. Use `superpowers:executing-plans` only if one session owns the work in checkpointed batches.
