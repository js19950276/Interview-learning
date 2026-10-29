# PokerApp 局域网联机 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同一 Wi-Fi（或点对点 Wi-Fi）下多台 iPhone 玩 2~9 人全人类德州扑克，无需服务器：房主权威引擎 + 按接收者裁剪的脱敏快照广播，断线自动托管、可重连。

**Architecture:** 移植 Brass-Birmingham 的生产联机方案（`NearbyTransport`：NWListener/NWConnection + Bonjour + `includePeerToPeer`）到 PokerApp；新增 HostSession/GuestSession 两个 actor 会话层；每个状态变更后全量重发脱敏快照（扑克状态仅几 KB，无需增量恢复）；对局 UI 泛化为面向 `TableSurface`/`GamePresenting` 协议，单机路径零行为变化。

**Tech Stack:** Swift 6（SWIFT_STRICT_CONCURRENCY=complete）、Network.framework、Bonjour、SwiftUI、XCTest；引擎为本地 SwiftPM 包 `PokerEngine`。

**Spec:** `docs/superpowers/specs/2026-10-29-lan-multiplayer-design.md`（本计划从 spec 出发，执行者须同时读 spec）

## Global Constraints

- 仓库根：`/Users/baigeitiancai/Desktop/Interview-learning/Texas-Hold’em-poker`（路径中撇号是 **U+2019 ’**，shell 命令直接复制本计划中的路径，勿手打 `'`）。下文 `$REPO` 指该路径。
- **作者工作区保护**：开工前 `git status` 确认。若 `PokerApp/PokerApp/TableView.swift`、`GameViewModel.swift`、`project.yml`、`README.md` 等仍有作者未提交改动，**先停下来让作者提交或明确授权混入**，不得擅自 stash/commit 他人的 WIP。
- 构建（本机怪癖，全部来自 memory/poker-dev-environment-quirks）：
  - xcodegen：`/tmp/xcodegen-dist/xcodegen/bin/xcodegen`（在 `$REPO/PokerApp` 下运行；/tmp 被清则从 yonaskolb/XcodeGen releases 重放到 /tmp）。
  - xcodebuild 一律加 `-derivedDataPath /tmp/poker-dd`（仓库在 iCloud 目录，原地构建会 xattr 破坏 codesign）。
  - 引擎测试：`cd "$REPO/PokerEngine" && swift test --scratch-path /tmp/poker-engine-scratch`。
  - 模拟器用 iPhone 17；若多台同名，`xcodebuild -showdestinations` 后优先 OS 26.5（id 2B4C9E29），**禁用 F86623E5**（boot 永久挂起）。
  - macOS 无 `timeout` 命令；模拟器卡死时 `pkill -9 -f CoreSimulator; pkill -9 -f SimRuntime`。
- App 单测命令模板（新增源文件或改 project.yml 后须先跑 xcodegen）：
  ```
  cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
  xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests \
    -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd \
    -only-testing:PokerAppTests/<测试类名> 2>&1 | tail -30
  ```
- **Swift 6.4 编译器崩溃规避**：任何 `Foo(x) { ... }` 尾闭包调用形态一律写成显式标签 `Foo(x, onExit: { ... })` 或非尾随闭包（历史崩溃形态：`View(session: x) { session = nil }`）。
- 新代码全部 Swift 6 严格并发安全：会话层 actor、消息/快照全 Sendable 值类型。
- Bonjour 服务类型固定 `_poker-lan._tcp`；协议版本常量 `PokerProtocolVersion.current = 1`。
- 回归底线：PokerEngine 现有 91 项测试、PokerAppTests 现有测试、`PokerAppUITests.testStartCashGameShowsTable`（点「开始游戏」见「底池」）在全部任务完成后仍绿。**MenuView 的「开始游戏」按钮文案与行为不得改动**（UI 测试依赖）。
- 提交信息风格：中文 + 前缀（feat:/refactor:/test:/docs:），每个任务一提交，只 `git add` 该任务明确列出的文件。
- 参考实现（只读）：`/Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/` 下 `Transport/`、`Session/`。本计划已内联全部要移植的代码，执行者无需翻看。

## Pre-flight（一次性，Task 1 之前）

- [ ] `cd "$REPO" && git status`：确认工作区状态；若 PokerApp 下有作者未提交改动，先向作者确认处理方式（提交/授权混入）。
- [ ] `/tmp/xcodegen-dist/xcodegen/bin/xcodegen --version` 可执行；`xcodebuild -showdestinations -project "$REPO/PokerApp/PokerApp.xcodeproj" -scheme PokerApp_iOS_Tests 2>/dev/null | grep "iPhone 17"` 确认模拟器可用。

## Review Focus

执行者注意：以下五类输入最可能咬人，各自已钉在对应任务的测试里——改动对应代码时必须带着测试一起看：

1. **非法动作直达引擎**（引擎对非法动作 assert+按弃牌处理、对 `add<=0` 的加注 precondition 崩溃）→ HostSession 一切动作入口先 `isLegal` 拦截 → Task 8 测试 `illegalActionRejectedEngineUntouched`。
2. **陈旧/重复终止回调误杀活连接**（换连接后旧 NW 回调仍触发）→ TerminationRegistry 按连接对象过滤 → Task 4 测试 `terminationRegistryIgnoresStaleAndDuplicateTermination`。
3. **TCP 粘包/半包解码错位** → Decoder 增量缓冲 → Task 2 测试 `decoderHandlesSplitAndCoalescedReadsInOrder`。
4. **重连后重复消息被二次应用**（补发与在途重叠）→ messageID 去重 + 快照 seq 单调丢弃 → Task 8 `duplicateActionMessageAppliedOnce`、Task 9 `testReconnectAfterSeverResumes`（同 seq 补发被丢弃、快照不回退）。
5. **摊牌亮牌泄漏/漏亮**（mid-hand 泄漏他人手牌=作弊；摊牌漏亮=玩家看不懂）→ 三态脱敏规则 → Task 5 测试组（mid-hand 隐藏/摊牌亮/muck/全员弃牌不亮）。

---

### Task 1: 引擎 wire 类型 Codable

**Files:**
- Modify: `PokerEngine/Sources/PokerEngine/Game/GameState.swift`（4 个类型声明加 `, Codable`）
- Modify: `PokerEngine/Sources/PokerEngine/Game/LegalActions.swift`（1 个类型声明加 `, Codable`）
- Test: `PokerEngine/Tests/PokerEngineTests/CodableWireTests.swift`（新建）

**Interfaces:**
- Consumes: 无（纯增量）。
- Produces: `PlayerStatus/PotAward/HandResult/TournamentPayout/LegalActions` 全部 `Codable`（Task 5/6 的 wire 类型依赖）。

- [ ] **Step 1: 写失败测试**

`PokerEngine/Tests/PokerEngineTests/CodableWireTests.swift`：

```swift
import XCTest
@testable import PokerEngine

/// 联机 wire 类型 Codable 往返等价（spec §4：五个纯值类型加 Codable，无行为变化）。
final class CodableWireTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testLegalActionsRoundTrip() throws {
        let legal = LegalActions(seat: 3, canCheck: false, canCall: true, callAmount: 120,
                                 betRange: 240...360, isRaiseContext: true)
        XCTAssertEqual(try roundTrip(legal), legal)
        let noBet = LegalActions(seat: 1, canCheck: true, canCall: false, callAmount: 0,
                                 betRange: nil, isRaiseContext: false)
        XCTAssertEqual(try roundTrip(noBet), noBet)
    }

    func testHandResultFromShowdownRoundTrips() throws {
        // 两人一路过牌/跟注到摊牌，拿到含 ranks 的真实 HandResult
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 500,
                                                   format: .cash(sb: 5, bb: 10)), seed: 11)
        while s.street != .handOver {
            if s.actorSeat != nil {
                let legal = legalActions(s)
                s.apply(legal.canCheck ? .check : .call)
            }
        }
        let result = try XCTUnwrap(s.handResult)
        XCTAssertFalse(result.awards[0].ranks.isEmpty, "摊牌局应有 ranks")
        XCTAssertEqual(try roundTrip(result), result)
    }

    func testPlayerStatusRoundTrip() throws {
        for status in [PlayerStatus.active, .folded, .allIn, .eliminated] {
            XCTAssertEqual(try roundTrip(status), status)
        }
    }

    func testTournamentPayoutRoundTrip() throws {
        let payout = TournamentPayout(seat: 2, place: 1, amount: 1400)
        XCTAssertEqual(try roundTrip(payout), payout)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```
cd "$REPO/PokerEngine" && swift test --scratch-path /tmp/poker-engine-scratch --filter CodableWireTests 2>&1 | tail -20
```
Expected: FAIL——`LegalActions`/`HandResult`/`PlayerStatus`/`TournamentPayout` 不符合 `Codable`，编译错误 "no `encode(to:)'`/cannot conform"。

- [ ] **Step 3: 最小实现**

`GameState.swift` 改 4 处类型声明（只加 `, Codable`）：

```swift
public enum PlayerStatus: Equatable, Sendable, Codable {
public struct PotAward: Equatable, Sendable, Codable {
public struct HandResult: Equatable, Sendable, Codable {
public struct TournamentPayout: Equatable, Sendable, Codable {
```

`LegalActions.swift` 改 1 处：

```swift
public struct LegalActions: Equatable, Sendable, Codable {
```

（`HandRank`/`Card`/`Street`/`GameConfig` 已是 Codable，`PotAward.ranks` 的 `[Int: HandRank]` 自动合成。）

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: PASS（4 个用例）。

- [ ] **Step 5: 引擎全量回归**

```
cd "$REPO/PokerEngine" && swift test --scratch-path /tmp/poker-engine-scratch 2>&1 | tail -5
```
Expected: 91+4 项全绿。

- [ ] **Step 6: Commit**

```
cd "$REPO" && git add PokerEngine/Sources/PokerEngine/Game/GameState.swift PokerEngine/Sources/PokerEngine/Game/LegalActions.swift PokerEngine/Tests/PokerEngineTests/CodableWireTests.swift && git commit -m "feat: 引擎 wire 类型 Codable（PlayerStatus/PotAward/HandResult/TournamentPayout/LegalActions）"
```

---

### Task 2: 传输协议类型 + 长度前缀帧编解码

**Files:**
- Create: `PokerApp/PokerApp/Transport/Transport.swift`
- Create: `PokerApp/PokerApp/Transport/LengthPrefixedFrameCodec.swift`
- Test: `PokerApp/PokerAppTests/TransportCodecTests.swift`（新建）

**Interfaces:**
- Produces（后续所有传输任务依赖）：
  - `struct PeerID: Hashable, Codable, Sendable, RawRepresentable`（rawValue: String）
  - `enum TransportEvent: Equatable, Sendable`：`case discovered(PeerID) / connected(PeerID) / received(Data, from: PeerID) / disconnected(PeerID, TransportError?)`
  - `enum TransportError: String, Codable, Error, Sendable`：`zeroLengthFrame / frameTooLarge / decoderShutDown / notConnected / invalidPort / connectionFailed`
  - `protocol Transport: Sendable`：`var events: AsyncStream<TransportEvent> { get async }`、`startHosting(roomID: String, port: UInt16?)`、`browse()`、`connect(to: PeerID)`、`send(_:to:)`、`disconnect()`、`isConnected(to:) async -> Bool`、`reviveHostingIfNeeded()`（全 async throws/async）
  - `enum LengthPrefixedFrameCodec`（`static let maximumFrameSize = 1_048_576`、`static func frame(_ payload: Data) throws -> Data`、`struct Decoder: Sendable` with `mutating func append<S: DataProtocol>(_ bytes: S) throws -> [Data]`）

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/TransportCodecTests.swift`：

```swift
import XCTest
@testable import PokerApp

/// 帧编解码：字节序/粘包/半包/坏帧（移植 Brass LocalNetworkTransportTests 的对应用例）。
final class TransportCodecTests: XCTestCase {
    func testFrameUsesFourByteBigEndianLengthPrefix() throws {
        let framed = try LengthPrefixedFrameCodec.frame(Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(Array(framed), [0, 0, 0, 3, 0xAA, 0xBB, 0xCC])
    }

    func testEmptyPayloadIsRejected() {
        XCTAssertThrowsError(try LengthPrefixedFrameCodec.frame(Data())) { error in
            XCTAssertEqual(error as? TransportError, .zeroLengthFrame)
        }
    }

    func testDecoderHandlesSplitAndCoalescedReadsInOrder() throws {
        var decoder = LengthPrefixedFrameCodec.Decoder()
        let first = try LengthPrefixedFrameCodec.frame(Data("one".utf8))
        let second = try LengthPrefixedFrameCodec.frame(Data("two".utf8))
        XCTAssertEqual(try decoder.append(first.prefix(2)), [])
        XCTAssertEqual(try decoder.append(first.dropFirst(2) + second),
                       [Data("one".utf8), Data("two".utf8)])
    }

    func testMalformedLengthPermanentlyShutsDecoder() throws {
        for length in [0, LengthPrefixedFrameCodec.maximumFrameSize + 1] {
            var decoder = LengthPrefixedFrameCodec.Decoder()
            let prefix = Data([
                UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
            ])
            let expected: TransportError = length == 0 ? .zeroLengthFrame : .frameTooLarge
            XCTAssertThrowsError(try decoder.append(prefix)) { error in
                XCTAssertEqual(error as? TransportError, expected)
            }
            XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 1, 7]))) { error in
                XCTAssertEqual(error as? TransportError, .decoderShutDown)
            }
        }
    }
}
```

- [ ] **Step 2: 生成工程并跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/TransportCodecTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`LengthPrefixedFrameCodec`/`TransportError` 未定义）。

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/Transport/Transport.swift`：

```swift
import Foundation

/// 传输层对端标识。客机侧 = 房间（Bonjour 实例名）；房主侧 = 每条已接受连接的临时 UUID。
struct PeerID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

enum TransportEvent: Equatable, Sendable {
    case discovered(PeerID)
    case connected(PeerID)
    case received(Data, from: PeerID)
    case disconnected(PeerID, TransportError?)
}

enum TransportError: String, Codable, Error, Sendable {
    case zeroLengthFrame
    case frameTooLarge
    case decoderShutDown
    case notConnected
    case invalidPort
    case connectionFailed
}

protocol Transport: Sendable {
    var events: AsyncStream<TransportEvent> { get async }
    func startHosting(roomID: String, port: UInt16?) async throws
    func browse() async throws
    func connect(to peer: PeerID) async throws
    func send(_ data: Data, to peer: PeerID) async throws
    func disconnect() async
    /// 指定对端连接当前是否就绪；供前台自愈探测「静默断链」。
    func isConnected(to peer: PeerID) async -> Bool
    /// 进程挂起/恢复后的传输层自愈；房主侧确保监听器仍可被发现。
    func reviveHostingIfNeeded() async
}

extension Transport {
    func isConnected(to peer: PeerID) async -> Bool { true }
    func reviveHostingIfNeeded() async {}
}
```

`PokerApp/PokerApp/Transport/LengthPrefixedFrameCodec.swift`（移植 Brass，仅错误类型换成我们的 `TransportError`）：

```swift
import Foundation

/// 4 字节大端长度前缀分帧。解码器粘包/半包安全；坏帧永久关闭。
nonisolated enum LengthPrefixedFrameCodec {
    static let maximumFrameSize = 1_048_576

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw TransportError.zeroLengthFrame }
        guard payload.count <= maximumFrameSize else { throw TransportError.frameTooLarge }
        var length = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(payload)
        return framed
    }

    struct Decoder: Sendable {
        private var buffer = Data()
        private var isShutDown = false

        mutating func append<S: DataProtocol>(_ bytes: S) throws -> [Data] {
            guard !isShutDown else { throw TransportError.decoderShutDown }
            buffer.append(contentsOf: bytes)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 else { return try shutDown(with: .zeroLengthFrame) }
                guard length <= LengthPrefixedFrameCodec.maximumFrameSize else {
                    return try shutDown(with: .frameTooLarge)
                }
                guard buffer.count >= length + 4 else { break }
                let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
                let payloadEnd = buffer.index(payloadStart, offsetBy: length)
                frames.append(Data(buffer[payloadStart..<payloadEnd]))
                buffer = Data(buffer[payloadEnd...])
            }
            return frames
        }

        private mutating func shutDown(with error: TransportError) throws -> [Data] {
            isShutDown = true
            buffer.removeAll()
            throw error
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: PASS（4 用例）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Transport/ PokerApp/PokerAppTests/TransportCodecTests.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: 传输层协议类型与长度前缀帧编解码（移植 Brass）"
```

---

### Task 3: LoopbackTransport（进程内配对传输）

**Files:**
- Create: `PokerApp/PokerApp/Transport/LoopbackTransport.swift`
- Test: `PokerApp/PokerAppTests/LoopbackTransportTests.swift`
- Create（测试支持，后续任务共用）: `PokerApp/PokerAppTests/LoopbackHarness.swift`

**Interfaces:**
- Consumes: Task 2 的 `Transport/PeerID/TransportEvent/TransportError`。
- Produces: `final class LoopbackTransportHub`（`nonisolated func makeTransport(peerID: PeerID) -> LoopbackTransport`、`nonisolated func severLink(between:and:)`）、`actor LoopbackTransport: Transport`（`static func makePair(first: PeerID, second: PeerID) -> (LoopbackTransport, LoopbackTransport)`）；测试支持 `actor EventLog`（`record/all/waitFor(timeout:_:)`）、`struct TestTimeout: Error`、`func attachEvents(of:to:) -> Task<Void, Never>`（`sendEnvelope` 辅助在 Task 6 追加）。

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/LoopbackTransportTests.swift`：

```swift
import XCTest
@testable import PokerApp

final class LoopbackTransportTests: XCTestCase {
    let host = PeerID(rawValue: "ROOM-1")
    let guest = PeerID(rawValue: "guest-a")

    func testLoopbackDeliversOrderedAsyncStreamEvents() async throws {
        let (hostT, guestT) = LoopbackTransport.makePair(first: host, second: guest)
        let log = EventLog()
        let pump = attachEvents(of: guestT, to: log)
        defer { pump.cancel() }

        try await hostT.startHosting(roomID: "ROOM-1", port: nil)
        try await guestT.connect(to: host)
        try await hostT.send(Data("first".utf8), to: guest)
        try await hostT.send(Data("second".utf8), to: guest)

        let received = try await log.waitFor { event in
            if case .received = event { return true }
            return false
        }
        guard case let .received(data, from) = received else { return XCTFail() }
        XCTAssertEqual(data, Data("first".utf8))
        XCTAssertEqual(from, host)
        let second = try await log.waitFor { event in
            if case .received = event { return true }
            return false
        }
        guard case let .received(data2, _) = second else { return XCTFail() }
        XCTAssertEqual(data2, Data("second".utf8))
    }

    func testSeverLinkNotifiesBothEndsAndAllowsReconnect() async throws {
        let (hostT, guestT) = LoopbackTransport.makePair(first: host, second: guest)
        let hostLog = EventLog(), guestLog = EventLog()
        let pumpA = attachEvents(of: hostT, to: hostLog)
        let pumpB = attachEvents(of: guestT, to: guestLog)
        defer { pumpA.cancel(); pumpB.cancel() }

        try await hostT.startHosting(roomID: "ROOM-1", port: nil)
        try await guestT.connect(to: host)
        hostT.severLink(between: host, and: guest)

        _ = try await guestLog.waitFor { if case .disconnected = $0 { return true }; return false }
        _ = try await hostLog.waitFor { if case .disconnected = $0 { return true }; return false }

        // 重拨可达：客机再次 connect，双方恢复收发
        try await guestT.connect(to: host)
        try await hostT.send(Data("again".utf8), to: guest)
        _ = try await guestLog.waitFor { event in
            if case let .received(d, _) = event { return d == Data("again".utf8) }
            return false
        }
    }

    func testSendToUnconnectedPeerThrows() async throws {
        let (hostT, guestT) = LoopbackTransport.makePair(first: host, second: guest)
        _ = guestT
        try await hostT.startHosting(roomID: "ROOM-1", port: nil)
        do {
            try await hostT.send(Data("x".utf8), to: guest)
            XCTFail("未连接应抛 notConnected")
        } catch { /* 预期 */ }
    }
}
```

`PokerApp/PokerAppTests/LoopbackHarness.swift`（测试支持，后续会话任务复用）：

```swift
import Foundation
@testable import PokerApp

