from __future__ import annotations

import argparse
import html
import re
from pathlib import Path
from typing import Iterable

import pandas as pd

from analysis.hongguo_rank_analysis import (
    PRIMARY_TAG_COLORS,
    PRIMARY_TAG_PRIORITY,
    normalize_tag_tokens,
    resolve_level2_tags,
    resolve_primary_tag,
    safe_pct,
)


CHART_TITLES = [
    ("top1_title", "top1_heat_w", 1),
    ("top2_title", "top2_heat_w", 2),
    ("top3_title", "top3_heat_w", 3),
]

KNOWN_NON_TITLE_PHRASES = {
    "DataEye",
    "TOP30",
    "TOP4",
    "TOP5",
    "TOP10",
    "TOP11",
    "TOP20",
    "TOP25",
    "Top1",
    "Top2",
    "Top3",
    "Top30",
    "红果",
    "真人AI版",
}


def clean_number(value) -> float | None:
    if pd.isna(value):
        return None
    text = str(value).strip()
    if not text:
        return None
    text = text.replace(",", "")
    try:
        return float(text)
    except ValueError:
        return None


def title_to_tags(title: str, notes: str = "") -> tuple[str, str]:
    title = str(title or "").strip()
    if not title or title == "未知":
        return "其他", ""
    # 只用剧名打标签，避免同一条 notes 里其它剧名/题材污染当前剧名。
    search_text = title
    source_tags: list[str] = []
    primary = resolve_primary_tag(search_text, source_tags)
    level2 = "、".join(resolve_level2_tags(search_text, source_tags))
    return primary, level2


