# 德州扑克 局域网联机（第 3 期）设计

日期：2026-10-29
状态：待作者审阅
参考实现：同机 `Brass-Birmingham/ui-prototype/IndustrialCityBirmingham` 的 `Transport/` + `Session/` 联机方案（生产路径 `NearbyTransport`）。

## 1. 背景与目标

给 PokerApp 增加本地联机：同一 Wi-Fi（或无路由器时的点对点 Wi-Fi）下，一台手机建房、其他手机搜索加入，进行 2~9 人的全人类对局。**不需要任何服务器**。

成功标准：
- 两台及以上 iPhone（或 iPhone + Mac 变体）在同一网络，30 秒内完成建房→加入→开局；
- 全手流程（发牌/下注/街道推进/摊牌/下一手/淘汰/终局）多端画面一致；
- 客机在任何情况下收不到其他玩家的手牌（抓包也拿不到）；
- 玩家锁屏/退 App 后：座位自动托管（能过则过、否则弃牌），回来自动恢复座位与手牌继续打；
- 现有单机模式（引擎 + AI 难度档）行为零变化，91/91 引擎测试与现有 App 测试全绿。

## 2. 已确认的产品决策（2026-10-29 作者拍板）

1. **仅全人类**：联机局不支持 AI 补位，桌人数 = 实际入座人数（2~9）。不搬 AI 难度选择进联机大厅。
2. **断线自动托管 + 可重连**：断线座位轮到时自动「能过牌就过牌、否则弃牌」；玩家可随时重新加入恢复座位。

## 3. 总体架构

### 3.1 路线选型

| 路线 | 结论 |
|---|---|
| **A. 房主权威 + 按接收者裁剪的全量快照广播**（采用） | 只有房主设备跑 `GameState` 引擎。客机只发动作意图；房主校验合法后 `apply`，然后对每个在线座位生成**脱敏快照**逐个发送。防作弊（隐藏手牌永不上网络）、重连平凡（补发一帧）、无多端同步难题。 |
| B. 状态镜像（lockstep，各端跑引擎共享种子+动作日志） | 否决：任何人可由种子推出全场手牌。 |
| C. MultipeerConnectivity（MCSession） | 否决：可靠性差、不可控；Brass 试过并改为 NW TCP。 |

扑克状态极小（快照几 KB），因此**每个状态变更后全量重发快照**，不需要 Brass 的事件窗口增量恢复与 catch-up 重放——这是对 Brass 方案最大的简化。

### 3.2 数据流

```
客机 UI ──action(PlayerAction)──▶ GuestSession ──PokerEnvelope──▶ 传输层(NW TCP)
                                                                  │
房主 UI ◀──GameState 直读──── HostSession ◀──PokerEnvelope────────┘
                                  │ apply 前先 isLegal 校验
                                  ▼
                     GameState（唯一权威副本，只在房主设备）
                                  │ 每次变更：对每个在线座位 seq++ 生成脱敏快照
                                  ▼
              房主自己（进程内直读）+ 各客机（网络下发）→ TableSurface 渲染
```

## 4. 模块与文件布局

新增（App target，目录仿 Brass）：

```
PokerApp/PokerApp/Transport/Transport.swift              TransportEvent/TransportError/Transport 协议
PokerApp/PokerApp/Transport/LengthPrefixedFrameCodec.swift  4 字节大端长度前缀分帧
PokerApp/PokerApp/Transport/NearbyTransport.swift        生产传输（NWListener+Bonjour+点对点，移植自 Brass）
PokerApp/PokerApp/Transport/BonjourRoomBrowser.swift     房间浏览（精简版 Brass BonjourPeerBrowser）
PokerApp/PokerApp/Transport/LoopbackTransport.swift      进程内配对传输（测试用，App target 内以便 @testable）
PokerApp/PokerApp/Session/PokerMessages.swift            信封/Payload/LobbyState/拒绝原因
PokerApp/PokerApp/Session/TableSnapshot.swift            脱敏快照 + SeatSurface/TableSurface 投影协议
PokerApp/PokerApp/Session/HostSession.swift              房主状态机（actor）
PokerApp/PokerApp/Session/GuestSession.swift             客机状态机（actor）
PokerApp/PokerApp/Features/Lobby/LobbyView.swift         建房/搜房/加入/大厅 UI
PokerApp/PokerApp/MultiplayerViewModels.swift            HostGameViewModel / GuestGameViewModel（@MainActor）
```

