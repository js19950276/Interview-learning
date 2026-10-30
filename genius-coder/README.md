# genius-coder

个人 iPhone 多 Agent 编程会话客户端。一台 Mac、一部 iPhone、四个装在 Mac 上的 coding agent（Codex、Claude Code、Grok Build、DeepSeek Harness）。

Mac 跑一个菜单栏 bridge：把四套本机会话存储编成按项目分组的索引、为继续会话拉起对应官方客户端、向手机暴露 TLS WebSocket JSON API。手机按 项目 → 会话 → 会话页 三级浏览全部历史，续聊走各 agent 自己的客户端协议（Codex `thread/resume` + `turn/start`、Grok `session/load`、dsh `session/resume`、Claude Agent SDK `resume`），批准卡片只有 Allow / Deny 两个按钮，断线 15 秒单调时钟宽限后失败关闭。

完整设计见 [iPhone多Agent客户端-设计规格.md](iPhone多Agent客户端-设计规格.md)。

## 仓库布局

```
Package.swift              Swift 包（macOS 15 / iOS 18）
Sources/PhoneProtocol/     两端共享：信封、状态机、错误码、WebSocket 编解码、手机客户端
Sources/BridgeCore/        菜单栏 bridge 逻辑：TLS 监听、配对、索引、历史、适配器、锁
Sources/BridgeCLI/         无头调试入口（scan / serve）
Apps/Bridge/               菜单栏 app（MenuBarExtra）+ ClaudeHost Node helper
Apps/Phone/                iPhone SwiftUI app
genius-coder.xcodeproj     两个 app target（指向本地包）
tools/zstd-fixtures.py     zstd 回归 fixture 生成（CPython 3.14 compression.zstd）
docs/vendor-schemas/       从本机 codex 二进制导出的 JSON schema 摘要
```

## 构建与测试

本仓库位于 iCloud 同步的 Desktop 下，**所有 swift 命令必须带 `--scratch-path`**（否则 fileprovider 扩展属性会弄坏 .build 里的签名）：

```bash
swift build --scratch-path /tmp/gc-build
swift test  --scratch-path /tmp/gc-build          # 45+ 单元/集成测试
python3 tools/zstd-fixtures.py                    # 生成 zstd fixture（首次必跑）
swift run --scratch-path /tmp/gc-build genius-bridge-cli scan     # 真实存储冒烟
swift run --scratch-path /tmp/gc-build genius-bridge-cli serve    # 无头 bridge
```

App target 用 Xcode 打开 `genius-coder.xcodeproj`（桥 = genius-coder-bridge，手机 = genius-coder-phone）。xcodebuild 也请用 `-derivedDataPath /tmp/gc-dd`。

## 安全模型（v1 摘要）

- 手机只拨出。家里 LAN + Bonjour `_geniuscoder._tcp`；出门绑 Tailscale 接口（100.64.0.0/10 或 fd7a:115c:a1e0::/48）。从不监听 0.0.0.0，无公网。
- TLS 1.3 + 自签 ECDSA P-256 证书钉扎（比较证书 SHA-256）。配对 = 一次性 32 字节 token（5 分钟单调时钟、单次），设备密钥 Ed25519，签名输入是 `rawNonce || utf8(bridgeId)`。
- 打开 app 默认 Face ID / 设备密码。批准只有 allow/deny；`acceptForSession`、`scope: "session"`、`bypassPermissions` 一律不发送。断线超时按各 agent 的协议 fail-close（Codex `cancel`/空授予+`turn/interrupt`/`abort`，ACP `session/cancel`，Claude deny+interrupt）。
- 每个agent的发送开关默认关闭，只能在菜单栏手动打开。写入者互斥（进程内 + flock + lsof）覆盖整个 turn，包括批准等待。turn 期间持有 `caffeinate -im`。
- 允许列表按路径分量匹配（`/Users/me/code` 不匹配 `/Users/me/code-evil`）；菜单栏首次启动询问一次是否播种已有会话的 cwd。

## 本机依赖（绝对路径，不走 PATH）

| Agent | 二进制 | 恢复方法 |
| --- | --- | --- |
| Codex | `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` | `thread/resume`（sandbox `"workspace-write"`）+ `turn/start`（`on-request`） |
| Grok | `~/.grok/bin/grok` | `session/load` |
| Claude | `~/.local/share/node-v24.18.1/bin/claude`（node 跑 ClaudeHost.mjs） | Agent SDK `resume`（streaming input） |
| DeepSeek | `/Applications/DeepSeek Harness.app/.../dsh` | `session/resume`（`session/load` 被拒绝） |

