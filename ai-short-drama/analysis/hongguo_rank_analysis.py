from __future__ import annotations

import argparse
import html
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import pandas as pd

TOP_N = 100
RANK_SCORE_BASE = TOP_N + 1


@dataclass(frozen=True)
class Level2TagRule:
    tag: str
    parent: str
    patterns: tuple[str, ...]


PRIMARY_TAG_PRIORITY = [
    "奇幻/系统",
    "穿越/重生",
    "古风/古代",
    "豪门/总裁",
    "逆袭/爽文",
    "家庭/亲情",
    "乡村/现实",
    "现代情感",
    "其他",
]

PRIMARY_TAG_COLORS = {
    "现代情感": "#ff7aa2",
    "古风/古代": "#c6925b",
    "逆袭/爽文": "#ffb000",
    "豪门/总裁": "#6f7bf7",
    "穿越/重生": "#00a896",
    "奇幻/系统": "#7b61ff",
    "家庭/亲情": "#16a34a",
    "乡村/现实": "#8b5e3c",
    "其他": "#94a3b8",
}

PRIMARY_TAG_PATTERNS = {
    "现代情感": (
        "爱",
        "妻子",
        "老婆",
        "老公",
        "夫人",
        "婚",
        "结婚",
        "离场",
        "上瘾",
        "娇宠",
        "撒娇",
        "青梅",
        "心尖宠",
        "抵达",
        "念念",
        "月光",
        "盛夏",
        "栀栀",
        "星星耀眼",
        "闪婚",
        "隐婚",
        "离婚",
        "前任",
        "白月光",
        "带球跑",
        "追妻",
        "恋爱",
        "心动",
        "先婚后爱",
        "替身",
        "情人",
        "求婚",
        "相亲",
        "复婚",
        "错爱",
    ),
    "古风/古代": (
        "君",
        "玉郎",
        "布衣",
        "胭脂",
        "少帅",
        "郡主",
        "纨绔",
        "首辅",
        "娘亲",
        "爹爹",
        "王爷",
        "王妃",
        "侯府",
        "侯爷",
        "将军",
        "太子",
        "皇后",
        "宫",
        "嫡女",
        "庶女",
        "郡主",
        "公主",
        "权臣",
        "摄政王",
        "宅斗",
        "宫斗",
        "国公",
    ),
    "逆袭/爽文": (
        "学霸",
        "赢麻",
        "商海",
        "屠龙",
        "荣耀",
        "不灭",
        "神主",
        "傲世",
        "九重天",
        "觉醒",
        "逆天",
        "逆袭",
        "打脸",
        "虐渣",
        "翻身",
        "神豪",
        "首富",
        "无敌",
        "崛起",
        "赘婿",
        "战神",
        "龙王",
        "兵王",
        "觉醒",
        "封神",
    ),
    "豪门/总裁": (
        "傅爷",
        "贺少",
        "顾机长",
        "机长",
        "豪门月嫂",
        "总裁",
        "首富",
        "豪门",
        "千金",
        "京圈",
        "继承人",
        "霸总",
        "财阀",
        "总监",
        "夫人",
    ),
    "穿越/重生": (
        "炮灰",
        "女配",
        "穿成",
        "八零",
        "选择不再原谅",
        "重生",
        "穿越",
        "回到",
        "再活一世",
        "上一世",
        "重回",
        "回档",
        "穿书",
        "重返",
    ),
    "奇幻/系统": (
        "魔尊",
        "菩提",
        "临世",
        "真人AI",
        "妖女",
        "天道",
        "云渺",
        "修仙多年",
        "强亿点",
        "心声",
        "改命",
        "掌生",
        "国师",
        "系统",
        "修仙",
        "仙尊",
        "仙帝",
        "灵气复苏",
        "末世",
        "异能",
        "玄学",
        "天命",
        "神医",
        "读心",
        "预知",
        "超能力",
        "怪谈",
        "妖",
        "魔",
    ),
    "家庭/亲情": (
        "全家",
        "太奶奶",
        "孝子贤孙",
        "公婆",
        "家族",
        "一家三口",
        "儿媳",
        "儿媳妇",
        "儿媳奔小康",
        "外甥女",
        "九个太阳",
        "月嫂",
        "白月光",
        "儿子",
        "不要自责",
        "爹",
        "当爹",
        "妈妈",
        "母亲",
        "父亲",
        "爸爸",
        "奶奶",
        "爷爷",
        "女儿",
        "儿子",
        "外婆",
        "家人",
        "亲情",
        "团宠",
        "回家",
        "养女",
        "养子",
        "寻亲",
    ),
    "乡村/现实": (
        "奔小康",
        "小圣医",
        "乡村",
        "山村",
        "村",
        "种田",
        "农家",
        "下乡",
        "创业",
        "厂妹",
        "打工",
        "返乡",
        "现实",
        "烟火",
        "乡镇",
    ),
}

