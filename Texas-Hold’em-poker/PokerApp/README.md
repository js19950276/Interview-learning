# PokerApp

单机德州扑克（现金局 + SNG）。引擎见 `../PokerEngine`（纯 Swift Package，`swift test` 可独立运行）。

## 构建

```bash
cd PokerApp && xcodegen generate
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' build
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'generic/platform=iOS Simulator' build
```

或直接用 Xcode 打开 `PokerApp.xcodeproj`。

## AIConsole（AI 评测）

cd PokerEngine 后：

    swift run AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --concurrency 8
    swift run AIConsole bench --ai pimc:hard --hands 100

## 蓝图训练（2b）

    swift run AIConsole train --iterations 10000000 --seed 20261022 --checkpoint-every 1000000 --out blueprint-hu.json
    swift run AIConsole battle --a blueprint:hu --b pimc:normal --table hu --hands 20000