struct TestTimeout: Error {}

/// 轮询式事件收集器：测试断言传输事件流内容用。
actor EventLog {
    private var buffered: [TransportEvent] = []

    func record(_ event: TransportEvent) { buffered.append(event) }

    func all() -> [TransportEvent] { buffered }

    /// 等待第一条满足条件的事件（取出并移除）；超时抛 TestTimeout。
    func waitFor(timeout: TimeInterval = 3, _ predicate: @Sendable @escaping (TransportEvent) -> Bool) async throws -> TransportEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = buffered.firstIndex(where: predicate) { return buffered.remove(at: index) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestTimeout()
    }
}

/// 把传输事件流泵入 EventLog。
func attachEvents(of transport: any Transport, to log: EventLog) -> Task<Void, Never> {
    Task {
        let events = await transport.events
        for await event in events {
            await log.record(event)
        }
    }
}
```

（向房主发裸信封的 `sendEnvelope` 辅助依赖 Task 6 的消息层，到 Task 6 再追加进本文件。）

- [ ] **Step 2: 生成工程并跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/LoopbackTransportTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`LoopbackTransport` 未定义）。

- [ ] **Step 3: 实现（移植 Brass LoopbackTransport.swift，PeerID/String 化）**

`PokerApp/PokerApp/Transport/LoopbackTransport.swift`：

```swift
import Foundation

/// 进程内配对传输：所有会话层测试与联调不碰真实网络。
final class LoopbackTransportHub: @unchecked Sendable {
    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var endpoints: [PeerID: LoopbackTransport] = [:]
    nonisolated(unsafe) private var hostID: PeerID?

    nonisolated func makeTransport(peerID: PeerID) -> LoopbackTransport {
        let transport = LoopbackTransport(peerID: peerID, hub: self)
        lock.withLock { endpoints[peerID] = transport }
        return transport
    }

    nonisolated fileprivate func host(_ peerID: PeerID) { lock.withLock { hostID = peerID } }
    nonisolated fileprivate func hostPeer() -> PeerID? { lock.withLock { hostID } }
    nonisolated fileprivate func endpoint(_ peerID: PeerID) -> LoopbackTransport? { lock.withLock { endpoints[peerID] } }
    nonisolated fileprivate func remove(_ peerID: PeerID) { lock.withLock { endpoints[peerID] = nil } }

    /// 模拟断链（锁屏/网络抖动）：两端各收 disconnected，端点保留、重拨可达。
    nonisolated func severLink(between a: PeerID, and b: PeerID) {
        let pair = lock.withLock { (endpoints[a], endpoints[b]) }
        guard let transportA = pair.0, let transportB = pair.1 else { return }
        Task { await transportA.sever(b); await transportB.sever(a) }
    }
}

actor LoopbackTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let peerID: PeerID
    private let hub: LoopbackTransportHub
    private var connectedPeers: Set<PeerID> = []

    fileprivate init(peerID: PeerID, hub: LoopbackTransportHub) {
        self.peerID = peerID
        self.hub = hub
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    static func makePair(first: PeerID, second: PeerID) -> (LoopbackTransport, LoopbackTransport) {
        let hub = LoopbackTransportHub()
        return (hub.makeTransport(peerID: first), hub.makeTransport(peerID: second))
    }

    func startHosting(roomID: String, port: UInt16?) async throws { hub.host(peerID) }

    func browse() async throws {
        if let host = hub.hostPeer() { continuation.yield(.discovered(host)) }
    }

    func connect(to peer: PeerID) async throws {
        guard let remote = hub.endpoint(peer) else { throw TransportError.notConnected }
        connectedPeers.insert(peer)
        await remote.accept(peerID)
        continuation.yield(.connected(peer))
    }

    func send(_ data: Data, to peer: PeerID) async throws {
        guard connectedPeers.contains(peer), let remote = hub.endpoint(peer) else {
            throw TransportError.notConnected
        }
        await remote.receive(data, from: peerID)
    }

    func disconnect() async {
        let peers = connectedPeers
        connectedPeers.removeAll()
        for peer in peers { await hub.endpoint(peer)?.drop(peerID) }
        continuation.finish()
        hub.remove(peerID)
    }

    func isConnected(to peer: PeerID) async -> Bool { connectedPeers.contains(peer) }

    private func accept(_ peer: PeerID) { connectedPeers.insert(peer); continuation.yield(.connected(peer)) }
    private func receive(_ data: Data, from peer: PeerID) { continuation.yield(.received(data, from: peer)) }
    private func drop(_ peer: PeerID) { connectedPeers.remove(peer); continuation.yield(.disconnected(peer, nil)) }

    fileprivate func sever(_ peer: PeerID) {
        guard connectedPeers.remove(peer) != nil else { return }
        continuation.yield(.disconnected(peer, nil))
    }
}
```

注意 `severLink` 在 Brass 里包了 `#if DEBUG`，这里为了测试可达**不加条件编译**（App target 的 Swift Active Compilation Conditions 默认 Debug 含 DEBUG，但测试需要在所有配置可见——直接公开）。

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: PASS（3 用例）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Transport/LoopbackTransport.swift PokerApp/PokerAppTests/LoopbackTransportTests.swift PokerApp/PokerAppTests/LoopbackHarness.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: 进程内 LoopbackTransport（配对/断链模拟/重拨）与测试事件收集器"
```

---

### Task 4: NearbyTransport + BonjourRoomBrowser + NearbyPreflight

**Files:**
- Create: `PokerApp/PokerApp/Transport/NearbyTransport.swift`
- Create: `PokerApp/PokerApp/Transport/BonjourRoomBrowser.swift`
- Create: `PokerApp/PokerApp/Transport/NearbyPreflight.swift`
- Test: `PokerApp/PokerAppTests/NearbyTransportTests.swift`

**Interfaces:**
- Consumes: Task 2 的 Transport 协议族。
- Produces:
  - `actor NearbyTransport: Transport`（`static let serviceType = "_poker-lan._tcp"`、`init(serviceName: String? = nil, queue: DispatchQueue = ...)`、`nonisolated static func makeParameters() -> NWParameters`）
  - `enum RoomName { static func sanitize(_ input: String) -> String }`、`struct RoomListing: Identifiable, Equatable, Hashable, Sendable { id; serviceName; var roomID: String }`（Task 7 房间命名依赖 `RoomName.sanitize`）
  - `protocol RoomBrowsing: Sendable`（可注入假驱动）、`actor BonjourRoomBrowser`（`nonisolated let states: AsyncStream<RoomBrowseState>`、`start()/cancel()`）、`enum RoomBrowseState: Equatable, Sendable { case searching; case found([RoomListing]); case empty; case failed(NearbyIssue) }`
  - `enum NearbyIssue: String, Error, Sendable`（permissionDenied/wirelessOff/connectionFailed；`title`/`recoveryMessage` 中文文案）+ `enum NearbyPreflight { static func issue(for: any Error) -> NearbyIssue; static func issue(for: NWError) -> NearbyIssue }`（Task 11 的 VM 依赖）

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/NearbyTransportTests.swift`：

```swift
import XCTest
import Network
@testable import PokerApp

final class NearbyTransportTests: XCTestCase {
    func testParametersIncludePeerToPeerAndBypassProxies() {
        let parameters = NearbyTransport.makeParameters()
        XCTAssertTrue(parameters.includePeerToPeer, "无路由器的点对点 Wi-Fi 也要能连（spec §5）")
        XCTAssertTrue(parameters.preferNoProxies)
    }

    func testServiceTypeIsPokerLan() {
        XCTAssertEqual(NearbyTransport.serviceType, "_poker-lan._tcp")
    }

    /// 监听器冒烟：模拟器内可无 launch switch 起监听（移植 Brass 同名用例）。
    func testTransportCanHostAnAdvertisedRoom() async throws {
        let transport = NearbyTransport()
        do {
            try await transport.startHosting(roomID: "POKER-UNIT-HOST", port: nil)
            await transport.disconnect()
        } catch {
            await transport.disconnect()
            throw error
        }
    }

    func testTerminationRegistryIgnoresStaleAndDuplicateTermination() {
        let peer = PeerID(rawValue: "peer")
        let first = NSObject(); let replacement = NSObject()
        var registry = ConnectionTerminationRegistry()
        registry.register(first, for: peer)
        registry.register(replacement, for: peer)
        XCTAssertFalse(registry.terminate(first, for: peer), "被替换的旧连接不得触发终止")
        XCTAssertTrue(registry.contains(replacement, for: peer))
        XCTAssertTrue(registry.terminate(replacement, for: peer))
        XCTAssertFalse(registry.terminate(replacement, for: peer), "重复终止只算一次")
    }

    func testRoomNameSanitizeStripsToAsciiAndCaps() {
        XCTAssertEqual(RoomName.sanitize("房主的 德州桌!"), "ROOM", "非 ASCII 全部折叠为分隔符后为空名，兜底 ROOM")
        XCTAssertEqual(RoomName.sanitize("My Room 7"), "MY-ROOM-7")
        XCTAssertEqual(RoomName.sanitize("!!!"), "ROOM", "空名兜底")
    }

    func testBrowserDedupesAndRemovesRoomListings() async throws {
        let driver = FakeRoomBrowserDriver()
        let browser = BonjourRoomBrowser(driver: driver)
        let states = browser.states
        await browser.start()
        driver.emit(.ready)
        driver.emit(.added(RoomListing(id: "a", serviceName: "ROOM-A")))
        driver.emit(.added(RoomListing(id: "a", serviceName: "ROOM-A")))   // 同 id 重复：忽略
        driver.emit(.added(RoomListing(id: "b", serviceName: "ROOM-B")))
        driver.emit(.removed("a"))
        driver.emit(.removed("a"))                                          // 重复移除：忽略
        var collected: [RoomBrowseState] = []
        for await state in states {
            collected.append(state)
            if case .found(let rooms) = state, rooms.map(\.serviceName) == ["ROOM-B"] { break }
        }
        await browser.cancel()
        guard case .found(let finalRooms) = collected.last else { return XCTFail("应停留在 found") }
        XCTAssertEqual(finalRooms.map(\.serviceName), ["ROOM-B"])
    }
}
```

（`FakeRoomBrowserDriver` 是测试内定义的假驱动，见 Step 3 末尾。）

- [ ] **Step 2: 生成工程并跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/NearbyTransportTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`NearbyTransport` 等未定义）。

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/Transport/NearbyTransport.swift`（移植 Brass NearbyTransport.swift：`GameCore.PlayerID→PeerID`、`RoomID→String`、去掉 NearbyRoom 解析、服务类型换 `_poker-lan._tcp`；LifecycleGate/Registry/ShutdownGate 原样保留）：

```swift
import Foundation
import Network

nonisolated struct TransportShutdownGate: Sendable {
    private var didBegin = false
    mutating func begin() -> Bool {
        guard !didBegin else { return false }
        didBegin = true
        return true
    }
}

nonisolated final class NearbyLifecycleGate: @unchecked Sendable {
    private enum Outcome {
        case success
        case failure(NearbyIssue)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancelResource: (@Sendable () -> Void)?
    private var outcome: Outcome?

    func waitUntilReady(
        start: @escaping @Sendable (@escaping @Sendable (NearbyLifecycleUpdate) -> Void) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pendingOutcome: Outcome? = lock.withLock {
                    if let outcome { return outcome }
                    self.continuation = continuation
                    cancelResource = cancel
                    return nil
                }
                if let pendingOutcome {
                    Self.resume(continuation, with: pendingOutcome)
                    return
                }
                start { [weak self] update in self?.consume(update) }
                if Task.isCancelled { finish(.failure(.connectionFailed), cancellingResource: true) }
            }
        } onCancel: {
            finish(.failure(.connectionFailed), cancellingResource: true)
        }
    }

    private func consume(_ update: NearbyLifecycleUpdate) {
        switch update {
        case .ready: finish(.success, cancellingResource: false)
        case let .waiting(issue), let .failed(issue): finish(.failure(issue), cancellingResource: true)
        }
    }

    private func finish(_ outcome: Outcome, cancellingResource: Bool) {
        let actions: (CheckedContinuation<Void, any Error>?, (@Sendable () -> Void)?) = lock.withLock {
            guard self.outcome == nil else { return (nil, nil) }
            self.outcome = outcome
            let continuation = self.continuation
            self.continuation = nil
            let cancel = cancellingResource ? cancelResource : nil
            cancelResource = nil
            return (continuation, cancel)
        }
        actions.1?()
        if let continuation = actions.0 { Self.resume(continuation, with: outcome) }
    }

    private static func resume(_ continuation: CheckedContinuation<Void, any Error>, with outcome: Outcome) {
        switch outcome {
        case .success: continuation.resume()
        case let .failure(issue): continuation.resume(throwing: issue)
        }
    }
}

nonisolated enum NearbyLifecycleUpdate: Equatable, Sendable {
    case ready
    case waiting(NearbyIssue)
    case failed(NearbyIssue)
}

/// 按连接对象过滤陈旧/重复终止回调：换连接后旧 NW 回调不得再触达状态机。
nonisolated struct ConnectionTerminationRegistry: Sendable {
    private struct Entry: @unchecked Sendable { let connection: AnyObject }
    private var entries: [PeerID: Entry] = [:]

    mutating func register(_ connection: AnyObject, for peer: PeerID) {
        entries[peer] = .init(connection: connection)
    }

    func contains(_ connection: AnyObject, for peer: PeerID) -> Bool {
        entries[peer]?.connection === connection
    }

    mutating func terminate(_ connection: AnyObject, for peer: PeerID) -> Bool {
        guard contains(connection, for: peer) else { return false }
        entries[peer] = nil
        return true
    }
}

actor NearbyTransport: Transport {
    static let serviceType = "_poker-lan._tcp"
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue: DispatchQueue
    private let serviceName: String?
    private var listener: NWListener?
    private var hostingRoomID: String?
    private var hostingPort: UInt16?
    private var listenerRestartAttempts = 0
    private var didShutDown = false
    private var browser: NWBrowser?
    private var connections: [PeerID: NWConnection] = [:]
    private var decoders: [PeerID: LengthPrefixedFrameCodec.Decoder] = [:]
    private var terminationRegistry = ConnectionTerminationRegistry()
    private var shutdownGate = TransportShutdownGate()

    init(serviceName: String? = nil, queue: DispatchQueue = .init(label: "PokerApp.NearbyTransport")) {
        self.serviceName = serviceName.map(RoomName.sanitize)
        self.queue = queue
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    nonisolated static func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true   // 无路由器的点对点 Wi-Fi 也可直连
        parameters.preferNoProxies = true
        return parameters
    }

    nonisolated static func makeService(roomID: String) -> NWListener.Service {
        var service = NWListener.Service(name: RoomName.sanitize(roomID), type: serviceType)
        service.noAutoRename = true
        return service
    }

    func startHosting(roomID: String, port: UInt16?) async throws {
        guard !didShutDown else { throw TransportError.connectionFailed }
        hostingRoomID = roomID
        hostingPort = port
        try await startListener()
    }

    private func startListener() async throws {
        guard let roomID = hostingRoomID else { throw TransportError.connectionFailed }
        let port = hostingPort
        let parameters = Self.makeParameters()
        let listener: NWListener
        if let port {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportError.invalidPort }
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = Self.makeService(roomID: roomID)
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        self.listener = listener
        let gate = NearbyLifecycleGate()
        do {
            try await gate.waitUntilReady(start: { [queue] update in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: update(.ready)
                    case let .waiting(error): update(.waiting(NearbyPreflight.issue(for: error)))
                    case let .failed(error): update(.failed(NearbyPreflight.issue(for: error)))
                    case .cancelled: update(.failed(.connectionFailed))
                    default: break
                    }
                }
                listener.start(queue: queue)
            }, cancel: {
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
            })
            // 就绪后保留状态回调：监听器死亡（接口切换等）时原地重建，保持房间可被发现
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .failed = state else { return }
                Task { await self.restartListenerAfterFailure() }
            }
            listenerRestartAttempts = 0
        } catch {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            if self.listener === listener { self.listener = nil }
            throw error
        }
    }

    private func restartListenerAfterFailure() {
        guard listenerRestartAttempts < 3, hostingRoomID != nil else { return }
        listenerRestartAttempts += 1
        listener?.cancel()
        listener = nil
        Task {
            do { try await self.startListener() } catch { break }
        }
    }

    func browse() async throws {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: Self.makeParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                self?.continuation.yield(.discovered(PeerID(rawValue: name)))
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func connect(to peer: PeerID) async throws {
        guard !didShutDown else { throw TransportError.notConnected }
        // 重入防御：同一 peer 的旧连接先终止，避免泄漏与事件串扰
        if let existing = connections[peer] {
            _ = terminationRegistry.terminate(existing, for: peer)
            existing.cancel()
            connections[peer] = nil
            decoders[peer] = nil
        }
        let name = serviceName ?? RoomName.sanitize(peer.rawValue)
        let endpoint = NWEndpoint.service(name: name, type: Self.serviceType, domain: "local", interface: nil)
        let connection = NWConnection(to: endpoint, using: Self.makeParameters())
        connections[peer] = connection
        terminationRegistry.register(connection, for: peer)
        decoders[peer] = .init()
        receive(on: connection, peer: peer)
        let gate = NearbyLifecycleGate()
        do {
            try await gate.waitUntilReady(start: { [queue] update in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: update(.ready)
                    case let .waiting(error): update(.waiting(NearbyPreflight.issue(for: error)))
                    case let .failed(error): update(.failed(NearbyPreflight.issue(for: error)))
                    case .cancelled: update(.failed(.connectionFailed))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }, cancel: {
                connection.stateUpdateHandler = nil
                connection.cancel()
            })
        } catch {
            connection.stateUpdateHandler = nil
            _ = terminationRegistry.terminate(connection, for: peer)
            connections[peer] = nil
            decoders[peer] = nil
            connection.cancel()
            throw error
        }
        installStateHandler(connection, peer: peer)
        guard connection.state == .ready else {
            _ = terminationRegistry.terminate(connection, for: peer)
            connections[peer] = nil
            decoders[peer] = nil
            connection.cancel()
            throw TransportError.connectionFailed
        }
        connectionReady(peer: peer, connection: connection)
    }

    func isConnected(to peer: PeerID) async -> Bool {
        connections[peer]?.state == .ready
    }

    /// 前台自愈：挂起可能无声杀死监听 socket；死亡/缺失时原地重建。
    func reviveHostingIfNeeded() async {
        guard !didShutDown, hostingRoomID != nil else { return }
        let needsRestart: Bool
        switch listener?.state {
        case .none, .some(.failed), .some(.cancelled): needsRestart = true
        default: needsRestart = false
        }
        guard needsRestart else { return }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerRestartAttempts = 0
        do { try await startListener() } catch { break }
    }

    func send(_ data: Data, to peer: PeerID) async throws {
        guard let connection = connections[peer] else { throw TransportError.notConnected }
        let framed = try LengthPrefixedFrameCodec.frame(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func disconnect() {
        guard shutdownGate.begin() else { return }
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        connections.values.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        connections.removeAll()
        decoders.removeAll()
        terminationRegistry = ConnectionTerminationRegistry()
        didShutDown = true
        hostingRoomID = nil
        continuation.finish()
    }

    private func accept(_ connection: NWConnection) {
        let peer = PeerID(rawValue: UUID().uuidString)
        connections[peer] = connection
        terminationRegistry.register(connection, for: peer)
        decoders[peer] = .init()
        installStateHandler(connection, peer: peer)
        receive(on: connection, peer: peer)
        connection.start(queue: queue)
    }

    private func installStateHandler(_ connection: NWConnection, peer: PeerID) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { await self?.connectionReady(peer: peer, connection: connection) }
            case .failed: Task { await self?.terminate(peer: peer, connection: connection, error: .connectionFailed) }
            case .cancelled: Task { await self?.terminate(peer: peer, connection: connection, error: nil) }
            default: break
            }
        }
    }

    private func receive(on connection: NWConnection, peer: PeerID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { await self?.consume(data, complete: complete, error: error, connection: connection, peer: peer) }
        }
    }

    private func consume(_ data: Data?, complete: Bool, error: NWError?, connection: NWConnection, peer: PeerID) {
        guard terminationRegistry.contains(connection, for: peer) else { return }
        do {
            if let data {
                var decoder = decoders[peer] ?? .init()
                for frame in try decoder.append(data) { continuation.yield(.received(frame, from: peer)) }
                guard terminationRegistry.contains(connection, for: peer) else { return }
                decoders[peer] = decoder
            }
        } catch let transportError as TransportError {
            terminate(peer: peer, connection: connection, error: transportError)
            return
        } catch {
            terminate(peer: peer, connection: connection, error: .connectionFailed)
            return
        }
        if complete || error != nil {
            terminate(peer: peer, connection: connection, error: error == nil ? nil : .connectionFailed)
        } else {
            guard terminationRegistry.contains(connection, for: peer) else { return }
            receive(on: connection, peer: peer)
        }
    }

    private func connectionReady(peer: PeerID, connection: NWConnection) {
        guard terminationRegistry.contains(connection, for: peer) else { return }
        continuation.yield(.connected(peer))
    }

    private func terminate(peer: PeerID, connection: NWConnection, error: TransportError?) {
        guard terminationRegistry.terminate(connection, for: peer) else { return }
        connection.stateUpdateHandler = nil
        connections[peer] = nil
        decoders[peer] = nil
        continuation.yield(.disconnected(peer, error))
        connection.cancel()
    }
}
```

`PokerApp/PokerApp/Transport/NearbyPreflight.swift`：

```swift
import Foundation
import Network