LEVEL2_TAG_RULES = [
    Level2TagRule("打脸虐渣", "逆袭/爽文", ("打脸", "虐渣", "复仇", "反击", "手撕")),
    Level2TagRule("女强", "逆袭/爽文", ("女强", "大女主", "独美", "女王", "女帝")),
    Level2TagRule("神豪", "逆袭/爽文", ("神豪", "首富", "暴富", "百亿", "千亿")),
    Level2TagRule("赘婿", "逆袭/爽文", ("赘婿", "上门女婿")),
    Level2TagRule("战神", "逆袭/爽文", ("战神", "兵王", "龙王")),
    Level2TagRule("萌宝", "家庭/亲情", ("萌宝", "天才宝宝", "崽", "奶团子", "团宠")),
    Level2TagRule("追妻火葬场", "现代情感", ("追妻", "火葬场", "追妻火葬场")),
    Level2TagRule("先婚后爱", "现代情感", ("先婚后爱", "闪婚", "隐婚")),
    Level2TagRule("带球跑", "现代情感", ("带球跑", "孕", "怀孕", "亲子鉴定")),
    Level2TagRule("白月光/替身", "现代情感", ("白月光", "替身", "替嫁")),
    Level2TagRule("豪门恩怨", "豪门/总裁", ("豪门", "财阀", "千金", "继承人")),
    Level2TagRule("霸总甜虐", "豪门/总裁", ("总裁", "霸总", "夫人", "京圈")),
    Level2TagRule("穿书", "穿越/重生", ("穿书",)),
    Level2TagRule("重生复仇", "穿越/重生", ("重生", "再活一世", "上一世")),
    Level2TagRule("穿越古代", "穿越/重生", ("穿越", "回到古代", "古穿今", "今穿古")),
    Level2TagRule("宫斗宅斗", "古风/古代", ("宫斗", "宅斗", "后宫", "嫡女", "庶女")),
    Level2TagRule("权谋", "古风/古代", ("权谋", "摄政王", "权臣", "夺嫡", "朝堂")),
    Level2TagRule("神医/玄学", "奇幻/系统", ("神医", "玄学", "算命", "风水", "通灵")),
    Level2TagRule("修仙升级", "奇幻/系统", ("修仙", "仙尊", "仙帝", "飞升")),
    Level2TagRule("系统任务", "奇幻/系统", ("系统", "任务", "签到", "金手指")),
    Level2TagRule("末世异能", "奇幻/系统", ("末世", "异能", "灵气复苏")),
    Level2TagRule("亲情救赎", "家庭/亲情", ("寻亲", "团圆", "回家", "养女", "养子")),
    Level2TagRule("乡村逆袭", "乡村/现实", ("乡村", "山村", "返乡", "种田", "农家")),
    Level2TagRule("现实成长", "乡村/现实", ("打工", "创业", "职场", "烟火", "现实")),
]

CANONICAL_COLUMNS = {
    "snapshot_date": ("snapshot_date", "date", "日期", "榜单日期", "day"),
    "rank": ("rank", "排名", "名次"),
    "title": ("title", "剧名", "短剧", "name", "drama_title", "drama_title_raw"),
    "heat_value": ("heat_value", "热度", "热力值", "播放热度", "heat", "value"),
    "source_tags": ("source_tags", "标签", "题材", "分类", "tag_text", "theme"),
    "synopsis": ("synopsis", "简介", "剧情简介", "description", "summary"),
    "content_type": ("content_type", "内容类型", "真人_ai", "类型"),
}


def slugify(text: str) -> str:
    value = re.sub(r"[^0-9a-zA-Z\u4e00-\u9fff]+", "_", text.strip().lower())
    return value.strip("_") or "tag"


def normalize_title(title: str) -> str:
    text = str(title or "").strip()
    text = text.replace("\u3000", " ")
    text = re.sub(r"\s+", "", text)
    text = re.sub(r"[【\[][^】\]]*[】\]]$", "", text)
    text = re.sub(r"[（(][^）)]*(红果|DataEye|热榜|榜单|短剧)[^）)]*[）)]$", "", text, flags=re.IGNORECASE)
    text = re.sub(r"[·•—\-_:：]+$", "", text)
    return text


def normalize_tag_tokens(raw_value: str) -> list[str]:
    if not raw_value:
        return []
    parts = re.split(r"[、,，/|；;]+", raw_value)
    return [part.strip() for part in parts if part.strip()]


def resolve_primary_tag(text: str, source_tags: list[str]) -> str:
    score_map: dict[str, int] = {}
    for token in source_tags:
        token_lower = token.lower()
        for tag, patterns in PRIMARY_TAG_PATTERNS.items():
            if token == tag:
                score_map[tag] = score_map.get(tag, 0) + 6
            for pattern in patterns:
                if pattern.lower() == token_lower:
                    score_map[tag] = score_map.get(tag, 0) + 6
                elif pattern.lower() in token_lower:
                    score_map[tag] = score_map.get(tag, 0) + 4
    for tag, patterns in PRIMARY_TAG_PATTERNS.items():
        for pattern in patterns:
            if pattern in text:
                score_map[tag] = score_map.get(tag, 0) + 1
    if not score_map:
        return "其他"

    has_boss_token = any(
        pattern.lower() in token.lower()
        for token in source_tags
        for pattern in PRIMARY_TAG_PATTERNS["豪门/总裁"]
    )
    if has_boss_token:
        boss_score = score_map.get("豪门/总裁", 0)
        max_score = max(score_map.values())
        if boss_score >= max_score - 1:
            return "豪门/总裁"

    ordered = sorted(
        score_map.items(),
        key=lambda item: (-item[1], PRIMARY_TAG_PRIORITY.index(item[0])),
    )
    return ordered[0][0]


