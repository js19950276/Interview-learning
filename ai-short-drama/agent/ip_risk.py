"""剧本魔改/重写后的版权侵权风险初筛。

该模块在生成变体后追加一层“IP 风险”判断,用于识别是否过度贴近
原始/参考文本的人物关系、主线结构、连续桥段、台词等受保护表达。
结论仅作创作风控,不替代律师意见。
"""
from __future__ import annotations

import logging
from typing import Callable, Optional

from agent.llm import CACHE_CONTROL, call_llm_messages_json
from agent.state import IPRiskPoint, IPRiskReport
from prompts.ip_risk import HUMAN_INTRO, SCHEMA_BLOCK, SYSTEM

log = logging.getLogger("ip_risk")


def _build_messages(source_text: str, rewritten_text: str) -> list[dict]:
    """把「指令 + 原始/参考文本」做成可缓存前缀块:同一原稿在 5 个变体的
    风控调用里完全一致,缓存后只有首次付全价,其余按 ~0.1x 读取计费.
    易变的魔改文本 + schema 放在断点之后的第二块."""
    cacheable_prefix = f"{HUMAN_INTRO}\n\n【原始/参考文本】\n---\n{source_text}\n---"
    volatile_suffix = (
        f"\n\n【生成/魔改文本】\n---\n{rewritten_text}\n---\n\n{SCHEMA_BLOCK}"
    )
    return [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": [
            {"type": "text", "text": cacheable_prefix, "cache_control": CACHE_CONTROL},
            {"type": "text", "text": volatile_suffix},
        ]},
    ]


JudgeFn = Callable[[str, str], dict]


def _normalize_report(target_id: str, result: dict) -> IPRiskReport:
    points = []
    for item in result.get("risk_points", []) or []:
        if not isinstance(item, dict):
            continue
        points.append(IPRiskPoint(
            dimension=str(item.get("dimension", "")),
            severity=str(item.get("severity", "medium")),
            detail=str(item.get("detail", "")),
            suggestion=str(item.get("suggestion", "")),
        ))
    return IPRiskReport(
        target_id=target_id,
        risk_level=str(result.get("risk_level", "中")),
        launch_advice=str(result.get("launch_advice", "修改后上线")),
        summary=str(result.get("summary", "")),
        basis=[str(x) for x in (result.get("basis", []) or [])],
        risk_points=points,
        must_change=[str(x) for x in (result.get("must_change", []) or [])],
        safe_points=[str(x) for x in (result.get("safe_points", []) or [])],
        disclaimer=str(result.get("disclaimer", "本结果仅为创作风控初筛,不能替代律师法律意见。")),
    )


def assess(
    source_text: str,
    rewritten_text: str,
    target_id: str = "default",
    *,
    judge_fn: Optional[JudgeFn] = None,
) -> IPRiskReport:
    """对 source_text 与 rewritten_text 做侵权风险初筛。"""
    try:
        if judge_fn is not None:
            result = judge_fn(source_text, rewritten_text)
        else:
            messages = _build_messages(source_text, rewritten_text)
            result = call_llm_messages_json(messages)
        report = _normalize_report(target_id, result)
    except Exception as e:
        log.warning("IP 风险初筛失败,保守按中风险处理 | target=%s | %s", target_id, e)
        report = IPRiskReport(
            target_id=target_id,
            risk_level="中",
            launch_advice="修改后上线",
            summary=f"IP 风险初筛调用失败({type(e).__name__}),建议人工复核。",
            basis=["系统未能完成自动相似性判断,商业上线前应由法务/律师复核。"],
            risk_points=[IPRiskPoint(
                dimension="权属来源",
                severity="medium",
                detail="未完成自动风控判断。",
                suggestion="补充原始参考来源、创作过程记录和人工逐场景比对。",
            )],
            must_change=[],
            safe_points=[],
            disclaimer="本结果仅为创作风控初筛,不能替代律师法律意见。",
        )
    log.info("IP 风险初筛完成 | target=%s | risk=%s | advice=%s", target_id, report.risk_level, report.launch_advice)
    return report
