"""两层合规扫描:本地敏感词命中 -> LLM 上下文判定.

关键词命中 ≠ 违规,LLM 第二层负责消除误报(如 "杀青" / "未成年保护法").
"""
from __future__ import annotations

import logging
import re
from typing import Callable, Optional

from agent.llm import call_llm_messages_json
from agent.state import ComplianceIssue, ComplianceReport
from prompts.compliance import PROMPT

log = logging.getLogger("compliance")


KEYWORD_CATEGORIES: dict[str, list[str]] = {
    "政治": [
        "习近平", "毛泽东", "邓小平", "江泽民", "胡锦涛", "共产党", "国家主席",
        "台独", "藏独", "疆独", "港独", "六四", "天安门事件", "法轮功", "达赖",
    ],
    "未成年": [
        "未成年", "未满十八", "小学生", "初中生", "童工", "援交", "雏妓", "未成年人性",
    ],
    "广告法": [
        "最便宜", "最好的", "唯一", "绝对最", "100%有效", "永远不复发", "瞬间见效",
        "彻底根治", "包治百病", "神效", "神药", "祖传秘方", "国家级认证", "世界级",
    ],
    "暴力": [
        "杀人", "凶杀", "血腥", "尸体", "毒杀", "自杀", "自焚", "爆炸案", "炸弹",
        "虐待", "强奸", "虐杀", "斩首", "肢解", "活埋", "枪击",
    ],
    "低俗": [
        "脱衣", "内裤", "做爱", "上床", "淫荡", "骚货", "嫖娼", "妓女",
        "包养", "出轨", "一夜情", "性交易",
    ],
}


def _scan_keywords(text: str) -> list[tuple[str, str, int]]:
    hits: list[tuple[str, str, int]] = []
    for category, words in KEYWORD_CATEGORIES.items():
        for w in words:
            for m in re.finditer(re.escape(w), text):
                hits.append((category, w, m.start()))
    return hits


def _extract_context(text: str, position: int, window: int = 30) -> str:
    start = max(0, position - window)
    end = min(len(text), position + window)
    return text[start:end]


def _format_messages(prompt_template, **kwargs):
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


def _llm_judge(category: str, keyword: str, context: str) -> dict:
    messages = _format_messages(PROMPT, category=category, keyword=keyword, context=context)
    return call_llm_messages_json(messages)


JudgeFn = Callable[[str, str, str], dict]


def scan(
    text: str,
    target_id: str = "default",
    *,
    llm_judge_fn: Optional[JudgeFn] = None,
) -> ComplianceReport:
    """两层扫描:本地敏感词 -> LLM 上下文判定.

    同一 (category, keyword) 在文本中多次命中,只判第一次(节省 LLM 调用).
    `llm_judge_fn` 可注入(用于测试 mock).
    """
    judge = llm_judge_fn or _llm_judge
    raw_hits = _scan_keywords(text)

    seen: set[tuple[str, str]] = set()
    issues: list[ComplianceIssue] = []
    for category, keyword, position in raw_hits:
        key = (category, keyword)
        if key in seen:
            continue
        seen.add(key)

        context = _extract_context(text, position)
        try:
            result = judge(category, keyword, context)
        except Exception as e:
            log.warning("LLM 上下文判定失败,保守按 warn 处理 | %s/%s | %s",
                        category, keyword, e)
            result = {
                "is_violation": True,
                "severity": "warn",
                "reason": f"LLM 判定失败({e}),保守处理",
                "suggestion": "",
            }

        if not result.get("is_violation", False):
            continue

        issues.append(ComplianceIssue(
            severity=result.get("severity", "warn"),
            category=category,
            text_span=keyword,
            reason=result.get("reason", ""),
            suggestion=result.get("suggestion", ""),
        ))

    log.info("合规扫描完成 | target=%s | 命中=%d | 违规=%d | 阻断=%d",
             target_id, len(raw_hits), len(issues),
             sum(1 for i in issues if i.severity == "block"))
    return ComplianceReport(target_id=target_id, issues=issues)
