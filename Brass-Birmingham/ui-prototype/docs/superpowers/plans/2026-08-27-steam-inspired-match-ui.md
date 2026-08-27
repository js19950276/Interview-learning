# Steam 式对局界面与原创工业贴图 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变规则、地图拓扑和联机行为的前提下，把权威对局界面重做为地图优先的紧凑 Steam 式结构，并应用原创维多利亚工业贴图。

**Architecture:** 先用纯值 token 和可复用 SwiftUI 外观组件建立工业视觉系统，再分别替换顶栏、玩家轨、产业轨、手牌坞与行动流程。SpriteKit 地图只调整展示材质和高亮，不改变数据投影、目标 ID 或相机计算。所有响应式尺寸仍由 `MatchLayoutMetrics` 统一提供。

**Tech Stack:** Swift 6、SwiftUI、SpriteKit、Asset Catalog、Swift Testing、XCTest UI Testing、Xcode iOS Simulator。

**Checkpoint policy:** 当前父仓库存在大量用户修改和未跟踪文件；实施期间不创建提交，避免把不完整的项目基线误提交。每个任务用针对性测试和 `git diff --check` 作为可恢复检查点。

---

## 文件结构

- Create: `IndustrialCityBirmingham/DesignSystem/IndustrialMatchChrome.swift` — 原创贴图名称、可拉伸外观和产业徽章组件。
- Create: `IndustrialCityBirmingham/Features/Match/ActionContextBar.swift` — 单行行动阶段提示和取消入口。
- Create: `IndustrialCityBirminghamTests/IndustrialMatchChromeTests.swift` — 资产、颜色、产业映射和尺寸不变量。
- Modify: `IndustrialCityBirmingham/DesignSystem/BrassColor.swift` — 工业材质与交互状态颜色。
- Modify: `IndustrialCityBirmingham/DesignSystem/BrassComponents.swift` — 主按钮、面板和状态容器统一换肤。
- Modify: `IndustrialCityBirmingham/Features/Match/MatchLayoutMetrics.swift` — 新顶栏高度、iPad 紧凑侧轨与既有地图遮挡边界。
- Modify: `IndustrialCityBirmingham/Features/Match/MatchHeaderView.swift` — 单层连续状态带。
- Modify: `IndustrialCityBirmingham/Features/Match/PlayerRailView.swift` — 紧凑玩家轨和当前玩家表现。
- Modify: `IndustrialCityBirmingham/Features/Match/IndustryRailView.swift` — 原创产业徽章和紧凑产业条。
- Modify: `IndustrialCityBirmingham/Features/Match/HandView.swift` — 中央手牌坞、材质卡面和选中反馈。
- Modify: `IndustrialCityBirmingham/Features/Match/ActionGridView.swift` — 紧凑行动条。
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift` — 组合新顶栏与上下文条，保持规则状态不变。
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapScene.swift` — 路线、城市、产业、贸易商的工业材质与状态高亮。
- Modify: `IndustrialCityBirminghamTests/BrassColorTests.swift` — 新颜色对比度。
- Modify: `IndustrialCityBirminghamTests/MatchLayoutMetricsTests.swift` — 新布局指标。
- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift` — 地图目标名称、可点击面积和高亮语义回归。
- Modify: `IndustrialCityBirminghamUITests/MatchInteractionUITests.swift` — iPhone 抽屉、行动流程与地图交互回归。
- Modify: `IndustrialCityBirminghamUITests/SnapshotCaptureUITests.swift` — iPhone/iPad 新界面截图覆盖。
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/*` — 原创可拉伸纹理和六枚产业徽章。

### Task 1: 锁定工业主题 token 与资产契约

**Files:**
- Create: `IndustrialCityBirminghamTests/IndustrialMatchChromeTests.swift`
- Modify: `IndustrialCityBirminghamTests/BrassColorTests.swift`
- Modify: `IndustrialCityBirmingham/DesignSystem/BrassColor.swift`
- Create: `IndustrialCityBirmingham/DesignSystem/IndustrialMatchChrome.swift`

