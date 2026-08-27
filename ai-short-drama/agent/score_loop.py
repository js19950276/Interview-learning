"""评分循环:primary + cross + arbiter + 自动重写 + 合规联动 + 全局 budget.

业务最复杂的模块.每个变体内部串行(评分依赖前一步),5 变体之间并行.
合规阻断时自动修复 1 次,失败再放弃;final 分 < 7 触发重写,受单变体/全局双预算约束.
"""
from __future__ import annotations

import logging
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Callable, Optional

from agent.compliance import scan as compliance_scan
from agent.ip_risk import assess as ip_risk_assess
from agent.emotion_scorer import ScoreResult, score_text
from agent.hook_rewriter import Variant, rewrite_single_variant
from agent.state import ComplianceReport, DramaState

log = logging.getLogger("score_loop")

PASSING_THRESHOLD = 7.0
DISAGREEMENT_THRESHOLD = 1.5
MAX_REWRITES_PER_VARIANT = 2
MAX_TOTAL_REWRITES = 8
# 5 变体全并行 + 每变体 2 评分调用 = 峰值 10 个并发 LLM 请求,在 llm-proxy 上易触发 429.
# 改成 2 路并发 → 峰值 4 个并发,与 LLM 服务限流共存.
SCORE_LOOP_CONCURRENCY = 2


def _final_score(
    primary: ScoreResult,
    cross: ScoreResult,
    arbiter: Optional[ScoreResult],
) -> float:
    if arbiter is not None:
        return sorted([primary.total, cross.total, arbiter.total])[1]  # 中位数
    return (primary.total + cross.total) / 2


def _score_variant(
    variant: Variant,
) -> tuple[ScoreResult, ScoreResult, Optional[ScoreResult]]:
    primary = score_text(variant.emotion_type, variant.full_rewrite, persona="primary")
    cross = score_text(variant.emotion_type, variant.full_rewrite, persona="secondary")
    arbiter: Optional[ScoreResult] = None
    diff = abs(primary.total - cross.total)
    if diff > DISAGREEMENT_THRESHOLD:
        log.info("分歧 %.1f > %.1f → arbiter 仲裁 | %s",
                 diff, DISAGREEMENT_THRESHOLD, variant.emotion_type)
        arbiter = score_text(variant.emotion_type, variant.full_rewrite, persona="arbiter")
    return primary, cross, arbiter