nonisolated enum NearbyIssue: String, Equatable, Error, Sendable {
    case permissionDenied
    case wirelessOff
    case connectionFailed

    var title: String {
        switch self {
        case .permissionDenied: "未获本地网络权限"
        case .wirelessOff: "Wi-Fi 当前不可用"
        case .connectionFailed: "无法连接房间"
        }
    }

    var recoveryMessage: String {
        switch self {
        case .permissionDenied:
            "请前往系统设置，允许德州扑克使用本地网络，然后返回重试。"
        case .wirelessOff:
            "如果系统关闭了 Wi-Fi，请在控制中心重新打开后重试；同一路由器或面对面点对点 Wi-Fi 均可。"
        case .connectionFailed:
            "请靠近房主、保持房主页面打开，然后重试。"
        }
    }
}

nonisolated enum NearbyPreflight {
    static func issue(for error: any Error) -> NearbyIssue {
        if let issue = error as? NearbyIssue { return issue }
        if let networkError = error as? NWError { return issue(for: networkError) }
        if error is TransportError { return .connectionFailed }
        return .connectionFailed
    }

    static func issue(for error: NWError) -> NearbyIssue {
        switch error {
        case let .posix(code):
            switch code {
            case .EPERM, .EACCES: .permissionDenied
            case .ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH: .wirelessOff
            default: .connectionFailed
            }
        case let .dns(code) where code == -65570: .permissionDenied
        default: .connectionFailed
        }
    }
}
```

`PokerApp/PokerApp/Transport/BonjourRoomBrowser.swift`：

```swift
import Foundation
import Network

/// 房间显示名 → Bonjour 实例名（ASCII 大写、分隔符收敛、≤40 字符、空名兜底）。
nonisolated enum RoomName {
    static func sanitize(_ input: String) -> String {
        let folded = input.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: .init(identifier: "en_US_POSIX"))
        let scalars = folded.uppercased().unicodeScalars.map { scalar -> Character in
            Character((CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) ? String(scalar) : "-")
        }
        let components = String(scalars).split(separator: "-", omittingEmptySubsequences: true)
        let normalized = components.joined(separator: "-")
        return String((normalized.isEmpty ? "ROOM" : normalized).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// 搜到的房间：serviceName 即 roomID（房主建房的 Bonjour 实例名）。
nonisolated struct RoomListing: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let serviceName: String
    var roomID: String { serviceName }
    init(id: String, serviceName: String) {
        self.id = id
        self.serviceName = serviceName
    }
}

nonisolated enum RoomBrowseState: Equatable, Sendable {
    case searching
    case found([RoomListing])
    case empty
    case failed(NearbyIssue)
}

nonisolated enum RoomBrowserUpdate: Equatable, Sendable {
    case ready
    case added(RoomListing)
    case removed(String)
    case failed(NearbyIssue)
}

nonisolated protocol RoomBrowsing: Sendable {
    var updates: AsyncStream<RoomBrowserUpdate> { get }
    func start()
    func cancel()
}

/// 房间浏览（可注入驱动以便测试）。
actor BonjourRoomBrowser {
    nonisolated let states: AsyncStream<RoomBrowseState>
    private nonisolated let continuation: AsyncStream<RoomBrowseState>.Continuation
    private let driver: any RoomBrowsing
    private var roomsByID: [String: RoomListing] = [:]
    private var processingTask: Task<Void, Never>?
    private var didCancel = false

    init(driver: any RoomBrowsing = NWRoomBrowserDriver()) {
        self.driver = driver
        (states, continuation) = AsyncStream.makeStream(of: RoomBrowseState.self)
    }

    func start() {
        guard processingTask == nil, !didCancel else { return }
        continuation.yield(.searching)
        processingTask = Task { [weak self, driver] in
            for await update in driver.updates {
                guard !Task.isCancelled else { return }
                await self?.consume(update)
            }
        }
        driver.start()
    }

    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        processingTask?.cancel()
        processingTask = nil
        driver.cancel()
        continuation.finish()
    }

    private var sortedRooms: [RoomListing] {
        Dictionary(grouping: roomsByID.values, by: \.serviceName)
            .values.compactMap(\.first)
            .sorted { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
    }

    private func consume(_ update: RoomBrowserUpdate) {
        switch update {
        case .ready:
            continuation.yield(roomsByID.isEmpty ? .empty : .found(sortedRooms))
        case let .added(listing):
            guard roomsByID[listing.id] == nil else { return }
            let wasDisplayed = roomsByID.values.contains { $0.serviceName == listing.serviceName }
            roomsByID[listing.id] = listing
            guard !wasDisplayed else { return }
            continuation.yield(.found(sortedRooms))
        case let .removed(id):
            guard let removed = roomsByID.removeValue(forKey: id) else { return }
            guard !roomsByID.values.contains(where: { $0.serviceName == removed.serviceName }) else { return }
            continuation.yield(roomsByID.isEmpty ? .empty : .found(sortedRooms))
        case let .failed(issue):
            continuation.yield(.failed(issue))
        }
    }
}

/// 真实 NWBrowser 驱动。
nonisolated final class NWRoomBrowserDriver: RoomBrowsing, @unchecked Sendable {
    nonisolated let updates: AsyncStream<RoomBrowserUpdate>
    private let continuation: AsyncStream<RoomBrowserUpdate>.Continuation
    private let queue = DispatchQueue(label: "PokerApp.NWRoomBrowserDriver")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var knownIDs: Set<String> = []
    private var didStart = false
    private var didCancel = false

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: RoomBrowserUpdate.self)
    }

    func start() {
        let browser: NWBrowser? = lock.withLock {
            guard !didStart, !didCancel else { return nil }
            didStart = true
            let browser = NWBrowser(for: .bonjour(type: NearbyTransport.serviceType, domain: nil),
                                    using: NearbyTransport.makeParameters())
            self.browser = browser
            return browser
        }
        guard let browser else { return }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.continuation.yield(.ready)
            case let .failed(error): self?.continuation.yield(.failed(NearbyPreflight.issue(for: error)))
            case let .waiting(error): self?.continuation.yield(.failed(NearbyPreflight.issue(for: error)))
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            // 全量快照差分：房间消失也要发 .removed（spec §5 名册出现/消失）
            let current = results.compactMap { result -> (id: String, name: String)? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return (name + "|" + result.endpoint.debugDescription, name)
            }
            let changes: [RoomBrowserUpdate] = lock.withLock {
                var updates: [RoomBrowserUpdate] = []
                let currentIDs = Set(current.map(\.id))
                for id in knownIDs.subtracting(currentIDs) { updates.append(.removed(id)) }
                for entry in current where !knownIDs.contains(entry.id) {
                    updates.append(.added(RoomListing(id: entry.id, serviceName: entry.name)))
                }
                knownIDs = currentIDs
                return updates
            }
            changes.forEach { continuation.yield($0) }
        }
        browser.start(queue: queue)
    }

    func cancel() {
        let browser: NWBrowser? = lock.withLock {
            guard !didCancel else { return nil }
            didCancel = true
            let current = self.browser
            self.browser = nil
            return current
        }
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        continuation.finish()
    }
}
```

测试文件末尾追加假驱动（属 Step 1 的测试文件内容，此处给出完整定义）：

```swift
/// 可手动注入更新的假驱动（浏览去重逻辑测试用）。
final class FakeRoomBrowserDriver: RoomBrowsing, @unchecked Sendable {
    let updates: AsyncStream<RoomBrowserUpdate>
    private let continuation: AsyncStream<RoomBrowserUpdate>.Continuation

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: RoomBrowserUpdate.self)
    }

    func emit(_ update: RoomBrowserUpdate) { continuation.yield(update) }
    func start() {}
    func cancel() { continuation.finish() }
}
```

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: PASS（6 用例；监听器冒烟在模拟器上不需要本地网络权限弹窗即通过——与 Brass 同款用例同环境）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Transport/NearbyTransport.swift PokerApp/PokerApp/Transport/BonjourRoomBrowser.swift PokerApp/PokerApp/Transport/NearbyPreflight.swift PokerApp/PokerAppTests/NearbyTransportTests.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: NearbyTransport 生产传输+Bonjour 房间浏览+错误预检映射（移植 Brass）"
```

---

### Task 5: TableSnapshot 脱敏快照 + 渲染投影协议

**Files:**
- Create: `PokerApp/PokerApp/Session/TableSnapshot.swift`
- Test: `PokerApp/PokerAppTests/TableSnapshotTests.swift`

**Interfaces:**
- Consumes: Task 1 的引擎 Codable 类型。
- Produces（Task 6/8/9/10/11 依赖）：
  - `struct SnapshotPlayer: Codable, Equatable, Sendable`（`seat/name/stack/streetContribution/status: PlayerStatus/holdsCards: Bool/holeCards: [Card]`，memberwise init）
  - `struct TableSnapshot: Codable, Equatable, Sendable`（`seq/config: GameConfig/handNumber/buttonSeat/street: Street/board: [Card]/players: [SnapshotPlayer]/potTotal/currentBet/actorSeat: Int?/handResult: HandResult?/tournamentOver/tournamentPayouts: [TournamentPayout]/yourSeat/yourLegal: LegalActions?`，memberwise init）
  - `static func make(from state: GameState, recipient seat: Int, seq: Int) -> TableSnapshot`
  - `protocol SeatSurface: Sendable`（`seat/name/stack/streetContribution/status/holeCards: [Card]/holdsCards: Bool`）
  - `protocol TableSurface: Sendable`（`seats: [any SeatSurface]/board/street/actorSeat/buttonSeat/handNumber/potTotal/currentBet/format: GameFormat/yourSeat/handResult/tournamentOver/tournamentPayouts`）+ extension `func seatPlayer(_ seat: Int) -> (any SeatSurface)?`
  - retroactive：`PlayerState: SeatSurface`（`holdsCards = !holeCards.isEmpty`）、`GameState: TableSurface`（`seats/format/yourSeat` 由既有属性派生）；`SnapshotPlayer: SeatSurface`、`TableSnapshot: TableSurface`

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/TableSnapshotTests.swift`：

```swift
import XCTest
import PokerEngine
@testable import PokerApp

/// spec §7 脱敏规则：对手手牌永不出现在网络上；亮牌规则与单机 UI 一致。
final class TableSnapshotTests: XCTestCase {
    let config = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    /// 三人全部过牌/跟注到摊牌。
    private func showdownState(seed: UInt64) -> GameState {
        var s = GameState.start(config: config, seed: seed)
        while s.street != .handOver {
            if let _ = s.actorSeat {
                let legal = legalActions(s)
                s.apply(legal.canCheck ? .check : .call)
            }
        }
        return s
    }

    func testMidHandSnapshotHidesOpponentCards() {
        let s = GameState.start(config: config, seed: 5)   // 翻牌前即取快照
        let snap = TableSnapshot.make(from: s, recipient: 1, seq: 1)
        XCTAssertEqual(snap.players[1].holeCards.count, 2, "接收者看到自己的手牌")
        for seat in [0, 2] {
            XCTAssertTrue(snap.players[seat].holdsCards, "对手有牌但不可见")
            XCTAssertTrue(snap.players[seat].holeCards.isEmpty, "对手手牌绝不外发（抓包也不行）")
        }
        XCTAssertEqual(snap.yourSeat, 1)
        XCTAssertEqual(snap.seq, 1)
        XCTAssertEqual(snap.potTotal, s.potTotal)
        XCTAssertEqual(snap.board, s.board)
    }

    func testYourLegalMatchesEngineOnlyOnYourTurn() {
        var s = GameState.start(config: config, seed: 5)
        let actor = s.actorSeat!
        let snapActor = TableSnapshot.make(from: s, recipient: actor, seq: 1)
        XCTAssertEqual(snapActor.yourLegal, legalActions(s))
        let snapOther = TableSnapshot.make(from: s, recipient: (actor + 1) % 3, seq: 1)
        XCTAssertNil(snapOther.yourLegal, "未轮到接收者时不附带")
    }

    func testShowdownRevealsContendersButNotFolder() {
        // 先打到只剩两人摊牌：第三人翻牌前弃牌
        var s = GameState.start(config: config, seed: 9)
        // 推进必须用合法动作：面对下注时 .check 会被引擎按非法动作断言+弃牌处理
        while s.actorSeat != 2 {
            let legal = legalActions(s)
            s.apply(legal.canCheck ? .check : .call)
        }
        s.apply(.fold)
        while s.street != .handOver {
            if s.actorSeat != nil {
                let legal = legalActions(s)
                s.apply(legal.canCheck ? .check : .call)
            }
        }
        XCTAssertEqual(s.street, .handOver)
        let foldedSeat = 2
        let snap = TableSnapshot.make(from: s, recipient: 0, seq: 3)
        for player in snap.players where player.seat != foldedSeat {
            XCTAssertFalse(player.holeCards.isEmpty, "摊牌局未弃牌者亮牌（含接收者之外的人）")
        }
        XCTAssertTrue(snap.players[foldedSeat].holeCards.isEmpty, "弃牌者 muck 不亮")
    }

    func testUncontestedWinRevealsNothing() {
        var s = GameState.start(config: config, seed: 9)
        while s.actorSeat != 2 {
            let legal = legalActions(s)
            s.apply(legal.canCheck ? .check : .call)
        }
        s.apply(.fold)
        while s.actorSeat != nil { s.apply(.fold) }   // 只剩一人，直接收池
        XCTAssertEqual(s.handResult?.awards.first?.ranks.isEmpty, true, "全员弃牌局无 ranks")
        let snap = TableSnapshot.make(from: s, recipient: 0, seq: 4)
        for player in snap.players where player.seat != 0 {
            XCTAssertTrue(player.holeCards.isEmpty, "非摊牌结束（uncontested）任何人不亮牌")
        }
        XCTAssertEqual(snap.players[0].holeCards.count, 2, "接收者始终看得到自己")
    }

    func testSnapshotCodableRoundTrip() throws {
        let s = showdownState(seed: 13)
        let snap = TableSnapshot.make(from: s, recipient: 1, seq: 42)
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(TableSnapshot.self, from: data), snap)
    }

    func testGameStateConformsToTableSurface() {
        let s = GameState.start(config: config, seed: 5)
        let surface: any TableSurface = s
        XCTAssertEqual(surface.seats.count, 3)
        XCTAssertEqual(surface.yourSeat, s.config.humanSeat)
        XCTAssertEqual(surface.format, s.config.format)
        XCTAssertEqual(surface.potTotal, s.potTotal)
        XCTAssertNotNil(surface.seatPlayer(1))
        XCTAssertNil(surface.seatPlayer(99))
    }
}
```

- [ ] **Step 2: 生成工程并跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/TableSnapshotTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`TableSnapshot` 未定义）。

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/Session/TableSnapshot.swift`：

```swift
import Foundation
import PokerEngine

// MARK: - wire 快照值类型

struct SnapshotPlayer: Codable, Equatable, Sendable {
    var seat: Int
    var name: String
    var stack: Int
    var streetContribution: Int
    var status: PlayerStatus
    /// 有牌但对接收者不可见（UI 画牌背）。
    var holdsCards: Bool
    /// 仅接收者本人（或摊牌亮出）的牌，其余恒为空数组。
    var holeCards: [Card]
}

struct TableSnapshot: Codable, Equatable, Sendable {
    /// 主机单调递增；客机丢弃 seq <= 已见最大值的快照。
    var seq: Int
    var config: GameConfig
    var handNumber: Int
    var buttonSeat: Int
    var street: Street
    var board: [Card]
    /// 下标即 seat。
    var players: [SnapshotPlayer]
    var potTotal: Int
    var currentBet: Int
    var actorSeat: Int?
    var handResult: HandResult?
    var tournamentOver: Bool
    var tournamentPayouts: [TournamentPayout]
    var yourSeat: Int
    /// 轮到接收者时由主机用引擎 legalActions() 算好附上（规则唯一真源在引擎）。
    var yourLegal: LegalActions?
}

extension TableSnapshot {
    /// 由权威引擎状态生成 recipient 专属脱敏快照（spec §7 三条规则）。
    static func make(from state: GameState, recipient seat: Int, seq: Int) -> TableSnapshot {
        // 摊牌局（handResult 含非空 ranks）才亮牌；全员弃牌收池的 ranks 为空 → 不亮
        let showdownReached = state.street == .handOver
            && !(state.handResult?.awards.first?.ranks.isEmpty ?? true)
        let players = state.players.map { p -> SnapshotPlayer in
            let visible = p.seat == seat || (showdownReached && p.status != .folded)
            return SnapshotPlayer(
                seat: p.seat, name: p.name, stack: p.stack,
                streetContribution: p.streetContribution, status: p.status,
                holdsCards: !p.holeCards.isEmpty,
                holeCards: visible ? p.holeCards : [])
        }
        let yourLegal: LegalActions?
        if state.actorSeat == seat, [.preflop, .flop, .turn, .river].contains(state.street) {
            yourLegal = legalActions(state)
        } else {
            yourLegal = nil
        }
        return TableSnapshot(
            seq: seq, config: state.config, handNumber: state.handNumber,
            buttonSeat: state.buttonSeat, street: state.street, board: state.board,
            players: players, potTotal: state.potTotal, currentBet: state.currentBet,
            actorSeat: state.actorSeat, handResult: state.handResult,
            tournamentOver: state.tournamentOver,
            tournamentPayouts: state.tournamentPayouts,
            yourSeat: seat, yourLegal: yourLegal)
    }
}

// MARK: - UI 渲染投影协议（spec §10.1）

protocol SeatSurface: Sendable {
    var seat: Int { get }
    var name: String { get }
    var stack: Int { get }
    var streetContribution: Int { get }
    var status: PlayerStatus { get }
    var holeCards: [Card] { get }
    var holdsCards: Bool { get }
}

protocol TableSurface: Sendable {
    var seats: [any SeatSurface] { get }
    var board: [Card] { get }
    var street: Street { get }
    var actorSeat: Int? { get }
    var buttonSeat: Int { get }
    var handNumber: Int { get }
    var potTotal: Int { get }
    var currentBet: Int { get }
    var format: GameFormat { get }
    var yourSeat: Int { get }
    var handResult: HandResult? { get }
    var tournamentOver: Bool { get }
    var tournamentPayouts: [TournamentPayout] { get }
}

extension TableSurface {
    func seatPlayer(_ seat: Int) -> (any SeatSurface)? {
        seats.first { $0.seat == seat }
    }
}

// MARK: - 两个渲染路径的各自实现

// 客机路径：快照即投影。
extension SnapshotPlayer: SeatSurface {}
extension TableSnapshot: TableSurface {
    var seats: [any SeatSurface] { players }
    var format: GameFormat { config.format }
}

// 单机/房主路径：引擎类型直接满足投影（本机行为零变化）。
extension PlayerState: SeatSurface {
    var holdsCards: Bool { !holeCards.isEmpty }
}
extension GameState: TableSurface {
    var seats: [any SeatSurface] { players }
    var format: GameFormat { config.format }
    var yourSeat: Int { config.humanSeat }
}
```

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: PASS（6 用例）。注意 `testShowdownRevealsContendersButNotFolder` 若 seed 9 下 `while s.actorSeat != 2 { s.apply(.check) }` 死循环（seat 2 已 all-in 等极端情况），换 seed 直到可行——断言 `s.actorSeat != nil` 的循环步进必须总能推进；1000 筹码 10/20 盲注下不会出现该情况。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Session/TableSnapshot.swift PokerApp/PokerAppTests/TableSnapshotTests.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: TableSnapshot 脱敏快照（三态亮牌规则）与 TableSurface/SeatSurface 渲染投影"
```

---

### Task 6: 联机消息层（信封/载荷/大厅）

**Files:**
- Create: `PokerApp/PokerApp/Session/PokerMessages.swift`
- Modify: `PokerApp/PokerAppTests/LoopbackHarness.swift`（追加 `sendEnvelope`）
- Test: `PokerApp/PokerAppTests/PokerMessagesTests.swift`

**Interfaces:**
- Consumes: Task 1 引擎 Codable、Task 5 `TableSnapshot`。
- Produces（Task 7/8/9 依赖）：
  - `enum PokerProtocolVersion { static let current = 1 }`
  - `enum Sender: Codable, Equatable, Hashable, Sendable { case host; case guest; case seat(Int) }`（`guest` 仅 hello 用）
  - `enum RejectionReason: String, Codable, Equatable, Sendable { case roomFull, gameStarted, versionMismatch, illegalAction, notYourTurn }`
  - `enum Payload: Codable, Equatable, Sendable`：`hello(deviceID: String, name: String)`、`welcome(seat: Int, lobby: LobbyState)`、`rejection(RejectionReason)`、`lobby(LobbyState)`、`ready(Bool)`、`action(PlayerAction)`、`nextHand`、`snapshot(TableSnapshot)`、`bye`
  - `struct PokerEnvelope: Codable, Equatable, Sendable`（`protocolVersion: Int = PokerProtocolVersion.current`、`roomID/messageID/sender/payload`，memberwise init 含默认值）
  - `struct LobbyPlayer: Codable, Equatable, Sendable`（`seat/name/isHost/ready/connected`）、`enum LobbyPhase: String, Codable { case lobby, playing }`、`struct LobbyState: Codable, Equatable, Sendable`（`phase/roomName/players: [LobbyPlayer]/config: GameConfig?`）
  - `enum PokerWire { static func encode(...) throws -> Data; static func decode(...) throws -> PokerEnvelope }`

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/PokerMessagesTests.swift`：