- [ ] **Step 1: 写资产名称、产业映射和对比度失败测试**

```swift
import SwiftUI
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct IndustrialMatchChromeTests {
    @Test(arguments: IndustryKind.allCases)
    func everyIndustryHasAnOriginalMedallion(_ kind: IndustryKind) {
        #expect(IndustrialMatchAsset.industryMedallion(kind).name.isEmpty == false)
    }

    @Test func legalAndUnavailableStatesRemainReadableOnCoal() {
        #expect(BrassColor.legalGreen.contrastRatio(against: .coal) >= 3.0)
        #expect(BrassColor.unavailableRed.contrastRatio(against: .coal) >= 3.0)
    }
}
```

在 `BrassColorTests` 增加：

```swift
@Test func industrialPaperAndBrassRemainReadableOnWood() {
    #expect(BrassColor.paper.contrastRatio(against: .darkWood) >= 4.5)
    #expect(BrassColor.brass.contrastRatio(against: .darkWood) >= 3.0)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/IndustrialMatchChromeTests -only-testing:IndustrialCityBirminghamTests/BrassColorTests
```

Expected: FAIL，缺少 `IndustrialMatchAsset`、`legalGreen`、`unavailableRed` 和 `darkWood`。

- [ ] **Step 3: 实现主题纯值与资产枚举**

在 `BrassColor.swift` 增加：

```swift
static let darkWood = BrassColor(hex: 0x30251D)
static let forgedIron = BrassColor(hex: 0x2A2D2D)
static let parchmentShadow = BrassColor(hex: 0xA98D62)
static let legalGreen = BrassColor(hex: 0x8CCB6B)
static let unavailableRed = BrassColor(hex: 0xC66A59)
```

创建 `IndustrialMatchChrome.swift`：

```swift
import SwiftUI

enum IndustrialMatchAsset: String, CaseIterable {
    case ironHorizontal = "match-iron-horizontal"
    case ironVertical = "match-iron-vertical"
    case woodFill = "match-wood-fill"
    case parchmentLabel = "match-parchment-label"
    case cardTexture = "match-card-texture"
    case brassCorner = "match-brass-corner"
    case cotton = "industry-cotton-medallion"
    case manufacturer = "industry-manufacturer-medallion"
    case pottery = "industry-pottery-medallion"
    case coal = "industry-coal-medallion"
    case iron = "industry-iron-medallion"
    case brewery = "industry-brewery-medallion"

    var name: String { rawValue }

    static let required = Self.allCases

    static func industryMedallion(_ kind: IndustryKind) -> Self {
        switch kind {
        case .cotton: .cotton
        case .manufacturer: .manufacturer
        case .pottery: .pottery
        case .coal: .coal
        case .iron: .iron
        case .brewery: .brewery
        }
    }
}

enum IndustrialPanelAxis {
    case horizontal
    case vertical
}

struct IndustrialPanelSurface: ViewModifier {
    let axis: IndustrialPanelAxis

    func body(content: Content) -> some View {
        content
            .background(BrassColor.darkWood.color.opacity(0.96))
            .overlay {
                Image(axis == .horizontal
                    ? IndustrialMatchAsset.ironHorizontal.name
                    : IndustrialMatchAsset.ironVertical.name)
                    .resizable(
                        capInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
                        resizingMode: .tile
                    )
                    .allowsHitTesting(false)
            }
    }
}

struct ParchmentContextSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(BrassColor.coal.color)
            .padding(.horizontal, 10)
            .background {
                Image(IndustrialMatchAsset.parchmentLabel.name)
                    .resizable(
                        capInsets: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18),
                        resizingMode: .stretch
                    )
            }
    }
}
```

- [ ] **Step 4: 跑到颜色、映射和外观类型测试通过**

