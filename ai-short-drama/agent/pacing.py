"""节奏规划:纯函数,按 15/30/35/20 标准比例切分.

借鉴 0xsline/short-drama 的节奏分段法.
作用于 hook_rewrite(字数比例约束)和 storyboard(镜头数比例约束),±5% 容差.
首版不走 LLM,纯数学切分;若后续需要 LLM 重新分配段落归属,再加 prompt.

字数 / 镜头数推荐由**目标时长**反算,而非原剧本长度:
- target_words = target_minutes × CHARS_PER_MINUTE (默认 25 分钟 × 300 字/分钟 = 7500 字)
- target_scenes = target_minutes × 60 / SECONDS_PER_SCENE (默认 25 × 60 / 15 = 100 个小场景)
"""
from __future__ import annotations

import logging
from typing import Optional

from agent.state import HookDistribution, PacingPlan, PacingSegment

log = logging.getLogger("pacing")

# === 目标时长反算的核心常量(可调) ===
DEFAULT_TARGET_MINUTES = 25.0    # 默认目标时长(分钟),20-30 区间居中
CHARS_PER_MINUTE = 300           # 短剧典型字幕密度(中文字符)
SECONDS_PER_SCENE = 15           # 每个小场景目标时长(秒)
# ====================================

SEGMENT_PROPORTIONS: list[tuple[str, float]] = [
    ("起势", 0.15),   # 钩子 + 角色亮相
    ("攀升", 0.30),   # 矛盾递增
    ("风暴", 0.35),   # 高密度冲突 + 多重反转
    ("决战", 0.20),   # 高潮 + 收束
]

DEFAULT_HOOK_DISTRIBUTION = HookDistribution(
    suspense=3,
    twist=3,
    emotion=2,
    info=2,
    crisis=2,
)

TOLERANCE = 0.05  # ±5%


def plan_pacing(
    target_minutes: float = DEFAULT_TARGET_MINUTES,
    total_words: Optional[int] = None,
    total_shots: Optional[int] = None,
    hook_distribution: Optional[HookDistribution] = None,
) -> PacingPlan:
    """按目标时长生成节奏规划.

    若 total_words/total_shots 显式传入则用之(向后兼容);
    否则按 target_minutes 反算:
      - total_words = target_minutes × 300
      - total_shots = target_minutes × 60 / 15
    """
    if total_words is None:
        total_words = int(target_minutes * CHARS_PER_MINUTE)
    if total_shots is None:
        total_shots = int(target_minutes * 60 / SECONDS_PER_SCENE)
    if hook_distribution is None:
        hd = DEFAULT_HOOK_DISTRIBUTION
        hook_distribution = HookDistribution(
            suspense=hd.suspense, twist=hd.twist,
            emotion=hd.emotion, info=hd.info, crisis=hd.crisis,
        )

    segments = [
        PacingSegment(
            name=name,
            proportion=proportion,
            word_target=int(total_words * proportion),
            shot_target=int(total_shots * proportion) if total_shots else 0,
        )
        for name, proportion in SEGMENT_PROPORTIONS
    ]

    target_seconds = total_shots * SECONDS_PER_SCENE
    log.info("节奏规划完成 | 目标时长=%.1f分 | 总字=%d | 总镜=%d | 段数=%d",
             target_seconds / 60, total_words, total_shots, len(segments))
    return PacingPlan(segments=segments, hook_distribution=hook_distribution)


def pacing_constraints_text(plan: PacingPlan) -> str:
    """节奏约束的文字描述,供 prompt 注入."""
    seg_lines = []
    for seg in plan.segments:
        targets = []
        if seg.word_target:
            targets.append(f"约 {seg.word_target} 字")
        if seg.shot_target:
            targets.append(f"约 {seg.shot_target} 个镜头")
        targets_text = " / ".join(targets) if targets else "未定"
        seg_lines.append(f"  - {seg.name}({int(seg.proportion * 100)}%): {targets_text}")

    hd = plan.hook_distribution
    hook_total = hd.suspense + hd.twist + hd.emotion + hd.info + hd.crisis

    return (
        f"【节奏分段】(±{int(TOLERANCE * 100)}% 容差)\n"
        + "\n".join(seg_lines)
        + f"\n\n【钩子分布】(目标共 {hook_total} 个钩子)\n"
        + f"  - 悬疑钩子: {hd.suspense} 个\n"
        + f"  - 反转钩子: {hd.twist} 个\n"
        + f"  - 情感钩子: {hd.emotion} 个\n"
        + f"  - 信息钩子: {hd.info} 个\n"
        + f"  - 危机钩子: {hd.crisis} 个"
    )