改动：
- `PokerApp/PokerApp/TableView.swift`：`GameView/TableView/SeatView/ActionBar` 改为面向 `TableSurface/SeatSurface/GamePresenting` 协议（本机与房主走 GameState，客机走 TableSnapshot）。
- `PokerApp/PokerApp/MenuView.swift`：加「联机对战」入口。
- `PokerApp/PokerApp/PokerApp.swift`：根路由增加 host/guest 分支。
- `PokerApp/project.yml`：显式 Info.plist（本地网络权限 + Bonjour 服务声明）。
- `PokerEngine`：为 `PlayerStatus/PotAward/HandResult/TournamentPayout/LegalActions` 添加 `Codable` 一致性（纯值类型，无行为变化，wire 需要）。

不动的：`GameViewModel`（单机模式及其测试零改动）、引擎规则逻辑、AI 全部代码。

## 5. 传输层（移植 Brass 生产实现）

- `NWListener`（TCP）+ Bonjour 广播，服务类型 `_poker-lan._tcp`；`NWParameters.tcp` 且 **`includePeerToPeer = true`**——同一 Wi-Fi 与无路由器的点对点 Wi-Fi（AWDL）都能连，这是「手机自带 Wi-Fi 直连」的关键。
- 实例名 = 房间显示名清洗成 ASCII（移植 `NearbyServiceName.sanitize`）+ 4 位随机十六进制后缀（防同名房混淆）；实例名即 roomID，`noAutoRename = true`。
- 客机 `NWBrowser` 搜房、`NWEndpoint.service` 解析直连；房间列表有出现/消失去重。
- 分帧：`LengthPrefixedFrameCodec`，4 字节大端长度前缀，上限 1 MB，解码器粘包/半包安全，坏帧永久关闭该解码器。
- 照搬 Brass 已踩坑的健壮性件：
  - `ConnectionTerminationRegistry`：按连接对象过滤陈旧/重复终止回调（换连接后旧回调不得再触达状态机）；
  - 监听器 `.failed` 原地重建（≤3 次）；`reviveHostingIfNeeded()`：App 挂起可能无声杀死监听 socket，前台激活时检测并重建（宿主 UI 经 scenePhase 调用）；
  - `NearbyLifecycleGate`：连接/监听就绪的异步生命周期用 continuation + 取消处理收敛，杜绝「UI 永久卡在正在加入」；
  - 错误映射 `EPERM/EACCES`、DNS `-65570` → 「未获本地网络权限」；`ENETDOWN/ENETUNREACH/...` → 「Wi-Fi 不可用」；其余 → 「无法连接房间」。

## 6. 线协议

### 6.1 信封

```swift
struct PokerEnvelope: Codable, Equatable {
    var protocolVersion: Int = 1     // 不匹配 → rejection(.versionMismatch)，双方提示升级
    var roomID: String               // = Bonjour 实例名
    var messageID: String            // UUID；接收端去重（TCP 不会重排，但重连补发可能与在途重叠）
    var sender: Sender               // .host 或 .seat(Int)
    var payload: Payload
}
```

### 6.2 Payload

```
guest→host:  hello(deviceID, name)          连接后第一条；deviceID 是重连身份
            ready(Bool)                     仅大厅阶段有效
            action(PlayerAction)            对局中，发送座位 = 分配座位
            nextHand                        请求开下一手
            bye                             主动退出
host→guest:  welcome(seat, lobby)           接受加入/重连（seat 为分配或还原的座位号）
            rejection(Reason)               拒绝：roomFull / gameStarted / versionMismatch /
                                            illegalAction / notYourTurn
            lobby(LobbyState)               名册/桌子配置变化广播
            snapshot(TableSnapshot)         对局中每次状态变更后逐座位下发
```

`started` 消息不需要：客机收到第一帧 `snapshot`（或 `lobby.phase == .playing`）即切牌桌。`bye` 在大厅期 = 移出名册；对局中 = 标记断线托管（引擎名册开局后锁定，不做中途移座）。

### 6.3 LobbyState

