# UI 原型验收记录

> - 日期：2026-08-11
> - 范围：Phase 1 朋友间测试用高保真 UI 原型
> - 结论：模拟器自动化与截图审查通过；Phase 1 总验收未完成
> - 规格：[“工业城市伯明翰”iPhone/iPad App 产品与技术设计规格](../superpowers/specs/2026-08-06-industrial-city-birmingham-app-design.md)
> - 补充审查：[Task 14 视觉与无障碍审查](2026-08-11-task14-visual-accessibility-review.md)

## 结论与边界

本次记录确认高保真 UI 原型在现有 iOS 26.5 模拟器环境中的构建、单元测试、UI 测试、快照差异和脚本契约均通过。最终代码审查未发现 Critical、Important 或 Minor 问题。

由于没有可用的实体 iPhone/iPad，实体设备性能、内存、泄漏、前后台状态保持和 VoiceOver 手势顺序均未完成；当前机器也没有 iOS/iPadOS 17 runtime。因此不将规格状态改为“阶段 1：已验证”。本记录只覆盖固定 fixture 驱动的 UI 原型，不证明真实规则引擎、NearbyTransport 或 WebSocketTransport 已完成。

## 验证环境

| 项目 | 记录 |
| --- | --- |
| Xcode | 26.6（Build 17F113） |
| Swift | Apple Swift 6.3.3（swiftlang-6.3.3.1.3） |
| 模拟器 runtime | iOS 26.5 |
| iPhone 模拟器 | `IndustrialCity-iPhone` |
| iPad 模拟器 | `IndustrialCity-iPad` |
| 实体 iPhone 型号 / OS | 未采集（blocker） |
| 实体 iPad 型号 / OS | 未采集（blocker） |
| 最低系统 iOS/iPadOS 17 | 未验证（blocker）：当前机器只安装了 iOS 26.5 simulator runtime |

## 自动化证据

所有命令均从仓库根目录执行。

| 命令 | Exit code | 结果 |
| --- | ---: | --- |
| `xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' -derivedDataPath /tmp/industrial-city-derived-data.5s34BV -parallel-testing-enabled NO` | 0 | 全新 DerivedData 验证：Swift Testing 104 tests / 12 suites 全部通过；XCTest UI 24 tests，0 failures，1 个 iPad-only 测试按预期跳过；`TEST SUCCEEDED` |
| `bash scripts/verify_ui_prototype.sh` | 0 | 最终一键验收通过：iPhone 全量测试、iPad 构建、12 张快照和 `git diff --check` 均成功 |
| `xcodebuild build -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=IndustrialCity-iPad,OS=26.5'` | 0 | `BUILD SUCCEEDED` |
| `bash scripts/capture_ui_snapshots.sh` | 0 | 12 张快照全部通过；最终一键验收最大差异 0.0828%，低于 0.5% 阈值 |
| `bash scripts/test_snapshot_diff.sh` | 0 | SnapshotDiff 阈值边界自测通过 |
| `bash scripts/test_capture_ui_snapshots.sh` | 0 | 快照命名、方向归一化与 ignore 文件契约自测通过 |
| `bash scripts/test_verify_ui_prototype.sh` | 0 | 验证脚本执行顺序契约自测通过 |
| `git diff --check` | 0 | 无空白错误 |

快照集合共 12 张：`home-phone`、`online-error-phone`、`nearby-permission-phone`、`lobby-4-phone`、`match-2-phone`、`match-3-phone`、`match-4-phone`、`match-build-phone`、`match-sell-phone`、`match-disconnected-phone`、`home-ipad`、`match-4-ipad`。最终一键验收逐图差异为 0.0000%–0.0828%，全部低于 0.5% 阈值。

## 屏幕与交互清单

“自动”表示由本次 104 个 Swift 测试、24 个 UI 测试或 12 张快照验证；“人工”表示对最终快照进行视觉检查；“静态”表示通过编译成功和路由实现核对，但没有单独截图。