def explode_top_titles(frame: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for record in frame.itertuples(index=False):
        for title_col, heat_col, rank in CHART_TITLES:
            title = str(getattr(record, title_col, "") or "").strip()
            if not title or title == "nan" or title == "未知":
                continue
            heat = clean_number(getattr(record, heat_col, None))
            primary, secondary = title_to_tags(title, getattr(record, "notes", ""))
            rows.append(
                {
                    "snapshot_date": record.snapshot_date,
                    "rank": rank,
                    "rank_score": 4 - rank,
                    "title": title,
                    "heat_w": heat,
                    "primary_tag_l1": primary,
                    "secondary_tags_l2": secondary,
                    "source_url": getattr(record, "source_url", ""),
                    "completeness": getattr(record, "completeness", ""),
                }
            )
    result = pd.DataFrame(rows)
    if result.empty:
        return result
    result["snapshot_date"] = pd.to_datetime(result["snapshot_date"])
    return result.sort_values(["snapshot_date", "rank"]).reset_index(drop=True)


def extract_note_titles(notes: str) -> list[str]:
    if not notes:
        return []
    candidates = re.findall(r"《([^》]{2,40})》", str(notes))
    cleaned: list[str] = []
    for candidate in candidates:
        title = candidate.strip()
        title = title.replace("...", "")
        title = title.strip(" ，,；;。")
        if not title or title in KNOWN_NON_TITLE_PHRASES:
            continue
        if any(title.lower() == phrase.lower() for phrase in KNOWN_NON_TITLE_PHRASES):
            continue
        cleaned.append(title)
    return list(dict.fromkeys(cleaned))


def explode_extended_titles(frame: pd.DataFrame) -> pd.DataFrame:
    top_titles = explode_top_titles(frame)
    rows = top_titles.to_dict("records") if not top_titles.empty else []
    existing = {
        (pd.to_datetime(row["snapshot_date"]).date(), row["title"])
        for row in rows
    }

    for record in frame.itertuples(index=False):
        snapshot_date = pd.to_datetime(record.snapshot_date)
        notes = str(getattr(record, "notes", "") or "")
        for title in extract_note_titles(notes):
            key = (snapshot_date.date(), title)
            if key in existing:
                continue
            primary, secondary = title_to_tags(title, notes)
            rows.append(
                {
                    "snapshot_date": snapshot_date,
                    "rank": 99,
                    "rank_score": 0.5,
                    "title": title,
                    "heat_w": None,
                    "primary_tag_l1": primary,
                    "secondary_tags_l2": secondary,
                    "source_url": getattr(record, "source_url", ""),
                    "completeness": getattr(record, "completeness", ""),
                    "sample_source": "notes",
                }
            )
            existing.add(key)

    result = pd.DataFrame(rows)
    if result.empty:
        return result
    if "sample_source" not in result.columns:
        result["sample_source"] = "top3"
    result["sample_source"] = result["sample_source"].fillna("top3")
    result["snapshot_date"] = pd.to_datetime(result["snapshot_date"])
    return result.sort_values(["snapshot_date", "rank", "title"]).reset_index(drop=True)


def build_daily_tag_summary(top_titles: pd.DataFrame) -> pd.DataFrame:
    if top_titles.empty:
        return pd.DataFrame()
    summary = (
        top_titles.groupby(["snapshot_date", "primary_tag_l1"])
        .agg(
            title_count=("title", "nunique"),
            rank_score_sum=("rank_score", "sum"),
            heat_w_sum=("heat_w", "sum"),
        )
        .reset_index()
    )
    summary["rank_share"] = summary.groupby("snapshot_date")["rank_score_sum"].transform(lambda s: s / s.sum())
    heat_total = summary.groupby("snapshot_date")["heat_w_sum"].transform("sum")
    summary["heat_share"] = summary["heat_w_sum"] / heat_total.where(heat_total > 0, pd.NA)
    summary["heat_share"] = summary["heat_share"].fillna(0.0)
    return summary.sort_values(["snapshot_date", "primary_tag_l1"]).reset_index(drop=True)


def build_heat_series(frame: pd.DataFrame) -> pd.DataFrame:
    result = frame.copy()
    result["snapshot_date"] = pd.to_datetime(result["snapshot_date"])
    for col in ("top1_heat_w", "top2_heat_w", "top3_heat_w", "top30_floor_w"):
        if col in result.columns:
            result[col] = result[col].map(clean_number)
    return result.sort_values("snapshot_date").reset_index(drop=True)


def pct_or_na(value) -> str:
    if pd.isna(value):
        return "—"
    return safe_pct(float(value))


def heat_label(value) -> str:
    if value is None or pd.isna(value):
        return "—"
    value = float(value)
    if value >= 10000:
        return f"{value / 10000:.2g}亿"
    return f"{value:.0f}W"


def format_date(value) -> str:
    return pd.to_datetime(value).strftime("%Y-%m-%d")


def render_heat_line_svg(heat_series: pd.DataFrame) -> str:
    plot = heat_series.dropna(subset=["top1_heat_w"]).copy()
    if plot.empty:
        return "<p>暂无可绘制数据。</p>"

    width, height = 1060, 400
    left, right, top, bottom = 62, 28, 28, 54
    inner_w, inner_h = width - left - right, height - top - bottom
    dates = pd.to_datetime(plot["snapshot_date"]).tolist()
    min_date, max_date = min(dates), max(dates)
    span_days = max((max_date - min_date).days, 1)

    max_heat = max(plot["top1_heat_w"].max(), plot["top30_floor_w"].max(skipna=True) or 0)
    max_heat = max_heat * 1.12

    def x_of(date) -> float:
        return left + ((pd.to_datetime(date) - min_date).days / span_days) * inner_w

    def y_of(value) -> float:
        return top + inner_h * (1 - float(value) / max_heat)

    grid = []
    for i in range(6):
        value = max_heat * i / 5
        y = y_of(value)
        grid.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}" stroke="#e2e8f0" />')
        grid.append(f'<text x="{left-10}" y="{y+4:.1f}" text-anchor="end" font-size="12" fill="#64748b">{heat_label(value)}</text>')

    def path_for(col: str) -> str:
        points = [
            (x_of(row.snapshot_date), y_of(getattr(row, col)))
            for row in plot.itertuples(index=False)
            if not pd.isna(getattr(row, col))
        ]
        if not points:
            return ""
        return "M " + " L ".join(f"{x:.1f},{y:.1f}" for x, y in points)

    top1_path = path_for("top1_heat_w")
    floor_path = path_for("top30_floor_w") if "top30_floor_w" in plot.columns else ""

    circles = []
    labels = []
    for row in plot.itertuples(index=False):
        x = x_of(row.snapshot_date)
        y = y_of(row.top1_heat_w)
        title = html.escape(str(row.top1_title))
        circles.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4.5" fill="#ef4444">'
            f"<title>{format_date(row.snapshot_date)} {title} {heat_label(row.top1_heat_w)}</title></circle>"
        )
    tick_indexes = sorted(set([0, len(plot) // 4, len(plot) // 2, len(plot) * 3 // 4, len(plot) - 1]))
    for idx in tick_indexes:
        row = plot.iloc[idx]
        x = x_of(row["snapshot_date"])
        labels.append(f'<text x="{x:.1f}" y="{height-24}" text-anchor="middle" font-size="12" fill="#64748b">{pd.to_datetime(row["snapshot_date"]).strftime("%m-%d")}</text>')

    legend = (
        '<rect x="70" y="10" width="12" height="12" fill="#ef4444" rx="2"/><text x="88" y="21" font-size="12" fill="#334155">榜首热度</text>'
        '<rect x="165" y="10" width="12" height="12" fill="#64748b" rx="2"/><text x="183" y="21" font-size="12" fill="#334155">Top30门槛</text>'
    )
    return (
        f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="榜首热度趋势">'
        + "".join(grid)
        + (f'<path d="{floor_path}" fill="none" stroke="#64748b" stroke-width="2" stroke-dasharray="5 5"/>' if floor_path else "")
        + f'<path d="{top1_path}" fill="none" stroke="#ef4444" stroke-width="3"/>'
        + "".join(circles)
        + "".join(labels)
        + legend
        + "</svg>"
    )


def render_tag_bar_svg(tag_summary: pd.DataFrame) -> str:
    if tag_summary.empty:
        return "<p>暂无可绘制数据。</p>"
    tag_totals = (
        tag_summary.groupby("primary_tag_l1")["rank_score_sum"]
        .sum()
        .sort_values(ascending=False)
        .reset_index()
    )
    tag_totals = tag_totals[tag_totals["primary_tag_l1"] != "其他"]
    max_value = tag_totals["rank_score_sum"].max()
    width, height = 820, 340
    left, top = 128, 24
    bar_h, gap = 26, 10
    inner_w = width - left - 40
    elements = []
    for idx, row in enumerate(tag_totals.itertuples(index=False)):
        y = top + idx * (bar_h + gap)
        w = inner_w * row.rank_score_sum / max_value
        color = PRIMARY_TAG_COLORS.get(row.primary_tag_l1, "#94a3b8")
        elements.append(f'<text x="{left-10}" y="{y+18}" text-anchor="end" font-size="12" fill="#334155">{html.escape(row.primary_tag_l1)}</text>')
        elements.append(f'<rect x="{left}" y="{y}" width="{w:.1f}" height="{bar_h}" rx="5" fill="{color}"/>')
        elements.append(f'<text x="{left+w+8:.1f}" y="{y+18}" font-size="12" fill="#0f172a">{row.rank_score_sum:.0f}</text>')
    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="Top3标签积分分布">{"".join(elements)}</svg>'


def render_compare_tag_svg(top_summary: pd.DataFrame, extended_summary: pd.DataFrame) -> str:
    if top_summary.empty or extended_summary.empty:
        return "<p>暂无可绘制数据。</p>"

    top_totals = top_summary.groupby("primary_tag_l1")["rank_score_sum"].sum()
    ext_totals = extended_summary.groupby("primary_tag_l1")["rank_score_sum"].sum()
    tags = [
        tag
        for tag in PRIMARY_TAG_PRIORITY
        if tag != "其他" and (top_totals.get(tag, 0) > 0 or ext_totals.get(tag, 0) > 0)
    ]
    if not tags:
        return "<p>暂无可绘制数据。</p>"
    max_value = max([top_totals.get(tag, 0) for tag in tags] + [ext_totals.get(tag, 0) for tag in tags])

    width, height = 860, 380
    left, top = 128, 24
    group_h, bar_h = 42, 14
    inner_w = width - left - 52
    elements = []
    for idx, tag in enumerate(tags):
        y = top + idx * group_h
        top_w = inner_w * top_totals.get(tag, 0) / max_value
        ext_w = inner_w * ext_totals.get(tag, 0) / max_value
        color = PRIMARY_TAG_COLORS.get(tag, "#94a3b8")
        elements.append(f'<text x="{left-10}" y="{y+25}" text-anchor="end" font-size="12" fill="#334155">{html.escape(tag)}</text>')
        elements.append(f'<rect x="{left}" y="{y}" width="{top_w:.1f}" height="{bar_h}" rx="4" fill="{color}" fill-opacity="0.45"><title>Top3 {top_totals.get(tag, 0):.1f}</title></rect>')
        elements.append(f'<rect x="{left}" y="{y+18}" width="{ext_w:.1f}" height="{bar_h}" rx="4" fill="{color}"><title>扩展样本 {ext_totals.get(tag, 0):.1f}</title></rect>')
        elements.append(f'<text x="{left+ext_w+8:.1f}" y="{y+30}" font-size="11" fill="#0f172a">{ext_totals.get(tag, 0):.1f}</text>')
    legend = (
        '<rect x="130" y="350" width="12" height="12" fill="#334155" fill-opacity="0.35" rx="2"/><text x="148" y="361" font-size="12" fill="#334155">仅Top3</text>'
        '<rect x="210" y="350" width="12" height="12" fill="#334155" rx="2"/><text x="228" y="361" font-size="12" fill="#334155">Top3+备注剧名</text>'
    )
    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="Top3和扩展样本标签对比">{"".join(elements)}{legend}</svg>'


def render_month_tag_table(top_titles: pd.DataFrame) -> str:
    if top_titles.empty:
        return ""
    tmp = top_titles.copy()
    tmp["month"] = tmp["snapshot_date"].dt.strftime("%Y-%m")
    month_tag = (
        tmp.groupby(["month", "primary_tag_l1"])["rank_score"]
        .sum()
        .reset_index()
        .sort_values(["month", "rank_score"], ascending=[True, False])
    )
    rows = []
    for month, group in month_tag.groupby("month"):
        top_tags = "、".join(
            f"{row.primary_tag_l1}({row.rank_score:.0f})"
            for row in group.head(3).itertuples(index=False)
            if row.primary_tag_l1 != "其他"
        )
        rows.append(f"<tr><td>{html.escape(month)}</td><td>{html.escape(top_tags)}</td></tr>")
    return "".join(rows)


def build_monthly_tag_summary(extended_titles: pd.DataFrame) -> pd.DataFrame:
    if extended_titles.empty:
        return pd.DataFrame()
    tmp = extended_titles.copy()
    tmp["month"] = tmp["snapshot_date"].dt.strftime("%Y-%m")
    summary = (
        tmp.groupby(["month", "primary_tag_l1"])
        .agg(
            rank_score_sum=("rank_score", "sum"),
            title_count=("title", "nunique"),
            representative_titles=("title", lambda s: "、".join(list(dict.fromkeys(map(str, s)))[:4])),
        )
        .reset_index()
    )
    total = summary.groupby("month")["rank_score_sum"].transform("sum")
    summary["share"] = summary["rank_score_sum"] / total
    return summary.sort_values(["month", "rank_score_sum"], ascending=[True, False]).reset_index(drop=True)


def render_monthly_stacked_svg(monthly_summary: pd.DataFrame) -> str:
    if monthly_summary.empty:
        return "<p>暂无可绘制数据。</p>"
    tags = [tag for tag in PRIMARY_TAG_PRIORITY if tag != "其他"]
    pivot = (
        monthly_summary.pivot(index="month", columns="primary_tag_l1", values="share")
        .fillna(0.0)
        .reindex(columns=tags)
    )
    months = list(pivot.index)
    if not months:
        return "<p>暂无可绘制数据。</p>"

    width, height = 1060, 430
    left, right, top, bottom = 58, 24, 34, 64
    inner_w, inner_h = width - left - right, height - top - bottom
    band_w = inner_w / max(len(months), 1)
    bar_w = min(46, band_w * 0.68)
    elements = []

    for i in range(6):
        value = i / 5
        y = top + inner_h * (1 - value)
        elements.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}" stroke="#e2e8f0"/>')
        elements.append(f'<text x="{left-10}" y="{y+4:.1f}" text-anchor="end" font-size="12" fill="#64748b">{int(value*100)}%</text>')

    for month_idx, month in enumerate(months):
        x = left + month_idx * band_w + (band_w - bar_w) / 2
        cumulative = 0.0
        for tag in tags:
            share = float(pivot.loc[month, tag])
            if share <= 0:
                continue
            h = inner_h * share
            y = top + inner_h * (1 - cumulative - share)
            color = PRIMARY_TAG_COLORS.get(tag, "#94a3b8")
            elements.append(
                f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{h:.1f}" fill="{color}" rx="3">'
                f"<title>{html.escape(month)} {html.escape(tag)} {safe_pct(share)}</title></rect>"
            )
            cumulative += share
        elements.append(
            f'<text x="{x+bar_w/2:.1f}" y="{height-34}" text-anchor="middle" font-size="11" fill="#64748b" transform="rotate(-35 {x+bar_w/2:.1f},{height-34})">{html.escape(month[2:])}</text>'
        )

    legend = []
    for idx, tag in enumerate(tags):
        x = left + (idx % 4) * 150
        y = 8 + (idx // 4) * 18
        color = PRIMARY_TAG_COLORS.get(tag, "#94a3b8")
        legend.append(f'<rect x="{x}" y="{y}" width="12" height="12" fill="{color}" rx="2"/>')
        legend.append(f'<text x="{x+18}" y="{y+10}" font-size="12" fill="#334155">{html.escape(tag)}</text>')

    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="月度题材占比堆叠柱图">{"".join(elements)}{"".join(legend)}</svg>'


def render_monthly_representative_table(monthly_summary: pd.DataFrame) -> str:
    if monthly_summary.empty:
        return ""
    rows = []
    for month, group in monthly_summary.groupby("month", sort=True):
        top_group = group[group["primary_tag_l1"] != "其他"].head(3)
        tag_parts = []
        title_parts = []
        for row in top_group.itertuples(index=False):
            tag_parts.append(f"{row.primary_tag_l1} {safe_pct(float(row.share))}")
            title_parts.append(f"{row.primary_tag_l1}：{row.representative_titles}")
        rows.append(
            f"<tr><td>{html.escape(month)}</td><td>{html.escape('；'.join(tag_parts))}</td>"
            f"<td>{html.escape('；'.join(title_parts))}</td></tr>"
        )
    return "".join(rows)


TITLE_ELEMENT_RULES = {
    "太奶奶/家族": ("太奶奶", "家族", "全家", "一家三口", "孝子贤孙", "外甥女", "公婆"),
    "婚恋关系": ("妻子", "老婆", "老公", "结婚", "婚事", "未婚妻", "离婚", "闪婚", "爱", "心动"),
    "白月光": ("白月光",),
    "重生/穿书": ("重生", "穿书", "穿成", "炮灰", "女配", "八零"),
    "古风权贵": ("王妃", "侯府", "权臣", "郡主", "将军", "首辅", "少帅", "国师", "嫡女"),
    "萌宝/亲子": ("萌宝", "儿子", "女儿", "爹", "娘亲", "爹爹", "宝宝"),
    "豪门/霸总": ("豪门", "总裁", "傅爷", "贺少", "顾机长", "机长", "千金"),
    "逆袭/爽点": ("逆袭", "打脸", "觉醒", "赢", "学霸", "荣耀", "不灭", "傲世", "屠龙"),
    "奇幻/修仙": ("修仙", "魔尊", "神主", "妖女", "天道", "菩提", "临世", "魔", "仙"),
    "AI/漫剧": ("AI", "真人AI", "仿真人", "漫"),
    "乡村/现实": ("乡村", "山村", "奔小康", "小圣医"),
}

CONTENT_IDEA_LIBRARY = [
    {
        "direction": "家庭亲情爽剧",
        "signals": ("太奶奶/家族", "萌宝/亲子", "逆袭/爽点"),
        "why": "公开样本中“太奶奶/家族”元素积分最高，且家庭/亲情在多个月份成为主导题材。",
        "templates": [
            "《{辈分反差}驾到，全家跪求我改命》",
            "《被全家嫌弃后，{隐藏身份}带崽归来》",
            "《听见我心声后，{家族成员}全员觉醒》",
        ],
        "hooks": [
            "开局制造家庭误解或被轻视，3分钟内给出身份/能力反转。",
            "用亲情修复承接爽点，避免只打脸没有情绪回报。",
            "适合做系列化：第一部家族危机，第二部外部敌人，第三部下一代传承。",
        ],
        "risks": [
            "太奶奶/家族荣耀类已经有强势样本，跟风时需要换关系结构或新职业壳。",
            "亲情题材不能只堆称谓，必须有明确的亏欠、补偿、团圆情绪线。",
        ],
    },
    {
        "direction": "婚恋情感爽剧",
        "signals": ("婚恋关系", "白月光", "豪门/霸总"),
        "why": "现代情感是公开样本中最稳定的基础盘，婚恋关系、白月光、妻子/夫人类标题持续出现在头部。",
        "templates": [
            "《离婚当天，{男主身份}才知我是他的白月光》",
            "《人前不熟，人后{关系反差}》",
            "《替嫁后，{霸总/豪门}全家把我宠疯了》",
        ],
        "hooks": [
            "第一集要明确错位关系：隐婚、替嫁、误会、身份不对等。",
            "中段用“追妻/追夫火葬场 + 外部情敌”维持情绪强度。",
            "标题尽量直接给出关系张力，不要只写抽象情绪。",
        ],
        "risks": [
            "纯甜宠容易同质化，最好绑定身份反转、家族冲突或职业爽点。",
            "白月光/替身设定要控制虐感，红果用户更需要爽感回收。",
        ],
    },
    {
        "direction": "古风权贵女频",
        "signals": ("古风权贵", "重生/穿书", "逆袭/爽点"),
        "why": "古风/古代虽然不是每月第一，但在公开样本中持续出现，且常与穿书、炮灰、权臣、郡主等强设定结合。",
        "templates": [
            "《穿成炮灰嫡女后，{权贵男主}跪求我回头》",
            "《十岁郡主养成纨绔爹，最后他成了皇帝》",
            "《重生后，我用三条阳谋吓哭满朝权贵》",
        ],
        "hooks": [
            "开局给身份压迫：庶女/炮灰/弃妃/弱女。",
            "爽点不要只靠男主救场，女主需要主动布局或掌握稀缺能力。",
            "权谋要短剧化：每3-5集完成一个小反杀闭环。",
        ],
        "risks": [
            "古风制作成本较高，若预算不足可选择宅斗/侯府小场景。",
            "权谋信息密度不能太高，否则影响下沉用户理解。",
        ],
    },
    {
        "direction": "奇幻系统/AI漫剧",
        "signals": ("奇幻/修仙", "AI/漫剧", "逆袭/爽点"),
        "why": "扩展样本里奇幻/系统权重提升，且2026年公开摘要已经出现AI仿真人漫相关强信号。",
        "templates": [
            "《绑定{系统能力}后，我让全家逆天改命》",
            "《灵气复苏当天，我成了全城唯一清醒的人》",
            "《真人AI版：{经典爆款元素}重启》",
        ],
        "hooks": [
            "设定必须一句话讲清楚：绑定系统、读心、预知、修仙回归。",
            "每集给一个可视化能力展示，适合AI/漫剧传播。",
            "和家庭/婚恋结合，比纯设定更容易进入红果用户语境。",
        ],
        "risks": [
            "AI/漫剧和真人短剧口径可能混榜，分析和投放时要单独拆分。",
            "纯玄幻设定可能门槛高，建议绑定亲情、复仇或婚恋主线。",
        ],
    },
    {
        "direction": "豪门职业反差",
        "signals": ("豪门/霸总", "婚恋关系", "逆袭/爽点"),
        "why": "豪门/总裁在2025年8-9月公开样本中表现突出，且常和婚恋、身份反转一起出现。",
        "templates": [
            "《豪门月嫂转正后，全家把我当白月光》",
            "《顾机长，太太说自己已守寡三年》",
            "《傅爷的小青梅回国后，京圈炸了》",
        ],
        "hooks": [
            "用职业身份制造新鲜感：月嫂、机长、律师、医生、秘书。",
            "豪门不是目的，重点是阶层错位和情绪补偿。",
            "适合“人前低位、人后高能”的结构。",
        ],
        "risks": [
            "霸总题材高度成熟，需要靠职业壳或家庭壳做差异化。",
            "标题不要过度抽象，要保留具体身份词。",
        ],
    },
]

TITLE_GENERATOR = {
    "家庭亲情爽剧": [
        "《太奶奶驾到，全家跪求我改命》",
        "《被赶出家门后，我成了全家福星》",
        "《听见我心声后，三个哥哥全员觉醒》",
        "《我是你们太奶奶，孝子贤孙都别哭》",
        "《重回认亲当天，我带全家逆天改命》",
        "《团宠萌宝三岁半，全家靠我翻身》",
        "《妈妈别怕，这次换我保护你》",
        "《外婆回家后，全村都跟着暴富了》",
        "《九个外甥跪求我重整家族》",
        "《全家嫌我累赘，转身我救了豪门》",
        "《奶奶重生后，把白眼狼全家打醒》",
        "《被养女夺走人生后，亲生女儿杀回来了》",
        "《回家第一天，我听见全家心声》",
        "《孝子贤孙别装了，太奶奶全都知道》",
        "《三个哥哥悔疯了，妹妹才是真千金》",
        "《全家火葬场后，我带妈妈独美》",
        "《八零团宠小福星，带着全家奔小康》",
        "《我死后，全家才知我替他们挡灾》",
        "《萌宝找上门，爹地妈咪别想跑》",
        "《被婆家赶走后，我成了全城最旺的月嫂》",
    ],
    "婚恋情感爽剧": [
        "《离婚当天，顾机长才知我是他的白月光》",
        "《人前不熟，人后上瘾》",
        "《替嫁后，冷面总裁把我宠疯了》",
        "《隐婚三年，傅爷跪求我公开》",
        "《前妻回国后，京圈太子爷悔到失控》",
        "《错认我成替身后，他追妻火葬场》",
        "《久别重逢，偏执大佬又沦陷了》",
        "《闪婚后，我成了豪门全家的心尖宠》",
        "《白月光不装了，渣总跪求复婚》",
        "《她比星星耀眼，他比旧爱危险》",
        "《别有用心的妻子，才是真正的救命恩人》",
        "《协议到期后，总裁他不肯离婚》",
        "《带球跑五年后，傅爷堵在幼儿园门口》",
        "《顾太太说自己守寡三年》",
        "《先婚后爱，贺少每天都想官宣》",
        "《心动还请告诉我，别让我再等十年》",
        "《小青梅回国后，京圈炸了》",
        "《离婚夜，她成了全城最贵的玫瑰》",
        "《未婚妻与他人领证，我转身娶了她姐姐》",
        "《疯美人归来，前夫全家都慌了》",
    ],
    "豪门职业反差": [
        "《豪门月嫂转正后，全家把我当白月光》",
        "《我只是秘书，却成了傅爷的救命恩人》",
        "《女机长离职当天，顾总跪求复婚》",
        "《急诊医生不装了，豪门全家排队道歉》",
        "《金牌律师回国后，京圈太子爷输惨了》",
        "《财阀婆家嫌我低贱，得知身份后悔疯》",
        "《顾机长，太太说自己已守寡三年》",
        "《月嫂进门后，豪门三代都被治服了》",
        "《傅爷的小青梅，是全城最贵的医生》",
        "《离职当天，总裁才知我是公司大股东》",
        "《豪门保姆藏身份，少爷全家跪了》",
        "《我靠一碗汤，治好了豪门全家的心病》",
        "《京圈太子爷的救命恩人，是他的前妻》",
        "《她是月嫂，也是失踪二十年的真千金》",
        "《小秘书翻身后，傅爷连夜改遗嘱》",
        "《被豪门退婚后，我成了他们的主治医生》",
        "《冷面机长失控了，只因太太不回头》",
        "《豪门全家听我心声后，跪求我别走》",
        "《我不是保姆，是你们请不起的神医》",
        "《替豪门带娃三年，我成了孩子亲妈》",
    ],
    "古风权贵女频": [
        "《穿成炮灰嫡女后，摄政王跪求我回头》",
        "《十岁郡主养成纨绔爹，最后他成了皇帝》",
        "《重生后，我用三条阳谋吓哭满朝权贵》",
        "《侯府弃女归来，权臣夜夜求娶》",
        "《替嫁王妃会读心，王爷藏不住了》",
        "《将门孤女重生后，满朝都跪了》",
        "《庶女不装了，冷面首辅悔疯了》",
        "《穿书后，我把炮灰全家改命了》",
        "《嫡女国师归来，皇帝也要听我心声》",
        "《王妃十岁半，养出一个少年将军》",
        "《被退婚后，我成了摄政王的掌心娇》",
        "《她手握天命，侯府全员火葬场》",
        "《权臣嫌我弱，后来为我跪了一夜》",
        "《郡主别装了，满朝文武都听见你心声》",
        "《重生第一天，我休了未来皇帝》",
        "《将军夫人有点强，皇帝都不敢惹》",
        "《穿成恶毒女配后，我成了公婆心尖宠》",
        "《侯府弱女三条毒计，吓哭皇帝》",
        "《替嫁当天，我让王府全员改命》",
        "《嫡女归来，先把纨绔爹养成权臣》",
    ],
    "奇幻系统/AI漫剧": [
        "《绑定心声系统后，我让全家逆天改命》",
        "《灵气复苏当天，我成了唯一清醒的人》",
        "《真人AI版：天道崩坏时》",
        "《末世降临前，我靠预知系统囤满全城》",
        "《神豪系统觉醒后，前夫全家跪了》",
        "《修仙归来，我成了豪门月嫂》",
        "《全家炮灰命觉醒后，我绑定改命系统》",
        "《AI重启后，我看见了所有人的结局》",
        "《菩提临世，真人AI版》",
        "《我被天道选中后，全城都听见我心声》",
        "《绑定读心术后，我治好了豪门全家》",
        "《末世女王回到八零，带全家奔小康》",
        "《修仙多年强亿点，回家却被当废物》",
        "《高能漫剧：我靠系统把仇人送进火葬场》",
        "《预知三天后，我先让渣男破产》",
        "《我能听见弹幕，全家命运改写了》",
        "《魔尊归来后，成了三个萌宝的爹》",
        "《绑定神医系统后，豪门全家排队求我》",
        "《天命小祖宗，三岁半就能改国运》",
        "《仿真人漫：全城等我认输》",
    ],
}


def build_generated_titles(per_direction: int = 20) -> pd.DataFrame:
    rows = []
    for direction, titles in TITLE_GENERATOR.items():
        for title in titles[:per_direction]:
            primary, secondary = title_to_tags(title)
            rows.append(
                {
                    "direction": direction,
                    "title": title,
                    "primary_tag_l1": primary,
                    "secondary_tags_l2": secondary,
                }
            )
    return pd.DataFrame(rows)


def render_generated_titles_html(generated_titles: pd.DataFrame) -> str:
    blocks = []
    for direction, group in generated_titles.groupby("direction", sort=False):
        items = "".join(
            f"<li>{html.escape(row.title)}</li>"
            for row in group.head(20).itertuples(index=False)
        )
        blocks.append(f"<div class='title-block'><h3>{html.escape(direction)}</h3><ol>{items}</ol></div>")
    return "".join(blocks)


def render_generated_titles_markdown(generated_titles: pd.DataFrame) -> str:
    sections = []
    for direction, group in generated_titles.groupby("direction", sort=False):
        lines = [f"## {direction}", ""]
        lines.extend(f"{idx}. {row.title}" for idx, row in enumerate(group.itertuples(index=False), start=1))
        sections.append("\n".join(lines))
    return "# 红果短剧标题生成器\n\n" + "\n\n".join(sections) + "\n"


def build_content_ideas(element_summary: pd.DataFrame, monthly_summary: pd.DataFrame) -> list[dict]:
    element_score = dict(zip(element_summary["element"], element_summary["score"]))
    latest_month = monthly_summary["month"].max() if not monthly_summary.empty else None
    latest_tags: set[str] = set()
    if latest_month:
        latest_rows = monthly_summary[
            (monthly_summary["month"] == latest_month) & (monthly_summary["primary_tag_l1"] != "其他")
        ].head(3)
        latest_tags = set(latest_rows["primary_tag_l1"].tolist())

    ideas = []
    for idea in CONTENT_IDEA_LIBRARY:
        score = sum(float(element_score.get(signal, 0.0)) for signal in idea["signals"])
        if idea["direction"].startswith("家庭") and "家庭/亲情" in latest_tags:
            score += 3
        if idea["direction"].startswith("婚恋") and "现代情感" in latest_tags:
            score += 3
        if idea["direction"].startswith("奇幻") and "奇幻/系统" in latest_tags:
            score += 2
        ideas.append({**idea, "score": score})
    return sorted(ideas, key=lambda item: item["score"], reverse=True)


def render_content_ideas_html(ideas: list[dict]) -> str:
    cards = []
    for idea in ideas:
        templates = "".join(f"<li>{html.escape(item)}</li>" for item in idea["templates"])
        hooks = "".join(f"<li>{html.escape(item)}</li>" for item in idea["hooks"])
        risks = "".join(f"<li>{html.escape(item)}</li>" for item in idea["risks"])
        signals = "、".join(idea["signals"])
        cards.append(
            f"""
            <div class="idea-card">
              <h3>{html.escape(idea["direction"])} <span class="score">score {idea["score"]:.1f}</span></h3>
              <p class="subtle">信号：{html.escape(signals)}</p>
              <p>{html.escape(idea["why"])}</p>
              <div class="idea-grid">
                <div><strong>标题模板</strong><ul>{templates}</ul></div>
                <div><strong>内容钩子</strong><ul>{hooks}</ul></div>
                <div><strong>风险提醒</strong><ul>{risks}</ul></div>
              </div>
            </div>
            """
        )
    return "".join(cards)


def render_content_ideas_markdown(ideas: list[dict]) -> str:
    sections = []
    for idx, idea in enumerate(ideas, start=1):
        sections.append(
            f"""### {idx}. {idea["direction"]}（score {idea["score"]:.1f}）

**为什么做：** {idea["why"]}

**标题模板：**
{chr(10).join(f"- {item}" for item in idea["templates"])}

**内容钩子：**
{chr(10).join(f"- {item}" for item in idea["hooks"])}

**风险提醒：**
{chr(10).join(f"- {item}" for item in idea["risks"])}
"""
        )
    return "\n".join(sections)


def build_title_element_summary(extended_titles: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for element, patterns in TITLE_ELEMENT_RULES.items():
        matched = []
        score = 0.0
        for row in extended_titles.itertuples(index=False):
            title = str(row.title)
            if any(pattern in title for pattern in patterns):
                matched.append(title)
                score += float(row.rank_score)
        rows.append(
            {
                "element": element,
                "score": score,
                "title_count": len(set(matched)),
                "representative_titles": "、".join(list(dict.fromkeys(matched))[:6]),
            }
        )
    result = pd.DataFrame(rows)
    return result.sort_values(["score", "title_count"], ascending=[False, False]).reset_index(drop=True)


def render_element_bar_svg(element_summary: pd.DataFrame) -> str:
    plot = element_summary[element_summary["score"] > 0].head(12)
    if plot.empty:
        return "<p>暂无可绘制数据。</p>"
    width, height = 860, 420
    left, top = 132, 24
    inner_w = width - left - 60
    bar_h, gap = 24, 10
    max_score = plot["score"].max()
    colors = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6", "#3b82f6", "#6366f1", "#8b5cf6", "#d946ef", "#ec4899"]
    elements = []
    for idx, row in enumerate(plot.itertuples(index=False)):
        y = top + idx * (bar_h + gap)
        w = inner_w * row.score / max_score
        color = colors[idx % len(colors)]
        elements.append(f'<text x="{left-10}" y="{y+17}" text-anchor="end" font-size="12" fill="#334155">{html.escape(row.element)}</text>')
        elements.append(
            f'<rect x="{left}" y="{y}" width="{w:.1f}" height="{bar_h}" rx="5" fill="{color}">'
            f"<title>{html.escape(row.element)} score={row.score:.1f} titles={html.escape(str(row.representative_titles))}</title></rect>"
        )
        elements.append(f'<text x="{left+w+8:.1f}" y="{y+17}" font-size="12" fill="#0f172a">{row.score:.1f}</text>')
    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="标题元素词频">{"".join(elements)}</svg>'


def render_element_table(element_summary: pd.DataFrame) -> str:
    rows = []
    for row in element_summary[element_summary["score"] > 0].head(12).itertuples(index=False):
        rows.append(
            f"<tr><td>{html.escape(row.element)}</td><td>{row.score:.1f}</td><td>{int(row.title_count)}</td>"
            f"<td>{html.escape(str(row.representative_titles))}</td></tr>"
        )
    return "".join(rows)


def build_monthly_change_insights(monthly_summary: pd.DataFrame) -> list[str]:
    if monthly_summary.empty:
        return []
    pivot = (
        monthly_summary.pivot(index="month", columns="primary_tag_l1", values="share")
        .fillna(0.0)
        .sort_index()
    )
    if len(pivot) < 2:
        return []
    first_month = pivot.index[0]
    last_month = pivot.index[-1]
    delta = (pivot.loc[last_month] - pivot.loc[first_month]).sort_values(ascending=False)
    rising = [f"{tag} {value:+.1%}" for tag, value in delta.head(3).items() if tag != "其他"]
    falling = [f"{tag} {value:+.1%}" for tag, value in delta.tail(3).items() if tag != "其他"]

    dominant_rows = []
    for month, row in pivot.iterrows():
        row = row.drop(labels=["其他"], errors="ignore")
        if row.empty:
            continue
        dominant_rows.append(f"{month}：{row.idxmax()} {row.max():.1%}")
    return [
        f"从首月 {first_month} 到末月 {last_month}，扩展样本中升幅靠前的题材是：{'、'.join(rising)}。",
        f"同期回落较明显的题材是：{'、'.join(falling)}。",
        "各月主导题材为：" + "；".join(dominant_rows) + "。",
    ]


def build_markdown_report(
    frame: pd.DataFrame,
    extended_titles: pd.DataFrame,
    monthly_summary: pd.DataFrame,
    element_summary: pd.DataFrame,
    content_ideas: list[dict] | None = None,
) -> str:
    date_min = pd.to_datetime(frame["snapshot_date"]).min().date()
    date_max = pd.to_datetime(frame["snapshot_date"]).max().date()
    top_elements = element_summary[element_summary["score"] > 0].head(8)

    month_lines = []
    for month, group in monthly_summary.groupby("month", sort=True):
        group = group[group["primary_tag_l1"] != "其他"].head(3)
        month_lines.append(
            f"- **{month}**：" + "；".join(
                f"{row.primary_tag_l1} {safe_pct(float(row.share))}（{row.representative_titles}）"
                for row in group.itertuples(index=False)
            )
        )

    element_lines = [
        f"- **{row.element}**：积分 {row.score:.1f}，代表剧：{row.representative_titles}"
        for row in top_elements.itertuples(index=False)
    ]

    change_insights = build_monthly_change_insights(monthly_summary)
    change_section = "\n".join(f"- {line}" for line in change_insights)
    idea_section = render_content_ideas_markdown(content_ideas or [])

    return f"""# DataEye 红果热榜公开样本趋势分析

> 样本区间：{date_min} ~ {date_max}。本报告基于公开网页摘要整理，不是 DataEye 完整 Top100 明细。

## 1. 数据口径

- 样本来源：公开网页中可确认的 DataEye 红果热榜 / 短剧&漫剧日榜摘要。
- 样本规模：{len(frame)} 条日期样本，{extended_titles["title"].nunique()} 个去重剧名。
- 计分方式：Top1=3分，Top2=2分，Top3=1分，备注中补充剧名=0.5分。
- 注意：该口径适合观察公开样本中的题材偏好，不适合替代完整 Top100 榜单。

## 2. 核心判断

{change_section}

## 3. 月度题材变化

{chr(10).join(month_lines)}

## 4. 标题元素信号

{chr(10).join(element_lines)}

## 5. 内容策略启发

- **家庭/亲情 + 强关系爽点** 是红果公开样本里持续有效的方向，尤其是“太奶奶 / 家族 / 全家 / 亲子关系”。
- **现代情感** 仍然是最大基础盘，婚恋、妻子、白月光、上瘾、撒娇等词持续出现在头部样本。
- **古风/权贵 + 穿越/重生** 更适合做阶段性爆点，常和女频爽点、权谋、身份反转绑定。
- **奇幻/系统/AI仿真人漫** 在 2026 年公开摘要中更显性，后续应单独拆分真人短剧与 AI/漫剧口径。

## 6. 选题建议

{idea_section}

## 7. 后续建议

1. 继续扩充公开样本到 50 条以上，提高月度趋势稳定性。
2. 如果拿到 DataEye/剧查查正式 Top100 导出，用同一套标签字典直接替换公开样本口径。
3. 对“太奶奶/家族”“豪门月嫂”“白月光”“穿书炮灰”等标题元素建立专项追踪。
"""


def build_insights(
    frame: pd.DataFrame,
    top_titles: pd.DataFrame,
    tag_summary: pd.DataFrame,
    extended_titles: pd.DataFrame | None = None,
    extended_tag_summary: pd.DataFrame | None = None,
) -> list[str]:
    heat_series = build_heat_series(frame)
    top1_valid = heat_series.dropna(subset=["top1_heat_w"])
    insights = []
    if not top1_valid.empty:
        hottest = top1_valid.sort_values("top1_heat_w", ascending=False).iloc[0]
        insights.append(
            f"公开样本中榜首热度最高的是 {hottest.top1_title}，日期 {format_date(hottest.snapshot_date)}，热度 {heat_label(hottest.top1_heat_w)}。"
        )
        median_heat = top1_valid["top1_heat_w"].median()
        insights.append(f"公开样本榜首热度中位数约 {heat_label(median_heat)}；该数值只能作为摘要样本中枢，不能等同完整日榜均值。")

    if not tag_summary.empty:
        tag_totals = (
            tag_summary.groupby("primary_tag_l1")["rank_score_sum"]
            .sum()
            .sort_values(ascending=False)
        )
        top_tags = [f"{tag}({score:.0f})" for tag, score in tag_totals.head(4).items() if tag != "其他"]
        insights.append(f"按 Top3 排名积分累计，公开样本里最常出现的题材是：{'、'.join(top_tags)}。")

    if extended_titles is not None and not extended_titles.empty and extended_tag_summary is not None and not extended_tag_summary.empty:
        note_count = int((extended_titles["sample_source"] == "notes").sum())
        ext_totals = (
            extended_tag_summary.groupby("primary_tag_l1")["rank_score_sum"]
            .sum()
            .sort_values(ascending=False)
        )
        ext_tags = [f"{tag}({score:.1f})" for tag, score in ext_totals.head(4).items() if tag != "其他"]
        insights.append(f"把备注中出现的补充剧名纳入后，额外增加 {note_count} 条剧名样本；扩展样本主导题材为：{'、'.join(ext_tags)}。")

        monthly_summary = build_monthly_tag_summary(extended_titles)
        insights.extend(build_monthly_change_insights(monthly_summary)[:1])

    new_counts = pd.to_numeric(frame.get("new_title_count"), errors="coerce").dropna()
    if not new_counts.empty:
        insights.append(f"有新剧数披露的样本中，TOP30 新剧数最高为 {int(new_counts.max())} 部，说明部分时期红果榜单换血非常快。")

    rising = pd.to_numeric(frame.get("fastest_rising_delta"), errors="coerce")
    if rising.notna().any():
        idx = rising.idxmax()
        row = frame.loc[idx]
        insights.append(
            f"公开样本中最大单日跃升来自《{row.fastest_rising_title}》，上升 {int(rising.loc[idx])} 名。"
        )

    return insights


def render_report(
    frame: pd.DataFrame,
    top_titles: pd.DataFrame,
    tag_summary: pd.DataFrame,
    output_path: Path,
    extended_titles: pd.DataFrame | None = None,
    extended_tag_summary: pd.DataFrame | None = None,
) -> None:
    heat_series = build_heat_series(frame)
    if extended_titles is None:
        extended_titles = top_titles
    if extended_tag_summary is None:
        extended_tag_summary = tag_summary
    insights = build_insights(frame, top_titles, tag_summary, extended_titles, extended_tag_summary)
    full_count = int((frame["completeness"] == "full_top3").sum())
    partial_count = int((frame["completeness"] != "full_top3").sum())
    date_min = pd.to_datetime(frame["snapshot_date"]).min().date()
    date_max = pd.to_datetime(frame["snapshot_date"]).max().date()

    top_rows = "".join(
        f"<tr><td>{format_date(row.snapshot_date)}</td><td>{html.escape(str(row.top1_title))}</td><td>{heat_label(row.top1_heat_w)}</td>"
        f"<td>{html.escape(str(row.top2_title or ''))}</td><td>{heat_label(row.top2_heat_w)}</td>"
        f"<td>{html.escape(str(row.top3_title or ''))}</td><td>{heat_label(row.top3_heat_w)}</td>"
        f"<td>{html.escape(str(row.notes or ''))}</td></tr>"
        for row in heat_series.itertuples(index=False)
    )
    note_rows = ""
    if extended_titles is not None and not extended_titles.empty and "sample_source" in extended_titles.columns:
        note_samples = extended_titles[extended_titles["sample_source"] == "notes"]
        note_rows = "".join(
            f"<tr><td>{format_date(row.snapshot_date)}</td><td>{html.escape(str(row.title))}</td>"
            f"<td>{html.escape(str(row.primary_tag_l1))}</td><td>{html.escape(str(row.secondary_tags_l2 or ''))}</td></tr>"
            for row in note_samples.itertuples(index=False)
        )
    monthly_summary = build_monthly_tag_summary(extended_titles)
    element_summary = build_title_element_summary(extended_titles)
    content_ideas = build_content_ideas(element_summary, monthly_summary)
    generated_titles = build_generated_titles()

    html_doc = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>DataEye 红果热榜公开样本趋势报告</title>
  <style>
    body {{ margin: 0; background: #f8fafc; color: #0f172a; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    .page {{ max-width: 1220px; margin: 0 auto; padding: 28px 24px 56px; }}
    h1, h2 {{ margin: 0 0 12px; }}
    p, li {{ line-height: 1.65; }}
    .subtle {{ color: #64748b; }}
    .cards {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin: 22px 0; }}
    .card, .panel {{ background: white; border: 1px solid #e2e8f0; border-radius: 16px; box-shadow: 0 10px 30px rgba(15,23,42,.08); }}
    .card {{ padding: 18px 20px; }}
    .label {{ color: #64748b; font-size: 13px; }}
    .value {{ font-size: 28px; font-weight: 700; margin-top: 6px; }}
    .panel {{ padding: 18px 20px; margin-top: 18px; overflow: auto; }}
    .grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }}
    .chart-svg {{ width: 100%; height: auto; display: block; }}
    .idea-card {{ border: 1px solid #e2e8f0; border-radius: 14px; padding: 16px 18px; margin-top: 14px; background: #f8fafc; }}
    .idea-card h3 {{ margin: 0 0 8px; }}
    .idea-grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }}
    .title-block {{ border-top: 1px solid #e2e8f0; padding-top: 12px; margin-top: 12px; }}
    .title-block ol {{ columns: 2; column-gap: 28px; }}
    .score {{ font-size: 12px; color: #64748b; font-weight: 500; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
    th, td {{ padding: 9px 8px; border-bottom: 1px solid #e2e8f0; text-align: left; vertical-align: top; }}
    th {{ color: #64748b; font-weight: 600; }}
    @media (max-width: 980px) {{ .cards, .grid, .idea-grid {{ grid-template-columns: 1fr; }} .title-block ol {{ columns: 1; }} }}
  </style>
</head>
<body>
  <div class="page">
    <h1>DataEye 红果热榜公开样本趋势报告</h1>
    <p class="subtle">样本区间：{date_min} ~ {date_max}。注意：这是公开网页摘要样本，不是完整 Top100；适合看榜首/Top3题材和热度中枢，不适合替代 DataEye 正式榜单。</p>
    <div class="cards">
      <div class="card"><div class="label">样本数</div><div class="value">{len(frame)}</div></div>
      <div class="card"><div class="label">完整 Top3 样本</div><div class="value">{full_count}</div></div>
      <div class="card"><div class="label">部分样本</div><div class="value">{partial_count}</div></div>
      <div class="card"><div class="label">Top3 去重剧名</div><div class="value">{top_titles["title"].nunique() if not top_titles.empty else 0}</div></div>
    </div>
    <div class="panel">
      <h2>结论速览</h2>
      <ul>{''.join(f'<li>{html.escape(line)}</li>' for line in insights)}</ul>
    </div>
    <div class="panel">
      <h2>榜首热度趋势</h2>
      <p class="subtle">单位：万。灰色虚线为公开披露的 Top30 门槛。</p>
      {render_heat_line_svg(heat_series)}
    </div>
    <div class="grid">
      <div class="panel">
        <h2>Top3 题材积分分布</h2>
        <p class="subtle">Top1=3分，Top2=2分，Top3=1分。</p>
        {render_tag_bar_svg(tag_summary)}
      </div>
      <div class="panel">
        <h2>月度主导题材</h2>
        <table><thead><tr><th>月份</th><th>Top 3 题材</th></tr></thead><tbody>{render_month_tag_table(top_titles)}</tbody></table>
      </div>
    </div>
    <div class="panel">
      <h2>Top3 vs Top3+备注剧名</h2>
      <p class="subtle">备注剧名通常来自“空降第4 / 上升最快 / 第10 / 第25”等公开摘要，权重暂按 0.5 分计入，用来辅助观察题材外溢趋势。</p>
      {render_compare_tag_svg(tag_summary, extended_tag_summary)}
    </div>
    <div class="panel">
      <h2>月度题材占比变化</h2>
      <p class="subtle">基于扩展样本计算，Top1=3分、Top2=2分、Top3=1分、备注剧名=0.5分；用于观察公开摘要层面的偏好迁移。</p>
      {render_monthly_stacked_svg(monthly_summary)}
    </div>
    <div class="panel">
      <h2>月度主导题材与代表剧</h2>
      <table>
        <thead><tr><th>月份</th><th>主导题材</th><th>代表剧</th></tr></thead>
        <tbody>{render_monthly_representative_table(monthly_summary)}</tbody>
      </table>
    </div>
    <div class="panel">
      <h2>标题元素信号</h2>
      <p class="subtle">从剧名中抽取高频内容钩子，用来解释题材变化背后的“用户兴趣点”。</p>
      {render_element_bar_svg(element_summary)}
      <table>
        <thead><tr><th>标题元素</th><th>积分</th><th>剧名数</th><th>代表剧</th></tr></thead>
        <tbody>{render_element_table(element_summary)}</tbody>
      </table>
    </div>
    <div class="panel">
      <h2>内容选题建议</h2>
      <p class="subtle">基于公开样本题材趋势和标题元素自动生成，score 越高代表越贴近当前样本信号。</p>
      {render_content_ideas_html(content_ideas)}
    </div>
    <div class="panel">
      <h2>红果标题生成器</h2>
      <p class="subtle">按方向自动生成标题草案，每组 20 个，适合做选题会初筛；上线前仍需人工查重和合规审核。</p>
      {render_generated_titles_html(generated_titles)}
    </div>
    <div class="panel">
      <h2>从备注中抽取的补充剧名</h2>
      <table>
        <thead><tr><th>日期</th><th>剧名</th><th>一级标签</th><th>细标签</th></tr></thead>
        <tbody>{note_rows}</tbody>
      </table>
    </div>
    <div class="panel">
      <h2>公开样本明细</h2>
      <table>
        <thead><tr><th>日期</th><th>Top1</th><th>热度</th><th>Top2</th><th>热度</th><th>Top3</th><th>热度</th><th>备注</th></tr></thead>
        <tbody>{top_rows}</tbody>
      </table>
    </div>
  </div>
</body>
</html>"""
    output_path.write_text(html_doc, encoding="utf-8")


def export_public_sample_report(input_path: Path, output_dir: Path) -> dict[str, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    frame = pd.read_csv(input_path)
    frame["snapshot_date"] = pd.to_datetime(frame["snapshot_date"])
    top_titles = explode_top_titles(frame)
    extended_titles = explode_extended_titles(frame)
    tag_summary = build_daily_tag_summary(top_titles)
    extended_tag_summary = build_daily_tag_summary(extended_titles)
    heat_series = build_heat_series(frame)

    top_titles_path = output_dir / "public_top_titles_tagged.csv"
    extended_titles_path = output_dir / "public_extended_titles_tagged.csv"
    tag_summary_path = output_dir / "public_daily_tag_summary.csv"
    extended_tag_summary_path = output_dir / "public_extended_daily_tag_summary.csv"
    monthly_tag_summary_path = output_dir / "public_monthly_tag_summary.csv"
    element_summary_path = output_dir / "public_title_element_summary.csv"
    content_ideas_path = output_dir / "public_content_ideas.md"
    generated_titles_path = output_dir / "public_generated_titles.csv"
    generated_titles_md_path = output_dir / "public_generated_titles.md"
    markdown_report_path = output_dir / "public_sample_report.md"
    heat_series_path = output_dir / "public_heat_series.csv"
    report_path = output_dir / "public_sample_report.html"

    top_titles.to_csv(top_titles_path, index=False)
    extended_titles.to_csv(extended_titles_path, index=False)
    tag_summary.to_csv(tag_summary_path, index=False)
    extended_tag_summary.to_csv(extended_tag_summary_path, index=False)
    monthly_summary = build_monthly_tag_summary(extended_titles)
    element_summary = build_title_element_summary(extended_titles)
    content_ideas = build_content_ideas(element_summary, monthly_summary)
    generated_titles = build_generated_titles()
    monthly_summary.to_csv(monthly_tag_summary_path, index=False)
    element_summary.to_csv(element_summary_path, index=False)
    generated_titles.to_csv(generated_titles_path, index=False)
    heat_series.to_csv(heat_series_path, index=False)
    render_report(frame, top_titles, tag_summary, report_path, extended_titles, extended_tag_summary)
    content_ideas_path.write_text(render_content_ideas_markdown(content_ideas), encoding="utf-8")
    generated_titles_md_path.write_text(render_generated_titles_markdown(generated_titles), encoding="utf-8")
    markdown_report_path.write_text(
        build_markdown_report(frame, extended_titles, monthly_summary, element_summary, content_ideas),
        encoding="utf-8",
    )
    return {
        "top_titles": top_titles_path,
        "extended_titles": extended_titles_path,
        "tag_summary": tag_summary_path,
        "extended_tag_summary": extended_tag_summary_path,
        "monthly_tag_summary": monthly_tag_summary_path,
        "element_summary": element_summary_path,
        "content_ideas": content_ideas_path,
        "generated_titles": generated_titles_path,
        "generated_titles_md": generated_titles_md_path,
        "heat_series": heat_series_path,
        "report": report_path,
        "markdown_report": markdown_report_path,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="基于 DataEye 红果热榜公开样本 CSV 生成趋势报告。")
    parser.add_argument(
        "--input",
        default="output/hongguo_public_samples/dataeye_hongguo_public_samples.csv",
        help="公开样本 CSV。",
    )
    parser.add_argument(
        "--output-dir",
        default="output/hongguo_public_samples/report",
        help="报告输出目录。",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    outputs = export_public_sample_report(Path(args.input), Path(args.output_dir))
    print("公开样本趋势报告已生成：")
    for name, path in outputs.items():
        print(f"- {name}: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
