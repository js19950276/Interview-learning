# Friends Playable 真机矩阵

<!-- physical-matrix-status: NOT RUN -->
<!-- two-device-bundle: NOT RUN -->
<!-- four-device-bundle: NOT RUN -->

> 当前结论：**NOT RUN / BLOCKED**。本页只定义真机验收协议；没有可用真机，因而没有填写
> `.xcresult`、Instruments、系统日志或人工观察结果。模拟器不能证明 Local Network 隐私授权、
> Bonjour 发现或点对点连接。

## 设备与角色

每次执行必须填写设备种类、真实型号、OS build、UDID 后四位、席位角色和可访问的证据路径。
两机拓扑必须恰好一台 iPhone 和一台 iPad；四机拓扑必须恰好两台 iPhone 和两台 iPad。
UDID 后四位必须为四位十六进制字符，并且在同一拓扑内唯一。不得用
模拟器、截图占位符或口头结论替代。

| 拓扑 | 设备 | device_kind | 型号 | OS / build | UDID 后四位 | 角色 | 证据 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
<!-- device-evidence:start -->
| iPhone ↔ iPad | A | NOT RUN | NOT RUN | NOT RUN | NOT RUN | host / seat 1 | NOT RUN | NOT RUN |
| iPhone ↔ iPad | B | NOT RUN | NOT RUN | NOT RUN | NOT RUN | guest / seat 2 | NOT RUN | NOT RUN |
| 4 台混合设备 | A | NOT RUN | NOT RUN | NOT RUN | NOT RUN | host / seat 1 | NOT RUN | NOT RUN |
| 4 台混合设备 | B | NOT RUN | NOT RUN | NOT RUN | NOT RUN | guest / seat 2 | NOT RUN | NOT RUN |
| 4 台混合设备 | C | NOT RUN | NOT RUN | NOT RUN | NOT RUN | guest / seat 3 | NOT RUN | NOT RUN |
| 4 台混合设备 | D | NOT RUN | NOT RUN | NOT RUN | NOT RUN | guest / seat 4 | NOT RUN | NOT RUN |
<!-- device-evidence:end -->

## 场景矩阵

两种拓扑都必须完整执行。每格记录操作者、时间、结果以及 `.xcresult`、统一日志、录屏或
Instruments trace 的仓库外稳定路径。

| 场景键 | 两机证据 | 两机状态 | 四机证据 | 四机状态 |
| --- | --- | --- | --- | --- |
<!-- scenario-evidence:start -->
| internet-unavailable-no-router | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| airplane-wifi-reenabled | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| create-discover-join-start | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| one-action-per-seat | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| guest-background-lock-reconnect | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| actor-disconnect | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| host-disconnect-relaunch | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
<!-- scenario-evidence:end -->

以下中文表格用于人工阅读；validator 只读取上方固定 machine-controlled 区间，不猜测 Markdown 链接。

| 互联网不可用 / 无路由器 | NOT RUN | NOT RUN | 仅设备间 Wi-Fi；不得借助互联网或基础设施路由器 |
| 飞行模式后重新打开 Wi-Fi | NOT RUN | NOT RUN | 蜂窝保持关闭，记录 Local Network 权限状态 |
| 创建 / 发现 / 加入 / 开始 | NOT RUN | NOT RUN | 所有席位看到相同房间、顺序和初始版本 |
| 每席至少一个动作 | NOT RUN | NOT RUN | 每席提交一次合法动作，其他设备收到相同 accepted event/version |
| 访客后台 / 锁屏 / 重连 | NOT RUN | NOT RUN | 后台 10 秒后恢复；重连耗时另记 metrics |
| 当前行动者断开 | NOT RUN | NOT RUN | 新 intent 暂停，状态明确，重连后同步并保留席位 |
| 主机断开并重启 | NOT RUN | NOT RUN | 所有访客暂停；同一主机/存档恢复后 catch-up |

## 人工可访问性（真机）

在可支持的最小 iPhone 和一台 iPad 上开启 VoiceOver，以逐项滑动方式走完 create/join/ready/start、
turn/resources/hand、card/action/target、confirmation/rejection/recovery/paused/syncing。必须确认：

- 所有交互控件至少 44 × 44 pt 且可到达；
- 没有空 label、重复可访问性节点或重复 identifier；
- 状态、玩家与资源不依赖颜色作为唯一信息；
- 焦点顺序和拒绝后的恢复建议可理解。

| 设备 | 操作者 / 日期 | VoiceOver 录屏或记录 | 结果 |
| --- | --- | --- | --- |
<!-- voiceover-evidence:start -->
| iPhone | NOT RUN | NOT RUN | NOT RUN |
| iPad | NOT RUN | NOT RUN | NOT RUN |
<!-- voiceover-evidence:end -->

以上两行是 validator 读取的固定设备键；真机执行时 `iPhone` 必须选用最小支持型号。

只有所有设备、所有场景和两次人工 VoiceOver 走查都有真实证据并通过复核后，才可把页首
marker 改为 `physical-matrix-status: PASS`。
