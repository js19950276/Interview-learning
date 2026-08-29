# Industrial City Birmingham UI Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Phase 1 native iPhone/iPad high-fidelity interactive prototype with fake 2–4 player data, adaptive match layouts, a SpriteKit map, seven action flows, lobby screens, accessibility, and repeatable visual/performance checks.

**Architecture:** A single iOS application target renders navigation and panels in SwiftUI and embeds a SpriteKit map through SpriteView. An observable DemoSessionStore consumes a DemoTransport protocol; Phase 1 binds it only to FakeTransport and deterministic fixtures. MatchInteractionReducer owns card selection, mutually exclusive overlays, and the seven fixture-driven action state machines so no game rule logic leaks into views.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, SpriteKit, Swift Testing, XCTest/XCUITest, OSLog signposts, ImageIO/CoreGraphics, Xcode 26.6; deployment target iOS/iPadOS 17.0; no third-party packages.

---

## Scope and execution constraints

- Implement only Phase 1 from [the approved design specification](../specs/2026-08-06-industrial-city-birmingham-app-design.md).
- Do not implement GameCore, NearbyTransport, WebSocketTransport, accounts, AI, or a complete playable game.
- Create all art, icons, sounds, and textures as original prototype assets. SF Symbols are allowed. Do not trace or copy the reference game UI.
- Run `superpowers:using-git-worktrees` before Task 1. Create the implementation worktree from `main` on a `codex/ui-prototype` branch.
- Run `superpowers:test-driven-development` for every behavior task. Each red test must fail for the intended reason before production code is added.
- Do not add Swift packages, CocoaPods, Homebrew tools, or runtime dependencies.
- Keep tracked `RULES.md` and `.gitignore` unchanged. Leave untracked `AGENTS.md` and `.codex/` content untouched unless a task explicitly lists them.
- Commit only the paths listed in each task.

## Planned file structure

```text
IndustrialCityBirmingham.xcodeproj/
IndustrialCityBirmingham/
  App/
    IndustrialCityBirminghamApp.swift
    AppDelegate.swift
    AppRoute.swift
    RootView.swift
    OrientationCoordinator.swift
  DesignSystem/
    BrassColor.swift
    BrassTheme.swift
    BrassTypography.swift
    BrassComponents.swift
    MotionPreferences.swift
  Models/
    DemoModels.swift
    ActionModels.swift
  Fixtures/
    DemoFixture.swift
  Session/
    DemoTransport.swift
    FakeTransport.swift
    DemoSessionStore.swift
  Features/
    Home/HomeView.swift
    Online/OnlineRoomView.swift
    Nearby/NearbyRoomView.swift
    Lobby/LobbyView.swift
    Rules/RulesSummaryView.swift
    Settings/SettingsView.swift
    Gallery/UIGalleryView.swift
    Match/
      MatchView.swift
      MatchLayoutMetrics.swift
      MatchHeaderView.swift
      PlayerRailView.swift
      IndustryRailView.swift
      ResourceMarketView.swift
      HandView.swift
      ActionGridView.swift
      MatchInteractionReducer.swift
      ActionFlowView.swift
      ConfirmationPanel.swift
    Map/
      GameMapView.swift
      GameMapScene.swift
      MapNodeFactory.swift
  Assets.xcassets/
    IndustrialMap.imageset/
      Contents.json
      industrial-map.png
IndustrialCityBirminghamTests/
  BrassColorTests.swift
  DemoFixtureTests.swift
  FakeTransportTests.swift
  NavigationTests.swift
  MatchLayoutMetricsTests.swift
  MatchInteractionReducerTests.swift
  ActionFlowTests.swift
  GameMapSceneTests.swift
IndustrialCityBirminghamUITests/
  AppSmokeUITests.swift
  MatchInteractionUITests.swift
  SnapshotCaptureUITests.swift
scripts/
  capture_ui_snapshots.sh
  SnapshotDiff.swift
  verify_ui_prototype.sh
Tests/
  Snapshots/
    Baselines/
    Current/
```

## Shared build commands

Use these exact simulator names throughout the plan:

```bash
if ! xcrun simctl list devices available | rg -q "IndustrialCity-iPhone"; then
  xcrun simctl create "IndustrialCity-iPhone" \
    "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro" \
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
fi

if ! xcrun simctl list devices available | rg -q "IndustrialCity-iPad"; then
  xcrun simctl create "IndustrialCity-iPad" \
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB" \
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
fi
```

Unit tests:

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -only-testing:IndustrialCityBirminghamTests
```

UI tests:

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -only-testing:IndustrialCityBirminghamUITests
```

## Task 1: Bootstrap the native iOS project

**Files:**
- Create: `IndustrialCityBirmingham.xcodeproj/project.pbxproj`
- Create: `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift`
- Create: `IndustrialCityBirmingham/App/RootView.swift`
- Create: `IndustrialCityBirminghamUITests/AppSmokeUITests.swift`
- Modify: `IndustrialCityBirmingham/Assets.xcassets/Contents.json`

- [ ] **Step 1: Create the Xcode template without external generators**

Open Xcode and use File → New → Project with these exact values:

- Template: iOS App
- Product Name: `IndustrialCityBirmingham`
- Team: None
- Organization Identifier: `com.example`
- Interface: SwiftUI
- Language: Swift
- Testing System: Swift Testing with XCTest UI Tests
- Storage: None
- Include Tests: enabled
- Save at repository root
- Create Git repository: disabled

Set the app target deployment to iOS 17.0, supported destinations to iPhone and iPad, and Swift language mode to Swift 6. The generated Xcode 26 synchronized groups must point at `IndustrialCityBirmingham/`, `IndustrialCityBirminghamTests/`, and `IndustrialCityBirminghamUITests/`.

- [ ] **Step 2: Write the failing launch UI test**

Replace `IndustrialCityBirminghamUITests/AppSmokeUITests.swift` with:

```swift
import XCTest

final class AppSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsHomeTitle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["home.title"].label, "工业城市伯明翰")
    }
}
```

- [ ] **Step 3: Run the launch test and verify the intended failure**

Run the shared UI-test command.

Expected: FAIL because no element has accessibility identifier `home.title`.

- [ ] **Step 4: Add the minimal app shell**

Set `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift` to:

```swift
import SwiftUI

@main
struct IndustrialCityBirminghamApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```

Set `IndustrialCityBirmingham/App/RootView.swift` to:

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        Text("工业城市伯明翰")
            .accessibilityIdentifier("home.title")
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 5: Verify, then commit**

Run the shared UI-test command and:

```bash
xcodebuild build \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'generic/platform=iOS Simulator'

git add IndustrialCityBirmingham.xcodeproj IndustrialCityBirmingham IndustrialCityBirminghamTests IndustrialCityBirminghamUITests
git commit -m "chore: bootstrap iOS app"
```

Expected: build succeeds and `testLaunchShowsHomeTitle` passes.

## Task 2: Establish the measurable design system

**Files:**
- Create: `IndustrialCityBirmingham/DesignSystem/BrassColor.swift`
- Create: `IndustrialCityBirmingham/DesignSystem/BrassTheme.swift`
- Create: `IndustrialCityBirmingham/DesignSystem/BrassTypography.swift`
- Create: `IndustrialCityBirmingham/DesignSystem/BrassComponents.swift`
- Create: `IndustrialCityBirmingham/DesignSystem/MotionPreferences.swift`
- Create: `IndustrialCityBirminghamTests/BrassColorTests.swift`

- [ ] **Step 1: Write failing contrast and token tests**

Create `IndustrialCityBirminghamTests/BrassColorTests.swift`:

```swift
import Testing
@testable import IndustrialCityBirmingham

struct BrassColorTests {
    @Test func paperOnCoalMeetsNormalTextContrast() {
        #expect(BrassColor.paper.contrastRatio(against: .coal) >= 4.5)
    }

    @Test func brassOnCoalMeetsLargeTextContrast() {
        #expect(BrassColor.brass.contrastRatio(against: .coal) >= 3.0)
    }

    @Test func spacingTokensStayOnFourPointGrid() {
        #expect(BrassSpacing.all.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
    }
}
```

- [ ] **Step 2: Run the unit tests and verify they fail**

Run the shared unit-test command.

Expected: compile failure because `BrassColor` and `BrassSpacing` do not exist.

- [ ] **Step 3: Implement color math and theme tokens**

Create `IndustrialCityBirmingham/DesignSystem/BrassColor.swift`:

```swift
import SwiftUI

struct BrassColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let coal = BrassColor(hex: 0x1C2022)
    static let iron = BrassColor(hex: 0x7D5B45)
    static let brass = BrassColor(hex: 0xC49A50)
    static let fog = BrassColor(hex: 0x839093)
    static let paper = BrassColor(hex: 0xE7DDC8)
    static let danger = BrassColor(hex: 0xB44A3C)

    init(hex: Int) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    func contrastRatio(against other: BrassColor) -> Double {
        let brighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}
```

Create `IndustrialCityBirmingham/DesignSystem/BrassTheme.swift`:

```swift
import SwiftUI

enum BrassSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
    static let all = [xSmall, small, medium, large, xLarge, xxLarge]
}

enum BrassRadius {
    static let card: CGFloat = 12
    static let panel: CGFloat = 16
    static let capsule: CGFloat = 999
}

enum BrassShadow {
    static let panel = (color: Color.black.opacity(0.38), radius: CGFloat(18), y: CGFloat(10))
    static let selected = (color: BrassColor.brass.color.opacity(0.55), radius: CGFloat(14), y: CGFloat(4))
}
```