Run: 重复 Step 2 命令；资产文件存在性测试在 Task 2 生成最终 PNG 后加入。

Expected: PASS。

- [ ] **Step 5: 检查本任务差异**

Run: `git diff --check -- IndustrialCityBirmingham/DesignSystem IndustrialCityBirminghamTests/BrassColorTests.swift IndustrialCityBirminghamTests/IndustrialMatchChromeTests.swift`

Expected: 无输出。

### Task 2: 生成并接入原创贴图资产

**Files:**
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-iron-horizontal.imageset/*`
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-iron-vertical.imageset/*`
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-wood-fill.imageset/*`
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-parchment-label.imageset/*`
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-card-texture.imageset/*`
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-brass-corner.imageset/*`
- Create: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-*-medallion.imageset/*`

- [ ] **Step 1: 用 imagegen 分别生成六类无文字 UI 材质**

每个资产使用内置 imagegen 单独生成，统一约束：`original Victorian industrial iOS strategy-game UI asset; no logo, no text, no map, no recognizable Brass Birmingham artwork, crisp small-screen readability, no watermark`。具体主体依次为：

```text
1. seamless forged black iron horizontal strip with restrained rivets, transparent outside edge
2. seamless forged black iron vertical strip with restrained rivets, transparent outside edge
3. seamless dark walnut inset panel texture, low visual noise
4. stretchable aged parchment label plate with quiet brass edge, empty center
5. seamless charcoal leather and card-fiber texture, low visual noise
6. isolated aged brass corner ornament, restrained Victorian scrollwork, transparent background
```

- [ ] **Step 2: 用 imagegen 分别生成六枚透明产业徽章**

统一约束：`single original circular aged-brass medallion, centered subject, transparent background, no text, no logo, no copied board-game icon, readable at 24pt`。主体依次为：

```text
cotton boll and leaves
compact nineteenth-century factory goods motif
ceramic kiln pot
coal wagon
iron ingot and anvil
wooden brewery barrel
```

- [ ] **Step 3: 逐张检查并保存最终 PNG**

用 `view_image` 检查主体、透明边缘、噪声和小尺寸辨识度；把通过的原图复制进对应 `.imageset/asset.png`，保留 imagegen 原始文件。不要把风格板整图作为运行时资产。

每个 `.imageset/Contents.json` 使用完整内容：

```json
{
  "images": [
    { "filename": "asset.png", "idiom": "universal", "scale": "1x" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

在 `IndustrialMatchChromeTests` 增加最终资产存在性测试：

```swift
import UIKit

@Test(arguments: IndustrialMatchAsset.required)
func everyRequiredTextureExists(_ asset: IndustrialMatchAsset) {
    #expect(UIImage(named: asset.name) != nil)
}
```

- [ ] **Step 4: 设置可拉伸和渲染属性**

材质在 SwiftUI 中统一通过 Task 1 的 `resizable(capInsets:resizingMode:)` 处理平铺/拉伸。产业徽章使用 `.renderingMode(.original)`。

- [ ] **Step 5: 运行资产测试与构建**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/IndustrialMatchChromeTests
xcodebuild build -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'generic/platform=iOS Simulator'
```

Expected: tests PASS；build `** BUILD SUCCEEDED **`。

### Task 3: 重做布局指标和顶部状态带

**Files:**
- Modify: `IndustrialCityBirminghamTests/MatchLayoutMetricsTests.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchLayoutMetrics.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/MatchHeaderView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`
- Modify: `IndustrialCityBirmingham/DesignSystem/BrassComponents.swift`

- [ ] **Step 1: 把新尺寸写成失败测试**

```swift
@Test func steamInspiredChromeKeepsMapDominant() {
    let phone = MatchLayoutMetrics(viewport: CGSize(width: 852, height: 393))
    #expect(phone.headerHeight == 44)
    #expect(phone.mapTopInset == 44)
    #expect(phone.leftRailWidth == 44)
    #expect(phone.rightRailWidth == 44)
    #expect(phone.handHeight == 92)

    let tablet = MatchLayoutMetrics(viewport: CGSize(width: 1_194, height: 834))
    #expect(tablet.headerHeight == 48)
    #expect(tablet.mapTopInset == 48)
    #expect(tablet.leftRailWidth == 184)
    #expect(tablet.rightRailWidth == 176)
}
```

- [ ] **Step 2: 运行测试确认旧布局失败**

Run: `xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/MatchLayoutMetricsTests`

Expected: FAIL，旧 iPhone 顶部为 76、iPad 侧轨为 220/210。

- [ ] **Step 3: 实现新指标**

在 `MatchLayoutMetrics` 增加 `headerHeight`，并设置：

```swift
if viewport.width >= Self.tabletWidthThreshold {
    formFactor = .tablet
    headerHeight = 48
    leftRailWidth = 184
    rightRailWidth = 176
    handHeight = 132
    mapTopInset = headerHeight
    marketPlacement = .underPlayerRail
} else {
    formFactor = .phone
    headerHeight = 44
    leftRailWidth = 44
    rightRailWidth = 44
    handHeight = 92
    mapTopInset = headerHeight
    marketPlacement = .bottomLeftCompact
}
```

地图 viewport inset 仍保持 iPhone `top: 0`、iPad `.zero`。

- [ ] **Step 4: 合并双层顶栏**

让 `MatchHeaderView` 同时接收 `roomID`、`syncStatus` 和 `ActiveTurnPresentation?`，单个 `HStack` 顺序为：时代/回合、当前玩家、行动、牌库、资金、收入、VP、同步。外层使用 `IndustrialPanelSurface(axis: .horizontal)`，高度由 `metrics.headerHeight` 提供；iPhone 隐藏房间号的可见文字但保留辅助功能摘要。

- [ ] **Step 5: 运行布局与当前回合测试**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/MatchLayoutMetricsTests -only-testing:IndustrialCityBirminghamTests/ActiveTurnIndicatorTests
```

Expected: PASS。

### Task 4: 重做玩家轨和产业轨

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Match/PlayerRailView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/IndustryRailView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`
- Modify: `IndustrialCityBirminghamUITests/MatchInteractionUITests.swift`

- [ ] **Step 1: 写 iPhone/iPad 结构 UI 回归测试**

```swift
@MainActor
func testSteamInspiredRailsPreserveResponsiveInteraction() {
    launchLandscapeMatch(arguments: ["-fixture", "players4"])
    XCTAssertTrue(app.buttons["real.playerRail.toggle"].waitForExistence(timeout: 4))
    app.buttons["real.playerRail.toggle"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["overlay.playerRail"].waitForExistence(timeout: 2))
    app.buttons["real.industryRail.toggle"].tap()
    XCTAssertFalse(app.descendants(matching: .any)["overlay.playerRail"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["overlay.industryRail"].exists)
}
```

在 iPad 用例断言 `match.playerRail.content` 和 `match.industryRail.content` 常驻，并且两个 `.toggle` 不存在。

- [ ] **Step 2: 运行 UI 测试确认外观标识缺失或布局断言失败**

Run: `xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamUITests/MatchInteractionUITests/testSteamInspiredRailsPreserveResponsiveInteraction`

Expected: RED，直到新结构和标识完成。

- [ ] **Step 3: 实现玩家轨**

收起态沿用 44pt 点击区，内部改为 `IndustrialPanelSurface(axis: .vertical)`；每位玩家显示颜色辅助符号、顺序和小型状态。当前玩家同时使用 3pt 黄铜边、浅绿外光和“行动”短标签。iPad 行高保持至少 44pt，移除多层圆角灰卡。

- [ ] **Step 4: 实现产业轨**

用：

```swift
Image(IndustrialMatchAsset.industryMedallion(industry.kind).name)
    .resizable()
    .renderingMode(.original)
    .scaledToFit()
```

替换 SF Symbol 主图；徽章旁保留产业中文、`L(level)`、费用和煤铁成本。选中/可选/不可用分别使用黄铜、绿光、暗化红边，点击和辅助功能标识不变。

- [ ] **Step 5: 运行抽屉和匹配交互测试**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/MatchInteractionReducerTests -only-testing:IndustrialCityBirminghamUITests/MatchInteractionUITests
```

Expected: PASS。

### Task 5: 重做手牌坞、行动条和上下文提示

**Files:**
- Modify: `IndustrialCityBirminghamTests/MatchInteractionReducerTests.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/HandView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/ActionGridView.swift`
- Create: `IndustrialCityBirmingham/Features/Match/ActionContextBar.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`

- [ ] **Step 1: 锁定手牌占用和行动标题纯值**

```swift
@Test func phoneHandKeepsOcclusionBudgetWhileCardsRemainCompact() {
    let layout = HandView.layout(availableWidth: 764, cardCount: 8, formFactor: .phone)
    #expect(layout.cardWidth <= 78)
    #expect(layout.spacing < 0)
}

@Test(arguments: [
    (GameAction.build, "建造"), (.network, "铺设"), (.develop, "研发"),
    (.sell, "出售"), (.loan, "贷款"), (.scout, "侦察"), (.pass, "跳过")
])
func actionContextUsesChineseLabels(_ action: GameAction, _ expected: String) {
    #expect(ActionContextBar.title(for: action) == expected)
}
```

- [ ] **Step 2: 运行测试确认 `ActionContextBar` 缺失**

Run: `xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/MatchInteractionReducerTests`

Expected: FAIL。

- [ ] **Step 3: 实现中央手牌坞**

外层继续占 `metrics.handHeight` 供地图计算，但仅中央内容绘制深色卡槽；`HandCardFace` 使用 `match-card-texture`、薄黄铜边和原创产业徽章/既有位置图标。选中牌上抬 18pt，Scout 牌上抬 10pt，现有动画、点击区和辅助功能不变。

- [ ] **Step 4: 把行动网格改为紧凑图标条**

`ActionGridView` 使用自适应单行或两行布局；每项至少 44pt，允许动作正常显示，不允许动作保持可见但降到 0.32 透明度。关闭按钮在尾部，仍使用 `action.close`。

- [ ] **Step 5: 添加 `ActionContextBar` 并接入流程**

```swift
struct ActionContextBar: View {
    let actionNumber: Int
    let action: GameAction
    let instruction: String
    let onCancel: () -> Void

    static func title(for action: GameAction) -> String {
        switch action {
        case .build: "建造"
        case .network: "铺设"
        case .develop: "研发"
        case .sell: "出售"
        case .loan: "贷款"
        case .scout: "侦察"
        case .pass: "跳过"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("行动 \(actionNumber)/2")
            Text(Self.title(for: action))
            Text(instruction).lineLimit(1)
            Spacer(minLength: 4)
            Button("取消", action: onCancel)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("action.context.cancel")
        }
        .modifier(ParchmentContextSurface())
        .accessibilityIdentifier("action.context")
    }
}
```

仅在已有 `interaction.selectedAction` 和 legal flow 活跃时显示，不创造第二套行动状态。

- [ ] **Step 6: 运行手牌和行动流程测试**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/MatchInteractionReducerTests -only-testing:IndustrialCityBirminghamTests/ActionFlowTests -only-testing:IndustrialCityBirminghamUITests/MatchInteractionUITests
```

Expected: PASS。

### Task 6: 给地图、产业与贸易商应用新视觉层级

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapScene.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/MapRouteEraStyle.swift`
- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

- [ ] **Step 1: 写展示状态失败测试**

```swift
@Test func highlightedTargetsUseLegalStateWithoutChangingTargetIdentity() throws {
    let scene = GameMapScene(size: CGSize(width: 1_200, height: 800))
    var state = makeState()
    state.locations[0].merchantPlacements = [.init(
        slotID: "merchant-legal", acceptedIndustries: [.cotton], hasBeer: true,
        bonusKind: .income, bonusAmount: 2
    )]
    scene.configure(state: state, highlightedIDs: ["merchant-legal"])
    let node = try #require(scene.childNode(withName: "//merchant:merchant-legal"))
    #expect(node.userData?["visualState"] as? String == "legal")
    #expect(GameMapScene.targetID(fromNodeName: node.name) == "merchant-legal")
}
```

增加普通路线与合法路线的 `visualState == "normal"/"legal"` 断言，同时保留运河/铁路时代断言。

- [ ] **Step 2: 运行地图测试确认 `visualState` 缺失**

Run: `xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests`

Expected: FAIL。

- [ ] **Step 3: 调整路线与节点表现**

普通运河/铁路路线使用低饱和暗蓝/铁黑；wrong-era 继续遵守既有虚实线语义；合法目标增加独立绿光子节点并设置 `visualState`，不通过改变目标 name 表达状态。

- [ ] **Step 4: 调整已建产业与贸易商牌**

已建产业保留玩家色条，主体改用对应产业徽章；贸易商牌使用羊皮纸/深木底、黄铜边，仍显示接受产业、酒和奖励。`merchant-hit-area` 继续保持透明 44pt 点击区，装饰子节点 `isUserInteractionEnabled = false`。

- [ ] **Step 5: 运行全部地图测试**

Run: 重复 Step 2 命令。

Expected: 现有地图、贸易商、路线时代、点击和 44pt 测试全部 PASS。

### Task 7: 全量验证与双模拟器验收

**Files:**
- Modify: `IndustrialCityBirminghamUITests/SnapshotCaptureUITests.swift`
- Update only if evidence requires: `docs/testing/friends-playable-verification.md`

- [ ] **Step 1: 捕获 iPhone 和 iPad 对局截图**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamUITests/SnapshotCaptureUITests/testCapturePhoneSnapshots
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPad' -only-testing:IndustrialCityBirminghamUITests/SnapshotCaptureUITests/testCaptureIPadSnapshots
```

Expected: PASS，并产生 match-2/3/4、build、sell 和 iPad match 截图附件。

- [ ] **Step 2: 逐图检查视觉问题**

检查：顶栏裁切、地图占比、贴图拉伸接缝、手牌遮挡、当前玩家识别、产业徽章小尺寸可读性、贸易商牌重叠、合法目标是否压过普通路线。发现问题只修改对应展示层并重跑相关截图。

- [ ] **Step 3: 运行完整单元测试**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone' -only-testing:IndustrialCityBirminghamTests
```

Expected: 全部测试 PASS。

- [ ] **Step 4: 运行 Debug 构建与差异检查**

Run:

```bash
xcodebuild build -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -configuration Debug -destination 'generic/platform=iOS Simulator'
git diff --check -- Brass-Birmingham/ui-prototype
```

Expected: `** BUILD SUCCEEDED **`；diff check 无输出。

- [ ] **Step 5: 运行双模拟器真实房间脚本**

Run: `bash scripts/run_two_simulator_room_test.sh`

Expected: iPad 创建、iPhone 搜索加入、双方准备、房主开始，日志到达 `real.sync`，脚本退出 0。

- [ ] **Step 6: 手动检查关键路径**

在两台已启动模拟器上验证：当前回合明确；iPhone 左右抽屉可开关且互斥；地图可以拖到最下方城市；基德明斯特只提供合法产业；建造后地图显示产业；出售时贸易商接受类型、啤酒和奖励可辨认。

- [ ] **Step 7: 汇总证据**

最终报告列出：新增原创资产、修改的主要组件、单元测试数量、UI 测试结果、双模拟器结果、仍需用户主观验收的视觉细节。不要用“完成”代替实际命令输出。