zstd 解压通过 dlopen 链接绝对路径的 `libzstd.dylib`（本机由 CPython 3.14 附带，1.5.7）；另有一个纯 Swift 的 RAW/RLE 块回退解码器，压缩块一律拒绝（fail-closed）。`GENIUS_CODER_LIBZSTD` 可覆盖库路径。

## 状态

PR1–PR9 的代码全部落地（见规格的 PR Plan）：

- ✅ PR1 骨架 + 共享协议类型（含签名输入、兄弟目录允许列表单测）
- ✅ PR2 loopback/真机配对 + ping（TLS 钉扎、单调时钟 token/nonce、Bonjour）
- ✅ PR3 四家索引器 + SQLite 缓存（本机实测冷索引 ~140ms）
- ✅ PR4 只读历史：Grok `updates.jsonl`、dsh zstd（真机日志端到端）、Codex app-server 只读 RPC
- ✅ PR5 批准中心、写入者锁、追赶环、caffeinate、进程组回收
- ✅ PR6–PR8 Grok / Codex / dsh 适配器（发送开关默认关）
- ✅ PR9 ClaudeHost.mjs + ClaudeAdapter（SDK 版本需钉死后再启用）
- ⏳ PR10 Claude 历史解析器：等第一份脱敏 fixture（spec 规定无 fixture 不合并）

真机验收顺序（spec Rollout）：先配对 + ping，再看列表/历史，再看一张不会放行的批准卡片，然后一次只开一个 agent 的发送开关。

## 单命令形态（Layer ①②）

```
./tools/dist.sh                 # 产出 dist/genius-bridge/（含二进制+libzstd+tsnet helper）
cd dist/genius-bridge
./genius-bridge serve           # Mac 端唯一一条命令：终端直接打印配对二维码
```

- **zstd**：libzstd.dylib 随文件夹分发（dlopen 绝对路径顺序：可执行文件同目录 → app support → CPython）。
- **ClaudeHost.mjs** 内嵌为 SPM 资源，首次使用时落盘到 app support，无需随包携带文件。
- **远程连接（内嵌 Tailscale，spec 之外的 v2 偏离）**：两端内嵌 tsnet（用户态 WireGuard，无 TUN、无 NetworkExtension、不装官方 Tailscale app）。
  - Mac：`gc-tsnet-helper`（Go 静态二进制，`tools/tsnet-helper`；dist 脚本从 `vendor/bin/` 取或用 `~/.gc-toolchain` 的 Go 现场构建）。设置 `TS_AUTHKEY` 一次性静默入网，或按终端提示浏览器登录一次。
  - 手机：`GeniusTsnet.xcframework`（`tools/gctsnet-mobile` gomobile 产物，已内嵌 `Apps/Phone/Frameworks/`）在 app 内跑 tsnet，通过 127.0.0.1 环回代理拨号（TLS 钉扎端到端不变）；首次远程连接 app 内会出现 Tailscale 登录链接。
  - 重建 Go 侧：`PATH=$HOME/.gc-toolchain/go/bin:$HOME/go/bin:$PATH GOPROXY=https://goproxy.cn GOTOOLCHAIN=local` 后在对应目录 `go build` / `gomobile bind -target ios`（x/mobile 按 2024-12 伪版本钉住）。
- 注意：`serve` 的 stdout 重定向到文件时受 stdio 8KB 缓冲影响可能看不到后半段输出——在真终端运行即正常。

## 已知限制

- 手机端缓存为 JSON 文件（spec 允许 SQLite 上限 200MiB 的 LRU，v1 未做 LRU 淘汰）。
- FSEvents 去抖刷新未接，v1 为手动/定时刷新。
- `dsh --profile acp` 首次启动会创建 `~/.dsh/profiles/acp`（已知副作用）。
- Codex 打开归档线程是否必须先 `thread/unarchive` 由打开路径自动重试并记录（spec Open Question 5）。
- 内嵌 tsnet 需要免费的 Tailscale 账号（控制面）；退后台连接挂起与 v1 断线模型一致。
- 手机 app 安装仍走免费签名（Xcode + 7 天续签）；TestFlight/App Store 需付费开发者账号。