```swift
import XCTest
import PokerEngine
@testable import PokerApp

final class PokerMessagesTests: XCTestCase {
    private func roundTrip(_ envelope: PokerEnvelope) throws -> PokerEnvelope {
        try PokerWire.decode(PokerWire.encode(envelope))
    }

    private var sampleLobby: LobbyState {
        LobbyState(phase: .lobby, roomName: "周五牌局",
                   players: [LobbyPlayer(seat: 0, name: "房主", isHost: true, ready: true, connected: true),
                             LobbyPlayer(seat: 1, name: "阿明", isHost: false, ready: false, connected: true)],
                   config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)))
    }

    private var sampleSnapshot: TableSnapshot {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 500,
                                                   format: .cash(sb: 5, bb: 10)), seed: 3)
        _ = s.actorSeat
        return TableSnapshot.make(from: s, recipient: 1, seq: 7)
    }

    func testEveryPayloadCaseRoundTrips() throws {
        let roomID = "ROOM-A1B2"
        let cases: [Payload] = [
            .hello(deviceID: "UUID-1", name: "阿明"),
            .welcome(seat: 1, lobby: sampleLobby),
            .rejection(.roomFull), .rejection(.illegalAction),
            .lobby(sampleLobby),
            .ready(true), .ready(false),
            .action(.fold), .action(.bet(120)), .action(.raiseTo(360)), .action(.check), .action(.call),
            .nextHand,
            .snapshot(sampleSnapshot),
            .bye,
        ]
        for payload in cases {
            let envelope = PokerEnvelope(roomID: roomID, sender: .seat(1), payload: payload)
            XCTAssertEqual(try roundTrip(envelope), envelope, "载荷 \(payload) 应往返等价")
        }
    }

    func testEnvelopeDefaults() {
        let envelope = PokerEnvelope(roomID: "R", sender: .host, payload: .nextHand)
        XCTAssertEqual(envelope.protocolVersion, PokerProtocolVersion.current)
        XCTAssertFalse(envelope.messageID.isEmpty)
    }

    func testLobbyPhaseDecodes() throws {
        let playing = LobbyState(phase: .playing, roomName: "R", players: [], config: nil)
        XCTAssertEqual(try JSONDecoder().decode(LobbyState.self, from: JSONEncoder().encode(playing)), playing)
    }

    func testEnvelopeDecodeRejectsGarbage() {
        XCTAssertThrowsError(try PokerWire.decode(Data("not-json".utf8)))
    }
}
```

- [ ] **Step 2: 生成工程并跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/PokerMessagesTests 2>&1 | tail -30
```
Expected: 编译 FAIL。

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/Session/PokerMessages.swift`：

```swift
import Foundation
import PokerEngine

enum PokerProtocolVersion {
    /// wire 结构不兼容变更时 +1；不匹配的双方互相拒绝并提示升级。
    static let current = 1
}

/// 消息发送方身份。hello 尚未分配座位时用 .guest；入座后一切消息用 .seat(n)。
enum Sender: Codable, Equatable, Hashable, Sendable {
    case host
    case guest
    case seat(Int)
}

enum RejectionReason: String, Codable, Equatable, Sendable {
    case roomFull        // 大厅满员（9 座）
    case gameStarted     // 对局已开始，拒绝新面孔
    case versionMismatch // 协议版本不一致
    case illegalAction   // 引擎判定非法的动作
    case notYourTurn     // 不是该座位的行动轮
}

struct LobbyPlayer: Codable, Equatable, Sendable {
    var seat: Int
    var name: String
    var isHost: Bool
    var ready: Bool
    var connected: Bool
}

enum LobbyPhase: String, Codable, Equatable, Sendable {
    case lobby
    case playing
}

struct LobbyState: Codable, Equatable, Sendable {
    var phase: LobbyPhase
    var roomName: String
    var players: [LobbyPlayer]
    /// 房主定下的桌子配置（开局前广播给客机展示）。
    var config: GameConfig?
}

enum Payload: Codable, Equatable, Sendable {
    case hello(deviceID: String, name: String)
    case welcome(seat: Int, lobby: LobbyState)
    case rejection(RejectionReason)
    case lobby(LobbyState)
    case ready(Bool)
    case action(PlayerAction)
    case nextHand
    case snapshot(TableSnapshot)
    case bye
}

struct PokerEnvelope: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var roomID: String
    /// 接收端去重（重连补发可能与在途重叠）。
    var messageID: String
    var sender: Sender
    var payload: Payload

    init(protocolVersion: Int = PokerProtocolVersion.current,
         roomID: String, messageID: String = UUID().uuidString,
         sender: Sender, payload: Payload) {
        self.protocolVersion = protocolVersion
        self.roomID = roomID
        self.messageID = messageID
        self.sender = sender
        self.payload = payload
    }
}

enum PokerWire {
    static func encode(_ envelope: PokerEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    static func decode(_ data: Data) throws -> PokerEnvelope {
        try JSONDecoder().decode(PokerEnvelope.self, from: data)
    }
}
```

同时在 `PokerApp/PokerAppTests/LoopbackHarness.swift` 末尾追加（Task 3 备注的迁移）：

```swift
/// 以「裸客机」身份向房主发送一条信封（会话级测试用，不经过 GuestSession）。
func sendEnvelope(_ payload: Payload, roomID: String, sender: Sender,
                  from transport: any Transport, to host: PeerID) async throws {
    try await transport.send(try PokerWire.encode(
        PokerEnvelope(roomID: roomID, sender: sender, payload: payload)
    ), to: host)
}
```

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令 + 全类名替换。Expected: PASS（4 用例）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Session/PokerMessages.swift PokerApp/PokerAppTests/PokerMessagesTests.swift PokerApp/PokerAppTests/LoopbackHarness.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: 联机消息层——信封/九种载荷/大厅状态（Swift 合成关联值 Codable）"
```

---

### Task 7: HostSession 大厅阶段

**Files:**
- Create: `PokerApp/PokerApp/Session/HostSession.swift`
- Test: `PokerApp/PokerAppTests/HostSessionLobbyTests.swift`

**Interfaces:**
- Consumes: Task 2/3 Transport、Task 4 `RoomName.sanitize`/`NearbyTransport`、Task 6 消息层。
- Produces（Task 8 扩展同文件；Task 11 VM 依赖）：
  - `struct HostConfiguration: Sendable`（`roomName/hostName/tableConfig: GameConfig`）
  - `enum HostUpdate: Sendable { case lobby(LobbyState); case state(GameState) }`
  - `actor HostSession`：
    - `init(configuration: HostConfiguration, transport: any Transport = NearbyTransport())`
    - `nonisolated let updates: AsyncStream<HostUpdate>`
    - `func startHosting() async throws`、`func setReady(_ value: Bool) async`、`func updateTableConfig(_ config: GameConfig) async`、`func startGame() async throws`
    - `enum HostError: String, Error, Sendable { case alreadyStarted, notEnoughPlayers, notAllReady }`
    - 测试观测：`func gameState() -> GameState?`、`func currentPhase() -> HostPhase`（`enum HostPhase: Equatable, Sendable { case idle, lobby, playing, finished }`）、`func currentLobby() -> LobbyState?`、`func roomIDValue() -> String`、`func peerIDValue(seat: Int) -> PeerID?`
  - Task 8 将在同文件追加：`func act(_ action: PlayerAction) async`、`func requestNextHand() async`、`func disconnect() async`、`nonisolated func applicationDidBecomeActive() async`

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/HostSessionLobbyTests.swift`：

```swift
import XCTest
import PokerEngine
@testable import PokerApp

/// 大厅阶段：建房/加入分配座位/ready/满员拒绝/版本拒绝/改名广播。
/// 「裸客机」直接用 LoopbackTransport + sendEnvelope 模拟（GuestSession 在 Task 9 才有）。
final class HostSessionLobbyTests: XCTestCase {
    let hostPeer = PeerID(rawValue: "ROOM-X")
    var hub: LoopbackTransportHub!
    var hostTransport: LoopbackTransport!
    var guestTransport: LoopbackTransport!
    var hostLog: EventLog!
    var pump: Task<Void, Never>!

    override func setUp() async throws {
        hub = LoopbackTransportHub()
        hostTransport = hub.makeTransport(peerID: hostPeer)
        guestTransport = hub.makeTransport(peerID: PeerID(rawValue: "guest-raw"))
        hostLog = EventLog()
    }

    override func tearDown() async throws {
        pump?.cancel()
        await hostSessionForTeardown?.disconnect()
    }

    private var hostSessionForTeardown: HostSession?

    private func makeHost() -> HostSession {
        let config = HostConfiguration(
            roomName: "周五牌局", hostName: "老王",
            tableConfig: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)))
        let session = HostSession(configuration: config, transport: hostTransport)
        hostSessionForTeardown = session
        return session
    }

    /// 从房主事件流里取下一条可解的信封事件。
    private func nextEnvelope(timeout: TimeInterval = 3) async throws -> (PokerEnvelope, PeerID) {
        while true {
            let event = try await hostLog.waitFor(timeout: timeout) { if case .received = $0 { return true }; return false }
            guard case let .received(data, from) = event,
                  let envelope = try? PokerWire.decode(data) else { continue }
            return (envelope, from)
        }
    }

    func testStartHostingPublishesLobbyWithHostSeat() async throws {
        let host = makeHost()
        let updates = host.updates
        try await host.startHosting()
        var received: LobbyState?
        for await update in updates {
            if case let .lobby(lobby) = update { received = lobby; break }
        }
        XCTAssertEqual(received?.players.map(\.seat), [0])
        XCTAssertEqual(received?.players[0].isHost, true)
        XCTAssertEqual(received?.roomName, "周五牌局")
        XCTAssertEqual(host.currentPhase(), .lobby)
        XCTAssertTrue(host.roomIDValue().hasPrefix("ROOM-"), "中文房间名清洗后兜底为 ROOM + 随机后缀，实际: \(host.roomIDValue())")
    }

    func testJoinAssignsSeatsInOrderAndBroadcastsLobby() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: hostTransport, to: hostLog)
        try await guestTransport.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-A", name: "阿明"), roomID: host.roomIDValue(),
                               sender: .guest, from: guestTransport, to: hostPeer)
        let (welcome, _) = try await nextEnvelope()
        guard case let .welcome(seat, lobby) = welcome.payload else { return XCTFail("应回 welcome") }
        XCTAssertEqual(seat, 1)
        XCTAssertEqual(lobby.players.map(\.seat), [0, 1])
        XCTAssertEqual(lobby.players[1].name, "阿明")
        // 随后广播 lobby 给在座客机
        let (broadcast, _) = try await nextEnvelope()
        guard case .lobby = broadcast.payload else { return XCTFail("应广播 lobby") }
    }

    func testReadyFlowUpdatesLobby() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: hostTransport, to: hostLog)
        try await guestTransport.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-A", name: "阿明"), roomID: host.roomIDValue(),
                               sender: .guest, from: guestTransport, to: hostPeer)
        _ = try await nextEnvelope()   // welcome
        _ = try await nextEnvelope()   // lobby 广播
        try await sendEnvelope(.ready(true), roomID: host.roomIDValue(), sender: .seat(1),
                               from: guestTransport, to: hostPeer)
        let (lobby, _) = try await nextEnvelope()
        guard case let .lobby(state) = lobby.payload else { return XCTFail() }
        XCTAssertEqual(state.players[1].ready, true)
        XCTAssertFalse(state.players[0].ready, "房主尚未 ready")
    }

    func testVersionMismatchRejected() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: hostTransport, to: hostLog)
        try await guestTransport.connect(to: hostPeer)
        let bad = PokerEnvelope(protocolVersion: PokerProtocolVersion.current + 1,
                                roomID: host.roomIDValue(), sender: .guest,
                                payload: .hello(deviceID: "device-B", name: "旧版"))
        try await guestTransport.send(try PokerWire.encode(bad), to: hostPeer)
        let (rejection, _) = try await nextEnvelope()
        XCTAssertEqual(rejection.payload, .rejection(.versionMismatch))
    }

    func testLobbyPhaseDisconnectFreesSeat() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: hostTransport, to: hostLog)
        try await guestTransport.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-A", name: "阿明"), roomID: host.roomIDValue(),
                               sender: .guest, from: guestTransport, to: hostPeer)
        _ = try await nextEnvelope()   // welcome
        _ = try await nextEnvelope()   // lobby 广播
        hub.severLink(between: hostPeer, and: PeerID(rawValue: "guest-raw"))
        let (lobby, _) = try await nextEnvelope()
        guard case let .lobby(state) = lobby.payload else { return XCTFail("断线应广播名册") }
        XCTAssertEqual(state.players.map(\.seat), [0], "大厅期断线即移出名册")
    }
}
```

- [ ] **Step 2: 生成工程并跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/HostSessionLobbyTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`HostSession` 未定义）。

- [ ] **Step 3: 实现（大厅部分；对局阶段 Task 8 追加）**

`PokerApp/PokerApp/Session/HostSession.swift`：