- [ ] **Step 4: Add typography, panel, button, and motion primitives**

Create `IndustrialCityBirmingham/DesignSystem/BrassTypography.swift`:

```swift
import SwiftUI

enum BrassTypography {
    static let display = Font.system(size: 34, weight: .semibold, design: .serif)
    static let title = Font.system(size: 22, weight: .semibold, design: .serif)
    static let body = Font.system(size: 15, weight: .regular, design: .rounded)
    static let label = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let number = Font.system(size: 14, weight: .bold, design: .monospaced)
}
```

Create `IndustrialCityBirmingham/DesignSystem/MotionPreferences.swift`:

```swift
import Observation

@MainActor
@Observable
final class MotionPreferences {
    var isSoundEnabled = true
    var isHapticsEnabled = true
    var reduceMotion = false
    var colorAssistEnabled = true
}
```

Create `IndustrialCityBirmingham/DesignSystem/BrassComponents.swift`:

```swift
import SwiftUI

struct BrassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(BrassSpacing.large)
            .background(.ultraThinMaterial)
            .background(BrassColor.coal.color.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: BrassRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BrassRadius.panel, style: .continuous)
                    .stroke(BrassColor.brass.color.opacity(0.45), lineWidth: 1)
            }
            .shadow(
                color: BrassShadow.panel.color,
                radius: BrassShadow.panel.radius,
                y: BrassShadow.panel.y
            )
    }
}

extension View {
    func brassPanel() -> some View {
        modifier(BrassPanel())
    }
}

struct BrassPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrassTypography.label)
            .foregroundStyle(BrassColor.coal.color)
            .padding(.horizontal, BrassSpacing.xLarge)
            .frame(minHeight: 44)
            .background(BrassColor.brass.color.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
```

- [ ] **Step 5: Verify, then commit**

Run the shared unit-test and build commands.

```bash
git add IndustrialCityBirmingham/DesignSystem IndustrialCityBirminghamTests/BrassColorTests.swift
git commit -m "feat: add industrial design system"
```

Expected: all design-system tests pass and the app builds without warnings introduced by these files.

## Task 3: Define deterministic demo models, fixtures, and FakeTransport

**Files:**
- Create: `IndustrialCityBirmingham/Models/DemoModels.swift`
- Create: `IndustrialCityBirmingham/Models/ActionModels.swift`
- Create: `IndustrialCityBirmingham/Fixtures/DemoFixture.swift`
- Create: `IndustrialCityBirmingham/Session/DemoTransport.swift`
- Create: `IndustrialCityBirmingham/Session/FakeTransport.swift`
- Create: `IndustrialCityBirmingham/Session/DemoSessionStore.swift`
- Create: `IndustrialCityBirminghamTests/DemoFixtureTests.swift`
- Create: `IndustrialCityBirminghamTests/FakeTransportTests.swift`

- [ ] **Step 1: Write failing fixture and transport tests**

Create `IndustrialCityBirminghamTests/DemoFixtureTests.swift`:

```swift
import Testing
@testable import IndustrialCityBirmingham

struct DemoFixtureTests {
    @Test(arguments: [2, 3, 4])
    func fixtureHasRequestedPlayerCount(_ count: Int) {
        let state = DemoFixture.match(playerCount: count)
        #expect(state.players.count == count)
        #expect(state.hand.count == 8)
        #expect(state.coalMarket.remaining >= 0)
        #expect(state.ironMarket.remaining >= 0)
    }

    @Test func allActionsHaveFixtureData() {
        let fixture = ActionFixture.standard
        #expect(Set(fixture.availableActions) == Set(GameAction.allCases))
        #expect(fixture.buildLocationIDs.isEmpty == false)
        #expect(fixture.networkRouteIDs.count >= 2)
        #expect(fixture.developIndustryIDs.count >= 2)
        #expect(fixture.sellOptions.isEmpty == false)
        #expect(fixture.scoutCardIDs.count >= 2)
    }
}
```

Create `IndustrialCityBirminghamTests/FakeTransportTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run tests and verify the compile failure**

Run the shared unit-test command.

Expected: compile failure because the demo model and transport types do not exist.

- [ ] **Step 3: Implement the model contracts**

Create `IndustrialCityBirmingham/Models/DemoModels.swift` with these public shapes:

```swift
import Foundation

enum ConnectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case online
    case nearby
    var id: String { rawValue }
}

enum PlayerColor: String, CaseIterable, Codable, Sendable {
    case amber, crimson, teal, violet
    var symbol: String {
        switch self {
        case .amber: "diamond.fill"
        case .crimson: "triangle.fill"
        case .teal: "circle.fill"
        case .violet: "square.fill"
        }
    }
}

struct PlayerSummary: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var name: String
    var color: PlayerColor
    var order: Int
    var spent: Int
    var isCurrent: Bool
    var isHost: Bool
    var isReady: Bool
    var isConnected: Bool
}

enum IndustryKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case cotton, manufacturer, pottery, coal, iron, brewery
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cotton: "square.grid.3x3.fill"
        case .manufacturer: "shippingbox.fill"
        case .pottery: "cup.and.saucer.fill"
        case .coal: "seal.fill"
        case .iron: "cube.fill"
        case .brewery: "waterbottle.fill"
        }
    }
}

struct IndustrySummary: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let kind: IndustryKind
    var level: Int
    var cost: Int
    var coalCost: Int
    var ironCost: Int
    var isAvailable: Bool
}

struct MarketSummary: Equatable, Codable, Sendable {
    var remaining: Int
    var cheapestPrice: Int
    var ladder: [Int]
}

enum HandCardKind: Equatable, Codable, Sendable {
    case location(String)
    case industry(IndustryKind)
    case wildLocation
    case wildIndustry
}

struct HandCard: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let kind: HandCardKind
    let allowedActions: Set<GameAction>
}

struct MapLocation: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let x: Double
    let y: Double
}

struct MapRoute: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let fromLocationID: String
    let toLocationID: String
}

struct LobbyState: Equatable, Codable, Sendable {
    let mode: ConnectionMode
    var roomCode: String
    var players: [PlayerSummary]
}

struct DemoMatchState: Equatable, Codable, Sendable {
    var era: String
    var round: Int
    var roundCount: Int
    var actionNumber: Int
    var deckRemaining: Int
    var money: Int
    var income: Int
    var victoryPoints: Int
    var players: [PlayerSummary]
    var industries: [IndustrySummary]
    var coalMarket: MarketSummary
    var ironMarket: MarketSummary
    var hand: [HandCard]
    var locations: [MapLocation]
    var routes: [MapRoute]
}
```

Create `IndustrialCityBirmingham/Models/ActionModels.swift`:

```swift
import Foundation

enum GameAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case build, network, develop, sell, loan, scout, pass
    var id: String { rawValue }
}

struct SellOption: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let industryID: String
    let merchantName: String
    let beerSource: String
}

struct ActionFixture: Equatable, Codable, Sendable {
    let availableActions: [GameAction]
    let buildLocationIDs: [String]
    let networkRouteIDs: [String]
    let developIndustryIDs: [String]
    let sellOptions: [SellOption]
    let scoutCardIDs: [String]

    static let standard = ActionFixture(
        availableActions: GameAction.allCases,
        buildLocationIDs: ["birmingham", "coventry"],
        networkRouteIDs: ["birmingham-coventry", "birmingham-walsall", "walsall-cannock"],
        developIndustryIDs: ["industry-coal", "industry-iron"],
        sellOptions: [
            SellOption(
                id: "sell-cotton-oxford",
                industryID: "industry-cotton",
                merchantName: "Oxford",
                beerSource: "Your brewery"
            )
        ],
        scoutCardIDs: ["card-walsall", "card-iron"]
    )
}
```

- [ ] **Step 4: Implement fixtures, protocol, transport, and session store**

Create `IndustrialCityBirmingham/Fixtures/DemoFixture.swift`:

```swift
enum DemoFixture {
    static func players(count: Int) -> [PlayerSummary] {
        precondition((2...4).contains(count))
        return Array(allPlayers.prefix(count))
    }

    static func match(playerCount: Int) -> DemoMatchState {
        DemoMatchState(
            era: "运河时代",
            round: 1,
            roundCount: playerCount == 4 ? 8 : playerCount == 3 ? 9 : 10,
            actionNumber: 1,
            deckRemaining: 26,
            money: 17,
            income: 0,
            victoryPoints: 0,
            players: players(count: playerCount),
            industries: industries,
            coalMarket: MarketSummary(remaining: 7, cheapestPrice: 2, ladder: [1, 2, 3, 4, 5, 6, 7, 8]),
            ironMarket: MarketSummary(remaining: 5, cheapestPrice: 3, ladder: [1, 2, 3, 4, 5, 6]),
            hand: hand,
            locations: locations,
            routes: routes
        )
    }

