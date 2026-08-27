# 地图贸易商槽位实施计划

> 日期：2026-08-26

## 目标

把权威快照中的贸易商投影为地图上的可见、可访问、可点击槽位，并让出售选项提供可区分的中文说明。

## 任务 1：投影模型

文件：

- `IndustrialCityBirmingham/Models/DemoModels.swift`
- `IndustrialCityBirmingham/Features/Match/RealMatchViewModel.swift`
- `IndustrialCityBirminghamTests/RealMatchProjectionTests.swift`

步骤：

1. 先增加失败测试，构造包含已知贸易商摆放的快照，断言槽位被分组到正确市场，并保留接受产业、啤酒和奖励。
2. 增加 `MerchantBonusKind`、`MapMerchantPlacement` 和 `MapLocation.merchantPlacements`。
3. 在 `RealMatchViewModel` 中解析地图槽位及贸易商定义，并投影 `match.merchants`。
4. 运行 `RealMatchProjectionTests`，确认测试由红转绿。

## 任务 2：SpriteKit 呈现与命中

文件：

- `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift`
- `IndustrialCityBirmingham/Features/Map/GameMapScene.swift`
- `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

步骤：

1. 先增加失败测试，断言场景生成 `merchant:<slotID>`，包含接受产业、啤酒、奖励标签和语义数据。
2. 增加贸易商牌节点，按同一市场的槽位数量居中排列，并应用高亮辉光。
3. 扩展目标名称解析，让贸易商牌及其子节点都能命中槽位 ID。
4. 运行 `GameMapSceneTests`，确认呈现和命中测试通过。

## 任务 3：出售交互与文案

文件：

- `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`
- `IndustrialCityBirmingham/GameCore/Rules/LegalActionQueryEngine.swift`
- `IndustrialCityBirminghamTests/BuildAndNetworkRulesTests.swift`
- 新增 `IndustrialCityBirminghamTests/AuthoritativeMapTargetResolverTests.swift`（如需抽取纯解析器）

步骤：

1. 先增加失败测试，断言 `.merchant` 进入高亮 ID，并能通过精确槽位 ID 解析回合法选择。
2. 增加出售查询测试，断言标签包含中文市场、接受产业和奖励，而不是通用“商人市场”。
3. 抽取可单测的地图目标解析器并接入对局界面。
4. 为出售查询增加贸易商说明辅助函数。
5. 运行相关测试，确认地图和底部两种入口行为一致。

## 任务 4：可访问性与验证

文件：

- `IndustrialCityBirmingham/Features/Map/GameMapView.swift`
- `IndustrialCityBirminghamTests/GameMapSceneTests.swift` 或新增专用测试

步骤：

1. 增加贸易商可访问性标签纯函数及测试。
2. 把高亮贸易商加入地图的可访问目标集合。
3. 运行贸易商相关定向测试、完整单元测试和 Debug 构建。
4. 安装到 iPhone 与 iPad 模拟器，使用 Debug 附近房间目录复验地图展示与出售交互。
5. 完成独立代码审查，处理有效问题后再报告完成。
