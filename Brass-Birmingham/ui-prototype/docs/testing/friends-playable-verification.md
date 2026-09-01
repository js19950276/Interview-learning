# Friends Playable 验证记录

<!-- automated-accessibility-status: PASS -->
<!-- manual-voiceover-status: NOT RUN -->
<!-- voiceover-iphone-status: NOT RUN -->
<!-- voiceover-iphone-operator-date: NOT RUN -->
<!-- voiceover-iphone-evidence: NOT RUN -->
<!-- voiceover-ipad-status: NOT RUN -->
<!-- voiceover-ipad-operator-date: NOT RUN -->
<!-- voiceover-ipad-evidence: NOT RUN -->

> 当前状态：**BLOCKED / NOT RUN**。本仓库已有可重复的模拟器门禁和结构完整的 Task 3 数值
> 草稿，但没有第二位人员对实体组件的独立复核，也没有两台/四台真机、Instruments 或人工
> VoiceOver 证据。当前禁止打印或记录 friends-playable 最终 PASS。

## 证据边界

| 证据类型 | 能证明 | 当前状态 |
| --- | --- | --- |
| 自动化模拟器 | reducer/session 行为、双进程传输、UI route、44 pt/label/identifier 断言、快照差异 | 可运行；不能证明 Local Network 隐私授权或 P2P |
| 人工真机 | iPhone↔iPad、四机混合、无互联网/无路由、后台/锁屏/重连、系统权限 | NOT RUN |
| 人工 VoiceOver | 最小支持 iPhone 与一台 iPad 的焦点顺序、可到达性、非颜色唯一表达 | NOT RUN |
| Instruments / 真机日志 | 30 分钟性能、RSS 增长、crash/hang/leak、重连耗时 | NOT RUN |
| 完整游戏数据 | 完整 catalog、来源记录与独立复核 | BLOCKED；`v2018.11` 数值草稿结构完整并通过自动校验，但仍未由第二人逐行核对 |

模拟器结果不得写入[真机矩阵](friends-playable-device-matrix.md)，也不得用模拟器 `.xcresult`
冒充真机、Instruments 或手动 VoiceOver 证据。

## 最终门禁

从仓库根目录运行：

```bash
bash scripts/verify_friends_playable.sh
```

固定执行顺序为：

1. `data-gate`；
2. `release-build`；
3. `release-fixture-boundary`；
4. `unit-tests`；
5. `two-simulator-test`；
6. `ui-iphone-tests`；
7. `ui-ipad-tests`；
8. `snapshots`；
9. `diff-check`；
10. `accessibility-journey`（自动 UI route 后检查真实人工 VoiceOver marker）；
11. `physical-device-matrix`；
12. `physical-device-metrics`。

Release 构建与 fixture 边界检查复用同一份临时 DerivedData，UI 则分别执行完整的 iPhone 与
iPad 测试 target。脚本启用 `set -euo pipefail`，任一门禁失败即停止，只有十二项都通过才可能
打印最终成功行。

只检查结构或运行无设备自测：

```bash
bash scripts/verify_friends_playable.sh --check-structure
bash scripts/capture_physical_device_metrics.sh --self-test
bash scripts/test_verify_ui_prototype.sh
```

这些命令只验证门禁本身；不会生成真机 PASS。

数据门禁可单独运行：

```bash
bash scripts/verify_game_data.sh --self-test
bash scripts/verify_game_data.sh --export-review /tmp/brass-v2018.11-review.jsonl
bash scripts/verify_game_data.sh --check-review /tmp/brass-v2018.11-review.jsonl
bash scripts/verify_game_data.sh --suggest-review-metadata /tmp/brass-v2018.11-review.jsonl
bash scripts/verify_game_data.sh --rules-proof
bash scripts/verify_game_data.sh
```