    private static let allPlayers = [
        PlayerSummary(id: "player-amber", name: "Owen", color: .amber, order: 1, spent: 0, isCurrent: true, isHost: true, isReady: true, isConnected: true),
        PlayerSummary(id: "player-crimson", name: "Bessemer", color: .crimson, order: 2, spent: 5, isCurrent: false, isHost: false, isReady: true, isConnected: true),
        PlayerSummary(id: "player-teal", name: "Coade", color: .teal, order: 3, spent: 8, isCurrent: false, isHost: false, isReady: true, isConnected: true),
        PlayerSummary(id: "player-violet", name: "Cadbury-Langname", color: .violet, order: 4, spent: 12, isCurrent: false, isHost: false, isReady: true, isConnected: true)
    ]

    private static let industries = [
        IndustrySummary(id: "industry-cotton", kind: .cotton, level: 1, cost: 12, coalCost: 0, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-manufacturer", kind: .manufacturer, level: 1, cost: 8, coalCost: 1, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-pottery", kind: .pottery, level: 1, cost: 17, coalCost: 1, ironCost: 0, isAvailable: false),
        IndustrySummary(id: "industry-coal", kind: .coal, level: 1, cost: 5, coalCost: 0, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-iron", kind: .iron, level: 1, cost: 5, coalCost: 1, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-brewery", kind: .brewery, level: 1, cost: 5, coalCost: 0, ironCost: 1, isAvailable: true)
    ]

    private static let hand: [HandCard] = [
        HandCard(id: "card-birmingham", title: "Birmingham", kind: .location("Birmingham"), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-coventry", title: "Coventry", kind: .location("Coventry"), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-walsall", title: "Walsall", kind: .location("Walsall"), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-iron", title: "Iron Works", kind: .industry(.iron), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-coal", title: "Coal Mine", kind: .industry(.coal), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-brewery", title: "Brewery", kind: .industry(.brewery), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-wild-location", title: "Wild Location", kind: .wildLocation, allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-wild-industry", title: "Wild Industry", kind: .wildIndustry, allowedActions: Set(GameAction.allCases))
    ]

    private static let locations = [
        MapLocation(id: "birmingham", name: "Birmingham", x: 0.50, y: 0.54),
        MapLocation(id: "coventry", name: "Coventry", x: 0.70, y: 0.60),
        MapLocation(id: "walsall", name: "Walsall", x: 0.45, y: 0.34),
        MapLocation(id: "cannock", name: "Cannock", x: 0.35, y: 0.20),
        MapLocation(id: "worcester", name: "Worcester", x: 0.35, y: 0.78),
        MapLocation(id: "oxford", name: "Oxford", x: 0.80, y: 0.82),
        MapLocation(id: "gloucester", name: "Gloucester", x: 0.56, y: 0.90),
        MapLocation(id: "burton", name: "Burton", x: 0.70, y: 0.22)
    ]

    private static let routes = [
        MapRoute(id: "birmingham-coventry", fromLocationID: "birmingham", toLocationID: "coventry"),
        MapRoute(id: "birmingham-walsall", fromLocationID: "birmingham", toLocationID: "walsall"),
        MapRoute(id: "walsall-cannock", fromLocationID: "walsall", toLocationID: "cannock"),
        MapRoute(id: "birmingham-worcester", fromLocationID: "birmingham", toLocationID: "worcester"),
        MapRoute(id: "coventry-oxford", fromLocationID: "coventry", toLocationID: "oxford"),
        MapRoute(id: "worcester-gloucester", fromLocationID: "worcester", toLocationID: "gloucester"),
        MapRoute(id: "walsall-burton", fromLocationID: "walsall", toLocationID: "burton")
    ]
}
```

Create the transport protocol and fake adapter:

```swift
protocol DemoTransport: Sendable {
    func loadLobby(mode: ConnectionMode, playerCount: Int) async throws -> LobbyState
    func loadMatch(playerCount: Int) async throws -> DemoMatchState
}

actor FakeTransport: DemoTransport {
    func loadLobby(mode: ConnectionMode, playerCount: Int) async throws -> LobbyState {
        LobbyState(
            mode: mode,
            roomCode: mode == .online ? "BRASS7" : "NEARBY",
            players: DemoFixture.players(count: playerCount)
        )
    }

    func loadMatch(playerCount: Int) async throws -> DemoMatchState {
        DemoFixture.match(playerCount: playerCount)
    }
}
```

Create `IndustrialCityBirmingham/Session/DemoSessionStore.swift`:

```swift
import Observation

@MainActor
@Observable
final class DemoSessionStore {
    private let transport: any DemoTransport

    var selectedMode: ConnectionMode?
    var lobby: LobbyState?
    var match: DemoMatchState?
    var playerCount = 4
    var errorMessage: String?

    init(transport: any DemoTransport = FakeTransport()) {
        self.transport = transport
    }

    func loadLobby(mode: ConnectionMode) async {
        do {
            selectedMode = mode
            lobby = try await transport.loadLobby(mode: mode, playerCount: playerCount)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMatch() async {
        do {
            match = try await transport.loadMatch(playerCount: playerCount)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: Verify, then commit**

Run the shared unit-test command.

```bash
git add IndustrialCityBirmingham/Models IndustrialCityBirmingham/Fixtures IndustrialCityBirmingham/Session IndustrialCityBirminghamTests/DemoFixtureTests.swift IndustrialCityBirminghamTests/FakeTransportTests.swift
git commit -m "feat: add deterministic UI fixtures"
```

Expected: fixture and transport tests pass for 2, 3, and 4 players.

## Task 4: Build the compiling navigation vertical slice

**Files:**
- Create: `IndustrialCityBirmingham/App/AppDelegate.swift`
- Create: `IndustrialCityBirmingham/App/AppRoute.swift`
- Create: `IndustrialCityBirmingham/App/OrientationCoordinator.swift`
- Modify: `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift`
- Modify: `IndustrialCityBirmingham/App/RootView.swift`
- Create: `IndustrialCityBirmingham/Features/Home/HomeView.swift`
- Create: `IndustrialCityBirmingham/Features/Rules/RulesSummaryView.swift`
- Create: `IndustrialCityBirmingham/Features/Settings/SettingsView.swift`
- Create: `IndustrialCityBirmingham/Features/Gallery/UIGalleryView.swift`
- Create: `IndustrialCityBirmingham/Features/Online/OnlineRoomView.swift`
- Create: `IndustrialCityBirmingham/Features/Nearby/NearbyRoomView.swift`
- Create: `IndustrialCityBirmingham/Features/Lobby/LobbyView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/MatchView.swift`
- Create: `IndustrialCityBirminghamTests/NavigationTests.swift`

- [ ] **Step 1: Write failing route and orientation tests**

Create `IndustrialCityBirminghamTests/NavigationTests.swift`:

```swift
import Testing
import UIKit
@testable import IndustrialCityBirmingham

struct NavigationTests {
    @Test func matchRouteRequiresLandscape() {
        #expect(AppRoute.match(playerCount: 4).orientationMask == .landscape)
    }

    @Test func nonMatchRoutesAllowAllButUpsideDown() {
        #expect(AppRoute.home.orientationMask == .allButUpsideDown)
        #expect(AppRoute.settings.orientationMask == .allButUpsideDown)
    }
}
```

- [ ] **Step 2: Run tests and verify the compile failure**

Run the shared unit-test command.

Expected: compile failure because `AppRoute` does not exist.

- [ ] **Step 3: Implement routes and orientation coordinator**

Create `IndustrialCityBirmingham/App/AppRoute.swift`:

```swift
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
```

Create `IndustrialCityBirmingham/App/OrientationCoordinator.swift`:

```swift
import UIKit

@MainActor
enum OrientationCoordinator {
    static var supportedMask: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ mask: UIInterfaceOrientationMask) {
        supportedMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
```

Create `IndustrialCityBirmingham/App/AppDelegate.swift`:

```swift
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated {
            OrientationCoordinator.supportedMask
        }
    }
}
```

- [ ] **Step 4: Implement the navigation shell and four screens**

Update the app entry to own `DemoSessionStore` and `MotionPreferences` with `@State`, then inject both using `.environment`. RootView must own `[AppRoute]` and switch destinations by `AppRoute`.

Set `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift` to:

```swift
import SwiftUI

@main
struct IndustrialCityBirminghamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = DemoSessionStore()
    @State private var preferences = MotionPreferences()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(preferences)
        }
    }
}
```

Set `IndustrialCityBirmingham/App/RootView.swift` to:

```swift
import SwiftUI

struct RootView: View {
    @State private var path: [AppRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(onNavigate: { path.append($0) })
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .home:
                        HomeView(onNavigate: { path.append($0) })
                    case .online:
                        OnlineRoomView(onNavigate: { path.append($0) })
                    case .nearby:
                        NearbyRoomView(onNavigate: { path.append($0) })
                    case .lobby(let mode):
                        LobbyView(mode: mode, onNavigate: { path.append($0) })
                    case .rules:
                        RulesSummaryView()
                    case .settings:
                        SettingsView()
                    case .gallery:
                        UIGalleryView()
                    case .match(let count):
                        MatchView(playerCount: count)
                    }
                }
        }
        .onChange(of: path) {
            OrientationCoordinator.apply(path.last?.orientationMask ?? .allButUpsideDown)
        }
    }
}
```

Create `IndustrialCityBirmingham/Features/Home/HomeView.swift`:

```swift
import SwiftUI

struct HomeView: View {
    let onNavigate: (AppRoute) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [BrassColor.coal.color, BrassColor.fog.color.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: BrassSpacing.xLarge) {
                Text("工业城市伯明翰")
                    .font(BrassTypography.display)
                    .foregroundStyle(BrassColor.paper.color)
                    .accessibilityIdentifier("home.title")

                HStack(spacing: BrassSpacing.large) {
                    Button("在线房间") { onNavigate(.online) }
                        .accessibilityIdentifier("home.online")
                    Button("附近离线房间") { onNavigate(.nearby) }
                        .accessibilityIdentifier("home.nearby")
                }
                .buttonStyle(BrassPrimaryButtonStyle())

                HStack(spacing: BrassSpacing.large) {
                    Button("规则") { onNavigate(.rules) }
                    Button("设置") { onNavigate(.settings) }
                    Button("UI 展示") { onNavigate(.gallery) }
                }
                .foregroundStyle(BrassColor.paper.color)
            }
            .brassPanel()
            .padding(BrassSpacing.xLarge)
        }
    }
}
```

Create `RulesSummaryView`, `SettingsView`, and `UIGalleryView` with these complete first-slice bodies:

```swift
import SwiftUI

struct RulesSummaryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrassSpacing.large) {
                Text("开发规则摘要").font(BrassTypography.title)
                Text("规则裁决以项目 RULES.md 所列 Roxley 英文规则为准。")
                Text("游戏包含运河时代和铁路时代。每个行动使用一张牌。")
                Text("六种行动：建造、铺网、发展、出售、贷款、侦察；也可以跳过。")
                Text("煤要求连通且优先最近来源；铁不要求连通；啤酒来源规则独立。")
            }
            .font(BrassTypography.body)
            .foregroundStyle(BrassColor.paper.color)
            .brassPanel()
            .padding()
        }
        .background(BrassColor.coal.color)
    }
}
```

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(MotionPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Toggle("音效", isOn: $preferences.isSoundEnabled)
            Toggle("触觉", isOn: $preferences.isHapticsEnabled)
            Toggle("减少动态效果", isOn: $preferences.reduceMotion)
            Toggle("色觉辅助符号", isOn: $preferences.colorAssistEnabled)
        }
        .navigationTitle("设置")
    }
}
```

```swift
import SwiftUI

struct UIGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrassSpacing.large) {
                Text("UI 设计系统").font(BrassTypography.display)
                HStack {
                    swatch("Coal", BrassColor.coal)
                    swatch("Iron", BrassColor.iron)
                    swatch("Brass", BrassColor.brass)
                    swatch("Fog", BrassColor.fog)
                    swatch("Paper", BrassColor.paper)
                    swatch("Danger", BrassColor.danger)
                }
                Button("主要按钮") {}
                    .buttonStyle(BrassPrimaryButtonStyle())
                Text("面板示例").font(BrassTypography.body).brassPanel()
            }
            .foregroundStyle(BrassColor.paper.color)
            .padding()
        }
        .background(BrassColor.coal.color)
    }

