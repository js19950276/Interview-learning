# PokerApp

单机德州扑克（现金局 + SNG）。引擎见 `../PokerEngine`（纯 Swift Package，`swift test` 可独立运行）。

## 构建

```bash
cd PokerApp && xcodegen generate
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' build
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'generic/platform=iOS Simulator' build
```

或直接用 Xcode 打开 `PokerApp.xcodeproj`。

iOS 测试（单测 + UI 冒烟）：

    xcodebuild -project PokerApp.xcodeproj -scheme PokerApp_iOS_Tests -destination 'platform=iOS Simulator,name=iPhone 17' test

## 联机对战（局域网，无需服务器）

- 同一 Wi-Fi（或无路由器时的点对点 Wi-Fi）下：一台设备「创建房间」，其他设备「搜索附近房间」加入，2~9 人全人类对局。
- 房主为权威端：所有牌局判定在房主设备完成，其他设备只看到自己视角的脱敏牌面（他人手牌永不上网络）。
- 首次使用会请求「本地网络」权限；拒绝后可在系统设置中开启。
- 玩家锁屏/断线后座位自动托管（能过则过、否则弃牌），回到 App 自动重连续打；对局中途不支持新玩家加入。
- 实现细节见 `../docs/superpowers/specs/2026-10-29-lan-multiplayer-design.md`。

## 素材

- App 图标：`Scripts/gen_appicon.swift` 代码绘制（双 A 扇形 + 绿绒面，iOS/macOS 各一变体），改动后运行 `swift Scripts/gen_appicon.swift <输出目录>` 重新生成并替换 `Assets.xcassets/AppIcon.appiconset` 里的两个 PNG。
- 对局背景图：Pexels 免费许可照片 [A Person Lying Down the Cards on the Gaming Table](https://www.pexels.com/photo/a-person-lying-down-the-cards-on-the-gaming-table-7594255/)（`Assets.xcassets/poker-table-bg`）。

## AIConsole（AI 评测）

cd PokerEngine 后：

    swift run AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --concurrency 8
    swift run AIConsole bench --ai pimc:hard --hands 100

## 蓝图训练（2b）

    swift run AIConsole train --iterations 10000000 --seed 20261022 --checkpoint-every 1000000 --out blueprint-hu.json
    swift run AIConsole battle --a blueprint:hu --b pimc:normal --table hu --hands 20000