第一条证明结构、review coverage、哈希篡改、遗漏/重复、self-checker 和 partial review 会被拒绝；
中间三条依次生成 243 行审阅物、检查其仍绑定当前数据，并在全部行由独立 checkerID 核对后输出
带 `verificationEvidence` 的 advisory-only manifest 建议（不会自动写回）。`--rules-proof` 运行
Task 10 的完整确定性规则证明；最后一条当前会按设计因 `draft` 状态失败。人工操作详见
[结构化游戏数据人工复核](game-data-human-review.md)。地图、卡牌、产业、贸易商和收入轨的结构化
数值已经录入；官方图片与 PDF 不存入仓库或 App 包。

## Task 10 自动化规则证据

`GameRulesEngineTests.seededCompleteGamesProduceReplayableDeterministicProofs` 使用固定 seed 和
HostEngine 接受的 typed intent，让 2/3/4 人对局从 setup 依次完成运河与铁路时代并进入最终计分。
脚本只选择当前行动者手牌中的合法 Pass；因为该策略不花钱，所以完整对局不会进入 forced sale。
测试逐项断言：

- 每个 accepted Pass intent 各增加一个 version 和 action number，且完整对局 events 数量等于
  accepted Pass 数量；round/era/scoring transitions 包含在对应 authoritative event 中，不额外
  增加 version；
- 从 version 0、action number 0 的同 seed setup 状态重放完整 event 列表，得到完全相同的最终
  `GameState`；
- 同一次测试内重跑完整脚本，event 列表、最终状态和 canonical SHA-256 全部相同；
- 固定 final hash：2 人
  `da4e0e405139b24c500f9820bb496025bea0f35f6fd306a8176d5d04beae556f`，3 人
  `6209a2452e4fa6f71aa53d3c1d368864a06fba2c70c78f4fdd6c7aaa31e119fd`，4 人
  `5d1144952cdd74fa58f7fa37f87e979e52de3dac3e189bc3d0bcd03e2d4df129`。

forced sale 使用独立的专项证明，不把它伪装成 pass-only 完整对局的一部分：
`forcedSaleSubmittedThroughHostIncrementsVersionAndReplaysExactly` 先由收入结算生成真实 pending
forced-sale 状态，再通过 `HostEngine.submit` 提交 typed `ForcedSaleIntent`；测试断言 accepted event
将 version 与 action number 各增加一、payload 为 `forcedSaleResolved`，并从提交前 pending 状态
严格 replay 到 HostEngine 的最终状态。该测试也登记在 `turns` area 并由 rules-proof runner 执行。

`RulesCoverageTests` 将 `RULES.md` Section 12 的 12 项风险逐项绑定到可执行的具名规则测试，并
要求 setup/resources/actions（build、network、develop、sell、loan、scout、pass）/turns/scoring
五类 manifest 全部非空。风险数量、类别或测试名不匹配会 fail closed；测试还执行一份故意写入
不存在测试名的 malformed manifest，证明拒绝路径有效。runner 合并 risk 与 area 名单后去重执行，
因此 setup/resources/七种 action/turns/scoring 不只是登记项，而是 `--rules-proof` 的真实执行项。

如需保留独立结果包，可运行两次：

```bash
TASK10_XCRESULT_PATH=/tmp/task10-run-a.xcresult bash scripts/verify_game_data.sh --rules-proof
TASK10_XCRESULT_PATH=/tmp/task10-run-b.xcresult bash scripts/verify_game_data.sh --rules-proof
```

此证据只证明当前 test catalog 上的确定性规则、版本合同与可重放性。它不证明仓库中的 data
draft 已经由第二人核对，也不替代双机/四机真机、Local Network 权限、30 分钟 Instruments 或
人工 VoiceOver；这些门禁继续保持 BLOCKED / NOT RUN。

## Accessibility journey

`AccessibilityJourneyUITests` 在 `IndustrialCity-iPhone` 模拟器上自动覆盖：

- create / join / ready / start；
- turn / resources / hand；
- card / action / target / confirmation；
- rejection / recovery / disconnected-paused representation；
- 真实 `SessionViewStore` 的 connecting、recovering、暂停提示、行动禁用与 synchronized 恢复；
- 关键控件 label、可点击性、44 × 44 pt，以及关键 identifier 唯一性。