    private func swatch(_ name: String, _ value: BrassColor) -> some View {
        VStack {
            RoundedRectangle(cornerRadius: BrassRadius.card)
                .fill(value.color)
                .frame(width: 56, height: 56)
            Text(name).font(BrassTypography.label)
        }
    }
}
```

The home screen contract is:

- title identifier `home.title`;
- primary buttons `home.online` and `home.nearby`;
- secondary buttons `home.rules`, `home.settings`, and `home.gallery`;
- an industrial gradient background and BrassPanel cards;
- navigation callbacks only, with no network behavior.

RulesSummaryView must show the source precedence, two eras, six actions, coal/iron/beer distinctions, and a visible label that this is a development summary. SettingsView must bind sound, haptics, reduce motion, and color assist toggles. UIGalleryView must show palette swatches, typography samples, buttons, panels, player symbols, and resource chips.

Create compiling first slices for the four routes that are enriched later:

```swift
import SwiftUI

struct OnlineRoomView: View {
    let onNavigate: (AppRoute) -> Void

    var body: some View {
        VStack(spacing: BrassSpacing.large) {
            Text("在线房间").font(BrassTypography.title)
            Button("进入演示大厅") { onNavigate(.lobby(.online)) }
                .buttonStyle(BrassPrimaryButtonStyle())
        }
        .brassPanel()
    }
}
```

```swift
import SwiftUI

struct NearbyRoomView: View {
    let onNavigate: (AppRoute) -> Void

    var body: some View {
        VStack(spacing: BrassSpacing.large) {
            Text("附近离线房间").font(BrassTypography.title)
            Button("进入演示大厅") { onNavigate(.lobby(.nearby)) }
                .buttonStyle(BrassPrimaryButtonStyle())
        }
        .brassPanel()
    }
}
```

```swift
import SwiftUI

struct LobbyView: View {
    let mode: ConnectionMode
    let onNavigate: (AppRoute) -> Void

    var body: some View {
        VStack(spacing: BrassSpacing.large) {
            Text(mode == .online ? "在线大厅" : "附近大厅")
                .font(BrassTypography.title)
            Button("开始 UI 演示") { onNavigate(.match(playerCount: 4)) }
                .buttonStyle(BrassPrimaryButtonStyle())
        }
        .brassPanel()
    }
}
```

```swift
import SwiftUI

struct MatchView: View {
    let playerCount: Int

    var body: some View {
        ZStack {
            BrassColor.coal.color.ignoresSafeArea()
            Text("\(playerCount) 人对局 UI")
                .font(BrassTypography.title)
                .foregroundStyle(BrassColor.paper.color)
        }
    }
}
```

- [ ] **Step 5: Verify, then commit**

Run unit tests, build, and the launch UI test.

```bash
git add IndustrialCityBirmingham/App IndustrialCityBirmingham/Features/Home IndustrialCityBirmingham/Features/Rules IndustrialCityBirmingham/Features/Settings IndustrialCityBirmingham/Features/Gallery IndustrialCityBirminghamTests/NavigationTests.swift
git commit -m "feat: add app navigation and utility screens"
```

Expected: home launches, every utility route returns successfully, and orientation tests pass.

## Task 5: Enrich online, nearby, and common lobby screens

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Online/OnlineRoomView.swift`
- Modify: `IndustrialCityBirmingham/Features/Nearby/NearbyRoomView.swift`
- Modify: `IndustrialCityBirmingham/Features/Lobby/LobbyView.swift`
- Modify: `IndustrialCityBirminghamUITests/AppSmokeUITests.swift`

- [ ] **Step 1: Add failing UI tests for both room paths**

Add tests that:

1. tap `home.online`;
2. assert `online.create`, `online.join.code`, and `online.state` exist;
3. return home;
4. tap `home.nearby`;
5. assert `nearby.create`, `nearby.search`, and `nearby.preflight` exist;
6. enter each lobby;
7. assert exactly four `lobby.player` rows and `lobby.start`.

Use `matching(identifier: "lobby.player").count` for the row count.

- [ ] **Step 2: Run the UI tests and verify they fail**

Run the shared UI-test command.

Expected: FAIL because the online, nearby, and lobby controls do not exist.

- [ ] **Step 3: Implement OnlineRoomView and NearbyRoomView**

Both screens use BrassPanel and expose deterministic segmented demo states.

Online states: idle, connecting, roomNotFound, offline, versionMismatch.

Nearby states: searching, found, empty, wirelessOff, permissionDenied.

Each state must render:

- a unique SF Symbol;
- a title and concrete recovery text;
- the accessibility identifier `online.state` or `nearby.preflight`;
- a primary action with a minimum 44 pt hit target.

The primary successful action loads the FakeTransport lobby and navigates to `.lobby(mode)`.

- [ ] **Step 4: Implement LobbyView**

Render:

- mode badge and room code;
- 2–4 player rows from `DemoSessionStore.lobby`;
- player color plus unique shape symbol;
- host, ready, and connection state;
- rule version `v2018.11`;
- a disabled Start button until all fixture players are ready;
- player-count segmented control that reloads the lobby;
- `lobby.player` on every row and `lobby.start` on the start button.

Start calls `store.loadMatch()`, then navigates to `.match(playerCount: store.playerCount)`.

- [ ] **Step 5: Verify, then commit**

Run unit and UI tests on IndustrialCity-iPhone and build for IndustrialCity-iPad.

```bash
git add IndustrialCityBirmingham/Features/Online IndustrialCityBirmingham/Features/Nearby IndustrialCityBirmingham/Features/Lobby IndustrialCityBirminghamUITests/AppSmokeUITests.swift
git commit -m "feat: add room and lobby flows"
```

Expected: both connection paths reach a 2–4 player lobby using only fake data.

## Task 6: Generate original map art and build the SpriteKit map

**Files:**
- Create: `IndustrialCityBirmingham/Assets.xcassets/IndustrialMap.imageset/industrial-map.png`
- Create: `IndustrialCityBirmingham/Assets.xcassets/IndustrialMap.imageset/Contents.json`
- Create: `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift`
- Create: `IndustrialCityBirmingham/Features/Map/GameMapScene.swift`
- Create: `IndustrialCityBirmingham/Features/Map/GameMapView.swift`
- Create: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

- [ ] **Step 1: Write failing map geometry tests**

Create tests for:

- every fixture location creates a node named `location:<id>`;
- every route creates a node named `route:<id>`;
- `targetID(fromNodeName:)` returns the ID after either prefix;
- highlighted targets have a nonzero glow and non-highlighted targets do not.

The pure parser contract is:

```swift
static func targetID(fromNodeName name: String?) -> String? {
    guard let name else { return nil }
    let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, ["location", "route"].contains(parts[0]) else { return nil }
    return parts[1]
}
```

- [ ] **Step 2: Run tests and verify the compile failure**

Run the shared unit-test command.

Expected: compile failure because `GameMapScene` does not exist.

- [ ] **Step 3: Generate the original raster background**

Use the `imagegen` skill with this exact prompt:

> Original top-down cinematic map background for a fictional 19th-century English industrial region. Dark desaturated slate terrain, misty valleys, subtle rivers, warm distant furnace glows, restrained brass-and-charcoal palette, painterly realistic texture, no text, no labels, no icons, no borders, no game pieces, no logos, no recognizable board-game composition, no copyrighted characters. Keep the center and route corridors readable under UI overlays. Landscape 4:3, 2732×2048.

Save the chosen output as `industrial-map.png`. Add `Contents.json`:

```json
{
  "images": [
    {
      "filename": "industrial-map.png",
      "idiom": "universal",
      "scale": "1x"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

- [ ] **Step 4: Implement map nodes, camera, gestures, and accessibility mirror**

GameMapScene uses a 2732 × 2048 coordinate system, a camera node, an SKSpriteNode with texture `IndustrialMap`, code-drawn route lines, and code-drawn location markers. Expose:

```swift
final class GameMapScene: SKScene {
    var onTargetTap: ((String) -> Void)?

    func configure(state: DemoMatchState, highlightedIDs: Set<String>)
    func updateCamera(scale: CGFloat, translation: CGPoint)
    static func targetID(fromNodeName name: String?) -> String?
}
```

GameMapView wraps SpriteView, uses DragGesture plus MagnifyGesture, clamps scale to 0.75...2.8, and passes location/route taps through `onTargetTap`. Add a hidden SwiftUI accessibility list over the map with buttons named `map.target.<id>` so VoiceOver users can activate every currently legal target without relying on SpriteKit nodes.

- [ ] **Step 5: Verify, then commit**

Run map unit tests, the app build, and manually drag/zoom on both simulators.

```bash
git add IndustrialCityBirmingham/Assets.xcassets/IndustrialMap.imageset IndustrialCityBirmingham/Features/Map IndustrialCityBirminghamTests/GameMapSceneTests.swift
git commit -m "feat: add original interactive industrial map"
```

Expected: all nodes are hittable, scale is clamped, and no official board art appears in the asset.

## Task 7: Build the adaptive iPhone/iPad match shell

**Files:**
- Create: `IndustrialCityBirmingham/Features/Match/MatchLayoutMetrics.swift`
- Create: `IndustrialCityBirmingham/Features/Match/MatchHeaderView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/PlayerRailView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/IndustryRailView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchView.swift`
- Create: `IndustrialCityBirminghamTests/MatchLayoutMetricsTests.swift`

- [ ] **Step 1: Write failing six-viewport layout tests**

Create `MatchLayoutMetricsTests` with the approved widths:

```swift
import Testing
import CoreGraphics
@testable import IndustrialCityBirmingham

struct MatchLayoutMetricsTests {
    @Test(arguments: [667.0, 852.0, 932.0])
    func phoneUsesMiniRails(_ width: Double) {
        let metrics = MatchLayoutMetrics(viewport: CGSize(width: width, height: 393))
        #expect(metrics.formFactor == .phone)
        #expect(metrics.leftRailWidth == 44)
        #expect(metrics.rightRailWidth == 44)
        #expect(metrics.marketPlacement == .bottomLeftCompact)
    }

    @Test(arguments: [1024.0, 1194.0, 1366.0])
    func tabletUsesFullRails(_ width: Double) {
        let metrics = MatchLayoutMetrics(viewport: CGSize(width: width, height: 834))
        #expect(metrics.formFactor == .tablet)
        #expect(metrics.leftRailWidth == 220)
        #expect(metrics.rightRailWidth == 210)
        #expect(metrics.marketPlacement == .underPlayerRail)
    }
}
```

- [ ] **Step 2: Run tests and verify the compile failure**

Run the shared unit-test command.

Expected: compile failure because `MatchLayoutMetrics` does not exist.

- [ ] **Step 3: Implement deterministic layout metrics**

```swift
import CoreGraphics

enum MatchFormFactor: Equatable {
    case phone
    case tablet
}

enum MarketPlacement: Equatable {
    case bottomLeftCompact
    case underPlayerRail
}

struct MatchLayoutMetrics: Equatable {
    let formFactor: MatchFormFactor
    let leftRailWidth: CGFloat
    let rightRailWidth: CGFloat
    let handHeight: CGFloat
    let marketPlacement: MarketPlacement

    init(viewport: CGSize) {
        if viewport.width >= 1_000 {
            formFactor = .tablet
            leftRailWidth = 220
            rightRailWidth = 210
            handHeight = 132
            marketPlacement = .underPlayerRail
        } else {
            formFactor = .phone
            leftRailWidth = 44
            rightRailWidth = 44
            handHeight = 92
            marketPlacement = .bottomLeftCompact
        }
    }
}
```

- [ ] **Step 4: Implement header, rails, and MatchView composition**

MatchHeaderView shows era, round, action, deck, money, income, and VP with monospaced digits. PlayerRailView has:

- tablet: four full rows and the resource market below;
- phone: a persistent 44 pt rail with order, current-player glow, and spend;
- color plus shape for each player.

IndustryRailView has:

- tablet: six full industry rows;
- phone: persistent 44 pt icon rail with level and availability.

MatchView uses GeometryReader and the exact metrics. Its ZStack order is map, left rail, right rail, bottom hand, resource market, action button, transient overlay, confirmation panel. Add accessibility identifiers `match.header`, `match.playerRail`, `match.industryRail`, `match.hand`, and `match.actionButton`.

- [ ] **Step 5: Verify all viewports, then commit**

Run layout unit tests. Use Xcode previews at all six approved point sizes and build on both named simulators.

```bash
git add IndustrialCityBirmingham/Features/Match IndustrialCityBirminghamTests/MatchLayoutMetricsTests.swift
git commit -m "feat: add adaptive match shell"
```

Expected: the six viewport previews contain no overlap and the map remains the largest region.

## Task 8: Implement card selection and mutually exclusive overlays

**Files:**
- Create: `IndustrialCityBirmingham/Features/Match/HandView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/ActionGridView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/ResourceMarketView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/MatchInteractionReducer.swift`
- Create: `IndustrialCityBirminghamTests/MatchInteractionReducerTests.swift`
- Create: `IndustrialCityBirminghamUITests/MatchInteractionUITests.swift`

- [ ] **Step 1: Write failing reducer tests**

Cover these exact transitions:

- selecting a card stores its ID;
- selecting a second card replaces the first and clears the draft;
- opening player drawer then market leaves only market open;
- selecting an action closes any transient overlay;
- canceling an action keeps the selected card;
- phone drawer width is `min(viewportWidth * 0.42, 360)`.

Define the overlay enum in the test contract:

```swift
enum MatchOverlay: Equatable {
    case playerRail
    case industryRail
    case resourceMarket
    case actionGrid
}
```

- [ ] **Step 2: Run tests and verify the compile failure**

Run the shared unit-test command.

Expected: compile failure because `MatchInteractionReducer` does not exist.

- [ ] **Step 3: Implement the interaction reducer**

```swift
enum MatchOverlay: Equatable {
    case playerRail
    case industryRail
    case resourceMarket
    case actionGrid
}

enum NetworkCount: Int, Equatable {
    case one = 1
    case two = 2
}

struct BuildDraft: Equatable { var locationID: String? }
struct NetworkDraft: Equatable {
    var count: NetworkCount = .one
    var routeIDs: [String] = []
}
struct DevelopDraft: Equatable { var industryIDs: [String] = [] }
struct SellDraft: Equatable { var optionIDs: [String] = [] }
struct ScoutDraft: Equatable { var extraCardIDs: [String] = [] }

enum ActionFlowState: Equatable {
    case idle
    case build(BuildDraft)
    case network(NetworkDraft)
    case develop(DevelopDraft)
    case sell(SellDraft)
    case loan
    case scout(ScoutDraft)
    case pass

    static func start(_ action: GameAction) -> ActionFlowState {
        switch action {
        case .build: .build(BuildDraft())
        case .network: .network(NetworkDraft())
        case .develop: .develop(DevelopDraft())
        case .sell: .sell(SellDraft())
        case .loan: .loan
        case .scout: .scout(ScoutDraft())
        case .pass: .pass
        }
    }
}
```

```swift
import Observation

@MainActor
@Observable
final class MatchInteractionReducer {
    private(set) var selectedCardID: String?
    private(set) var selectedAction: GameAction?
    private(set) var overlay: MatchOverlay?
    private(set) var flow: ActionFlowState = .idle

    func selectCard(_ id: String) {
        if selectedCardID != id {
            selectedCardID = id
            selectedAction = nil
            flow = .idle
        }
        overlay = nil
    }

    func toggleOverlay(_ candidate: MatchOverlay) {
        overlay = overlay == candidate ? nil : candidate
    }