def run_score_loop(
    state: DramaState,
    story_card_summary: str = "",
    pacing_constraints: str = "",
    on_progress: Optional[Callable[[int, str], None]] = None,
) -> None:
    n = len(state.variants)
    if n == 0:
        log.warning("score_loop: variants 为空")
        return

    with state._lock:
        state.primary_scores = [None] * n
        state.cross_scores = [None] * n
        state.arbiter_scores = {}
        state.final_scores = [0.0] * n
        state.rewrite_counts = [0] * n
        state.compliance_reports = []
        state.ip_risk_reports = []
        state._save_locked()

    rewrite_budget = [MAX_TOTAL_REWRITES]
    budget_lock = threading.Lock()

    def _claim_rewrite() -> bool:
        with budget_lock:
            if rewrite_budget[0] <= 0:
                return False
            rewrite_budget[0] -= 1
            return True

    def _process(idx: int) -> None:
        variant = state.variants[idx]
        # 生成阶段失败的占位变体(空内容)→ 跳过评分,直接标记 score_error,不浪费 LLM 调用.
        if not variant or not (variant.full_rewrite or "").strip():
            msg = "变体生成失败(内容为空),跳过评分"
            log.error("variant-%d %s", idx, msg)
            with state._lock:
                state.score_errors[idx] = msg
                state._save_locked()
            if on_progress:
                on_progress(idx, variant.emotion_type if variant else f"variant-{idx}")
            return
        attempt = 0
        while True:
            target_id = f"variant-{idx}"
            try:
                report = compliance_scan(variant.full_rewrite, target_id=target_id)
            except Exception as e:
                log.error("compliance scan 失败 | variant-%d | %s", idx, e)
                report = ComplianceReport(target_id=target_id)

            with state._lock:
                state.compliance_reports = [
                    r for r in state.compliance_reports if r.target_id != target_id
                ]
                state.compliance_reports.append(report)
                state._save_locked()

            if report.has_blockers:
                if attempt < MAX_REWRITES_PER_VARIANT and _claim_rewrite():
                    blocker_lines = [
                        f"- [{i.category}] {i.reason} 建议: {i.suggestion}"
                        for i in report.issues if i.severity == "block"
                    ]
                    log.info("variant-%d 合规阻断,自动修复 | %s",
                             idx, "; ".join(blocker_lines))
                    try:
                        variant = rewrite_single_variant(
                            variant,
                            suggestions="以下是合规问题,必须修正:\n" + "\n".join(blocker_lines),
                            story_card_summary=story_card_summary,
                            pacing_constraints=pacing_constraints,
                        )
                    except Exception as e:
                        err_msg = f"合规修复重写失败: {type(e).__name__}: {str(e)[:200]}"
                        log.error("variant-%d %s", idx, err_msg)
                        with state._lock:
                            state.score_errors[idx] = err_msg
                            state._save_locked()
                        break
                    with state._lock:
                        state.variants[idx] = variant
                        state.rewrite_counts[idx] += 1
                        state._save_locked()
                    attempt += 1
                    continue
                else:
                    log.error("variant-%d 合规阻断,无法修复,标记终止", idx)
                    break

            try:
                primary, cross, arbiter = _score_variant(variant)
            except Exception as e:
                err_msg = f"{type(e).__name__}: {str(e)[:200]}"
                log.error("评分失败 | variant-%d | %s", idx, err_msg)
                with state._lock:
                    state.score_errors[idx] = err_msg
                    state._save_locked()
                break

            final = _final_score(primary, cross, arbiter)

            with state._lock:
                state.primary_scores[idx] = primary
                state.cross_scores[idx] = cross
                if arbiter is not None:
                    state.arbiter_scores[idx] = arbiter
                state.final_scores[idx] = final
                state._save_locked()

            log.info(
                "variant-%d (%s) | primary=%.1f cross=%.1f arbiter=%s | final=%.1f | attempt=%d",
                idx, variant.emotion_type,
                primary.total, cross.total,
                f"{arbiter.total:.1f}" if arbiter else "—",
                final, attempt,
            )

            if final >= PASSING_THRESHOLD:
                break

            if attempt >= MAX_REWRITES_PER_VARIANT:
                log.info("variant-%d 单变体重写预算耗尽,停止", idx)
                break
            if not _claim_rewrite():
                log.warning("全局重写预算耗尽,variant-%d 停止 | final=%.1f", idx, final)
                break

            suggestions = primary.suggestions or primary.comment or "请基于以上评语优化"
            log.info("variant-%d final=%.1f < %.1f,触发重写 | 单变=%d/全局剩=%d",
                     idx, final, PASSING_THRESHOLD, attempt + 1, rewrite_budget[0])
            try:
                variant = rewrite_single_variant(
                    variant,
                    suggestions=suggestions,
                    story_card_summary=story_card_summary,
                    pacing_constraints=pacing_constraints,
                )
            except Exception as e:
                err_msg = f"质量重写失败: {type(e).__name__}: {str(e)[:200]}"
                log.error("variant-%d %s", idx, err_msg)
                with state._lock:
                    state.score_errors[idx] = err_msg
                    state._save_locked()
                break
            with state._lock:
                state.variants[idx] = variant
                state.rewrite_counts[idx] += 1
                state._save_locked()
            attempt += 1

        # IP 风险初筛:对定稿变体只跑一次(原先每轮重写都重发整篇原稿+变体,浪费).
        target_id = f"variant-{idx}"
        try:
            source_text = state.script.raw_text if state.script else ""
            ip_report = ip_risk_assess(source_text, variant.full_rewrite, target_id=target_id)
        except Exception as e:
            log.error("IP 风险初筛失败 | variant-%d | %s", idx, e)
            ip_report = None
        if ip_report is not None:
            with state._lock:
                state.ip_risk_reports = [
                    r for r in state.ip_risk_reports if r.target_id != target_id
                ]
                state.ip_risk_reports.append(ip_report)
                state._save_locked()

        if on_progress:
            on_progress(idx, variant.emotion_type)

    workers = min(n, SCORE_LOOP_CONCURRENCY)
    log.info("score_loop 启动 | 变体=%d | 并发=%d", n, workers)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        future_to_idx = {pool.submit(_process, i): i for i in range(n)}
        for f in as_completed(future_to_idx):
            idx = future_to_idx[f]
            try:
                f.result()
            except Exception as e:
                err_msg = f"{type(e).__name__}: {str(e)[:200]}"
                log.error("score_loop worker-%d 未捕获异常: %s", idx, err_msg)
                with state._lock:
                    state.score_errors[idx] = err_msg
                    state._save_locked()

    log.info("score_loop 完成 | 总重写=%d/%d | finals=%s",
             MAX_TOTAL_REWRITES - rewrite_budget[0], MAX_TOTAL_REWRITES,
             [f"{s:.1f}" for s in state.final_scores])