运行：

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamUITests/AccessibilityJourneyUITests
```

这不是 VoiceOver 人工验收。仍须在最小支持 iPhone 和一台 iPad 上逐项滑动，并留下真实
操作者、日期、设备/OS、录屏或记录路径；在证据复核前，页首
`manual-voiceover-status` 必须保持 `NOT RUN`。

自动 journey 最初发现 online、nearby 与 Lobby 的 segmented Picker 只有约 31 pt。三处已用
系统 `extraLarge` control size 提升到至少 44 pt，并由同一 UI journey 回归；没有更改颜色或
信息结构。

## 真机 metrics 输入

真实执行前设置三个显式参数：

```bash
export FRIENDS_PHYSICAL_DEVICE_UDID='<physical-udid>'
export FRIENDS_PHYSICAL_DEVICE_UDIDS='<udid-a>,<udid-b>,<udid-c>,<udid-d>'
export FRIENDS_PHYSICAL_METRICS_RESULT='/absolute/path/metrics.tsv'
export FRIENDS_PHYSICAL_METRICS_OUTPUT_DIR='/absolute/path/validated-output'
```

`FRIENDS_PHYSICAL_DEVICE_UDID` 必须指定四台中最旧支持型号、实际运行 Instruments 的设备；
`FRIENDS_PHYSICAL_DEVICE_UDIDS` 必须列出四个唯一完整 UDID，且包含该 instrumented UDID。
脚本能验证四台设备在验收时均由 `xctrace list devices` 识别为已连接真机，但不会声称单台
Instruments trace 采样了其余三台；四席联机行为仍由真机矩阵及其独立 evidence bundle 证明。

`metrics.tsv` 是 tab-separated `metric<TAB>value`。键集合固定，每个键必须恰好出现一次，
每行必须恰好两列；未知键、重复键或附加列都会拒绝。必须包含：

- `device_udid`、`device_kind=physical`、`duration_minutes>=30`；
- `seat_count=4`、`physical_device_count=4`，证明 trace 是四席、四台真机；
- `preview_p95_ms<100`、`nearby_event_p95_ms<250`、`map_fps>=55`；
- `peak_rss_mb<350`、`rss_growth_30m_mb<25`；
- `crashes=0`、`hangs=0`、`leaked_coordinators=0`、`leaked_connections=0`；
- `background_seconds>=10`、`reconnect_seconds<5`；
- 非空且实际存在的 `xcresult_path`、`instruments_trace_path`、`crash_hang_log_path`。

脚本逐一用 `xctrace list devices` 只读确认四个完整 UDID 当前对应已连接真机；再用
`xcresulttool get test-results summary` 验证 `.xcresult` 是可解析且通过的真机结果，并用
`xctrace export --toc` 验证 `.trace` 可解析、instrumented UDID 一致、TOC 中唯一 run duration
不少于 1800 秒且不短于 TSV 的 `duration_minutes`。因此 `duration_minutes` 不是单独可信的
自报值。缺字段、重复/未知字段、越预算、模拟器 UDID、无法解析或元数据不一致的 artifact、
空证据或不存在的路径都会非零退出。脚本不自动启动 30 分钟录制；trace 必须先按矩阵采集。

输出目录必须是绝对非符号链接路径，canonical 后不得为文件系统根目录；已存在
`physical-metrics-validation.txt` 时拒绝覆盖。成功记录通过同目录临时文件原子发布。

## 当前故意阻塞的门禁

- **完整游戏数据：** `scripts/verify_game_data.sh` 已实现，当前会因 `v2018.11` 保持 `draft` 且
  缺少第二位 checker/date 而精确失败，不会把跨来源草稿或 fixture 数值当成已验证数据。
- **人工 VoiceOver：** 最小 iPhone 与 iPad 都是 NOT RUN。
- **真机矩阵：** 两机与四机所有格均为 NOT RUN，页首 marker 不是 PASS。
- **性能：** 没有真机 UDID、30 分钟 trace、`.xcresult` 和 device log。

## 明确延期（不属于本阶段）

- 在线服务器 / WebSocket；
- 账号体系；
- AI 玩家或 AI 建议；
- 反作弊；
- host migration（主机丢失时只暂停，必须由同一主机和存档恢复）。