    func selectAction(_ action: GameAction) {
        selectedAction = action
        overlay = nil
        flow = ActionFlowState.start(action)
    }

    func cancelFlow() {
        selectedAction = nil
        flow = .idle
    }
}
```

- [ ] **Step 4: Implement hand, action grid, drawers, and market**

HandView renders eight overlapping cards on phone and eight fully readable cards on iPad. Selection raises a card by 18 pt, scales it to 1.06, and dims others. Every card has a 44 pt hit target and identifier `hand.card.<id>`.

ActionGridView is a 2 × 4 grid above the lower-right button with seven actions and one close cell. Disable actions not present in the selected card’s `allowedActions`. Use identifiers `action.<rawValue>`.

ResourceMarketView:

- phone compact row permanently shows coal/iron remaining and cheapest price;
- expanded price ladder overlays only the map;
- tablet full ladder sits under the player rail;
- identifiers `market.coal`, `market.iron`, and `market.expand`.

Player and industry drawers use the reducer overlay. Only one transient layer can exist because the reducer stores a single optional enum.

- [ ] **Step 5: Verify, then commit**

Run unit and UI tests. The UI test must select two cards, open each overlay, and assert the previous overlay disappears.

```bash
git add IndustrialCityBirmingham/Features/Match IndustrialCityBirminghamTests/MatchInteractionReducerTests.swift IndustrialCityBirminghamUITests/MatchInteractionUITests.swift
git commit -m "feat: add card and overlay interactions"
```

Expected: card-first interaction and overlay exclusivity pass in automated tests.

## Task 9: Add shared confirmation rules and the confirmation panel

**Files:**
- Create: `IndustrialCityBirmingham/Features/Match/ActionFlowView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/ConfirmationPanel.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchInteractionReducer.swift`
- Create: `IndustrialCityBirminghamTests/ActionFlowTests.swift`

- [ ] **Step 1: Write failing confirmation-property tests**

The test must assert `ActionFlowState.start` returns:

- build with no location;
- network with one-track mode and no routes;
- develop with no industries;
- sell with no sale items;
- loan;
- scout with no extra cards;
- pass.

Also assert:

- idle, empty build/network/develop/sell/scout are not confirmable;
- loan and pass are immediately confirmable;
- only build, network, and sell may request map targets;
- selecting a new card resets every draft.

- [ ] **Step 2: Run tests and verify the compile failure**

Run the shared unit-test command.

Expected: compile failure because `isConfirmable` and `usesMapTargets` do not exist.

- [ ] **Step 3: Implement the complete confirmation properties**

```swift
extension ActionFlowState {
    var isConfirmable: Bool {
        switch self {
        case .idle:
            false
        case .build(let draft):
            draft.locationID != nil
        case .network(let draft):
            draft.routeIDs.count == draft.count.rawValue
        case .develop(let draft):
            (1...2).contains(draft.industryIDs.count)
        case .sell(let draft):
            draft.optionIDs.isEmpty == false
        case .loan, .pass:
            true
        case .scout(let draft):
            draft.extraCardIDs.count == 2
        }
    }

    var usesMapTargets: Bool {
        switch self {
        case .build, .network, .sell:
            true
        case .idle, .develop, .loan, .scout, .pass:
            false
        }
    }
}
```

- [ ] **Step 4: Implement shared flow and confirmation UI**

ActionFlowView switches exhaustively over ActionFlowState. ConfirmationPanel always shows:

- discarded card;
- money delta;
- coal, iron, and beer delta;
- income before/after when present;
- primary Confirm and secondary Cancel;
- accessibility identifier `action.confirmation`.

Confirm remains disabled until the specific flow’s fixture requirements are met. Cancel calls `cancelFlow()` and returns to the selected card.

- [ ] **Step 5: Verify, then commit**

Run unit tests and build.

```bash
git add IndustrialCityBirmingham/Features/Match IndustrialCityBirminghamTests/ActionFlowTests.swift
git commit -m "feat: add fixture action state machine"
```

Expected: all seven initial states and cancellation behavior pass.

## Task 10: Implement build and canal/rail network fixture flows

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Match/MatchInteractionReducer.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ActionFlowView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ConfirmationPanel.swift`
- Modify: `IndustrialCityBirminghamUITests/MatchInteractionUITests.swift`
- Modify: `IndustrialCityBirminghamTests/ActionFlowTests.swift`

- [ ] **Step 1: Write failing build and network transition tests**

Assert:

- build accepts only IDs in `ActionFixture.buildLocationIDs`;
- build becomes confirmable after one legal location;
- one-route network accepts exactly one route;
- two-route network rejects a second route until the first is selected;
- two-route network preserves selection order;
- changing network count clears selected routes.

- [ ] **Step 2: Run tests and verify behavior failures**

Run only `ActionFlowTests`.

Expected: tests compile but fail because the reducer has no target-selection methods.

- [ ] **Step 3: Implement build and network reducer methods**

Add:

```swift
func selectBuildLocation(_ id: String, fixture: ActionFixture) {
    guard fixture.buildLocationIDs.contains(id) else { return }
    flow = .build(BuildDraft(locationID: id))
}

func setNetworkCount(_ count: NetworkCount) {
    flow = .network(NetworkDraft(count: count, routeIDs: []))
}

func appendNetworkRoute(_ id: String, fixture: ActionFixture) {
    guard fixture.networkRouteIDs.contains(id) else { return }
    guard case .network(var draft) = flow else { return }
    guard draft.routeIDs.contains(id) == false else { return }
    guard draft.routeIDs.count < draft.count.rawValue else { return }
    draft.routeIDs.append(id)
    flow = .network(draft)
}
```

- [ ] **Step 4: Implement map highlights and confirmation content**

Build highlights fixture location IDs and shows industry cost, coal/iron sources, and discard. Network:

- canal fixture fixes count to one;
- rail fixture exposes a one/two segmented control;
- after the first two-rail route is selected, highlight only fixture routes connected to its endpoint;
- confirmation lists routes in selection order and shows £5 + 1 coal for one rail or £15 + 2 coal + 1 beer for two rails.

The UI test must complete one build and one two-rail preview, cancel each before final submission, and verify the selected card remains.

- [ ] **Step 5: Verify, then commit**

Run `ActionFlowTests` and `MatchInteractionUITests`.

```bash
git add IndustrialCityBirmingham/Features/Match IndustrialCityBirminghamTests/ActionFlowTests.swift IndustrialCityBirminghamUITests/MatchInteractionUITests.swift
git commit -m "feat: add build and network UI flows"
```

Expected: ordered route selection and build target validation pass.

## Task 11: Implement develop and multi-sale fixture flows

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Match/MatchInteractionReducer.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ActionFlowView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ConfirmationPanel.swift`
- Modify: `IndustrialCityBirminghamTests/ActionFlowTests.swift`
- Modify: `IndustrialCityBirminghamUITests/MatchInteractionUITests.swift`

- [ ] **Step 1: Write failing develop and sell tests**

Assert:

- develop accepts only fixture IDs;
- tapping the same industry removes it;
- a third industry is ignored;
- each selected industry adds one iron to confirmation;
- sell accepts only fixture option IDs;
- sell keeps insertion order;
- tapping an added sale removes it;
- sell is confirmable with at least one item.

- [ ] **Step 2: Run tests and verify failures**

Run only `ActionFlowTests`.

Expected: FAIL because develop and sale mutation methods do not exist.

- [ ] **Step 3: Implement reducer methods**

```swift
func toggleDevelopIndustry(_ id: String, fixture: ActionFixture) {
    guard fixture.developIndustryIDs.contains(id) else { return }
    guard case .develop(var draft) = flow else { return }
    if let index = draft.industryIDs.firstIndex(of: id) {
        draft.industryIDs.remove(at: index)
    } else if draft.industryIDs.count < 2 {
        draft.industryIDs.append(id)
    }
    flow = .develop(draft)
}

func toggleSaleOption(_ id: String, fixture: ActionFixture) {
    guard fixture.sellOptions.contains(where: { $0.id == id }) else { return }
    guard case .sell(var draft) = flow else { return }
    if let index = draft.optionIDs.firstIndex(of: id) {
        draft.optionIDs.remove(at: index)
    } else {
        draft.optionIDs.append(id)
    }
    flow = .sell(draft)
}
```

- [ ] **Step 4: Implement industry multi-select and sale builder UI**

Develop mode changes the right industry rail to selection mode, shows `1/2` or `2/2`, and displays one iron source per selected tile.

Sell mode:

1. highlights fixture industries;
2. opens a merchant/beer source card for the selected industry;
3. adds the chosen SellOption to an ordered list;
4. allows adding another option or removing an existing option;
5. shows merchant reward and income change in confirmation.

The UI test completes two develop selections and one sale option.

- [ ] **Step 5: Verify, then commit**

Run unit and UI tests.

```bash
git add IndustrialCityBirmingham/Features/Match IndustrialCityBirminghamTests/ActionFlowTests.swift IndustrialCityBirminghamUITests/MatchInteractionUITests.swift
git commit -m "feat: add develop and sell UI flows"
```

Expected: selection limits, ordering, and confirmation values pass.

## Task 12: Implement loan, scout, and pass fixture flows

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Match/MatchInteractionReducer.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ActionFlowView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ConfirmationPanel.swift`
- Modify: `IndustrialCityBirminghamTests/ActionFlowTests.swift`
- Modify: `IndustrialCityBirminghamUITests/MatchInteractionUITests.swift`