| 验收项 | 状态 | 证据与边界 |
| --- | --- | --- |
| home | 通过（自动 + 人工） | 启动 UI 测试、iPhone/iPad 快照与人工审查 |
| online | 通过（自动 + 人工） | 创建/加入房间 fixture、错误恢复 UI 测试及错误态快照 |
| nearby | 通过（自动 + 人工） | 创建房间、权限/无线连接恢复 UI 测试及权限态快照 |
| lobby | 通过（自动 + 人工） | 四人 lobby UI 测试及快照 |
| rules、settings | 通过（静态） | 路由实现、构建和非 match 方向策略测试通过；未作为最终人工截图样本 |
| gallery | 通过（自动） | 组件状态矩阵、44 pt 命中区域、标签与 color-assist UI 测试 |
| match | 通过（自动 + 人工） | match shell、地图交互、快照与人工审查 |
| 2/3/4 玩家 | 通过（自动 + 人工） | 三种 fixture 的命名状态 UI 测试；六张 iPhone match 视口与 iPad 四人视口截图 |
| 卡牌替换 | 通过（自动） | reducer 测试验证第二张牌替换第一张并清空 draft；UI 测试验证选中行为 |
| 玩家/产业抽屉 | 通过（自动 + 人工） | 抽屉打开、切换、关闭和互斥 UI 测试；断线玩家抽屉截图审查 |
| 行动网格与市场阶梯互斥 | 通过（自动） | reducer 与 UI 测试验证同一时刻只有一个 transient overlay |
| build、canal、one rail、two rail、develop、sell、loan、scout、pass | 通过（自动 + 人工抽样） | action reducer/flow 测试覆盖九种 fixture 流程；UI 测试覆盖确认、取消与关键目标；build/sell 截图人工抽样。只证明 fixture UI 状态机，不证明真实规则 |
| accepted、rejected | 通过（自动 + 人工抽样） | 成功反馈、资源变化、拒绝原因/恢复建议与 draft 保留 UI 测试；最终截图审查覆盖相关 match 状态 |
| waiting sync | 通过（自动，fixture） | gallery 的 waiting 状态与 FakeTransport 并发/取消测试通过；不代表真实网络同步 |
| disconnected | 通过（自动 + 人工） | deterministic disconnected fixture UI 测试与截图审查 |
| Reduce Motion、color assist | 通过（自动） | reduced-motion 替代反馈及 color-assist 开关/状态矩阵 UI 测试 |
| VoiceOver | 部分通过（自动）；实体检查阻塞 | 标签、identifier、焦点契约与 44 pt 命中区域自动测试通过；实体设备 swipe-through 未执行（blocker） |
| 非 match 纵/横屏、match 横屏锁定 | 通过（自动 + 人工） | NavigationTests、UI 几何断言和纵横向快照通过；iPhone/iPad 最终截图未见方向或布局异常 |

## 五点人工视觉审查

人工审查覆盖 home、online、nearby、lobby、build、sell、disconnected、iPad home 和 iPad match 最终图片；更细的无障碍层级记录见 [Task 14 视觉与无障碍审查](2026-08-11-task14-visual-accessibility-review.md)。

1. **层级**：地图仍是 match 第一视觉主体，左右 rail、底部手牌、市场与确认面板层级清楚；非 match 页面的标题、主操作与状态面板顺序明确。
2. **可读性**：黄铜/炭黑/纸色文本在审查图片中保持可读，长中英文与玩家/资源摘要未见明显截断；自动对比度测试通过。
3. **触控与遮挡**：关键按钮、卡牌、rail 和抽屉未见相互遮挡；自动测试确认 gallery 控件和地图目标命中区域至少 44 pt。实体手持误触仍需真机观察。
4. **状态区分**：normal、selected、disabled、illegal、waiting、disconnected、reduced-motion 以及 accepted/rejected 状态使用文字、图形与颜色共同表达，不只依赖颜色。
5. **iPhone/iPad 方向与布局**：iPhone 非 match 纵屏、match 横屏以及 iPad 横屏图片布局稳定；iPad 能显示完整玩家 rail、八张可读手牌与完整市场阶梯。

## 实体设备性能与稳定性

以下目标必须在最老的目标实体 iPhone 上使用 Release 构建和 Instruments 采集。模拟器结果不替代实体指标。

| 指标 | 验收目标 | 实测 |
| --- | --- | --- |
| 实体设备型号 / OS | 记录最老目标 iPhone 的准确型号和 OS | 未采集（blocker） |
| FPS 平均值 | ≥ 58 FPS | 未采集（blocker） |
| P95 帧时间 | ≤ 20 ms | 未采集（blocker） |
| 卡牌首次视觉响应 | ≤ 100 ms | 未采集（blocker） |
| 抽屉首次视觉响应 | ≤ 100 ms | 未采集（blocker） |
| 市场首次视觉响应 | ≤ 100 ms | 未采集（blocker） |
| 10 分钟内存 baseline / final / growth | 记录三项实测值并判断增长 | 未采集（blocker） |
| Instruments Leaks | 0 个确认泄漏 | 未采集（blocker） |
| 后台 / 前台状态保持 | 当前 fixture 状态保持 | 未采集（blocker） |

## Blockers 与后续关闭条件

- 没有可用的实体 iPhone/iPad，无法采集上表性能、内存、泄漏和前后台状态保持证据。
- 没有可用的实体 iPhone/iPad，无法完成 VoiceOver 实体 swipe-through。
- 当前机器只安装 iOS 26.5 simulator runtime，无法验证项目声明的 iOS/iPadOS 17.0 最低运行时。

只有这些 blocker 全部关闭、结果达到目标且没有新增验收失败时，才可将规格阶段更新为“阶段 1：已验证”。GameCore、NearbyTransport 和 WebSocketTransport 仍属于后续阶段，不因本记录改变状态。

## 审查记录

- 最终代码审查：0 Critical / 0 Important / 0 Minor。
- 文档记录只引用已完成的自动化、快照和人工审查，不补造实体设备型号、OS 或性能数值。