```swift
struct LobbyPlayer: Codable { seat, name, isHost, ready, connected }
struct LobbyState: Codable { phase: Phase(.lobby/.playing), roomName, players: [LobbyPlayer],
                             config: GameConfig? }   // 房主定的桌子配置，开局前可见
```

大厅流程：房主建房（填房间名 + 桌子配置：模式现金/SNG、小盲、初始筹码/买入——复用 MenuView 的既有配置项，去掉人数与 AI 难度两项）→ 客机搜索→点房→填昵称（默认 `玩家-XXXX`，≤12 字）→ hello → 主机分配座位（房主恒 seat 0，客机按加入顺序 1..）→ welcome + lobby 广播 → 各自 ready → 房主「开局」（条件：人数 ≥2 且全员 ready）。

开局：先广播 `lobby(phase: .playing)`（客机切牌桌屏），随后 `GameState.start(config: GameConfig(playerCount: 入座人数, ...), seed: 时间戳)`；把 `players[i].name` 改写为大厅昵称（`PlayerState.name` 为 public var）；对每个在线座位生成首帧快照下发。

## 7. 快照与脱敏规则

```swift
struct SnapshotPlayer: Codable, Equatable {
    seat, name, stack, streetContribution, status: PlayerStatus,
    holdsCards: Bool,          // 「有牌但不可见」标记（UI 据此画牌背）
    holeCards: [Card]          // 仅接收者自己的；或摊牌亮出的
}
struct TableSnapshot: Codable, Equatable {
    seq: Int,                  // 主机单调递增；客机丢弃 seq <= 已见最大值
    config: GameConfig, handNumber, buttonSeat, street, board: [Card],
    players: [SnapshotPlayer], // 下标即 seat
    potTotal, currentBet, actorSeat: Int?,
    handResult: HandResult?, tournamentOver, tournamentPayouts: [TournamentPayout],
    yourSeat: Int,
    yourLegal: LegalActions?   // 仅当 actorSeat == yourSeat 时由主机用引擎 legalActions() 算好附上
}
```

脱敏规则（生成 `TableSnapshot recipient=seat r` 时，对每个玩家 p）：
1. `p.seat == r` → 发真实手牌；
2. `street == .handOver` 且 `handResult` 含非空 ranks（即走到摊牌，`settleUncontested` 的 ranks 为空）且 `p.status != .folded` → 发真实手牌（亮牌；弃牌者 muck 不亮）——与现有单机 UI 的摊牌展示完全一致；
3. 其余 → `holeCards = []`、`holdsCards = true`（游戏中）或 `holdsCards = false`（未发牌/无牌）。
4. 牌堆、RNG、对手 mid-hand 手牌**永不**出现在任何载荷里。

`yourLegal` 由主机计算：规则唯一真源在引擎，客机不复制任何合法性逻辑。UI 的快捷额度按钮（1/2 池、满池）只用 `potTotal/currentBet/betRange` 等公开量。

## 8. 主机状态机 HostSession（actor）

状态：`idle → hosting(lobby) → playing → finished`。

持有：大厅名册（座位↔deviceID↔peer↔昵称↔ready↔connected）、桌子配置、引擎 `GameState?`、快照 `seq`。

对传输事件的响应（全部先做绑定校验，仿 Brass：一条连接只绑一个 deviceID；同 deviceID 新连接 = 接管，旧连接作废）：
- `hello`：
  - 大厅期：deviceID 已知 → 还原座位；未知且 <9 人 → 分配下一空位；满员 → `rejection(.roomFull)`。→ welcome + lobby 广播。
  - 对局中：deviceID 已知（原座位）→ welcome + 立即补发最新快照（重连恢复）；未知 → `rejection(.gameStarted)`。
  - `protocolVersion` 不匹配 → `rejection(.versionMismatch)`。