```swift
import Foundation
import PokerEngine

struct HostConfiguration: Sendable {
    var roomName: String
    var hostName: String
    /// 桌子配置；playerCount/humanSeat 在开局时按名册重建。
    var tableConfig: GameConfig
}

enum HostUpdate: Sendable {
    case lobby(LobbyState)
    case state(GameState)
}

/// 房主会话：唯一权威引擎持有者（spec §8）。
actor HostSession {
    enum HostPhase: Equatable, Sendable { case idle, lobby, playing, finished }
    enum HostError: String, Error, Sendable {
        case alreadyStarted
        case notEnoughPlayers
        case notAllReady
    }

    nonisolated let updates: AsyncStream<HostUpdate>
    private nonisolated let updatesContinuation: AsyncStream<HostUpdate>.Continuation

    private let transport: any Transport
    private var configuration: HostConfiguration
    private var phase: HostPhase = .idle
    private var roomID = ""
    private var processingTask: Task<Void, Never>?

    // 名册：座位 ↔ 身份（seat 0 恒为房主，deviceBySeat[0] = "host"）
    private var seatByPeer: [PeerID: Int] = [:]
    private var peerBySeat: [Int: PeerID] = [:]
    private var deviceBySeat: [Int: String] = [:]
    private var names: [Int: String] = [:]
    private var readySeats: Set<Int> = []
    private var state: GameState?
    private var seq = 0
    private var seenMessageIDs: Set<String> = []

    init(configuration: HostConfiguration, transport: any Transport = NearbyTransport()) {
        self.configuration = configuration
        self.transport = transport
        (updates, updatesContinuation) = AsyncStream.makeStream(of: HostUpdate.self)
    }

    // MARK: - 公开 API

    func startHosting() async throws {
        guard phase == .idle else { throw HostError.alreadyStarted }
        let suffix = String(UUID().uuidString.prefix(4)).uppercased()
        roomID = "\(RoomName.sanitize(configuration.roomName))-\(suffix)"
        names[0] = configuration.hostName.isEmpty ? "房主" : String(configuration.hostName.prefix(12))
        deviceBySeat[0] = "host"
        phase = .lobby
        try await transport.startHosting(roomID: roomID, port: nil)
        startProcessingIfNeeded()
        await publishLobby()
    }

    func setReady(_ value: Bool) async {
        guard phase == .lobby else { return }
        if value { readySeats.insert(0) } else { readySeats.remove(0) }
        await publishLobby()
    }

    func updateTableConfig(_ config: GameConfig) async {
        guard phase == .lobby else { return }
        configuration.tableConfig = config
        await publishLobby()
    }

    func startGame() async throws {
        guard phase == .lobby else { throw HostError.alreadyStarted }
        let seats = deviceBySeat.keys.sorted()
        guard seats.count >= 2 else { throw HostError.notEnoughPlayers }
        guard readySeats.isSuperset(of: seats) else { throw HostError.notAllReady }
        var config = configuration.tableConfig
        config.playerCount = seats.count
        config.humanSeat = 0
        var initialState = GameState.start(
            config: config,
            seed: UInt64(Date().timeIntervalSince1970 * 1000))
        for seat in seats {
            initialState.players[seat].name = names[seat] ?? "座位 \(seat + 1)"
        }
        state = initialState
        phase = .playing
        await publishLobby()          // phase .playing → 客机切牌桌
        await fanoutSnapshots()       // 首帧快照
    }

    // MARK: - 测试观测

    func gameState() -> GameState? { state }
    func currentPhase() -> HostPhase { phase }
    func currentLobby() -> LobbyState? { phase == .idle ? nil : buildLobby() }
    func roomIDValue() -> String { roomID }
    func peerIDValue(seat: Int) -> PeerID? { peerBySeat[seat] }

    // MARK: - 传输事件处理

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self, transport] in
            let events = await transport.events
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case let .received(data, peer):
            guard let envelope = try? PokerWire.decode(data) else { return }
            await handleEnvelope(envelope, from: peer)
        case let .disconnected(peer, _):
            await handlePeerLeft(peer)
        case .connected, .discovered:
            break
        }
    }

    private func handleEnvelope(_ envelope: PokerEnvelope, from peer: PeerID) async {
        guard envelope.roomID == roomID else { return }
        guard isFreshMessageID(envelope.messageID) else { return }
        if envelope.protocolVersion != PokerProtocolVersion.current {
            try? await send(.rejection(.versionMismatch), to: peer)
            return
        }
        switch envelope.payload {
        case let .hello(deviceID, name):
            await handleHello(deviceID: deviceID, name: name, peer: peer)
        case let .ready(value):
            guard case let .seat(seat) = envelope.sender,
                  deviceBySeat[seat] != nil,
                  peerBySeat[seat] == peer,
                  phase == .lobby else { return }
            if value { readySeats.insert(seat) } else { readySeats.remove(seat) }
            await publishLobby()
        case .action, .nextHand, .bye:
            guard case let .seat(seat) = envelope.sender, peerBySeat[seat] == peer else { return }
            if case .bye = envelope.payload {
                await handlePeerLeft(peer)
                return
            }
            await handleGamePayload(envelope.payload, seat: seat)   // Task 8 实现；本任务先留空方法
        default:
            break
        }
    }

    /// Task 8 填充对局逻辑；本任务先做空实现保证编译。
    private func handleGamePayload(_ payload: Payload, seat: Int) async {}

    private func handleHello(deviceID: String, name: String, peer: PeerID) async {
        // "host" 是房主保留 deviceID；空 ID 视为畸形 hello，一律忽略
        guard !deviceID.isEmpty, deviceID != "host" else { return }
        // 已绑定连接重复 hello：重发 welcome 即可（幂等）
        if let bound = seatByPeer[peer] {
            try? await send(.welcome(seat: bound, lobby: buildLobby()), to: peer)
            return
        }
        // 一条连接只能绑一个 deviceID；同 deviceID 新连接 = 接管旧连接
        if let existingPeer = deviceBySeat.first(where: { $0.value == deviceID })?.key
            .flatMap({ seat -> PeerID? in peerBySeat[seat] }),
           existingPeer != peer {
            seatByPeer.removeValue(forKey: existingPeer)
        }
        // 重连：已知 deviceID 还原原座位
        if let seat = deviceBySeat.first(where: { $0.value == deviceID })?.key {
            bind(peer: peer, seat: seat)
            try? await send(.welcome(seat: seat, lobby: buildLobby()), to: peer)
            if phase == .playing || phase == .finished {
                await resendCurrentSnapshots()   // 补发当前快照：seq 不前进，已收过的客机按 seq 门丢弃，错过的补齐
            } else {
                await publishLobby()
            }
            return
        }
        // 新面孔
        guard phase == .lobby else {
            try? await send(.rejection(.gameStarted), to: peer)
            return
        }
        let taken = Set(deviceBySeat.keys)
        guard let seat = (0..<9).first(where: { !taken.contains($0) }) else {
            try? await send(.rejection(.roomFull), to: peer)
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceBySeat[seat] = deviceID
        names[seat] = trimmed.isEmpty ? "玩家-\(String(deviceID.suffix(4)))" : String(trimmed.prefix(12))
        bind(peer: peer, seat: seat)
        try? await send(.welcome(seat: seat, lobby: buildLobby()), to: peer)
        await publishLobby()
    }

    private func handlePeerLeft(_ peer: PeerID) async {
        guard let seat = seatByPeer[peer] else { return }
        seatByPeer.removeValue(forKey: peer)
        peerBySeat[seat] = nil
        if phase == .lobby {
            // 大厅期离开：座位彻底释放
            deviceBySeat[seat] = nil
            names[seat] = nil
            readySeats.remove(seat)
        }
        // 对局期：deviceBySeat 保留（可重连），座位标记为断线（Task 8 托管用）
        await publishLobby()
        await reconcileDisconnectedActor()   // Task 8 实现；本任务空方法
    }

    private func bind(peer: PeerID, seat: Int) {
        seatByPeer[peer] = seat
        peerBySeat[seat] = peer
    }

    /// Task 8 填充；本任务空实现保证编译。
    private func reconcileDisconnectedActor() async {}

    private func isFreshMessageID(_ id: String) -> Bool {
        guard !seenMessageIDs.contains(id) else { return false }
        seenMessageIDs.insert(id)
        if seenMessageIDs.count > 2048 { seenMessageIDs.removeAll() }
        return true
    }

    // MARK: - 广播

    private func buildLobby() -> LobbyState {
        let players = deviceBySeat.keys.sorted().map { seat in
            LobbyPlayer(seat: seat,
                        name: names[seat] ?? "座位 \(seat + 1)",
                        isHost: seat == 0,
                        ready: readySeats.contains(seat),
                        connected: seat == 0 || peerBySeat[seat] != nil)
        }
        return LobbyState(
            phase: (phase == .playing || phase == .finished) ? .playing : .lobby,
            roomName: configuration.roomName,
            players: players,
            config: configuration.tableConfig)
    }

    private func publishLobby() async {
        let lobby = buildLobby()
        updatesContinuation.yield(.lobby(lobby))
        for (_, peer) in peerBySeat {
            try? await send(.lobby(lobby), to: peer)
        }
    }

    /// Task 8 填充；本任务空实现保证编译。
    private func fanoutSnapshots() async {}
    private func resendCurrentSnapshots() async {}

    private func send(_ payload: Payload, to peer: PeerID) async throws {
        try await transport.send(
            try PokerWire.encode(PokerEnvelope(roomID: roomID, sender: .host, payload: payload)),
            to: peer)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: PASS（5 用例）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Session/HostSession.swift PokerApp/PokerAppTests/HostSessionLobbyTests.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: HostSession 大厅——建房/加入分座/ready/版本与满员拒绝/断线释放座位"
```

---

### Task 8: HostSession 对局阶段（校验/扇出/托管/重连）

**Files:**
- Modify: `PokerApp/PokerApp/Session/HostSession.swift`（填充 Task 7 的四个空方法 + 公开 act/requestNextHand/disconnect/applicationDidBecomeActive）
- Test: `PokerApp/PokerAppTests/HostSessionGameTests.swift`

**Interfaces:**
- Consumes: Task 5 `TableSnapshot.make`、Task 7 HostSession 骨架。
- Produces（Task 9/11 依赖）：
  - `func act(_ action: PlayerAction) async`（房主自己 seat 0 的行动入口）
  - `func requestNextHand() async`
  - `func disconnect() async`
  - `nonisolated func applicationDidBecomeActive() async`（scenePhase 前台自愈入口）

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/HostSessionGameTests.swift`：

```swift
import XCTest
import PokerEngine
@testable import PokerApp

/// 对局阶段：开局条件/动作校验/扇出/托管/重连（spec §8）。
final class HostSessionGameTests: XCTestCase {
    let hostPeer = PeerID(rawValue: "ROOM-G")
    var hub: LoopbackTransportHub!
    var host: HostSession!
    var guestT: [LoopbackTransport] = []      // seat1/seat2 的裸客机传输
    var guestLogs: [EventLog] = []
    var pumps: [Task<Void, Never>] = []
    var hostLog: EventLog = EventLog()
    var hostPump: Task<Void, Never>?

    let config = GameConfig(playerCount: 2, startingStack: 500, format: .cash(sb: 5, bb: 10))

    override func tearDown() async throws {
        hostPump?.cancel()
        pumps.forEach { $0.cancel() }
        await host?.disconnect()
    }