- [ ] **Step 1: Write failing non-map action tests**

Assert:

- loan is immediately confirmable and reports +£30 plus three income levels down;
- scout accepts two distinct extra cards from `scoutCardIDs`;
- scout cannot select the action card again;
- scout ignores a third extra card;
- pass is immediately confirmable and reports one discarded card;
- none of these flows produces map highlights.

- [ ] **Step 2: Run tests and verify failures**

Run only `ActionFlowTests`.

Expected: FAIL because scout mutation and confirmation summaries are missing.

- [ ] **Step 3: Implement scout mutation**

```swift
func toggleScoutCard(_ id: String, fixture: ActionFixture) {
    guard id != selectedCardID else { return }
    guard fixture.scoutCardIDs.contains(id) else { return }
    guard case .scout(var draft) = flow else { return }
    if let index = draft.extraCardIDs.firstIndex(of: id) {
        draft.extraCardIDs.remove(at: index)
    } else if draft.extraCardIDs.count < 2 {
        draft.extraCardIDs.append(id)
    }
    flow = .scout(draft)
}
```

- [ ] **Step 4: Implement the three confirmation screens**

Loan shows before/after money and income levels side-by-side with no map targets. Scout turns the hand into two-card multi-select, then previews two visually distinct wildcard cards. Pass states that the selected card is discarded and the action counter advances. Every flow supports Cancel before submission.

The UI test confirms all three flows open `action.confirmation` without map highlights; it cancels loan and pass, and completes the two-card scout selection.

- [ ] **Step 5: Verify, then commit**

Run unit and UI tests.

```bash
git add IndustrialCityBirmingham/Features/Match IndustrialCityBirminghamTests/ActionFlowTests.swift IndustrialCityBirminghamUITests/MatchInteractionUITests.swift
git commit -m "feat: add loan scout and pass UI flows"
```

Expected: all seven fixture action flows now meet their Phase 1 interaction contracts.

## Task 13: Add fake event feedback, haptics, motion reduction, and error recovery

**Files:**
- Create: `IndustrialCityBirmingham/Session/DemoEvent.swift`
- Modify: `IndustrialCityBirmingham/Session/DemoTransport.swift`
- Modify: `IndustrialCityBirmingham/Session/FakeTransport.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchInteractionReducer.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ResourceMarketView.swift`
- Create: `IndustrialCityBirminghamTests/FakeEventTests.swift`

- [ ] **Step 1: Write failing accepted/rejected event tests**

Test that FakeTransport:

- returns an accepted DemoEvent with incremented version for fixture-valid intent;
- returns RejectedIntent with `reason` and `recoverySuggestion` for `invalid-target`;
- never mutates the match before an accepted event;
- produces market, resource movement, industry flip, income, and turn-advance visible effects.

- [ ] **Step 2: Run tests and verify the compile failure**

Run the shared unit-test command.

Expected: compile failure because `DemoEvent` and `RejectedIntent` do not exist.

- [ ] **Step 3: Implement fake event contracts**

```swift
struct DemoIntent: Equatable, Sendable {
    let action: GameAction
    let selectedCardID: String
    let targetIDs: [String]
}

struct DemoEvent: Equatable, Sendable {
    let version: Int
    let title: String
    let effects: [DemoEffect]
}

enum DemoEffect: Equatable, Sendable {
    case moveResource(kind: IndustryKind, from: String, to: String)
    case marketChanged(coal: MarketSummary, iron: MarketSummary)
    case industryFlipped(String)
    case incomeChanged(from: Int, to: Int)
    case actionAdvanced(from: Int, to: Int)
}

struct RejectedIntent: Error, Equatable, Sendable {
    let reason: String
    let recoverySuggestion: String
}
```

Extend DemoTransport with `submit(intent:state:) async throws -> DemoEvent`. MatchInteractionReducer converts its confirmed draft into DemoIntent. FakeTransport must use ActionFixture membership checks only; it must not implement Brass rules.

- [ ] **Step 4: Render event feedback and accessibility alternatives**

On accepted event:

- animate resource chips from source to destination unless reduceMotion is true;
- roll market numbers instead of flashing the whole panel;
- flip the industry card and update income;
- trigger distinct light/medium/success haptics when enabled;
- expose a VoiceOver announcement containing the event title.

On rejection, show a BrassPanel error containing both reason and recovery suggestion, focus it for VoiceOver, and keep the editable action draft.

- [ ] **Step 5: Verify, then commit**

Run all unit/UI tests with normal motion and launch argument `-reduce-motion YES`.

```bash
git add IndustrialCityBirmingham/Session IndustrialCityBirmingham/Features/Match IndustrialCityBirminghamTests/FakeEventTests.swift
git commit -m "feat: add fake action feedback and recovery"
```

Expected: accepted events animate or provide reduced-motion equivalents, and rejection text is actionable.

## Task 14: Close the accessibility and visual-fixture matrix

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Gallery/UIGalleryView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchView.swift`
- Modify: `IndustrialCityBirminghamUITests/AppSmokeUITests.swift`
- Modify: `IndustrialCityBirminghamUITests/MatchInteractionUITests.swift`

- [ ] **Step 1: Add failing UI tests for fixture launch arguments**

Use launch arguments:

- `-fixture players2`;
- `-fixture players3`;
- `-fixture players4`;
- `-fixture wirelessOff`;
- `-fixture versionMismatch`;
- `-fixture rejectedAction`;
- `-fixture disconnected`;
- `-reduce-motion YES`;
- `-color-assist YES`.

Assert each argument produces its named screen/state and that critical controls have non-empty labels and frames at least 44 × 44 pt.

- [ ] **Step 2: Run UI tests and verify failures**

Run the shared UI-test command.

Expected: FAIL because launch-argument routing is not implemented.

- [ ] **Step 3: Implement fixture launch routing**

At app launch, parse ProcessInfo arguments into:

```swift
enum DemoLaunchFixture: String {
    case players2
    case players3
    case players4
    case wirelessOff
    case versionMismatch
    case rejectedAction
    case disconnected
}
```

Apply player count, initial route, error state, reduce motion, and color-assist settings before RootView appears. Do not compile this behavior out of release builds; keep it inert unless the explicit `-fixture` flag is present.

- [ ] **Step 4: Complete UIGallery and manual visual checklist**

Gallery must show every component in normal, pressed, disabled, selected, illegal, waiting, disconnected, and reduced-motion forms. Add long Chinese/English player names and all four color-assist symbols.

Capture review screenshots and check:

1. cold fog industrial map;
2. restrained warm brass focus;
3. modern panel hierarchy;
4. map remains the first visual subject;
5. decoration never obscures game information.

- [ ] **Step 5: Verify, then commit**

Run all UI tests on both named simulators and inspect VoiceOver focus order manually.

```bash
git add IndustrialCityBirmingham/Features/Gallery IndustrialCityBirmingham/Features/Match IndustrialCityBirmingham/App IndustrialCityBirminghamUITests
git commit -m "test: cover visual and accessibility fixtures"
```

Expected: all fixture states are directly reproducible and the manual five-point visual review is recorded.

## Task 15: Add screenshot regression tooling and performance evidence

**Files:**
- Create: `IndustrialCityBirminghamUITests/SnapshotCaptureUITests.swift`
- Create: `scripts/capture_ui_snapshots.sh`
- Create: `scripts/SnapshotDiff.swift`
- Create: `scripts/verify_ui_prototype.sh`
- Create: `Tests/Snapshots/Baselines/.gitkeep`
- Create: `Tests/Snapshots/Current/.gitkeep`
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchView.swift`

- [ ] **Step 1: Write the failing screenshot capture UI test**

SnapshotCaptureUITests must launch each required fixture, wait for `snapshot.ready`, set landscape orientation for match screens, and add `XCUIScreen.main.screenshot()` as an XCTAttachment named:

- `home-phone`;
- `online-error-phone`;
- `nearby-permission-phone`;
- `lobby-4-phone`;
- `match-2-phone`;
- `match-3-phone`;
- `match-4-phone`;
- `match-build-phone`;
- `match-sell-phone`;
- `match-disconnected-phone`;
- corresponding `-ipad` variants for home and match-4.

Run the test before adding `snapshot.ready`.

Expected: FAIL waiting for `snapshot.ready`.

- [ ] **Step 2: Add snapshot readiness and performance signposts**

Add `snapshot.ready` to the root of every stable screen only after async fixture loading completes. Wrap card response, drawer response, map pan/zoom, target glow, and market update in OSLog points-of-interest:

```swift
import OSLog

enum PrototypeSignpost {
    static let log = OSLog(subsystem: "com.example.IndustrialCityBirmingham", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
```

- [ ] **Step 3: Implement snapshot export and pixel comparison**