- `ready`：大厅期标记并广播；对局期忽略。
- `action(PlayerAction)`：校验 `sender 座位 == actorSeat` 且引擎 `isLegal`——**非法动作绝不进引擎**（引擎对非法动作按弃牌处理、对非法加注有 precondition 崩溃路径，网络输入必须先拦）。通过 → `apply` → 全员快照扇出；座位不符 → `rejection(.notYourTurn)`；非法 → `rejection(.illegalAction)`。
- `nextHand`：`street == .handOver && !tournamentOver` 时执行 `nextHand()` 并扇出；引擎幂等（street 已变则后续请求自然无效），任何座位（含房主本地）第一次按生效。
- `disconnected(peer)`：大厅期 → 移出名册并广播；对局期 → 标记该座位断线，若正是 `actorSeat` 立即托管。
- **托管**：每次 actorSeat 落到断线座位时自动 `canCheck ? .check : .fold`（经引擎 `legalActions` 判定，立即执行）。盲注由引擎 `dealNewHand` 自动投，断线者照常输盲。
- 房主自己的行动不经网络：`HostGameViewModel` 直接调 HostSession 的本地方法（与远端意图走同一校验与扇出路径）。
- 扇出：每次引擎变更后 `seq+1`，对每个**在线**座位生成 `recipient` 专属 `TableSnapshot` 逐个 `send`；发送失败仅记日志并依赖该端后续断线事件重连补发，不阻塞其他座位。
- 对房主 UI 的通知：`AsyncStream<HostUpdate>`（`.lobby(LobbyState)` / `.state(GameState)`），VM 消费后驱动界面。

## 9. 客机状态机 GuestSession（actor）

状态：`idle → browsing → joining(TCP 已连，等 welcome) → lobby → playing →（disconnected → 自动重连循环）→ left/failed`。

- 身份：deviceID（UserDefaults 持久 UUID，`poker.deviceID`）+ 昵称。
- 加入：搜房列表 → 选房 → connect → hello → 等 welcome（2s 超时）；被拒显示对应文案。
- 对局中：收 `snapshot`（seq 去重）→ 存储 → 推给 VM；`act/nextHand` 封装意图发送。
- 断线：对 host 的 `disconnected` → 进入自动重连循环（1s 起、指数退避、上限 5s，无限次）：重连成功（hello→welcome→补发快照）即恢复；UI 显示「连接断开，重连中…」。客机**无法区分**房主暂时失联与永久退出（房主进程消失时不会有告别消息），因此不设自动放弃：横幅常驻重连提示，用户可随时点「返回大厅」主动结束（整局结束，房主权威无迁移）。
- 场景自愈：scenePhase `.active` 时若在重连循环则立即重试（锁屏回来秒恢复）。

## 10. UI 集成

### 10.1 渲染抽象（改动最小的统一）

```swift
protocol SeatSurface { seat, name, stack, streetContribution, status, holeCards: [Card], holdsCards: Bool }
protocol TableSurface { players: [any SeatSurface], board, street, actorSeat, buttonSeat, handNumber,
                        potTotal, currentBet, format: GameFormat, yourSeat: Int,
                        handResult, tournamentOver, tournamentPayouts }
protocol GamePresenting: ObservableObject {
    surface（发布）、humanLegal: LegalActions?、lastResult、isHandOver、isSessionOver
    act(_:), nextHand()
}
```

- `GameState`/`PlayerState` 以 App 侧 retroactive extension 实现两个 Surface（`holdsCards = !holeCards.isEmpty`）——**单机与房主路径行为零变化**。
- `TableSnapshot`/`SnapshotPlayer` 实现之——客机路径。
- `SeatView` 画牌背的判定从 `holeCards.count == 2` 改为 `holdsCards`（快照里对手牌为空但仍需画背；本地路径两者语义等价）。
- `ActionBar` 读 `humanLegal` 与 `potTotal/currentBet`；`GameView` 泛化为接受任意 `GamePresenting`。单机 `.task { driveBots }` 收进 local VM 自身（协议加默认空实现），联机路径无感。

### 10.2 界面流

```
MenuView「联机对战」→ LobbyView
  ├─ 创建房间：房间名+桌子配置 → HostGameViewModel(大厅: 名册/ready/开局按钮)
  └─ 搜索房间：BonjourRoomBrowser 列表 → 点房 → 昵称 → GuestGameViewModel(大厅: 名册/ready)
对局：复用 GameView（surface 分别来自 GameState / TableSnapshot）
断线重连横幅、托管座位标记（名字旁「托管中」）、「房主已离开」终局提示。
```

## 11. 权限与工程配置

