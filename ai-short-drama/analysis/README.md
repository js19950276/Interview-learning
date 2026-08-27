# DataEye 红果热榜 Top100 分析

## 用法

```bash
python3 scripts/analyze_hongguo_top100.py --input /path/to/hongguo_snapshots.csv
```

也支持传目录，脚本会自动读取目录下的 `.csv / .json / .jsonl / .xlsx` 文件并合并。

## 输入字段

至少需要这 3 列：

- `snapshot_date` / `date` / `日期`
- `rank` / `排名`
- `title` / `剧名`

可选列：

- `heat_value` / `热度`
- `source_tags` / `标签`
- `synopsis` / `简介`
- `content_type` / `内容类型`

## 输出

- `hongguo_top100_cleaned.csv`：清洗后的逐日 Top100 明细
- `hongguo_title_summary.csv`：每个剧的在榜天数、最好名次、主标签
- `hongguo_daily_tag_summary.csv`：按天聚合的标签份额
- `hongguo_weekly_tag_summary.csv`：按周聚合的标签份额
- `hongguo_new_title_summary.csv`：新剧贡献占比
- `hongguo_trend_insights.md`：自动生成的趋势结论
- `hongguo_report.html`：可直接打开的静态报告

## 指标说明

- `rank_score = 101 - rank`
- 主趋势图使用 `rank_share_7d`，即一级标签在 Top100 中的 **7 日滚动积分份额**
- `new_title_rank_share`：上榜 7 天内的新剧所贡献的积分份额