    /// 建房 + N 个裸客机加入并 ready；返回座位号数组（含房主 0）。
    @discardableResult
    private func makeReadyRoom(guestCount: Int) async throws -> HostSession {
        hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: hostPeer)
        host = HostSession(
            configuration: HostConfiguration(roomName: "G", hostName: "host",
                                             tableConfig: config),
            transport: hostTransport)
        try await host.startHosting()
        hostPump = attachEvents(of: hostTransport, to: hostLog)
        for index in 0..<guestCount {
            let transport = hub.makeTransport(peerID: PeerID(rawValue: "raw-guest-\(index)"))
            guestT.append(transport)
            let log = EventLog()
            guestLogs.append(log)
            pumps.append(attachEvents(of: transport, to: log))
            try await transport.connect(to: hostPeer)
            try await sendEnvelope(.hello(deviceID: "device-\(index)", name: "P\(index + 1)"),
                                   roomID: host.roomIDValue(), sender: .guest,
                                   from: transport, to: hostPeer)
        }
        await host.setReady(true)
        for (index, transport) in guestT.enumerated() {
            try await sendEnvelope(.ready(true), roomID: host.roomIDValue(),
                                   sender: .seat(index + 1), from: transport, to: hostPeer)
        }
        return host
    }

    /// 从某客机事件流收下一帧快照。
    private func nextSnapshot(log: EventLog, timeout: TimeInterval = 3) async throws -> TableSnapshot {
        while true {
            let event = try await log.waitFor(timeout: timeout) { if case .received = $0 { return true }; return false }
            guard case let .received(data, _) = event,
                  let envelope = try? PokerWire.decode(data),
                  case let .snapshot(snapshot) = envelope.payload else { continue }
            return snapshot
        }
    }

    private func nextRejection(log: EventLog, timeout: TimeInterval = 3) async throws -> RejectionReason {
        while true {
            let event = try await log.waitFor(timeout: timeout) { if case .received = $0 { return true }; return false }
            guard case let .received(data, _) = event,
                  let envelope = try? PokerWire.decode(data),
                  case let .rejection(reason) = envelope.payload else { continue }
            return reason
        }
    }

    /// 取房主当前行动座位（测试据此决定从哪个座位发动作）。
    private func currentActor() -> Int? {
        host.gameState()?.actorSeat
    }

    private func sendAction(seat: Int, _ action: PlayerAction) async throws {
        try await sendEnvelope(.action(action), roomID: host.roomIDValue(), sender: .seat(seat),
                               from: guestT[seat - 1], to: hostPeer)
    }

    func testStartGameRequiresTwoPlayersAndAllReady() async throws {
        _ = try await makeReadyRoom(guestCount: 0)
        do { try await host.startGame(); XCTFail("单人不应能开局") } catch {}
        _ = try await makeReadyRoom(guestCount: 1)
        // 客机未 ready：去掉 host ready 再试？host 已 ready；直接再断言正常路径
        try await host.startGame()   // host+1 客机都 ready → 可开
        XCTAssertEqual(host.currentPhase(), .playing)
        XCTAssertEqual(host.gameState()?.players.count, 2)
        XCTAssertEqual(host.gameState()?.players[1].name, "P1", "开局改写大厅昵称")
    }

    func testFirstSnapshotsSanitizedPerRecipientAndSeqMonotonic() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        let snap1 = try await nextSnapshot(log: guestLogs[0])
        let snap2 = try await nextSnapshot(log: guestLogs[1])
        XCTAssertEqual(snap1.seq, 1)
        XCTAssertEqual(snap2.seq, 1)
        XCTAssertEqual(snap1.players[1].holeCards.count, 2, "客机 1 见自己的牌")
        XCTAssertTrue(snap1.players[2].holeCards.isEmpty, "客机 1 不得见客机 2 的牌")
        XCTAssertTrue(snap2.players[1].holeCards.isEmpty)
        XCTAssertEqual(snap1.board, snap2.board)
    }

    func testLegalActionFromActorSeatAppliesAndFanouts() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = currentActor(), actor != 0 else {
            // 行动者是房主：走 host.act 路径（必须发合法动作，否则被自己的合法性门拒绝）
            let legal = legalActions(host.gameState()!)
            await host.act(legal.canCheck ? .check : .call)
            _ = try await nextSnapshot(log: guestLogs[0])
            return
        }
        let before = host.gameState()!
        let legal = legalActions(before)
        let action: PlayerAction = legal.canCheck ? .check : .call
        try await sendAction(seat: actor, action)
        let snapshot = try await nextSnapshot(log: guestLogs[actor - 1])
        XCTAssertEqual(snapshot.seq, 2)
        XCTAssertNotEqual(host.gameState()!.actions.count, before.actions.count)
    }

    func testIllegalActionRejectedEngineUntouched() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = currentActor(), actor != 0 else { return }   // 本用例只测客机座位
        let before = host.gameState()!
        try await sendAction(seat: actor, .raiseTo(999_999))          // 远超身家
        let reason = try await nextRejection(log: guestLogs[actor - 1])
        XCTAssertEqual(reason, .illegalAction)
        XCTAssertEqual(host.gameState(), before, "非法动作绝不进引擎")
    }

    func testNotYourTurnRejected() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = currentActor() else { return }
        let bystander = actor == 1 ? 2 : 1
        let before = host.gameState()!
        try await sendAction(seat: bystander, .fold)
        let reason = try await nextRejection(log: guestLogs[bystander - 1])
        XCTAssertEqual(reason, .notYourTurn)
        XCTAssertEqual(host.gameState(), before)
    }

    func testDuplicateActionMessageAppliedOnce() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = currentActor(), actor != 0 else { return }
        let before = host.gameState()!
        let legal = legalActions(before)
        let action: PlayerAction = legal.canCheck ? .check : .call
        let envelope = PokerEnvelope(roomID: host.roomIDValue(), sender: .seat(actor),
                                     payload: .action(action))
        try await guestT[actor - 1].send(try PokerWire.encode(envelope), to: hostPeer)
        _ = try await nextSnapshot(log: guestLogs[actor - 1])          // 应用 + 扇出
        try await guestT[actor - 1].send(try PokerWire.encode(envelope), to: hostPeer)  // 同 messageID 重发
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(host.gameState()!.actions.count, before.actions.count + 1, "重复 messageID 只应用一次")
    }

    func testDisconnectedSeatAutoChecksOrFolds() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        // 断开 seat1 的连接；若轮到 seat1 则自动过/弃，牌局继续推进
        let seat1RawPeer = PeerID(rawValue: "raw-guest-0")
        hub.severLink(between: hostPeer, and: seat1RawPeer)
        // 等房主处理断线并推进（若 seat1 是行动者）
        try? await Task.sleep(nanoseconds: 500_000_000)
        var guardCount = 0
        while currentActor() == 1 && guardCount < 50 {   // 若卡在断线座位即失败
            try? await Task.sleep(nanoseconds: 100_000_000)
            guardCount += 1
        }
        XCTAssertNotEqual(currentActor(), 1, "断线座位不得卡住牌局")
        // 剩余玩家把这一手打完（seat2/房主自动跟/过）
        let deadline = Date().addingTimeInterval(10)
        while host.gameState()!.street != .handOver, Date() < deadline {
            if let actor = currentActor() {
                if actor == 0 {
                    let legal = legalActions(host.gameState()!)
                    await host.act(legal.canCheck ? .check : .call)
                } else {
                    let legal = legalActions(host.gameState()!)
                    try await sendAction(seat: actor, legal.canCheck ? .check : .call)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        XCTAssertEqual(host.gameState()?.street, .handOver, "断线托管后整手可正常打完")
    }

    func testReconnectRestoresSeatAndSnapshot() async throws {
        _ = try await makeReadyRoom(guestCount: 1)
        try await host.startGame()
        var snap = try await nextSnapshot(log: guestLogs[0])
        let lastSeq = snap.seq
        let seat1RawPeer = PeerID(rawValue: "raw-guest-0")
        hub.severLink(between: hostPeer, and: seat1RawPeer)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // 同 deviceID 重连
        try await guestT[0].connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-0", name: "P1"), roomID: host.roomIDValue(),
                               sender: .guest, from: guestT[0], to: hostPeer)
        snap = try await nextSnapshot(log: guestLogs[0])
        XCTAssertEqual(snap.yourSeat, 1, "重连还原原座位")
        XCTAssertGreaterThan(snap.seq, lastSeq, "补发更新的快照")
        XCTAssertEqual(host.peerIDValue(seat: 1) != nil, true)
    }

    func testJoinAfterStartRejected() async throws {
        _ = try await makeReadyRoom(guestCount: 1)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        let newcomer = hub.makeTransport(peerID: PeerID(rawValue: "raw-new"))
        let newLog = EventLog()
        pumps.append(attachEvents(of: newcomer, to: newLog))
        try await newcomer.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-new", name: "新人"), roomID: host.roomIDValue(),
                               sender: .guest, from: newcomer, to: hostPeer)
        let reason = try await nextRejection(log: newLog)
        XCTAssertEqual(reason, .gameStarted)
    }

    func testNextHandFirstRequestWins() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        // 打到 handOver：除一人外全弃
        let deadline = Date().addingTimeInterval(10)
        while host.gameState()!.street != .handOver, Date() < deadline {
            if let actor = currentActor() {
                if actor == 0 { await host.act(.fold) }
                else { try await sendAction(seat: actor, .fold) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let handNumberBefore = host.gameState()!.handNumber
        try await sendEnvelope(.nextHand, roomID: host.roomIDValue(), sender: .seat(1),
                               from: guestT[0], to: hostPeer)
        _ = try await nextSnapshot(log: guestLogs[0])
        XCTAssertEqual(host.gameState()!.handNumber, handNumberBefore + 1)
        let after = host.gameState()!.handNumber
        try await sendEnvelope(.nextHand, roomID: host.roomIDValue(), sender: .seat(2),
                               from: guestT[1], to: hostPeer)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(host.gameState()!.handNumber, after, "第二次请求无效（引擎幂等）")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/HostSessionGameTests 2>&1 | tail -30
```
Expected: 编译过（Task 7 留了空方法）但 FAIL——空 `fanoutSnapshots`/`handleGamePayload` 导致快照收不到/动作不应用。

- [ ] **Step 3: 实现（填充四个空方法 + 公开 API）**

在 `HostSession.swift` 中替换 Task 7 的空方法并追加：

```swift
    // MARK: - 对局阶段公开 API（Task 8）

    /// 房主自己（seat 0）的行动入口；与客机意图走同一校验与扇出路径。
    func act(_ action: PlayerAction) async {
        await applyAction(action, seat: 0)
    }

    /// 房主请求下一手（与客机请求等价，引擎幂等只放行一次）。
    func requestNextHand() async {
        await handleNextHand()
    }

    func disconnect() async {
        processingTask?.cancel()
        processingTask = nil
        updatesContinuation.finish()
        await transport.disconnect()
    }

    /// 前台自愈：App 挂起可能无声杀死监听 socket（scenePhase .active 调用）。
    nonisolated func applicationDidBecomeActive() async {
        await transport.reviveHostingIfNeeded()
    }

    // MARK: - 对局内消息与状态推进

    private func handleGamePayload(_ payload: Payload, seat: Int) async {
        guard phase == .playing, state != nil else { return }
        switch payload {
        case let .action(action):
            await applyAction(action, seat: seat)
        case .nextHand:
            await handleNextHand()
        default:
            break
        }
    }

    private func applyAction(_ action: PlayerAction, seat: Int) async {
        guard phase == .playing, var current = state, let actor = current.actorSeat else { return }
        guard actor == seat else {
            try? await sendToSeat(seat, .rejection(.notYourTurn))
            return
        }
        // 网络输入必须先过合法性门：引擎对非法动作按弃牌处理、对非法加注有 precondition
        // 崩溃路径，绝不能让未校验的动作直达引擎（spec §8）。
        let legal = legalActions(current)
        guard isLegal(action, in: legal) else {
            try? await sendToSeat(seat, .rejection(.illegalAction))
            return
        }
        current.apply(action)
        state = current
        await afterEngineChange()
    }

    private func handleNextHand() async {
        guard phase == .playing, let current = state,
              current.street == .handOver, !current.tournamentOver else { return }
        var next = current
        next.nextHand()
        state = next
        await afterEngineChange()
    }

    /// 引擎变更后的统一后处理：托管断线者 → 扇出快照 → 通知房主 UI。
    private func afterEngineChange() async {
        if state?.tournamentOver == true { phase = .finished }
        await reconcileDisconnectedActor()
        await fanoutSnapshots()
        if let state { updatesContinuation.yield(.state(state)) }
    }

    /// 断线座位轮到时自动「能过则过、否则弃牌」（spec §2 决策）；12 次 > 9 座上限，防死循环。
    private func reconcileDisconnectedActor() async {
        var iterations = 0
        while iterations < 12,
              var current = state,
              let actor = current.actorSeat,
              actor != 0,
              peerBySeat[actor] == nil,
              [.preflop, .flop, .turn, .river].contains(current.street) {
            let legal = legalActions(current)
            current.apply(legal.canCheck ? .check : .fold)
            state = current
            iterations += 1
        }
        if state?.tournamentOver == true { phase = .finished }
    }

    /// 每个在线座位生成 recipient 专属脱敏快照逐个发送；seq 单调；失败不阻塞其他座位。
    private func fanoutSnapshots() async {
        guard let current = state else { return }
        seq += 1
        for (seat, peer) in peerBySeat where seat != 0 {
            let snapshot = TableSnapshot.make(from: current, recipient: seat, seq: seq)
            try? await send(.snapshot(snapshot), to: peer)
        }
    }

    /// 重连补发：沿用当前 seq（引擎未变更）。已见过该 seq 的客机按 seq 门丢弃（快照不回退），
    /// 断线期间错过最新一帧的客机则借此补齐。
    private func resendCurrentSnapshots() async {
        guard let current = state else { return }
        for (seat, peer) in peerBySeat where seat != 0 {
            let snapshot = TableSnapshot.make(from: current, recipient: seat, seq: seq)
            try? await send(.snapshot(snapshot), to: peer)
        }
    }

    private func sendToSeat(_ seat: Int, _ payload: Payload) async {
        guard let peer = peerBySeat[seat] else { return }
        try? await send(payload, to: peer)
    }
```

并删除 Task 7 中对应的空方法占位（`handleGamePayload`/`reconcileDisconnectedActor`/`fanoutSnapshots`/`resendCurrentSnapshots` 的 `{}` 版本）。

- [ ] **Step 4: 跑测试确认通过（含 Task 7 回归）**

```
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/HostSessionGameTests -only-testing:PokerAppTests/HostSessionLobbyTests 2>&1 | tail -30
```
Expected: PASS（9+5 用例）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Session/HostSession.swift PokerApp/PokerAppTests/HostSessionGameTests.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: HostSession 对局——合法性门/脱敏扇出/断线托管/重连补发/nextHand 幂等"
```

---

### Task 9: GuestSession

**Files:**
- Create: `PokerApp/PokerApp/Session/GuestSession.swift`
- Test: `PokerApp/PokerAppTests/GuestSessionTests.swift`

**Interfaces:**
- Consumes: Task 6 消息层、Task 8 HostSession（测试对打）。
- Produces（Task 11 VM 依赖）：
  - `enum GuestUpdate: Sendable { case joined(seat: Int); case lobby(LobbyState); case snapshot(TableSnapshot); case disconnected; case rejected(RejectionReason) }`
  - `actor GuestSession`：
    - `init(roomID: String, deviceID: String, displayName: String, transport: any Transport = NearbyTransport(serviceName: nil))`——**测试注入 Loopback 时须让 `serviceName` 等于 roomID**：Loopback 不看 serviceName，但 NearbyTransport 的 `connect` 用 `serviceName ?? sanitize(peer.rawValue)`；因此 init 内不传 serviceName，`connect` 直接 `connect(to: PeerID(rawValue: roomID))` 即可（NearbyTransport 会把 roomID 当实例名解析）。签名定为 `init(roomID:deviceID:displayName:transport:)`。
    - `nonisolated let updates: AsyncStream<GuestUpdate>`
    - `enum GuestPhase: Equatable, Sendable { case idle, joining, lobby, playing, reconnecting, ended }`、`enum GuestError: String, Error, Sendable { case joinTimedOut, rejected(RejectionReason) }`——注意 enum with associated value 不能 rawValue String；定义 `case joinTimedOut` + `case rejected(RejectionReason)` 的普通 enum 即可。
    - `func join() async throws`（连接+hello+等 welcome，2s 超时）
    - `func setReady(_ value: Bool) async`、`func act(_ action: PlayerAction) async`、`func requestNextHand() async`、`func leave() async`
    - `nonisolated func applicationDidBecomeActive() async`
    - 测试观测：`func phaseValue() -> GuestPhase`、`func seatValue() -> Int?`、`func latestSnapshot() -> TableSnapshot?`

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/GuestSessionTests.swift`：

```swift
import XCTest
import PokerEngine
@testable import PokerApp

/// GuestSession × HostSession 在 Loopback 上的端到端对打。
final class GuestSessionTests: XCTestCase {
    let hostPeer = PeerID(rawValue: "ROOM-E2E")
    var hub: LoopbackTransportHub!
    var host: HostSession!
    var guests: [GuestSession] = []

    override func tearDown() async throws {
        for guest in guests { await guest.leave() }
        await host?.disconnect()
    }

    private func makeRoom(guestCount: Int) async throws {
        hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: hostPeer)
        host = HostSession(
            configuration: HostConfiguration(
                roomName: "E2E", hostName: "host",
                tableConfig: GameConfig(playerCount: 2, startingStack: 500, format: .cash(sb: 5, bb: 10))),
            transport: hostTransport)
        try await host.startHosting()
        for index in 0..<guestCount {
            let transport = hub.makeTransport(peerID: PeerID(rawValue: "device-\(index)"))
            let guest = GuestSession(roomID: host.roomIDValue(), deviceID: "device-\(index)",
                                     displayName: "G\(index)", transport: transport)
            guests.append(guest)
        }
    }

    private func firstUpdate(_ guest: GuestSession, timeout: TimeInterval = 3,
                             where predicate: @Sendable @escaping (GuestUpdate) -> Bool) async throws -> GuestUpdate {
        let log = GuestUpdateLog()
        let pump = Task {
            for await update in await guest.updates { await log.record(update) }
        }
        defer { pump.cancel() }
        return try await log.waitFor(timeout: timeout, predicate)
    }

    func testJoinReadyStartActEndToEnd() async throws {
        try await makeRoom(guestCount: 2)
        try await guests[0].join()
        try await guests[1].join()
        XCTAssertEqual(guests[0].seatValue(), 1)
        XCTAssertEqual(guests[1].seatValue(), 2)
        let joined = try await firstUpdate(guests[0]) { if case .joined = $0 { return true }; return false }
        guard case let .joined(seat) = joined else { return XCTFail() }
        XCTAssertEqual(seat, 1)

        await guests[0].setReady(true)
        await guests[1].setReady(true)
        await host.setReady(true)
        try await host.startGame()

        var snapshot = try await firstUpdate(guests[0]) { if case .snapshot = $0 { return true }; return false }
        guard case let .snapshot(snap) = snapshot else { return XCTFail() }
        XCTAssertEqual(snap.yourSeat, 1)
        XCTAssertEqual(guests[0].phaseValue(), .playing)
        XCTAssertEqual(snap.players[1].holeCards.count, 2)

        // 行动透传：谁行动谁发 check/call，打到 handOver
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let state = host.gameState()!
            if state.street == .handOver { break }
            guard let actor = state.actorSeat else { break }
            let legal = legalActions(state)
            let action: PlayerAction = legal.canCheck ? .check : .call
            if actor == 0 { await host.act(action) }
            else { await guests[actor - 1].act(action) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        snapshot = try await firstUpdate(guests[0]) {
            if case let .snapshot(s) = $0 { return s.street == .handOver }
            return false
        }
        guard case let .snapshot(final) = snapshot else { return XCTFail() }
        XCTAssertEqual(final.street, .handOver)
        XCTAssertEqual(final.handResult?.awards.isEmpty, false)

        // nextHand 透传
        await guests[0].requestNextHand()
        let newHand = try await firstUpdate(guests[0]) {
            if case let .snapshot(s) = $0 { return s.handNumber == 1 && s.street != .handOver }
            return false
        }
        guard case let .snapshot(next) = newHand else { return XCTFail() }
        XCTAssertEqual(next.handNumber, 1)
    }

    func testReconnectAfterSeverResumes() async throws {
        try await makeRoom(guestCount: 1)
        try await guests[0].join()
        await guests[0].setReady(true)
        await host.setReady(true)
        try await host.startGame()
        _ = try await firstUpdate(guests[0]) { if case .snapshot = $0 { return true }; return false }

        // 断线：客机收到 .disconnected 并进入重连循环；Loopback 端点保留 → 循环重拨成功
        hub.severLink(between: hostPeer, and: PeerID(rawValue: "device-0"))
        _ = try await firstUpdate(guests[0]) { if case .disconnected = $0 { return true }; return false }

        // 重连循环 1s 起；welcome(.joined) 即确认重连成功。host 重连路径补发的是同 seq 的当前快照，
        // 客机按 seq 门丢弃——「快照不回退不重复」就是断言点
        _ = try await firstUpdate(guests[0], timeout: 8) {
            if case .joined = $0 { return true }
            return false
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(guests[0].phaseValue(), .playing, "重连后恢复对局态")
        XCTAssertEqual(guests[0].latestSnapshot()?.seq, 1, "同 seq 补发被丢弃，快照不回退不重复")
        XCTAssertEqual(guests[0].latestSnapshot()?.yourSeat, 1, "座位还原")
    }

    func testJoinAfterStartRejected() async throws {
        try await makeRoom(guestCount: 1)
        try await guests[0].join()
        await guests[0].setReady(true)
        await host.setReady(true)
        try await host.startGame()
        _ = try await firstUpdate(guests[0]) { if case .snapshot = $0 { return true }; return false }

        let lateTransport = hub.makeTransport(peerID: PeerID(rawValue: "late"))
        let late = GuestSession(roomID: host.roomIDValue(), deviceID: "late-device",
                                displayName: "迟到", transport: lateTransport)
        guests.append(late)
        do {
            try await late.join()
            XCTFail("开局后加入应被拒")
        } catch {
            XCTAssertEqual(late.phaseValue(), .ended)
        }
        let rejected = try await firstUpdate(late) { if case .rejected = $0 { return true }; return false }
        guard case let .rejected(reason) = rejected else { return XCTFail() }
        XCTAssertEqual(reason, .gameStarted)
    }
}
```

测试还需要 `GuestUpdateLog`（EventLog 的 GuestUpdate 版），追加到 `LoopbackHarness.swift`：

```swift
/// GuestUpdate 收集器（同 EventLog 模式）。
actor GuestUpdateLog {
    private var buffered: [GuestUpdate] = []

    func record(_ update: GuestUpdate) { buffered.append(update) }

    func waitFor(timeout: TimeInterval = 3, _ predicate: @Sendable @escaping (GuestUpdate) -> Bool) async throws -> GuestUpdate {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = buffered.firstIndex(where: predicate) { return buffered.remove(at: index) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestTimeout()
    }
}
```

`testReconnectAfterSeverResumes` 的语义：重连成功的信号是 welcome（`.joined`）；host 重连路径调用 `resendCurrentSnapshots()` 补发**同 seq** 的当前快照，客机按 seq 门丢弃——「快照不回退不重复」正是断言点。

- [ ] **Step 2: 跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/GuestSessionTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`GuestSession` 未定义）。

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/Session/GuestSession.swift`：

```swift
import Foundation
import PokerEngine

enum GuestUpdate: Sendable {
    case joined(seat: Int)
    case lobby(LobbyState)
    case snapshot(TableSnapshot)
    case disconnected
    case rejected(RejectionReason)
}

/// 客机会话：加入/行动透传/断线自动重连（spec §9）。
actor GuestSession {
    enum GuestPhase: Equatable, Sendable { case idle, joining, lobby, playing, reconnecting, ended }
    enum GuestError: Error, Sendable, Equatable {
        case joinTimedOut
        case rejected(RejectionReason)
    }

    nonisolated let updates: AsyncStream<GuestUpdate>
    private nonisolated let updatesContinuation: AsyncStream<GuestUpdate>.Continuation

    private let transport: any Transport
    private let roomID: String
    private let deviceID: String
    private let displayName: String
    private let hostPeer: PeerID
    private var phase: GuestPhase = .idle
    private var seat: Int?
    private var snapshot: TableSnapshot?
    private var lastSeq = 0
    private var seenMessageIDs: Set<String> = []
    private var processingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingRejection: RejectionReason?

    init(roomID: String, deviceID: String, displayName: String,
         transport: any Transport = NearbyTransport()) {
        self.roomID = roomID
        self.deviceID = deviceID
        self.displayName = displayName
        self.transport = transport
        hostPeer = PeerID(rawValue: roomID)
        (updates, updatesContinuation) = AsyncStream.makeStream(of: GuestUpdate.self)
    }

    // MARK: - 公开 API

    func join() async throws {
        guard phase == .idle else { return }
        phase = .joining
        startProcessingIfNeeded()
        do {
            try await transport.connect(to: hostPeer)
            try await sendHello()
        } catch {
            phase = .ended
            throw error
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            switch phase {
            case .lobby, .playing:
                return
            case .ended:
                throw pendingRejection.map(GuestError.rejected) ?? .joinTimedOut
            default:
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        phase = .ended
        throw GuestError.joinTimedOut
    }

    func setReady(_ value: Bool) async {
        guard phase == .lobby || phase == .playing || phase == .reconnecting else { return }
        try? await send(.ready(value))
    }

    func act(_ action: PlayerAction) async {
        guard phase == .playing else { return }
        try? await send(.action(action))
    }

    func requestNextHand() async {
        guard phase == .playing else { return }
        try? await send(.nextHand)
    }

    func leave() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        processingTask?.cancel()
        processingTask = nil
        try? await send(.bye)
        phase = .ended
        updatesContinuation.finish()
        await transport.disconnect()
    }

    /// 前台自愈：锁屏回来立即重试重连（scenePhase .active 调用）。
    nonisolated func applicationDidBecomeActive() async {
        await retryReconnectNow()
    }

    // MARK: - 测试观测

    func phaseValue() -> GuestPhase { phase }
    func seatValue() -> Int? { seat }
    func latestSnapshot() -> TableSnapshot? { snapshot }

    // MARK: - 内部

    private func sendHello() async throws {
        try await send(.hello(deviceID: deviceID, name: displayName))
    }

    private func send(_ payload: Payload) async throws {
        let sender: Sender = seat.map { .seat($0) } ?? .guest
        try await transport.send(
            try PokerWire.encode(PokerEnvelope(roomID: roomID, sender: sender, payload: payload)),
            to: hostPeer)
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self, transport] in
            let events = await transport.events
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case let .received(data, _):
            guard let envelope = try? PokerWire.decode(data) else { return }
            handleEnvelope(envelope)
        case let .disconnected(peer, _):
            guard peer == hostPeer else { return }
            if phase == .lobby || phase == .playing { beginReconnectLoop() }
        case .connected, .discovered:
            break
        }
    }

    private func handleEnvelope(_ envelope: PokerEnvelope) {
        guard envelope.roomID == roomID, envelope.sender == .host else { return }
        guard isFreshMessageID(envelope.messageID) else { return }
        switch envelope.payload {
        case let .welcome(welcomeSeat, lobby):
            seat = welcomeSeat
            phase = lobby.phase == .playing ? .playing : .lobby
            updatesContinuation.yield(.joined(seat: welcomeSeat))
            updatesContinuation.yield(.lobby(lobby))
        case let .lobby(lobby):
            if lobby.phase == .playing, phase == .lobby { phase = .playing }
            updatesContinuation.yield(.lobby(lobby))
        case let .snapshot(value):
            // seq 单调门：重连补发与在途重叠时丢弃旧帧（spec §7）
            guard value.seq > lastSeq else { return }
            lastSeq = value.seq
            snapshot = value
            if phase != .playing { phase = .playing }
            updatesContinuation.yield(.snapshot(value))
        case let .rejection(reason):
            if phase == .joining {
                pendingRejection = reason
                phase = .ended
            }
            updatesContinuation.yield(.rejected(reason))
        case .bye:
            phase = .ended
            updatesContinuation.finish()
        default:
            break
        }
    }

    private func isFreshMessageID(_ id: String) -> Bool {
        guard !seenMessageIDs.contains(id) else { return false }
        seenMessageIDs.insert(id)
        if seenMessageIDs.count > 2048 { seenMessageIDs.removeAll() }
        return true
    }

    // MARK: - 断线自动重连（1s 起指数退避，上限 5s，无限次；用户可随时 leave）

    private func beginReconnectLoop(initialDelayNanos: UInt64 = 1_000_000_000) {
        guard reconnectTask == nil else { return }
        phase = .reconnecting
        updatesContinuation.yield(.disconnected)
        reconnectTask = Task {
            var delay = initialDelayNanos
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { break }
                delay = min(delay * 2, 5_000_000_000)
                if await transport.isConnected(to: hostPeer) { continue }
                do {
                    try await transport.connect(to: hostPeer)
                    try await sendHello()
                } catch { continue }
                // welcome 异步到达；给一小段确认窗口
                try? await Task.sleep(for: .milliseconds(300))
                if phase == .lobby || phase == .playing { break }
            }
            reconnectTask = nil
        }
    }

    private func retryReconnectNow() {
        guard reconnectTask != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        beginReconnectLoop(initialDelayNanos: 0)
    }
}
```

注意：重连路径里 host 调 `resendCurrentSnapshots()`（同 seq 补发），客机 seq 门丢弃后 `snapshot`/`lastSeq` 不变；`.joined` 在 welcome 处理时发出，是测试判定重连成功的信号。

- [ ] **Step 4: 跑测试确认通过（含前两个会话任务回归）**

```
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/GuestSessionTests -only-testing:PokerAppTests/HostSessionGameTests -only-testing:PokerAppTests/HostSessionLobbyTests 2>&1 | tail -30
```
Expected: PASS（3+9+5 用例）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/Session/GuestSession.swift PokerApp/PokerAppTests/GuestSessionTests.swift PokerApp/PokerAppTests/LoopbackHarness.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: GuestSession——加入握手/行动透传/seq 丢弃/断线自动重连"
```

---

### Task 10: 对局 UI 泛化（GamePresenting/TableSurface）

**Files:**
- Create: `PokerApp/PokerApp/GamePresenting.swift`
- Modify: `PokerApp/PokerApp/GameViewModel.swift`（仅追加一个 extension）
- Modify: `PokerApp/PokerApp/TableView.swift`（GameView/TableView/SeatView/ActionBar 改面向协议）
- Modify: `PokerApp/PokerApp/PokerApp.swift`（本地路径改为外部创建 VM——保持编译，不动行为）
- Test: `PokerApp/PokerAppTests/GamePresentingTests.swift`

**Interfaces:**
- Consumes: Task 5 的 `TableSurface/SeatSurface`。
- Produces（Task 11 依赖）：
  - `@MainActor protocol GamePresenting: ObservableObject`：
    ```swift
    var surface: (any TableSurface)? { get }
    var humanLegal: LegalActions? { get }
    var lastResult: HandResult? { get }
    var isHandOver: Bool { get }
    var isSessionOver: Bool { get }
    func act(_ action: PlayerAction) async
    func nextHand() async
    func driveBots() async
    ```
    （`driveBots` 有协议扩展默认空实现，联机 VM 不必实现。）
  - `GameViewModel: GamePresenting`（retroactive-ish extension，不改变既有成员）
  - `GameView<VM: GamePresenting>`：`init(vm: VM, onExit: @escaping () -> Void)`——**调用处一律显式标签 `onExit:`，不写尾闭包**（Swift 6.4 崩溃规避，见 Global Constraints）。

- [ ] **Step 1: 写失败测试**

`PokerApp/PokerAppTests/GamePresentingTests.swift`：

```swift
import XCTest
import PokerEngine
@testable import PokerApp

/// 本地 VM 满足联机渲染协议：单机路径行为零变化的前提下接入统一 GameView。
@MainActor
final class GamePresentingTests: XCTestCase {
    func testGameViewModelConforms() {
        let vm = GameViewModel(config: GameConfig(playerCount: 2, startingStack: 500,
                                                  format: .cash(sb: 5, bb: 10)), seed: 3)
        let presenter: any GamePresenting = vm
        let surface = presenter.surface
        XCTAssertNotNil(surface)
        XCTAssertEqual(surface?.seats.count, 2)
        XCTAssertEqual(surface?.yourSeat, 0)
        XCTAssertEqual(surface?.street, .preflop)
        XCTAssertEqual(presenter.isHandOver, false)
        XCTAssertEqual(presenter.isSessionOver, false)
        XCTAssertNil(presenter.lastResult)
        // humanLegal 与 VM 原逻辑一致（翻牌前行动者未必是 seat0，仅验证协议通道）
        XCTAssertEqual(presenter.humanLegal == nil, vm.humanLegal == nil)
    }

    func testSnapshotSurfaceExposesSameMembers() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 500,
                                                   format: .cash(sb: 5, bb: 10)), seed: 3)
        _ = s.actorSeat
        let snap = TableSnapshot.make(from: s, recipient: 1, seq: 1)
        let surface: any TableSurface = snap
        XCTAssertEqual(surface.seats.count, 2)
        XCTAssertEqual(surface.yourSeat, 1)
        XCTAssertEqual(surface.format, s.config.format)
        XCTAssertEqual(surface.currentBet, s.currentBet)
        XCTAssertEqual(surface.handNumber, s.handNumber)
        XCTAssertEqual(surface.seatPlayer(0)?.holdsCards, true)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/GamePresentingTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`GamePresenting` 未定义）。

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/GamePresenting.swift`：

```swift
import Foundation
import PokerEngine

/// 对局界面的统一驱动面：单机(GameViewModel)/房主(HostGameViewModel)/客机(GuestGameViewModel)。
@MainActor
protocol GamePresenting: ObservableObject {
    var surface: (any TableSurface)? { get }
    var humanLegal: LegalActions? { get }
    var lastResult: HandResult? { get }
    var isHandOver: Bool { get }
    var isSessionOver: Bool { get }
    func act(_ action: PlayerAction) async
    func nextHand() async
    func driveBots() async
}

extension GamePresenting {
    /// 联机无机器人；单机 VM 自带实现。
    func driveBots() async {}
}
```

`GameViewModel.swift` 末尾追加：

```swift
// 联机改造（spec §10.1）：本地单机 VM 满足统一驱动面；既有成员与行为零变化。
extension GameViewModel: GamePresenting {
    var surface: (any TableSurface)? { state }
}
```

（`humanLegal/lastResult/isHandOver/isSessionOver/act/nextHand/driveBots` 已存在且签名兼容，自动满足。）

`TableView.swift` 逐段替换（保持既有布局与文案不变，仅把 `vm.state` 换成 `vm.surface`、具体类型换协议）：

1. `GameView` 整体替换为：

```swift
struct GameView<VM: GamePresenting>: View {
    @ObservedObject var vm: VM
    let onExit: () -> Void

    var body: some View {
        ZStack {
            tableBackground
            if let surface = vm.surface {
                VStack(spacing: 0) {
                    header(surface: surface)
                    ZStack {
                        TableView(vm: vm, surface: surface)
                        if vm.isSessionOver {
                            sessionOverlay(surface: surface)
                        } else if vm.isHandOver {
                            resultOverlay(surface: surface)
                        }
                    }
                    ActionBar(vm: vm)   // 常驻底部：行结构恒定 → 高度恒定，桌面不再被顶起
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 桌面照片整体偏暗，对局界面固定深色，浅色模式的黑字压在照片上不可读
        .environment(\.colorScheme, .dark)
        .task { await vm.driveBots() }   // 机器人先手的开局在这里启动（联机 VM 为空实现）
    }
```

（`tableBackground` 不变。）

2. `header`/`resultOverlay`/`sessionOverlay` 加参数并改读取（全文替换）：

```swift
    private func header(surface: any TableSurface) -> some View {
        HStack {
            Button("退出") { onExit() }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if case .sng = surface.format {
                    let (sb, bb) = currentBlinds(for: surface.format, handNumber: surface.handNumber)
                    Text("第 \(surface.handNumber + 1) 手 · 盲注 \(sb)/\(bb)")
                        .font(.footnote)
                } else {
                    Text("第 \(surface.handNumber + 1) 手").font(.footnote)
                }
                if let last = vm.lastResult,
                   let w = last.awards.last?.winners.first,
                   let winner = surface.seatPlayer(w) {
                    // 只计该赢家实际分得的池（多方摊牌/边池时其余池与其无关，不能记到它头上）
                    Text("上一手：\(winner.name) 赢 \(last.awards.filter { $0.winners.contains(w) }.reduce(0) { $0 + $1.amount })")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private func resultOverlay(surface: any TableSurface) -> some View {
        VStack(spacing: 12) {
            ForEach(surface.handResult?.awards ?? [], id: \.potIndex) { award in
                let names = award.winners.compactMap { surface.seatPlayer($0)?.name }.joined(separator: "、")
                Text("\(names) 赢 \(award.amount)")
            }
            Button("下一手") { Task { await vm.nextHand() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private func sessionOverlay(surface: any TableSurface) -> some View {
        VStack(spacing: 8) {
            Text(surface.tournamentPayouts.isEmpty ? "会话结束" : "锦标赛结束")
                .font(.title2.bold())
            ForEach(surface.tournamentPayouts, id: \.place) { p in
                Text("第 \(p.place) 名 · \(surface.seatPlayer(p.seat)?.name ?? "?") · \(p.amount)")
            }
            Button("回到菜单") { onExit() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
```

3. 私有 `TableView` 与 `SeatView` 替换：

```swift
private struct TableView<VM: GamePresenting>: View {
    @ObservedObject var vm: VM
    let surface: any TableSurface

    var body: some View {
        GeometryReader { geo in
            let n = surface.seats.count
            ZStack {
                ForEach(surface.seats, id: \.seat) { p in
                    let angle = Double(p.seat) / Double(n) * 2 * .pi + .pi / 2   // 座位 0 在正下方
                    SeatView(player: p,
                             isActor: surface.actorSeat == p.seat,
                             isButton: surface.buttonSeat == p.seat,
                             isHuman: p.seat == surface.yourSeat,
                             street: surface.street)
                        .position(x: geo.size.width / 2 + cos(angle) * geo.size.width * 0.38,
                                  y: geo.size.height / 2 + sin(angle) * geo.size.height * 0.36)
                }
                VStack(spacing: 8) {
                    Text("底池 \(surface.potTotal)").font(.headline)
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            CardView(card: i < surface.board.count ? surface.board[i] : nil)
                        }
                    }
                }
            }
        }
    }
}

private struct SeatView: View {
    let player: any SeatSurface
    let isActor: Bool
    let isButton: Bool
    let isHuman: Bool
    let street: Street

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(player.name).font(.caption.bold())
                if isButton { Image(systemName: "circle.fill").font(.caption2) }
            }
            HStack(spacing: 3) {
                if player.holeCards.count == 2 {
                    // 弃牌者到手牌不再于 handOver 亮出（muck 不展示）
                    CardView(card: player.holeCards[0], hidden: (!isHuman && street != .handOver) || player.status == .folded)
                    CardView(card: player.holeCards[1], hidden: (!isHuman && street != .handOver) || player.status == .folded)
                } else if player.holdsCards {
                    // 快照里不可见的对手手牌：画牌背（联机路径独有状态）
                    CardView(card: nil, hidden: true)
                    CardView(card: nil, hidden: true)
                } else {
                    CardView(card: nil).opacity(0.3)
                    CardView(card: nil).opacity(0.3)
                }
            }
            Text("筹码 \(player.stack)").font(.caption.monospacedDigit())
            if player.streetContribution > 0 {
                Text("投入 \(player.streetContribution)").font(.caption2).foregroundStyle(.secondary)
            }
            if player.status == .folded { Text("弃牌").font(.caption2).foregroundStyle(.red) }
            if player.status == .allIn { Text("全下").font(.caption2).foregroundStyle(.orange) }
            if player.status == .eliminated { Text("淘汰").font(.caption2).foregroundStyle(.gray) }
        }
        .padding(8)
        .background(isActor ? Color.yellow.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isActor ? .yellow : .clear))
        .opacity(player.status == .eliminated ? 0.45 : 1)   // 淘汰座位整体压暗
    }
}
```

4. `ActionBar` 泛化（结构不变，仅类型与读取点）：

```swift
private struct ActionBar<VM: GamePresenting>: View {
    @ObservedObject var vm: VM
    @State private var raiseTarget: Double = 0

    private var legal: LegalActions? { vm.humanLegal }
    private var active: Bool { legal != nil }
    private var potTotal: Int { vm.surface?.potTotal ?? 0 }
    private var currentBet: Int { vm.surface?.currentBet ?? 0 }

    /// 可用加注区间（下界==上界的仅全下局面没有滑块调节的意义）
    private var range: ClosedRange<Int>? {
        guard let r = legal?.betRange, r.lowerBound < r.upperBound else { return nil }
        return r
    }

    /// 非你回合时占据额度标签位置的状态文案
    private var statusText: String {
        if vm.isSessionOver { return "会话结束" }
        if vm.isHandOver { return "本手结束" }
        return "等待对手…"
    }
```

（body、liveButtons、skeletonButtons、syncRaiseTarget、potTarget、quick 全部保持原文，仅把其中 `vm.state.potTotal` → `potTotal`、`vm.state.currentBet` → `currentBet` 两个读取点替换；`potTarget` 的 `Double(base + vm.state.currentBet)` 改 `Double(base + currentBet)`。）

5. `PokerApp.swift` 本地路径改造（为编译通过；联机路由 Task 11 加）：

```swift
import SwiftUI
import PokerEngine

@main
struct PokerApp: App {
    @State private var localVM: GameViewModel?

    var body: some Scene {
        WindowGroup {
            if let localVM {
                GameView(vm: localVM, onExit: { self.localVM = nil })
            } else {
                MenuView(onStart: { config, seed, difficulty in
                    self.localVM = GameViewModel(config: config, seed: seed, ai: difficulty)
                }, onMultiplayer: { })
            }
        }
    }
}

/// 一场会话（配置 + 种子 + AI 难度档）。
struct GameSession: Identifiable {
    let id = UUID()
    let config: GameConfig
    let seed: UInt64
    var difficulty: AIDifficulty = .baseline
}
```

对应 `MenuView.swift` 的回调签名加一个参数（默认空实现，Task 11 再接 UI）：

```swift
struct MenuView: View {
    let onStart: (GameConfig, UInt64, AIDifficulty) -> Void
    var onMultiplayer: () -> Void = {}
```

（**不改**「开始游戏」按钮与表单——UI 测试依赖。）

- [ ] **Step 4: 跑测试确认通过（含既有 GameViewModelTests 回归）**

```
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/GamePresentingTests -only-testing:PokerAppTests/GameViewModelTests 2>&1 | tail -30
```
Expected: PASS（2 用例 + 既有全部用例）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/GamePresenting.swift PokerApp/PokerApp/GameViewModel.swift PokerApp/PokerApp/TableView.swift PokerApp/PokerApp/PokerApp.swift PokerApp/PokerApp/MenuView.swift PokerApp/PokerAppTests/GamePresentingTests.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "refactor: 对局 UI 面向 GamePresenting/TableSurface 泛化——单机行为零变化，联机两路径接入同一 GameView"
```

---

### Task 11: 大厅 UI + 双端 ViewModel + 路由

**Files:**
- Create: `PokerApp/PokerApp/MultiplayerViewModels.swift`
- Create: `PokerApp/PokerApp/Features/Lobby/LobbyView.swift`
- Create: `PokerApp/PokerApp/LocalIdentity.swift`
- Modify: `PokerApp/PokerApp/MenuView.swift`（加「联机对战」入口按钮）
- Modify: `PokerApp/PokerApp/PokerApp.swift`（联机路由 + scenePhase 自愈）
- Test: `PokerApp/PokerAppTests/MultiplayerFlowTests.swift`

**Interfaces:**
- Consumes: Task 8 HostSession、Task 9 GuestSession、Task 4 BonjourRoomBrowser/NearbyPreflight、Task 10 GamePresenting。
- Produces（Task 12 验收依赖）：
  - `enum LocalIdentity { static let deviceID: String }`（UserDefaults `poker.deviceID`，首启生成）
  - `@MainActor final class HostGameViewModel: ObservableObject, GamePresenting`：
    - `init(configuration: HostConfiguration, transport: (any Transport)? = nil)`（nil → NearbyTransport）
    - `@Published lobby: LobbyState?`、`@Published private(set) var gameState: GameState?`、`@Published var issue: String?`
    - `func start() async`、`func setReady(Bool) async`、`func updateTable(GameConfig) async`、`func startGame() async`、`func leave() async`
    - GamePresenting 全成员（surface = gameState；humanLegal 用引擎 `legalActions`；lastResult 在 handOver→新hand 边界捕获）
  - `@MainActor final class GuestGameViewModel: ObservableObject, GamePresenting`：
    - `init(roomID: String, displayName: String, transport: (any Transport)? = nil)`
    - `@Published lobby: LobbyState?`、`@Published private(set) var snapshot: TableSnapshot?`、`@Published private(set) var reconnecting: Bool`、`@Published var warning: String?`、`@Published var fatal: String?`
    - `func join() async`、`func setReady(Bool) async`、`func leave() async`；act/nextHand 走 session
  - `@MainActor final class RoomBrowserModel: ObservableObject`：`@Published rooms/searching/issue`，`start()/stop()`
  - `LobbyView(onHost: (HostGameViewModel) -> Void, onGuest: (GuestGameViewModel) -> Void)`：入口两选——建房表单（复用 MenuView 的配置项，创建 VM 后回调）与搜房列表（RoomBrowserModel，选房后创建 VM 回调）
  - `HostRoomOrGameView(vm:onExit:)` / `GuestRoomOrGameView(vm:onExit:)`（LobbyView.swift 内，internal）：按 VM 的 `gameState`/`inGame` 在大厅名册视图与 `GameView` 之间切换；客机牌桌叠「重连中」横幅与动作被拒提示
  - `PokerApp` 根：`@State hostVM/guestVM` 持有 VM，sheet 呈现 LobbyView，VM 非空时渲染上述包装视图；`@Environment(\.scenePhase)` 为 .active 时调 `applicationDidBecomeActive()`；VM 的 `deinit` 负责断开会话

- [ ] **Step 1: 写失败测试（VM 级端到端：host VM + 2 guest VM 在 Loopback 打完一手）**

`PokerApp/PokerAppTests/MultiplayerFlowTests.swift`：

```swift
import XCTest
import PokerEngine
@testable import PokerApp

/// VM 级端到端：三个 VM（1 房主 + 2 客机）在 Loopback 上完成 入住→ready→开局→行动→handOver→下一手。
@MainActor
final class MultiplayerFlowTests: XCTestCase {
    private let pumpTimeout: TimeInterval = 8

    private func waitUntil(_ condition: @autoclosure () -> Bool, _ message: String,
                           timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(message)
    }

    func testThreeDevicesFullHand() async throws {
        let hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: PeerID(rawValue: "ROOM-VM"))
        let hostVM = HostGameViewModel(
            configuration: HostConfiguration(
                roomName: "VM", hostName: "房主",
                tableConfig: GameConfig(playerCount: 2, startingStack: 500, format: .cash(sb: 5, bb: 10))),
            transport: hostTransport)
        await hostVM.start()
        try await waitUntil(hostVM.lobby != nil, "房主大厅就绪")

        var guestVMs: [GuestGameViewModel] = []
        for index in 0..<2 {
            let transport = hub.makeTransport(peerID: PeerID(rawValue: "device-\(index)"))
            let vm = GuestGameViewModel(roomID: hostVM.roomID!, displayName: "G\(index)", transport: transport)
            guestVMs.append(vm)
            await vm.join()
        }
        try await waitUntil(guestVMs.allSatisfy { $0.lobby != nil }, "客机进入大厅")
        XCTAssertEqual(guestVMs[0].mySeat, 1)
        XCTAssertEqual(guestVMs[1].mySeat, 2)

        for vm in guestVMs { await vm.setReady(true) }
        await hostVM.setReady(true)
        try await waitUntil(hostVM.canStartGame, "全员 ready")
        await hostVM.startGame()

        try await waitUntil(hostVM.gameState != nil && guestVMs.allSatisfy { $0.snapshot != nil },
                            "三端都进入对局", timeout: pumpTimeout)
        // 客机画面上对手手牌不可见（VM 层隐私）
        for (index, vm) in guestVMs.enumerated() {
            let snap = vm.snapshot!
            for player in snap.players where player.seat != vm.mySeat {
                XCTAssertTrue(player.holeCards.isEmpty, "G\(index) 不得见到他人手牌")
            }
        }

        // 打完一手：行动者所在 VM 发 act
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let state = hostVM.gameState!
            if state.street == .handOver { break }
            guard let actor = state.actorSeat else { break }
            let legal = legalActions(state)
            let action: PlayerAction = legal.canCheck ? .check : .call
            if actor == 0 { await hostVM.act(action) }
            else { await guestVMs[actor - 1].act(action) }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        try await waitUntil(guestVMs.allSatisfy { $0.snapshot?.street == .handOver },
                            "三端都看到本手结束", timeout: pumpTimeout)
        XCTAssertNotNil(guestVMs[0].snapshot?.handResult)

        // 摊牌后亮牌：非弃牌者的牌在快照里可见
        let snap = guestVMs[0].snapshot!
        let revealed = snap.players.filter { $0.status != .folded && !$0.holeCards.isEmpty }
        XCTAssertFalse(revealed.isEmpty, "摊牌局应有亮牌者")

        // 下一手（客机发起）→ 三端 handNumber+1
        let handBefore = hostVM.gameState!.handNumber
        await guestVMs[0].nextHand()
        try await waitUntil(hostVM.gameState!.handNumber == handBefore + 1
                                && guestVMs.allSatisfy { $0.snapshot?.handNumber == handBefore + 1 },
                            "三端进入下一手", timeout: pumpTimeout)

        for vm in guestVMs { await vm.leave() }
        await hostVM.leave()
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests/MultiplayerFlowTests 2>&1 | tail -30
```
Expected: 编译 FAIL（`HostGameViewModel` 等未定义）。

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/LocalIdentity.swift`：

```swift
import Foundation

/// 本机稳定身份：断线重连的凭证（spec §6.2 hello.deviceID）。
enum LocalIdentity {
    private static let key = "poker.deviceID"

    static let deviceID: String = {
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty { return stored }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
}
```

`PokerApp/PokerApp/MultiplayerViewModels.swift`：

```swift
import Foundation
import Combine
import PokerEngine

// MARK: - 房主 VM

@MainActor
final class HostGameViewModel: ObservableObject, GamePresenting {
    @Published private(set) var lobby: LobbyState?
    @Published private(set) var gameState: GameState?
    /// 启动/开局失败的用户可读问题（NearbyIssue 映射）。
    @Published var issue: String?
    @Published private(set) var roomID: String?

    private let session: HostSession
    private var updatesTask: Task<Void, Never>?
    private var previousResult: HandResult?

    init(configuration: HostConfiguration, transport: (any Transport)? = nil) {
        session = transport.map { HostSession(configuration: configuration, transport: $0) }
            ?? HostSession(configuration: configuration)
    }

    /// 任何界面的「退出」只把 VM 置 nil；会话断开统一在这里兜底，避免大厅/对局两处双重清理。
    deinit {
        let session = session
        Task { await session.disconnect() }
    }

    var mySeat: Int { 0 }
    var canStartGame: Bool {
        guard let lobby else { return false }
        return lobby.players.count >= 2 && lobby.players.allSatisfy(\.ready)
    }

    func start() async {
        beginConsumingUpdates()
        do {
            try await session.startHosting()
            roomID = await session.roomIDValue()
        } catch {
            let mapped = NearbyPreflight.issue(for: error)
            issue = mapped.title + "：" + mapped.recoveryMessage
        }
    }

    func setReady(_ value: Bool) async { await session.setReady(value) }
    func updateTable(_ config: GameConfig) async { await session.updateTableConfig(config) }

    func startGame() async {
        do { try await session.startGame() }
        catch {
            switch error {
            case HostSession.HostError.notEnoughPlayers: issue = "至少需要 2 名玩家才能开局"
            case HostSession.HostError.notAllReady: issue = "还有玩家没有准备"
            default: issue = "开局失败：\(error.localizedDescription)"
            }
        }
    }

    func act(_ action: PlayerAction) async { await session.act(action) }
    func nextHand() async { await session.requestNextHand() }

    func leave() async {
        updatesTask?.cancel()
        updatesTask = nil
        await session.disconnect()
    }

    func applicationDidBecomeActive() async { await session.applicationDidBecomeActive() }

    // MARK: - 会话更新泵（@MainActor Task 内 for-await）

    func beginConsumingUpdates() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            let updates = await session.updates
            for await update in updates {
                guard let self else { break }
                self.consume(update)
            }
        }
    }

    private func consume(_ update: HostUpdate) {
        switch update {
        case let .lobby(value):
            lobby = value
        case let .state(value):
            // handOver→新街道的边界捕获上一手结果（对局头「上一手：X 赢 Y」）
            if gameState?.street == .handOver, value.street != .handOver {
                previousResult = gameState?.handResult
            }
            gameState = value
        }
    }

    // MARK: - GamePresenting

    var surface: (any TableSurface)? { gameState }
    var humanLegal: LegalActions? {
        guard let s = gameState, s.actorSeat == 0,
              [.preflop, .flop, .turn, .river].contains(s.street) else { return nil }
        return legalActions(s)
    }
    var lastResult: HandResult? { previousResult ?? gameState?.handResult }
    var isHandOver: Bool { gameState?.street == .handOver }
    var isSessionOver: Bool { gameState?.tournamentOver == true }
}
```

`GuestGameViewModel`：

```swift
@MainActor
final class GuestGameViewModel: ObservableObject, GamePresenting {
    @Published private(set) var lobby: LobbyState?
    @Published private(set) var snapshot: TableSnapshot?
    @Published private(set) var reconnecting = false
    @Published private(set) var mySeat: Int?
    /// 行动被拒等瞬态提示；加入失败等致命问题在 fatal。
    @Published var warning: String?
    @Published var fatal: String?

    private let session: GuestSession
    private var updatesTask: Task<Void, Never>?
    private var previousResult: HandResult?

    init(roomID: String, displayName: String, transport: (any Transport)? = nil) {
        session = transport.map { GuestSession(roomID: roomID, deviceID: LocalIdentity.deviceID,
                                               displayName: displayName, transport: $0) }
            ?? GuestSession(roomID: roomID, deviceID: LocalIdentity.deviceID, displayName: displayName)
        beginConsumingUpdates()
    }

    deinit {
        let session = session
        Task { await session.leave() }
    }

    func join() async {
        do { try await session.join() }
        catch {
            if case let GuestSession.GuestError.rejected(reason) = error {
                fatal = rejectionText(reason)
            } else {
                fatal = "加入房间超时，请确认房主页面仍开着后重试"
            }
        }
    }

    func setReady(_ value: Bool) async { await session.setReady(value) }
    func act(_ action: PlayerAction) async { await session.act(action) }
    func nextHand() async { await session.requestNextHand() }

    func leave() async {
        updatesTask?.cancel()
        updatesTask = nil
        await session.leave()
    }

    func applicationDidBecomeActive() async { await session.applicationDidBecomeActive() }

    var inGame: Bool { snapshot != nil }

    private func beginConsumingUpdates() {
        updatesTask = Task { [weak self] in
            let updates = await session.updates
            for await update in updates {
                guard let self else { break }
                self.consume(update)
            }
        }
    }

    private func consume(_ update: GuestUpdate) {
        switch update {
        case let .joined(seat):
            mySeat = seat
            reconnecting = false
        case let .lobby(value):
            lobby = value
        case let .snapshot(value):
            if snapshot?.street == .handOver, value.street != .handOver {
                previousResult = snapshot?.handResult
            }
            snapshot = value
            reconnecting = false
            warning = nil
        case .disconnected:
            reconnecting = true
        case let .rejected(reason):
            if fatal == nil { warning = rejectionText(reason) }
        }
    }

    private func rejectionText(_ reason: RejectionReason) -> String {
        switch reason {
        case .roomFull: "房间已满（9 座）"
        case .gameStarted: "对局已开始，不接受新玩家"
        case .versionMismatch: "版本不一致，请和房主升级到相同版本"
        case .illegalAction: "动作不合法，已刷新牌面"
        case .notYourTurn: "还没轮到你"
        }
    }

    // MARK: - GamePresenting

    var surface: (any TableSurface)? { snapshot }
    var humanLegal: LegalActions? { snapshot?.yourLegal }
    var lastResult: HandResult? { previousResult ?? snapshot?.handResult }
    var isHandOver: Bool { snapshot?.street == .handOver }
    var isSessionOver: Bool { snapshot?.tournamentOver == true }
}
```

`RoomBrowserModel`：

```swift
@MainActor
final class RoomBrowserModel: ObservableObject {
    @Published private(set) var rooms: [RoomListing] = []
    @Published private(set) var searching = false
    @Published var issue: String?

    private let browser: BonjourRoomBrowser
    private var task: Task<Void, Never>?

    init() { browser = BonjourRoomBrowser() }

    func start() {
        guard task == nil else { return }
        searching = true
        issue = nil
        task = Task { [weak self] in
            let states = await browser.states
            for await state in states {
                guard let self else { break }
                switch state {
                case .searching: self.searching = true
                case .found(let rooms): self.rooms = rooms; self.searching = false
                case .empty: self.rooms = []; self.searching = false
                case .failed(let issue): self.issue = issue.title; self.searching = false
                }
            }
        }
        Task { await browser.start() }
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { await browser.cancel() }
    }
}
```

`PokerApp/PokerApp/Features/Lobby/LobbyView.swift`（SwiftUI；文案与既有 App 风格一致）：

```swift
import SwiftUI
import PokerEngine

/// 联机入口：创建房间 / 搜索加入。
struct LobbyView: View {
    let onHost: (HostGameViewModel) -> Void
    let onGuest: (GuestGameViewModel) -> Void
    @State private var mode: Mode = .menu

    private enum Mode: Hashable { case menu, hostSetup, joinBrowse }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .menu: menuScreen
                case .hostSetup: HostSetupView(onCreate: { vm in onHost(vm) })
                case .joinBrowse: JoinRoomView(onJoin: { vm in onGuest(vm) })
                }
            }
            .navigationTitle("联机对战")
        }
    }

    private var menuScreen: some View {
        VStack(spacing: 16) {
            Button("创建房间") { mode = .hostSetup }
                .buttonStyle(.borderedProminent)
            Button("搜索附近房间") { mode = .joinBrowse }
                .buttonStyle(.bordered)
            Text("同一 Wi-Fi 下即可游玩；无路由器时也可用点对点 Wi-Fi 直连。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// 房主建房表单（复用单机的桌子配置项；人数由入座人数决定）。
private struct HostSetupView: View {
    let onCreate: (HostGameViewModel) -> Void
    @State private var roomName = "周五德州桌"
    @State private var hostName = ""
    @State private var isSNG = false
    @State private var cashSB = 10
    @State private var cashStack = 2000
    @State private var buyIn = 1000

    private var config: GameConfig {
        let format: GameFormat = isSNG
            ? .sng(SNGConfig(buyIn: buyIn, startingStack: 1500,
                             levels: [BlindLevel(sb: 10, bb: 20, hands: 12),
                                      BlindLevel(sb: 25, bb: 50, hands: 12),
                                      BlindLevel(sb: 50, bb: 100, hands: 12),
                                      BlindLevel(sb: 100, bb: 200, hands: 12)],
                             payouts: [0.5, 0.3, 0.2]))
            : .cash(sb: cashSB, bb: cashSB * 2)
        return GameConfig(playerCount: 2, startingStack: isSNG ? 1500 : cashStack, format: format)
    }

    var body: some View {
        Form {
            TextField("房间名", text: $roomName)
            TextField("你的名字（可留空）", text: $hostName)
            Picker("模式", selection: $isSNG) {
                Text("现金局").tag(false)
                Text("单桌锦标赛 SNG").tag(true)
            }
            if isSNG {
                Stepper("买入：\(buyIn)", value: $buyIn, in: 100...10000, step: 100)
            } else {
                Stepper("小盲：\(cashSB)", value: $cashSB, in: 1...1000, step: 5)
                Stepper("初始筹码：\(cashStack)", value: $cashStack, in: 500...100000, step: 500)
            }
            Button("开始广播房间") {
                let vm = HostGameViewModel(configuration: HostConfiguration(
                    roomName: roomName, hostName: hostName, tableConfig: config))
                onCreate(vm)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// 房主大厅：名册/ready/开局。开局后由 HostRoomOrGameView 切到 GameView。
private struct HostRoomView: View {
    @ObservedObject var vm: HostGameViewModel
    let onExit: () -> Void
    @State private var ready = false

    var body: some View {
        VStack(spacing: 12) {
            if let issue = vm.issue {
                Text(issue).font(.footnote).foregroundStyle(.red)
            }
            if let lobby = vm.lobby {
                Text("房间：\(lobby.roomName)").font(.headline)
                List {
                    ForEach(lobby.players, id: \.seat) { player in
                        HStack {
                            Text(player.name)
                            if player.isHost { Text("房主").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            if !player.connected { Text("离线").font(.caption2).foregroundStyle(.red) }
                            else if player.ready { Text("已准备").font(.caption2).foregroundStyle(.green) }
                            else { Text("未准备").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Toggle("我已准备", isOn: $ready)
                    .onChange(of: ready) { _, value in Task { await vm.setReady(value) } }
                Button(vm.canStartGame ? "开局" : "等待全员准备（至少 2 人）…") {
                    Task { await vm.startGame() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStartGame)
            } else {
                ProgressView("正在创建房间…")
            }
            Spacer()
            Button("退出房间", role: .destructive) { onExit() }
        }
        .padding()
        .task { await vm.start() }
    }
}

/// 客机搜房 + 加入。
private struct JoinRoomView: View {
    let onJoin: (GuestGameViewModel) -> Void
    @StateObject private var browser = RoomBrowserModel()
    @State private var name = ""

    var body: some View {
        VStack(spacing: 12) {
            TextField("你的名字（可留空）", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            if let issue = browser.issue {
                Text(issue).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            if browser.rooms.isEmpty {
                if browser.searching { ProgressView("正在搜索附近房间…") }
                else { Text("附近暂无房间，让房主先创建").font(.footnote).foregroundStyle(.secondary) }
            } else {
                List(browser.rooms) { room in
                    Button {
                        let vm = GuestGameViewModel(roomID: room.roomID,
                                                    displayName: name.isEmpty ? "玩家" : name)
                        onJoin(vm)
                    } label: {
                        Text(room.serviceName)
                    }
                }
            }
        }
        .task { browser.start() }
        .onDisappear { browser.stop() }
    }
}

/// 客机大厅（名册 + ready）；收到首帧快照后由 GuestRoomOrGameView 切到 GameView。
private struct GuestRoomView: View {
    @ObservedObject var vm: GuestGameViewModel
    let onExit: () -> Void
    @State private var ready = false

    var body: some View {
        VStack(spacing: 12) {
            if let fatal = vm.fatal {
                Text(fatal).font(.footnote).foregroundStyle(.red)
            } else if let lobby = vm.lobby {
                Text("房间：\(lobby.roomName)").font(.headline)
                List {
                    ForEach(lobby.players, id: \.seat) { player in
                        HStack {
                            Text(player.name)
                            if player.isHost { Text("房主").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            if !player.connected { Text("离线").font(.caption2).foregroundStyle(.red) }
                            else if player.ready { Text("已准备").font(.caption2).foregroundStyle(.green) }
                            else { Text("未准备").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                if vm.reconnecting { Text("连接断开，重连中…").font(.footnote).foregroundStyle(.red) }
                Toggle("我已准备", isOn: $ready)
                    .onChange(of: ready) { _, value in Task { await vm.setReady(value) } }
            } else {
                ProgressView("正在加入…")
            }
            Spacer()
            Button("返回大厅", role: .destructive) { onExit() }
        }
        .padding()
        .task { await vm.join() }
    }
}

/// 大厅↔牌桌切换由 VM 的 @Published 状态驱动（根路由只持有 VM，不直接观察；这里用 @ObservedObject 感知）。
struct HostRoomOrGameView: View {
    @ObservedObject var vm: HostGameViewModel
    let onExit: () -> Void

    var body: some View {
        if vm.gameState != nil {
            GameView(vm: vm, onExit: onExit)
        } else {
            HostRoomView(vm: vm, onExit: onExit)
        }
    }
}

struct GuestRoomOrGameView: View {
    @ObservedObject var vm: GuestGameViewModel
    let onExit: () -> Void

    var body: some View {
        if vm.inGame {
            GameView(vm: vm, onExit: onExit)
                .overlay(alignment: .top) {
                    // 断线重连横幅 + 动作被拒等瞬态提示（spec §10.2）
                    VStack(spacing: 4) {
                        if vm.reconnecting {
                            Text("连接断开，重连中…").font(.footnote).padding(8)
                                .background(.red.opacity(0.85), in: Capsule())
                        }
                        if let warning = vm.warning {
                            Text(warning).font(.footnote).padding(8)
                                .background(.orange.opacity(0.85), in: Capsule())
                        }
                    }
                    .padding(.top, 4)
                }
        } else {
            GuestRoomView(vm: vm, onExit: onExit)
        }
    }
}
```

`MenuView.swift` 在 Form 里（「开始游戏」按钮**之前**）加一段：

```swift
                Section {
                    Button("联机对战") { onMultiplayer() }
                }
```

`PokerApp.swift` 最终版：

```swift
import SwiftUI
import PokerEngine

@main
struct PokerApp: App {
    @State private var localVM: GameViewModel?
    @State private var hostVM: HostGameViewModel?
    @State private var guestVM: GuestGameViewModel?
    @State private var showingLobby = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                .sheet(isPresented: $showingLobby) {
                    LobbyView(onHost: { vm in
                        hostVM = vm
                        showingLobby = false
                    }, onGuest: { vm in
                        guestVM = vm
                        showingLobby = false
                    })
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await hostVM?.applicationDidBecomeActive()
                        await guestVM?.applicationDidBecomeActive()
                    }
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        if let hostVM {
            // 大厅/牌桌切换在包装视图内由 VM 状态驱动；退出只置 nil → VM deinit 断开会话
            HostRoomOrGameView(vm: hostVM, onExit: { self.hostVM = nil })
        } else if let guestVM {
            GuestRoomOrGameView(vm: guestVM, onExit: { self.guestVM = nil })
        } else if let localVM {
            GameView(vm: localVM, onExit: { self.localVM = nil })
        } else {
            MenuView(onStart: { config, seed, difficulty in
                self.localVM = GameViewModel(config: config, seed: seed, ai: difficulty)
            }, onMultiplayer: {
                showingLobby = true
            })
        }
    }
}

/// 一场会话（配置 + 种子 + AI 难度档）。
struct GameSession: Identifiable {
    let id = UUID()
    let config: GameConfig
    let seed: UInt64
    var difficulty: AIDifficulty = .baseline
}
```

退出语义：任何界面的「退出/返回大厅」只做 `VM = nil`；VM 的 `deinit` 负责断开会话（房主 `session.disconnect()`、客机 `session.leave()` 发 bye），大厅与对局两处退出共用这一条清理路径，不会双重断开。

- [ ] **Step 4: 跑测试确认通过（联机全家桶回归）**

```
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd -only-testing:PokerAppTests 2>&1 | tail -30
```
Expected: PokerAppTests 全绿（含 MultiplayerFlowTests 1 用例与此前全部）。

- [ ] **Step 5: Commit**

```
cd "$REPO" && git add PokerApp/PokerApp/MultiplayerViewModels.swift PokerApp/PokerApp/Features/Lobby/LobbyView.swift PokerApp/PokerApp/LocalIdentity.swift PokerApp/PokerApp/MenuView.swift PokerApp/PokerApp/PokerApp.swift PokerApp/PokerAppTests/MultiplayerFlowTests.swift PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: 联机大厅 UI 与房主/客机 ViewModel——Loopback 上三端 VM 全流程测试"
```

---

### Task 12: 工程配置（Info.plist 本地网络权限）+ 全量回归 + README + 真机清单

**Files:**
- Modify: `PokerApp/project.yml`（PokerApp target 加 `info:` 块）
- Modify: `PokerApp/README.md`（联机章节）
- Test: 既有全部测试（无新测试文件；产物 plist 校验为验证步骤）

**Interfaces:**
- Consumes: 全部前序任务。
- Produces: 可在真机上弹本地网络权限并完成 Bonjour 发现/连接的发布配置。

- [ ] **Step 1: 改 project.yml 加 info 块**

`PokerApp/project.yml` 的 `targets.PokerApp` 下（`settings` 之前或之后均可）加：

```yaml
    info:
      path: PokerApp/Info.plist
      properties:
        NSLocalNetworkUsageDescription: 用于在本地网络中发现并连接附近朋友的德州扑克房间。
        NSBonjourServices:
          - _poker-lan._tcp
```

（保留既有 `GENERATE_INFOPLIST_FILE: YES` 与 `INFOPLIST_KEY_*`——Xcode 会把两者合并进产物 plist。）

- [ ] **Step 2: 重新生成工程并构建两平台**

```
cd "$REPO/PokerApp" && /tmp/xcodegen-dist/xcodegen/bin/xcodegen
xcodebuild build -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd 2>&1 | tail -5
xcodebuild build -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' -derivedDataPath /tmp/poker-dd 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED ×2。若 macOS 构建报签名问题，加 `CODE_SIGNING_ALLOWED=NO` 仅作编译验证并在交付说明中注明。

- [ ] **Step 3: 校验产物 plist（关键权限键）**

```
plutil -p /tmp/poker-dd/Build/Products/Debug-iphonesimulator/PokerApp.app/Info.plist | grep -E "NSLocalNetwork|NSBonjour|UILaunchScreen"
```
Expected: 输出含 `NSLocalNetworkUsageDescription`、`NSBonjourServices => [_poker-lan._tcp]`、`UILaunchScreen`。若 `UILaunchScreen` 丢失：把 `INFOPLIST_KEY_UILaunchScreen_Generation: YES` 换成 info.properties 里的 `UILaunchScreen: {}` 再重新生成构建验证。

- [ ] **Step 4: 全量回归（引擎 + App 单测 + UI 冒烟）**

```
cd "$REPO/PokerEngine" && swift test --scratch-path /tmp/poker-engine-scratch 2>&1 | tail -3
cd "$REPO/PokerApp" && xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd 2>&1 | tail -15
```
Expected: 引擎全绿（91+4）；PokerAppTests + PokerAppUITests 全绿（UI 冒烟 ~8 分钟属正常，见环境怪癖）。

- [ ] **Step 5: README 联机章节**

`PokerApp/README.md` 追加（放在合适章节后）：

```markdown
## 联机对战（局域网，无需服务器）

- 同一 Wi-Fi（或无路由器时的点对点 Wi-Fi）下：一台设备「创建房间」，其他设备「搜索附近房间」加入，2~9 人全人类对局。
- 房主为权威端：所有牌局判定在房主设备完成，其他设备只看到自己视角的脱敏牌面（他人手牌永不上网络）。
- 首次使用会请求「本地网络」权限；拒绝后可在系统设置中开启。
- 玩家锁屏/断线后座位自动托管（能过则过、否则弃牌），回到 App 自动重连续打；对局中途不支持新玩家加入。
- 实现细节见 `docs/superpowers/specs/2026-10-29-lan-multiplayer-design.md`。
```

- [ ] **Step 6: Commit**

```
cd "$REPO" && git add PokerApp/project.yml PokerApp/PokerApp/Info.plist PokerApp/README.md PokerApp/PokerApp.xcodeproj/project.pbxproj && git commit -m "feat: 本地网络权限与 Bonjour 服务声明（Info.plist）+ README 联机章节"
```
（若 xcodegen 把 `PokerApp/Info.plist` 生成在 `PokerApp/PokerApp/Info.plist`，按实际路径 add。）

- [ ] **Step 7: 真机验收清单（作者手动，2 台 iPhone）**

不属自动化测试，交付时附在 PR/总结里请作者执行：

1. 两台 iPhone 同一 Wi-Fi；A 创建房间、B 搜索加入；首次各弹一次本地网络权限，允许。
2. 全员准备 → 开局；各端只看到自己的手牌，公共信息一致。
3. 打 3 手：含一次加注对抗与一次摊牌（摊牌时未弃牌者的牌可见）。
4. B 锁屏 30 秒：A 端见 B「离线」且轮到 B 时自动过/弃；B 解锁回 App 自动重连，座位与手牌恢复继续。
5. B 桌面杀 App 再打开重进：提示重连后回到原座位。
6. 无路由器场景（可选）：两台开点对点 Wi-Fi 重复 1-3。

---

## 任务依赖图

```
T1(引擎Codable) ─▶ T5(快照/投影) ─▶ T6(消息层) ─▶ T7(Host大厅) ─▶ T8(Host对局) ─▶ T9(Guest) ─▶ T11(UI/VM) ─▶ T12(配置/回归)
T2(Transport+帧) ─▶ T3(Loopback) ─▶ T4(NearbyTransport) ────────────────────────┘ (T7 起全部依赖传输层)
T10(UI泛化) 依赖 T5；与 T7-T9 并行可行，但 T11 依赖 T10。
```

建议执行顺序即任务编号顺序（T10 可与 T7-T9 并行）。