- `project.yml` 给 PokerApp 目标改用 xcodegen `info:` 生成的显式 Info.plist，新增：
  - `NSLocalNetworkUsageDescription`：「用于在本地网络中发现并连接附近朋友的德州扑克房间。」
  - `NSBonjourServices`：`["_poker-lan._tcp"]`
  - 实施时必须核验：原 `GENERATE_INFOPLIST_FILE + INFOPLIST_KEY_*` 注入的键（UILaunchScreen 等）在产物 plist 中仍然齐全（iOS 与 macOS 变体都要查），图标设置不动。
- macOS 变体：代码全部平台中立（Network.framework/SwiftUI 双平台可用）；macOS 15 同样会弹本地网络权限。macOS 变体为顺带支持，验收以 iOS 真机为准。
- `SWIFT_STRICT_CONCURRENCY=complete` 不变：会话层全 actor、消息全 Sendable 值类型。
- 真机签名（团队 JB7ZKPWM9C 自动签名）不动；本地网络权限弹窗在首次建房/搜房时出现，属预期。

## 12. 测试策略（XCTest，与现有一致；全部不依赖真实网络）

1. **帧编解码**：帧格式字节序、粘包/半包有序、超长/零长坏帧关解码器（移植 Brass 对应测试）。
2. **LoopbackTransport**：进程内配对，有序投递、断链模拟（`severLink`）。
3. **快照脱敏**（核心安全测试）：
   - 对局中对手 `holeCards == []` 且 `holdsCards == true`，自己手牌在；
   - 摊牌局非弃牌者亮牌、弃牌者不亮、全员弃牌局无人亮；
   - `yourLegal` 与引擎 `legalActions` 逐步一致（随机种子若干）；
   - 快照 Codable 往返等价。
4. **HostSession 集成**（LoopbackTransport：1 房主 + 2~3 客机）：
   - 大厅：加入/ready/满员拒绝/开局条件；
   - 完整一手脚本化对局（下注→加注→摊牌）：各端收到的快照中公开信息一致（街道/公共牌/筹码/底池/actorSeat），每人快照只含自己的手牌，seq 单调递增；
   - 非法动作被拒且引擎状态未动；非行动座位动作被拒；
   - 断线托管：断线座位轮到时自动过/弃，牌局继续；
   - 重连：断线→重连→座位还原、快照恢复、继续行动；
   - 对局中新 deviceID 加入被拒。
5. **GuestSession**：握手/ready/意图透传/断线重连循环状态。
6. **回归**：引擎 91 项 + PokerApp 现有测试全绿（单机路径零改动是设计约束）。

真机验收（作者手动，2 台 iPhone）：建房→加入→3 手对局→中途锁屏 30s 回来重连恢复；断链横幅与文案正确。

## 13. 边界与错误处理

| 情形 | 行为 |
|---|---|
| 本地网络权限被拒 | 映射为可操作文案（去系统设置开启），可重试 |
| 同名房间冲突 | 实例名带随机后缀；guest 按 roomID 严格匹配，错连被拒 |
| 一条连接换身份 / 双开同 deviceID | 连接绑定唯一；新连接接管旧连接 |
| 房主退出/失联 | 客机无法感知区分，横幅持续重连；用户手动返回大厅即整局结束（权威不迁移，休闲局可接受） |
| 客机对局中主动退出（bye） | 座位转断线托管直至终局，不收回座位 |
| 快照发送失败 | 不阻塞其他座位；该端靠断线重连全量补发 |
| 所有人断线 | 牌局停在原地等待（无人观看，无意义推进） |
| 9 人上限 / 2 人下限 | 大厅拒绝加入 / 开局按钮禁用 |

## 14. 明确不做（YAGNI，后续可加）

观战、聊天、中途加人、踢人、行动计时器、牌局回放、跨网络穿透、主机权威迁移、AI 补位（作者已拍板不做）、自定义规则。

## 15. 交付里程碑建议

1. 传输层 + 帧编解码 + Loopback（测试齐）；
2. 协议 + 快照脱敏（测试齐）；
3. HostSession/GuestSession 状态机（Loopback 集成测试齐）；
4. UI（大厅 + GameView 泛化）+ Info.plist/工程配置；
5. 真机双机验收。
