# 结构化游戏数据人工复核

这套流程用于让第二位真人逐条核对 `v2018.11` 的结构化数值。它只导出文字与数字，不下载、复制或
打包官方地图、卡面、规则书 PDF 或其他美术资源。当前 `manifest.json` 继续保持 `draft`，工具也不会
自动修改它。

## 1. 生成稳定审阅物

在仓库根目录运行：

```bash
bash scripts/verify_game_data.sh --export-review /tmp/brass-v2018.11-review.jsonl
bash scripts/verify_game_data.sh --check-review /tmp/brass-v2018.11-review.jsonl
```

JSONL 第一行是只读头信息，绑定当前 `manifest.json`、五个 canonical JSON 的 SHA-256、来源目录和
各区域条数。其后 243 行逐条覆盖：

- 27 个地图 location、39 条 route、9 个 merchant slot；
- 29 个产业等级；
- 31 种卡牌记录、8 种 merchant 记录；
- 收入轨 0–99 共 100 格。

每行都有稳定 `locator`、原文件 `jsonPointer`、该指针处的完整 canonical JSON、行 SHA-256、来源
引用、`transcriberIDs`，以及待填写的 checker ID/date/status/notes。除以下五个字段外不要编辑任何内容：

- `checker`：第二位真人姓名或可审计身份；
- `checkerID`：稳定、小写 ASCII 身份 ID，例如 `li-si`；不能等于任一 `transcriberID`；
- `checkedOn`：`YYYY-MM-DD`；
- `status`：确认相符后从 `pending` 改为 `checked`；
- `notes`：差异或物理组件定位说明；有未解决差异时保持 `pending`。

## 2. 逐行人工核对

checker 必须不是任一 source 的 transcriber。checker 使用自己合法持有的实体组件或获授权的组件
参考，按 `locator` 和 `canonicalJSON` 核对地图位置/线路/槽位、每级产业板、卡牌数量与人数掩码、
merchant 和收入轨。不能仅以 App、DemoFixture 或另一个转录文件反向证明自身正确。

发现差异时：在 `notes` 记录实体位置与差异，保持 `pending`，先修订 canonical JSON、来源记录和
manifest 文件哈希，再重新导出一份全新的审阅物。任何 canonical 文件、manifest 或不可编辑行字段
变化，旧审阅物都会被拒绝；遗漏、重复 locator 和行篡改也会被拒绝。

## 3. 校验并生成建议元数据

完成全部 243 行后运行：

```bash
bash scripts/verify_game_data.sh --check-review /tmp/brass-v2018.11-review.jsonl
bash scripts/verify_game_data.sh --suggest-review-metadata /tmp/brass-v2018.11-review.jsonl \
  > /tmp/brass-v2018.11-manifest-suggestion.json
```

只有所有行均为 `checked`、checker/checkerID/date 完整、checkerID 与所有 transcriberID 独立、日期
真实且满足 transcription ≤ check ≤ today（today 按 UTC 公历日期计算），并且整份审阅物仍绑定当前
数据时，第二条命令才输出建议。
建议包含不含 checker/evidence 的 `baseDataDigest`，以及 `verificationEvidence` 的 artifact path、SHA-256、
243 行计数和同一 base digest，避免 manifest 自引用。它是 advisory-only JSON，不会写回仓库。

人工审阅建议无误后，维护者把已完成 JSONL 放入 `v2018.11`，再手动把每个 source 的
checker/checkerID/checkedOn 与 `verificationEvidence` 写入 `manifest.json`，将状态改为 `verified`，
更新必要的审计记录，并运行：

```bash
bash scripts/verify_game_data.sh
```

在此之前，正常数据门禁按设计保持失败，结构化草稿不能作为已验证对局数据。

导出使用同目录临时文件和排他式原子发布；目标已存在（包括符号链接）时会拒绝，不提供覆盖参数。

## 4. 门禁自身验证

```bash
bash scripts/verify_game_data.sh --self-test
```

自测覆盖稳定导出、精确覆盖、canonical pointer、来源完整性，以及 tamper、missing、duplicate、
wrong-hash、数据变化导致旧审阅失效、self-checker、partial review 等拒绝路径。