Create `scripts/SnapshotDiff.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO

struct ImageBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

enum SnapshotError: Error {
    case unreadable(String)
    case dimensionMismatch
}

func loadImage(at path: String) throws -> ImageBuffer {
    let url = URL(fileURLWithPath: path) as CFURL
    guard
        let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw SnapshotError.unreadable(path)
    }

    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    let drewImage = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let baseAddress = rawBuffer.baseAddress else { return false }
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard drewImage else { throw SnapshotError.unreadable(path) }
    return ImageBuffer(width: width, height: height, bytes: bytes)
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: SnapshotDiff.swift baseline.png current.png\n", stderr)
    exit(2)
}

do {
    let baseline = try loadImage(at: CommandLine.arguments[1])
    let current = try loadImage(at: CommandLine.arguments[2])
    guard baseline.width == current.width, baseline.height == current.height else {
        throw SnapshotError.dimensionMismatch
    }

    var differentPixels = 0
    let pixelCount = baseline.width * baseline.height
    for offset in stride(from: 0, to: baseline.bytes.count, by: 4) {
        let differs = (0..<4).contains { channel in
            abs(Int(baseline.bytes[offset + channel]) - Int(current.bytes[offset + channel])) > 12
        }
        if differs { differentPixels += 1 }
    }

    let ratio = Double(differentPixels) / Double(pixelCount)
    print(String(format: "different pixels: %.4f%%", ratio * 100))
    exit(ratio > 0.005 ? 1 : 0)
} catch {
    fputs("snapshot comparison failed: \(error)\n", stderr)
    exit(1)
}
```

Create `scripts/capture_ui_snapshots.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

snapshot_temp="$(mktemp -d /tmp/industrial-city-snapshots.XXXXXX)"
snapshot_current="Tests/Snapshots/Current"
snapshot_baseline="Tests/Snapshots/Baselines"
trap 'rm -rf "$snapshot_temp"' EXIT

mkdir -p "$snapshot_current" "$snapshot_baseline"
find "$snapshot_current" -maxdepth 1 -type f -name '*.png' -delete

capture_for_device() {
  local device_name="$1"
  local result_name="$2"
  local result_path="$snapshot_temp/$result_name.xcresult"
  local export_path="$snapshot_temp/$result_name-attachments"

  xcodebuild test \
    -project IndustrialCityBirmingham.xcodeproj \
    -scheme IndustrialCityBirmingham \
    -destination "platform=iOS Simulator,name=$device_name,OS=26.5" \
    -only-testing:IndustrialCityBirminghamUITests/SnapshotCaptureUITests \
    -resultBundlePath "$result_path"

  xcrun xcresulttool export attachments \
    --path "$result_path" \
    --output-path "$export_path"

  jq -r '.[] | .attachments[] | [.exportedFileName, .suggestedHumanReadableName] | @tsv' \
    "$export_path/manifest.json" |
  while IFS=$'\t' read -r exported_file suggested_name; do
    normalized_name="$(printf '%s' "$suggested_name" | tr '[:upper:] ' '[:lower:]-')"
    normalized_name="${normalized_name%.png}"
    cp "$export_path/$exported_file" "$snapshot_current/$normalized_name.png"
  done
}

capture_for_device "IndustrialCity-iPhone" "phone"
capture_for_device "IndustrialCity-iPad" "ipad"

if [[ "${RECORD_SNAPSHOTS:-0}" == "1" ]]; then
  find "$snapshot_baseline" -maxdepth 1 -type f -name '*.png' -delete
  cp "$snapshot_current"/*.png "$snapshot_baseline"/
  exit 0
fi

for current_image in "$snapshot_current"/*.png; do
  image_name="$(basename "$current_image")"
  baseline_image="$snapshot_baseline/$image_name"
  test -f "$baseline_image"
  xcrun swift scripts/SnapshotDiff.swift "$baseline_image" "$current_image"
done
```

The script fails if dimensions differ or more than 0.5% of pixels differ by more than 12/255 per channel. `RECORD_SNAPSHOTS=1` replaces only PNG files inside the explicit Baselines directory.

- [ ] **Step 4: Implement the one-command verification script**

`scripts/verify_ui_prototype.sh` must run, in order:

```bash
#!/usr/bin/env bash
set -euo pipefail

xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5'

xcodebuild build \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPad,OS=26.5'

bash scripts/capture_ui_snapshots.sh
git diff --check
```

Record baselines once after the product owner approves the screenshots:

```bash
RECORD_SNAPSHOTS=1 bash scripts/capture_ui_snapshots.sh
```

- [ ] **Step 5: Collect performance evidence, verify, then commit**

On the oldest available physical iPhone test device using a Release build:

- run the 60-second pan/zoom/glow/resource-animation workload;
- confirm average FPS ≥ 58 and P95 frame time ≤ 20 ms;
- confirm card/drawer/market first visual response ≤ 100 ms from signposts;
- repeat map/panel interactions for 10 minutes, idle for 2 minutes, and confirm resident memory growth ≤ 15%;
- run Instruments Leaks and confirm no definite leak;
- background and foreground the app and verify the current fixture state remains.

Then run:

```bash
bash scripts/verify_ui_prototype.sh

git add IndustrialCityBirmingham IndustrialCityBirminghamTests IndustrialCityBirminghamUITests scripts Tests/Snapshots
git commit -m "test: add UI regression and performance checks"
```

Expected: unit/UI tests pass, both simulator builds pass, snapshot diff passes, and physical-device measurements meet the specification.

## Task 16: Final Phase 1 audit and handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-08-06-industrial-city-birmingham-app-design.md`
- Create: `docs/testing/ui-prototype-verification.md`

- [ ] **Step 1: Run the full automated verification from a clean build**

```bash
verification_derived_data="$(mktemp -d /tmp/industrial-city-derived-data.XXXXXX)"
trap 'rm -rf "$verification_derived_data"' EXIT

xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -derivedDataPath "$verification_derived_data"

bash scripts/verify_ui_prototype.sh
```

Expected: zero failed tests, both builds succeed, and snapshots match.

- [ ] **Step 2: Verify every approved screen and interaction**

Use this checklist without skipping entries:

- home, online, nearby, lobby, rules, settings, gallery, match;
- 2/3/4 players;
- six approved match viewports through previews/snapshots;
- card replacement;
- player/industry drawers;
- action grid and market ladder mutual exclusion;
- build, canal, one rail, two rail, develop, sell, loan, scout, pass;
- accepted event, rejected event, waiting sync, disconnected;
- VoiceOver, Reduce Motion, color assist;
- portrait/landscape outside match and landscape match lock.

- [ ] **Step 3: Write the verification record**

`docs/testing/ui-prototype-verification.md` must record:

- Xcode, Swift, simulator runtime, simulator names, and physical device model/OS;
- exact commands and exit codes;
- test counts;
- snapshot count and diff result;
- FPS average, P95 frame time, response latency, memory baseline/final, and leak result;
- five-point manual visual review outcome;
- any unmet criterion as an explicit blocker rather than a success.

- [ ] **Step 4: Update the specification status**

Only if every Phase 1 criterion passes, change the spec metadata from `当前阶段：朋友间测试用高保真 UI 原型` to `阶段 1：已验证` and add a link to the verification record. Do not mark GameCore or multiplayer phases complete.

- [ ] **Step 5: Request review, then commit the audit**

Use `superpowers:requesting-code-review`, address confirmed findings, rerun `scripts/verify_ui_prototype.sh`, then:

```bash
git add docs/superpowers/specs/2026-08-06-industrial-city-birmingham-app-design.md docs/testing/ui-prototype-verification.md
git commit -m "docs: record UI prototype verification"
```

Expected: Phase 1 has reproducible evidence and no claim extends to rules or networking.

## Self-review record

### Spec coverage

- Pages and routing: Tasks 4–5.
- iPhone/iPad equal-priority layouts and orientation: Tasks 4 and 7.
- Persistent player/industry mini rails: Tasks 7–8.
- Persistent phone coal/iron market and tablet price ladder: Tasks 7–8.
- Card-first flow and seven distinct action state machines: Tasks 8–12.
- SpriteKit map, pan/zoom, target glow, and accessibility mirror: Task 6.
- FakeTransport and deterministic 2/3/4 player states: Tasks 3 and 13.
- Error reason plus recovery suggestion: Task 13.
- Design system, original art, motion, haptics, color assist, and VoiceOver: Tasks 2, 6, 13–14.
- Six viewport screenshots, performance, memory, and physical-device evidence: Tasks 15–16.
- GameCore, NearbyTransport, and WebSocketTransport remain excluded.

### Known environment fact

The observed development machine has Xcode 26.6, Swift 6.3.3, and only the iOS 26.5 simulator runtime installed. The project still targets iOS/iPadOS 17.0. Final minimum-OS runtime behavior must be checked on an available iOS/iPadOS 17 physical device because this machine cannot currently run an iOS 17 simulator.

### Type consistency

- `GameAction` is defined once in `ActionModels.swift` and used by fixtures, cards, reducer, and action views.
- `ActionFixture` is defined once in `ActionModels.swift`.
- `ActionFlowState` and its draft types are defined once beside `MatchInteractionReducer`.
- `DemoTransport` returns `LobbyState`, `DemoMatchState`, and later `DemoEvent`.
- `MatchInteractionReducer` is the only owner of selected card, selected action, overlay, and draft.
- `DemoSessionStore` is the only observable owner of lobby and match fixture data.
- SpriteKit exposes target IDs to SwiftUI; it does not own action state.

### Placeholder scan

The plan contains no unfinished-marker keywords, cross-task shorthand, omitted error-handling request, or unnamed test request. Every deferred feature is explicitly out of Phase 1 rather than an implementation placeholder.
