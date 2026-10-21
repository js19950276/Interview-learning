# PokerApp

单机德州扑克（现金局 + SNG）。引擎见 `../PokerEngine`（纯 Swift Package，`swift test` 可独立运行）。

## 构建

```bash
cd PokerApp && xcodegen generate
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' build
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'generic/platform=iOS Simulator' build
```

或直接用 Xcode 打开 `PokerApp.xcodeproj`。