def resolve_level2_tags(text: str, source_tags: list[str]) -> list[str]:
    matches: list[str] = []
    joined_source = " ".join(source_tags)
    for rule in LEVEL2_TAG_RULES:
        if any(pattern in text or pattern in joined_source for pattern in rule.patterns):
            matches.append(rule.tag)
    return matches


def read_input_frame(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix == ".csv":
        return pd.read_csv(path)
    if suffix in {".jsonl", ".ndjson"}:
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        return pd.DataFrame(rows)
    if suffix == ".json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, list):
            return pd.DataFrame(payload)
        if isinstance(payload, dict):
            for key in ("rows", "data", "items", "records"):
                if isinstance(payload.get(key), list):
                    return pd.DataFrame(payload[key])
        raise ValueError(f"无法识别 JSON 结构: {path}")
    if suffix in {".xlsx", ".xls"}:
        return pd.read_excel(path)
    raise ValueError(f"不支持的输入格式: {path.suffix}")


def collect_input_frames(input_path: Path) -> pd.DataFrame:
    if input_path.is_file():
        return read_input_frame(input_path)

    frames: list[pd.DataFrame] = []
    for pattern in ("*.csv", "*.json", "*.jsonl", "*.ndjson", "*.xlsx", "*.xls"):
        for file_path in sorted(input_path.glob(pattern)):
            frame = read_input_frame(file_path)
            frame["__source_file"] = file_path.name
            frames.append(frame)
    if not frames:
        raise FileNotFoundError(f"在 {input_path} 下没有找到可读取的数据文件。")
    return pd.concat(frames, ignore_index=True)


def canonicalize_columns(frame: pd.DataFrame) -> pd.DataFrame:
    rename_map: dict[str, str] = {}
    for canonical_name, aliases in CANONICAL_COLUMNS.items():
        for alias in aliases:
            if alias in frame.columns:
                rename_map[alias] = canonical_name
                break
    result = frame.rename(columns=rename_map).copy()
    missing = [col for col in ("snapshot_date", "rank", "title") if col not in result.columns]
    if missing:
        raise ValueError(f"缺少必要列: {', '.join(missing)}")

    for optional in ("heat_value", "source_tags", "synopsis", "content_type"):
        if optional not in result.columns:
            result[optional] = None
    return result


def prepare_snapshot_data(raw_frame: pd.DataFrame) -> pd.DataFrame:
    frame = canonicalize_columns(raw_frame)
    frame["snapshot_date"] = pd.to_datetime(frame["snapshot_date"], errors="coerce").dt.date
    frame["rank"] = pd.to_numeric(frame["rank"], errors="coerce")
    frame["heat_value"] = pd.to_numeric(frame["heat_value"], errors="coerce")
    frame = frame.dropna(subset=["snapshot_date", "rank", "title"]).copy()
    frame["rank"] = frame["rank"].astype(int)
    frame = frame[(frame["rank"] >= 1) & (frame["rank"] <= TOP_N)].copy()
    frame["canonical_title"] = frame["title"].map(normalize_title)
    frame["source_tags"] = frame["source_tags"].fillna("").astype(str)
    frame["synopsis"] = frame["synopsis"].fillna("").astype(str)
    frame["content_type"] = frame["content_type"].fillna("").astype(str)
    frame["tag_tokens"] = frame["source_tags"].map(normalize_tag_tokens)
    frame["rank_score"] = RANK_SCORE_BASE - frame["rank"]
    frame = (
        frame.sort_values(["snapshot_date", "canonical_title", "rank"])
        .drop_duplicates(subset=["snapshot_date", "canonical_title"], keep="first")
        .reset_index(drop=True)
    )

    primary_tags: list[str] = []
    secondary_tags: list[str] = []
    for row in frame.itertuples(index=False):
        search_text = " ".join(
            part for part in [str(row.canonical_title), str(row.source_tags), str(row.synopsis)] if part
        )
        primary = resolve_primary_tag(search_text, list(row.tag_tokens))
        level2_tags = resolve_level2_tags(search_text, list(row.tag_tokens))
        if primary != "其他" and primary not in [rule.parent for rule in LEVEL2_TAG_RULES if rule.tag in level2_tags]:
            extra = [primary]
        else:
            extra = []
        primary_tags.append(primary)
        secondary_tags.append("、".join(dict.fromkeys(level2_tags + extra)))
    frame["primary_tag_l1"] = primary_tags
    frame["secondary_tags_l2"] = secondary_tags
    return frame


def build_title_summary(frame: pd.DataFrame) -> pd.DataFrame:
    first_seen = frame.groupby("canonical_title")["snapshot_date"].min().rename("first_seen_date")
    last_seen = frame.groupby("canonical_title")["snapshot_date"].max().rename("last_seen_date")
    summary = (
        frame.groupby("canonical_title")
        .agg(
            days_on_chart=("snapshot_date", "nunique"),
            best_rank=("rank", "min"),
            avg_rank=("rank", "mean"),
            avg_rank_score=("rank_score", "mean"),
            latest_title=("title", "last"),
            primary_tag_l1=("primary_tag_l1", lambda s: s.mode().iat[0] if not s.mode().empty else s.iloc[-1]),
            secondary_tags_l2=("secondary_tags_l2", lambda s: "、".join(sorted(set(filter(None, s))))),
            content_type=("content_type", lambda s: "、".join(sorted(set(filter(None, s))))),
        )
        .reset_index()
        .merge(first_seen.reset_index(), on="canonical_title", how="left")
        .merge(last_seen.reset_index(), on="canonical_title", how="left")
    )
    summary["avg_rank"] = summary["avg_rank"].round(2)
    summary["avg_rank_score"] = summary["avg_rank_score"].round(2)
    return summary.sort_values(["days_on_chart", "best_rank"], ascending=[False, True]).reset_index(drop=True)


def build_daily_tag_summary(frame: pd.DataFrame) -> pd.DataFrame:
    base = (
        frame.groupby(["snapshot_date", "primary_tag_l1"])
        .agg(
            title_count=("canonical_title", "nunique"),
            rank_score_sum=("rank_score", "sum"),
            heat_value_sum=("heat_value", "sum"),
        )
        .reset_index()
    )
    base["total_rank_score"] = base.groupby("snapshot_date")["rank_score_sum"].transform("sum")
    base["rank_share"] = base["rank_score_sum"] / base["total_rank_score"]

    heat_total = base.groupby("snapshot_date")["heat_value_sum"].transform("sum")
    base["heat_share"] = base["heat_value_sum"] / heat_total.where(heat_total > 0, pd.NA)
    base["heat_share"] = base["heat_share"].fillna(0.0)

    all_dates = sorted(frame["snapshot_date"].unique())
    dense_index = pd.MultiIndex.from_product(
        [all_dates, PRIMARY_TAG_PRIORITY], names=["snapshot_date", "primary_tag_l1"]
    )
    dense = base.set_index(["snapshot_date", "primary_tag_l1"]).reindex(dense_index, fill_value=0).reset_index()
    dense["rank_share"] = dense.groupby("snapshot_date")["rank_score_sum"].transform(
        lambda s: s / s.sum() if s.sum() else 0
    )
    dense["heat_share"] = dense.groupby("snapshot_date")["heat_value_sum"].transform(
        lambda s: s / s.sum() if s.sum() else 0
    )
    dense["title_count_share"] = dense.groupby("snapshot_date")["title_count"].transform(
        lambda s: s / s.sum() if s.sum() else 0
    )
    dense = dense.sort_values(["primary_tag_l1", "snapshot_date"]).reset_index(drop=True)
    dense["rank_share_7d"] = (
        dense.groupby("primary_tag_l1")["rank_share"].transform(lambda s: s.rolling(7, min_periods=1).mean())
    )
    dense["heat_share_7d"] = (
        dense.groupby("primary_tag_l1")["heat_share"].transform(lambda s: s.rolling(7, min_periods=1).mean())
    )
    return dense


def build_new_title_summary(frame: pd.DataFrame) -> pd.DataFrame:
    first_seen_map = frame.groupby("canonical_title")["snapshot_date"].min().to_dict()
    flagged = frame.copy()
    flagged["days_since_first_seen"] = flagged.apply(
        lambda row: (row["snapshot_date"] - first_seen_map[row["canonical_title"]]).days, axis=1
    )
    flagged["is_new_title"] = flagged["days_since_first_seen"] <= 6

    daily = (
        flagged.groupby("snapshot_date")
        .agg(
            total_rank_score=("rank_score", "sum"),
            new_title_rank_score=("rank_score", lambda s: flagged.loc[s.index, "rank_score"][flagged.loc[s.index, "is_new_title"]].sum()),
            total_title_count=("canonical_title", "nunique"),
            new_title_count=("canonical_title", lambda s: flagged.loc[s.index].query("is_new_title")["canonical_title"].nunique()),
        )
        .reset_index()
    )
    daily["new_title_rank_share"] = daily["new_title_rank_score"] / daily["total_rank_score"]
    daily["new_title_count_share"] = daily["new_title_count"] / daily["total_title_count"]
    daily["new_title_rank_share_7d"] = daily["new_title_rank_share"].rolling(7, min_periods=1).mean()
    return daily


def build_weekly_tag_summary(daily_summary: pd.DataFrame) -> pd.DataFrame:
    weekly = daily_summary.copy()
    weekly["snapshot_date"] = pd.to_datetime(weekly["snapshot_date"])
    weekly["week_start"] = weekly["snapshot_date"].dt.to_period("W-MON").apply(lambda period: period.start_time.date())
    result = (
        weekly.groupby(["week_start", "primary_tag_l1"])
        .agg(
            rank_share=("rank_share", "mean"),
            rank_share_7d=("rank_share_7d", "mean"),
            heat_share=("heat_share", "mean"),
            title_count=("title_count", "mean"),
        )
        .reset_index()
        .sort_values(["week_start", "primary_tag_l1"])
    )
    return result


def build_trend_insights(daily_summary: pd.DataFrame, title_summary: pd.DataFrame, new_title_summary: pd.DataFrame) -> list[str]:
    latest_date = pd.to_datetime(daily_summary["snapshot_date"]).max().date()
    daily_summary = daily_summary.copy()
    daily_summary["snapshot_date"] = pd.to_datetime(daily_summary["snapshot_date"]).dt.date

    recent_cutoff = latest_date - pd.Timedelta(days=13)
    previous_cutoff = latest_date - pd.Timedelta(days=27)
    recent = daily_summary[daily_summary["snapshot_date"] >= recent_cutoff]
    previous = daily_summary[
        (daily_summary["snapshot_date"] >= previous_cutoff) & (daily_summary["snapshot_date"] < recent_cutoff)
    ]

    recent_mean = recent.groupby("primary_tag_l1")["rank_share"].mean()
    previous_mean = previous.groupby("primary_tag_l1")["rank_share"].mean()
    delta = (recent_mean - previous_mean).fillna(0).sort_values(ascending=False)

    latest_daily = daily_summary[daily_summary["snapshot_date"] == latest_date].sort_values("rank_share", ascending=False)
    rising = [f"{tag} {value:+.1%}" for tag, value in delta.head(3).items() if tag != "其他"]
    falling = [f"{tag} {value:+.1%}" for tag, value in delta.tail(3).items() if tag != "其他"]

    top_titles = title_summary.sort_values(["days_on_chart", "best_rank"], ascending=[False, True]).head(5)
    top_titles_text = "；".join(
        f"{row.latest_title}(在榜{int(row.days_on_chart)}天, 最好名次#{int(row.best_rank)})"
        for row in top_titles.itertuples(index=False)
    )

    latest_new_title = new_title_summary.sort_values("snapshot_date").iloc[-1]
    insight_lines = [
        f"最近 14 天升温最快的一级标签：{'、'.join(rising) if rising else '暂无明显上升标签'}。",
        f"最近 14 天走弱最快的一级标签：{'、'.join(falling) if falling else '暂无明显下降标签'}。",
        f"{latest_date} 的榜单结构中，占比最高的标签依次为："
        + "、".join(
            f"{row.primary_tag_l1} {row.rank_share:.1%}"
            for row in latest_daily.head(4).itertuples(index=False)
            if row.primary_tag_l1 != "其他"
        )
        + "。",
        f"当前新上榜 7 日内剧集贡献了 {latest_new_title.new_title_rank_share:.1%} 的榜单积分，"
        f"说明{'用户明显在追新' if latest_new_title.new_title_rank_share >= 0.35 else '头部偏好仍由老剧稳定贡献'}。",
        f"当前在榜粘性最强的剧包括：{top_titles_text}。",
    ]
    return insight_lines


def safe_pct(value: float) -> str:
    return f"{value * 100:.1f}%"


def format_date_label(value) -> str:
    return pd.to_datetime(value).strftime("%m-%d")


def render_stacked_area_svg(daily_summary: pd.DataFrame, value_col: str = "rank_share_7d") -> str:
    plot = daily_summary[daily_summary["primary_tag_l1"] != "其他"].copy()
    plot["snapshot_date"] = pd.to_datetime(plot["snapshot_date"])
    pivot = (
        plot.pivot(index="snapshot_date", columns="primary_tag_l1", values=value_col)
        .fillna(0.0)
        .reindex(columns=[tag for tag in PRIMARY_TAG_PRIORITY if tag != "其他"])
    )
    dates = list(pivot.index)
    if not dates:
        return "<p>暂无可绘制数据。</p>"

    width = 1040
    height = 420
    margin = {"top": 24, "right": 24, "bottom": 44, "left": 52}
    inner_w = width - margin["left"] - margin["right"]
    inner_h = height - margin["top"] - margin["bottom"]

    x_positions = {
        date: margin["left"] + (index / max(len(dates) - 1, 1)) * inner_w
        for index, date in enumerate(dates)
    }
    paths: list[str] = []
    cumulative = [0.0] * len(dates)
    tick_labels = [dates[index] for index in sorted(set([0, len(dates) // 4, len(dates) // 2, (len(dates) * 3) // 4, len(dates) - 1]))]

    for tag in pivot.columns:
        values = pivot[tag].tolist()
        upper = [cumulative[index] + values[index] for index in range(len(values))]
        top_points = [
            (x_positions[date], margin["top"] + inner_h * (1 - upper[index]))
            for index, date in enumerate(dates)
        ]
        bottom_points = [
            (x_positions[date], margin["top"] + inner_h * (1 - cumulative[index]))
            for index, date in reversed(list(enumerate(dates)))
        ]
        point_string = " ".join(f"{x:.2f},{y:.2f}" for x, y in top_points + bottom_points)
        color = PRIMARY_TAG_COLORS.get(tag, "#94a3b8")
        latest_share = values[-1]
        paths.append(
            f'<polygon points="{point_string}" fill="{color}" fill-opacity="0.82" stroke="{color}" '
            f'stroke-width="1"><title>{html.escape(tag)} {safe_pct(latest_share)}</title></polygon>'
        )
        cumulative = upper

    y_grid = []
    for index in range(6):
        value = index / 5
        y = margin["top"] + inner_h * (1 - value)
        y_grid.append(
            f'<line x1="{margin["left"]}" y1="{y:.2f}" x2="{width - margin["right"]}" y2="{y:.2f}" '
            f'stroke="#e5e7eb" stroke-width="1" />'
        )
        y_grid.append(
            f'<text x="{margin["left"] - 10}" y="{y + 4:.2f}" text-anchor="end" '
            f'font-size="12" fill="#64748b">{int(value * 100)}%</text>'
        )

    x_axis = []
    for tick in tick_labels:
        x = x_positions[tick]
        x_axis.append(
            f'<line x1="{x:.2f}" y1="{height - margin["bottom"]}" x2="{x:.2f}" y2="{margin["top"]}" '
            f'stroke="#f1f5f9" stroke-width="1" />'
        )
        x_axis.append(
            f'<text x="{x:.2f}" y="{height - margin["bottom"] + 20}" text-anchor="middle" '
            f'font-size="12" fill="#64748b">{format_date_label(tick)}</text>'
        )

    legend = []
    legend_x = margin["left"]
    legend_y = 8
    for index, tag in enumerate(pivot.columns):
        x = legend_x + index * 120
        color = PRIMARY_TAG_COLORS.get(tag, "#94a3b8")
        legend.append(f'<rect x="{x}" y="{legend_y}" width="12" height="12" fill="{color}" rx="2" />')
        legend.append(
            f'<text x="{x + 18}" y="{legend_y + 10}" font-size="12" fill="#1f2937">{html.escape(tag)}</text>'
        )

    return (
        f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="标签份额堆叠面积图">'
        + "".join(y_grid)
        + "".join(x_axis)
        + "".join(paths)
        + "".join(legend)
        + "</svg>"
    )


def render_heatmap_svg(weekly_summary: pd.DataFrame) -> str:
    plot = weekly_summary[weekly_summary["primary_tag_l1"] != "其他"].copy()
    plot["week_start"] = pd.to_datetime(plot["week_start"])
    tags = [tag for tag in PRIMARY_TAG_PRIORITY if tag != "其他"]
    weeks = sorted(plot["week_start"].unique())
    if not weeks:
        return "<p>暂无可绘制数据。</p>"

    width = max(780, 100 + len(weeks) * 44)
    height = 70 + len(tags) * 38
    left = 110
    top = 24
    cell_w = 36
    cell_h = 28

    pivot = (
        plot.pivot(index="primary_tag_l1", columns="week_start", values="rank_share")
        .fillna(0.0)
        .reindex(index=tags, columns=weeks)
    )
    max_value = float(pivot.to_numpy().max()) if not pivot.empty else 0.0

    def color_for(value: float) -> str:
        if max_value <= 0:
            return "#f8fafc"
        ratio = value / max_value
        alpha = 0.16 + ratio * 0.84
        return f"rgba(79, 70, 229, {alpha:.3f})"

    cells = []
    for row_index, tag in enumerate(tags):
        y = top + row_index * cell_h
        cells.append(
            f'<text x="{left - 10}" y="{y + 19}" text-anchor="end" font-size="12" fill="#334155">{html.escape(tag)}</text>'
        )
        for col_index, week in enumerate(weeks):
            value = float(pivot.loc[tag, week])
            x = left + col_index * cell_w
            cells.append(
                f'<rect x="{x}" y="{y}" width="{cell_w - 3}" height="{cell_h - 3}" rx="4" fill="{color_for(value)}">'
                f"<title>{html.escape(tag)} {pd.to_datetime(week).strftime('%Y-%m-%d')} {safe_pct(value)}</title></rect>"
            )
            cells.append(
                f'<text x="{x + (cell_w - 3) / 2:.1f}" y="{y + 17}" text-anchor="middle" font-size="10" fill="#ffffff">{int(value * 100)}</text>'
            )

    headers = []
    for col_index, week in enumerate(weeks):
        x = left + col_index * cell_w + (cell_w - 3) / 2
        headers.append(
            f'<text x="{x:.1f}" y="16" text-anchor="middle" font-size="11" fill="#64748b">{pd.to_datetime(week).strftime("%m-%d")}</text>'
        )

    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="标签周热力矩阵">{"".join(headers)}{"".join(cells)}</svg>'


def render_delta_bar_svg(delta_frame: pd.DataFrame) -> str:
    plot = delta_frame[delta_frame["primary_tag_l1"] != "其他"].copy()
    plot = plot.sort_values("delta", ascending=False)
    if plot.empty:
        return "<p>暂无可绘制数据。</p>"

    width = 920
    height = 340
    margin = {"top": 24, "right": 24, "bottom": 36, "left": 160}
    inner_w = width - margin["left"] - margin["right"]
    bar_h = 28
    max_abs = max(abs(plot["delta"]).max(), 0.01)
    zero_x = margin["left"] + inner_w / 2

    elements = [
        f'<line x1="{zero_x}" y1="{margin["top"] - 8}" x2="{zero_x}" y2="{height - margin["bottom"]}" stroke="#94a3b8" stroke-width="1.5" />'
    ]
    for index, row in enumerate(plot.itertuples(index=False)):
        y = margin["top"] + index * (bar_h + 8)
        bar_w = inner_w * (abs(row.delta) / (max_abs * 2))
        if row.delta >= 0:
            x = zero_x
            color = "#16a34a"
        else:
            x = zero_x - bar_w
            color = "#dc2626"
        elements.append(
            f'<text x="{margin["left"] - 10}" y="{y + 18}" text-anchor="end" font-size="12" fill="#334155">{html.escape(row.primary_tag_l1)}</text>'
        )
        elements.append(f'<rect x="{x:.2f}" y="{y}" width="{bar_w:.2f}" height="{bar_h}" rx="4" fill="{color}" />')
        label_x = x + bar_w + 8 if row.delta >= 0 else x - 8
        anchor = "start" if row.delta >= 0 else "end"
        elements.append(
            f'<text x="{label_x:.2f}" y="{y + 18}" text-anchor="{anchor}" font-size="12" fill="#0f172a">{row.delta:+.1%}</text>'
        )

    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="标签涨跌对比图">{"".join(elements)}</svg>'


def build_delta_frame(daily_summary: pd.DataFrame) -> pd.DataFrame:
    daily_summary = daily_summary.copy()
    daily_summary["snapshot_date"] = pd.to_datetime(daily_summary["snapshot_date"]).dt.date
    latest_date = daily_summary["snapshot_date"].max()
    recent_cutoff = latest_date - pd.Timedelta(days=13)
    previous_cutoff = latest_date - pd.Timedelta(days=27)
    recent = daily_summary[daily_summary["snapshot_date"] >= recent_cutoff].groupby("primary_tag_l1")["rank_share"].mean()
    previous = daily_summary[
        (daily_summary["snapshot_date"] >= previous_cutoff) & (daily_summary["snapshot_date"] < recent_cutoff)
    ].groupby("primary_tag_l1")["rank_share"].mean()
    delta = (recent - previous).fillna(0.0).reset_index(name="delta")
    return delta


def render_html_report(
    *,
    output_path: Path,
    daily_summary: pd.DataFrame,
    weekly_summary: pd.DataFrame,
    title_summary: pd.DataFrame,
    new_title_summary: pd.DataFrame,
    insights: list[str],
) -> None:
    latest_date = pd.to_datetime(daily_summary["snapshot_date"]).max().date()
    tracked_days = pd.to_datetime(daily_summary["snapshot_date"]).dt.date.nunique()
    unique_titles = int(title_summary["canonical_title"].nunique())
    latest_new = new_title_summary.sort_values("snapshot_date").iloc[-1]
    delta_frame = build_delta_frame(daily_summary)

    latest_distribution = (
        daily_summary[pd.to_datetime(daily_summary["snapshot_date"]).dt.date == latest_date]
        .sort_values("rank_share", ascending=False)
        .head(8)
    )
    top_title_rows = title_summary.head(12)
    insights_html = "".join(f"<li>{html.escape(line)}</li>" for line in insights)
    latest_distribution_rows = "".join(
        f"<tr><td>{html.escape(str(row.primary_tag_l1))}</td>"
        f"<td>{safe_pct(float(row.rank_share))}</td>"
        f"<td>{int(row.title_count)}</td>"
        f"<td>{safe_pct(float(row.heat_share))}</td></tr>"
        for row in latest_distribution.itertuples(index=False)
    )

    sticky_title_rows: list[str] = []
    for row in top_title_rows.itertuples(index=False):
        pills = "".join(
            f'<span class="pill">{html.escape(tag)}</span>'
            for tag in str(row.secondary_tags_l2).split("、")
            if tag
        )
        sticky_title_rows.append(
            f"<tr><td>{html.escape(str(row.latest_title))}</td>"
            f"<td>{html.escape(str(row.primary_tag_l1))}</td>"
            f"<td>{int(row.days_on_chart)}</td>"
            f"<td>#{int(row.best_rank)}</td>"
            f"<td>{pills}</td></tr>"
        )
    sticky_titles_html = "".join(sticky_title_rows)

    html_content = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>DataEye 红果热榜 Top100 标签趋势报告</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f8fafc;
      --card: #ffffff;
      --text: #0f172a;
      --muted: #64748b;
      --line: #e2e8f0;
      --shadow: 0 10px 30px rgba(15, 23, 42, 0.08);
    }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    .page {{
      max-width: 1240px;
      margin: 0 auto;
      padding: 28px 24px 56px;
    }}
    h1, h2, h3 {{
      margin: 0 0 12px;
    }}
    p, li {{
      line-height: 1.65;
    }}
    .subtle {{
      color: var(--muted);
    }}
    .cards {{
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 16px;
      margin: 22px 0 26px;
    }}
    .card, .panel {{
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 16px;
      box-shadow: var(--shadow);
    }}
    .card {{
      padding: 18px 20px;
    }}
    .card .label {{
      color: var(--muted);
      font-size: 13px;
      margin-bottom: 6px;
    }}
    .card .value {{
      font-size: 28px;
      font-weight: 700;
    }}
    .grid {{
      display: grid;
      grid-template-columns: 1.4fr 1fr;
      gap: 18px;
      margin-top: 18px;
    }}
    .panel {{
      padding: 18px 20px 20px;
      overflow: auto;
    }}
    .panel + .panel {{
      margin-top: 0;
    }}
    .chart-svg {{
      width: 100%;
      height: auto;
      display: block;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }}
    th, td {{
      padding: 10px 8px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
    }}
    th {{
      color: var(--muted);
      font-weight: 600;
      font-size: 12px;
      letter-spacing: 0.02em;
      text-transform: uppercase;
    }}
    .pill {{
      display: inline-block;
      padding: 3px 8px;
      border-radius: 999px;
      font-size: 12px;
      background: #eef2ff;
      color: #4338ca;
      margin-right: 6px;
      margin-bottom: 6px;
    }}
    ul.insights {{
      margin: 0;
      padding-left: 20px;
    }}
    @media (max-width: 960px) {{
      .cards, .grid {{
        grid-template-columns: 1fr;
      }}
    }}
  </style>
</head>
<body>
  <div class="page">
    <h1>DataEye 红果热榜 Top100 标签趋势报告</h1>
    <p class="subtle">最近快照日期：{latest_date}。主指标使用 <strong>Top100 排名积分份额</strong>（rank_score = 101 - rank），避免热度口径变化直接影响趋势判断。</p>

    <div class="cards">
      <div class="card">
        <div class="label">覆盖天数</div>
        <div class="value">{tracked_days}</div>
      </div>
      <div class="card">
        <div class="label">去重后剧集数</div>
        <div class="value">{unique_titles}</div>
      </div>
      <div class="card">
        <div class="label">最新日新剧贡献</div>
        <div class="value">{safe_pct(float(latest_new.new_title_rank_share))}</div>
      </div>
      <div class="card">
        <div class="label">最新日新剧占比</div>
        <div class="value">{safe_pct(float(latest_new.new_title_count_share))}</div>
      </div>
    </div>

    <div class="panel">
      <h2>结论速览</h2>
      <ul class="insights">
        {insights_html}
      </ul>
    </div>

    <div class="panel" style="margin-top: 18px;">
      <h2>一级标签份额变化（7 日均线）</h2>
      <p class="subtle">用一级标签观察用户偏好迁移，更适合回答“红果用户最近更爱看哪类剧”。</p>
      {render_stacked_area_svg(daily_summary)}
    </div>

    <div class="grid">
      <div class="panel">
        <h2>周度标签热力矩阵</h2>
        <p class="subtle">颜色越深，代表该周该标签在 Top100 中占据更高积分份额。</p>
        {render_heatmap_svg(weekly_summary)}
      </div>
      <div class="panel">
        <h2>最近 14 天 vs 前 14 天</h2>
        <p class="subtle">正值说明近期升温，负值说明近期走弱。</p>
        {render_delta_bar_svg(delta_frame)}
      </div>
    </div>

    <div class="grid">
      <div class="panel">
        <h2>最新日标签结构</h2>
        <table>
          <thead>
            <tr>
              <th>标签</th>
              <th>积分份额</th>
              <th>上榜剧数</th>
              <th>热度份额</th>
            </tr>
          </thead>
          <tbody>
            {latest_distribution_rows}
          </tbody>
        </table>
      </div>
      <div class="panel">
        <h2>榜单粘性最强的剧</h2>
        <table>
          <thead>
            <tr>
              <th>剧名</th>
              <th>一级标签</th>
              <th>在榜天数</th>
              <th>最好名次</th>
              <th>细标签</th>
            </tr>
          </thead>
          <tbody>
            {sticky_titles_html}
          </tbody>
        </table>
      </div>
    </div>
  </div>
</body>
</html>
"""
    output_path.write_text(html_content, encoding="utf-8")


def export_analysis(frame: pd.DataFrame, output_dir: Path) -> dict[str, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    cleaned = prepare_snapshot_data(frame)
    title_summary = build_title_summary(cleaned)
    daily_summary = build_daily_tag_summary(cleaned)
    weekly_summary = build_weekly_tag_summary(daily_summary)
    new_title_summary = build_new_title_summary(cleaned)
    insights = build_trend_insights(daily_summary, title_summary, new_title_summary)

    cleaned_path = output_dir / "hongguo_top100_cleaned.csv"
    title_summary_path = output_dir / "hongguo_title_summary.csv"
    daily_summary_path = output_dir / "hongguo_daily_tag_summary.csv"
    weekly_summary_path = output_dir / "hongguo_weekly_tag_summary.csv"
    new_title_path = output_dir / "hongguo_new_title_summary.csv"
    insights_path = output_dir / "hongguo_trend_insights.md"
    report_path = output_dir / "hongguo_report.html"

    cleaned.to_csv(cleaned_path, index=False)
    title_summary.to_csv(title_summary_path, index=False)
    daily_summary.to_csv(daily_summary_path, index=False)
    weekly_summary.to_csv(weekly_summary_path, index=False)
    new_title_summary.to_csv(new_title_path, index=False)
    insights_path.write_text(
        "# 红果热榜趋势洞察\n\n" + "\n".join(f"- {line}" for line in insights),
        encoding="utf-8",
    )
    render_html_report(
        output_path=report_path,
        daily_summary=daily_summary,
        weekly_summary=weekly_summary,
        title_summary=title_summary,
        new_title_summary=new_title_summary,
        insights=insights,
    )
    return {
        "cleaned": cleaned_path,
        "title_summary": title_summary_path,
        "daily_summary": daily_summary_path,
        "weekly_summary": weekly_summary_path,
        "new_title_summary": new_title_path,
        "insights": insights_path,
        "report": report_path,
    }


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="分析 DataEye 红果热榜 Top100 每日快照，输出标签趋势报告。")
    parser.add_argument("--input", required=True, help="CSV / JSON / Excel 文件，或包含这些文件的目录。")
    parser.add_argument("--output-dir", default="output/hongguo_analysis", help="分析产物输出目录。")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)

    input_path = Path(args.input).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    raw_frame = collect_input_frames(input_path)
    outputs = export_analysis(raw_frame, output_dir)

    print("分析完成，生成文件：")
    for name, path in outputs.items():
        print(f"- {name}: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
