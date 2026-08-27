"""Pipeline stage orchestration for DramaState.

This module keeps pipeline execution separate from the state persistence/data
model definitions in :mod:`agent.state` while preserving the same public
``PipelineRun`` API.
"""
from __future__ import annotations

import logging
import time
from typing import Callable, Optional

from agent.state import STAGE_ORDER, DramaState, Stage, _resolve_target_minutes

log = logging.getLogger("pipeline")


class PipelineRun:
    def __init__(
        self,
        state: DramaState,
        on_progress: Optional[Callable[[Stage, str], None]] = None,
    ):
        self.state = state
        self.on_progress = on_progress

    def _emit(self, stage: Stage, msg: str) -> None:
        log.info("[pipeline] %s | %s", stage.value, msg)
        if self.on_progress:
            try:
                self.on_progress(stage, msg)
            except Exception as e:
                log.warning("on_progress 回调异常: %s", e)

    def _start_work(self) -> None:
        """每个 stage 方法开头调用,标记当前工作开始时间(供 UI 显示已运行时长)."""
        with self.state._lock:
            self.state.current_work_started_at = time.time()
            self.state._save_locked()

    def carded(self) -> None:
        from agent.story_card import generate_story_card
        from prompts.story_card import VERSION as STORY_CARD_VERSION
        if self.state.script is None:
            raise RuntimeError("CARDED 阶段需要 script(请先 PARSED)")
        self._start_work()
        self._emit(Stage.CARDED, "生成故事卡...")
        self.state.story_card = generate_story_card(self.state.script)
        self.state.prompt_versions["story_card"] = STORY_CARD_VERSION
        self.state.advance_to(Stage.CARDED)
        self.state.snapshot()
        self._emit(Stage.CARDED, "故事卡完成")

    def scene_matched(self) -> None:
        from agent.scene_match import match_scenes
        from agent.story_card import card_summary
        from prompts.scene_match import VERSION as SCENE_MATCH_VERSION
        if self.state.story_card is None:
            raise RuntimeError("SCENE_MATCHED 阶段需要 story_card(请先 CARDED)")
        self._start_work()
        self.state.prompt_versions["scene_match"] = SCENE_MATCH_VERSION
        self._emit(Stage.SCENE_MATCHED, "按剧本匹配漫剧场景...")
        result = match_scenes(self.state.story_card, story_card_summary=card_summary(self.state.story_card))
        with self.state._lock:
            self.state.scene_match = result
            self.state._save_locked()
        self.state.advance_to(Stage.SCENE_MATCHED)
        self.state.snapshot()
        self._emit(
            Stage.SCENE_MATCHED,
            f"场景匹配完成 | 频道={result.channel_inferred} | "
            f"选中 {len(result.selected)} 个: {', '.join(s.genre for s in result.selected)}",
        )

    def paced(self) -> None:
        from agent.pacing import DEFAULT_TARGET_MINUTES, plan_pacing
        if self.state.script is None:
            raise RuntimeError("PACED 阶段需要 script")
        self._start_work()

        target, source = _resolve_target_minutes(self.state)
        self._emit(Stage.PACED, f"目标时长 {target:.1f} 分钟(来源:{source})规划节奏...")
        self.state.pacing_plan = plan_pacing(target_minutes=target)
        self.state.effective_target_minutes = target
        self.state.advance_to(Stage.PACED)
        self.state.snapshot()
        seg = self.state.pacing_plan.segments
        self._emit(
            Stage.PACED,
            f"节奏规划完成 | 目标 {target:.1f} 分钟 ({source}) | "
            f"总字={sum(s.word_target for s in seg)} | 总镜={sum(s.shot_target for s in seg)}",
        )

    def rewritten(self) -> None:
        from agent.hook_rewriter import rewrite_hooks
        from agent.story_card import card_summary
        from agent.pacing import pacing_constraints_text
        from prompts.hook_rewrite import VERSION as HOOK_REWRITE_VERSION
        if self.state.script is None:
            raise RuntimeError("REWRITTEN 阶段需要 script")
        if self.state.scene_match is None or not self.state.scene_match.selected:
            raise RuntimeError("REWRITTEN 阶段需要 scene_match(请先 SCENE_MATCHED)")
        self._start_work()
        self.state.prompt_versions["hook_rewrite"] = HOOK_REWRITE_VERSION
        scenes = [
            (f"{s.genre}·{'/'.join(s.hook_tags)}" if s.hook_tags else s.genre, s.one_liner)
            for s in self.state.scene_match.selected
        ]
        self._emit(Stage.REWRITTEN, f"并行生成 {len(scenes)} 变体(动态场景)...")
        sc = card_summary(self.state.story_card) if self.state.story_card else ""
        pc = pacing_constraints_text(self.state.pacing_plan) if self.state.pacing_plan else ""
        variants = rewrite_hooks(
            self.state.script.raw_text,
            scenes,
            story_card_summary=sc,
            pacing_constraints=pc,
            pacing_plan=self.state.pacing_plan,
        )
        with self.state._lock:
            self.state.variants = variants
            self.state._save_locked()
        self.state.advance_to(Stage.REWRITTEN)
        self.state.snapshot()
        self._emit(Stage.REWRITTEN, f"5 变体生成完成 ({len(variants)} 个)")

    def scored(self) -> None:
        from agent.score_loop import run_score_loop
        from agent.story_card import card_summary
        from agent.pacing import pacing_constraints_text
        from prompts.emotion_score import VERSION as EMOTION_SCORE_VERSION
        from prompts.compliance import VERSION as COMPLIANCE_VERSION
        if not self.state.variants:
            raise RuntimeError("SCORED 阶段需要 variants(请先 REWRITTEN)")
        self._start_work()
        self.state.prompt_versions["emotion_score"] = EMOTION_SCORE_VERSION
        self.state.prompt_versions["compliance"] = COMPLIANCE_VERSION
        self._emit(Stage.SCORED, "评分 + 合规扫描 + 重写循环中...")
        sc = card_summary(self.state.story_card) if self.state.story_card else ""
        pc = pacing_constraints_text(self.state.pacing_plan) if self.state.pacing_plan else ""
        run_score_loop(self.state, story_card_summary=sc, pacing_constraints=pc)
        self.state.advance_to(Stage.SCORED)
        self.state.snapshot()
        self._emit(Stage.SCORED, "评分完成")

    def storyboarded(self) -> None:
        from agent.storyboard import generate_storyboard
        from agent.compliance import scan as compliance_scan
        from prompts.storyboard import VERSION as STORYBOARD_VERSION
        if self.state.selected_variant_idx is None:
            raise RuntimeError("STORYBOARDED 阶段需要 selected_variant_idx(请先 SELECTED)")
        idx = self.state.selected_variant_idx
        variant = self.state.variants[idx]
        self._start_work()
        self.state.prompt_versions["storyboard"] = STORYBOARD_VERSION
        self._emit(Stage.STORYBOARDED, f"为变体 {idx}({variant.emotion_type})分段生成分镜...")
        sb = generate_storyboard(
            variant,
            script_title=self.state.script.title if self.state.script else "未命名",
            script=self.state.script,
            pacing_plan=self.state.pacing_plan,  # 触发 4 段拆分调用
        )
        # 第二次合规:扫分镜的视觉描述(可能引入新违规)
        all_visual = "\n".join(s.visual_description for s in sb.shots)
        sb_report = compliance_scan(all_visual, target_id="storyboard")
        with self.state._lock:
            self.state.storyboard = sb
            self.state.compliance_reports = [
                r for r in self.state.compliance_reports if r.target_id != "storyboard"
            ]
            self.state.compliance_reports.append(sb_report)
            self.state._save_locked()
        self.state.advance_to(Stage.STORYBOARDED)
        self.state.snapshot()
        self._emit(
            Stage.STORYBOARDED,
            f"分镜完成 | 镜头={len(sb.shots)} | 合规阻断={sum(1 for i in sb_report.issues if i.severity == 'block')}",
        )

    def exported(self) -> None:
        # 实际下载由 UI 触发,这里只标记状态
        self._start_work()
        self.state.advance_to(Stage.EXPORTED)
        self.state.snapshot()
        self._emit(Stage.EXPORTED, "导出阶段标记完成")

    _AUTO_STAGES = [
        Stage.CARDED, Stage.SCENE_MATCHED, Stage.PACED, Stage.REWRITTEN, Stage.SCORED,
        Stage.STORYBOARDED, Stage.EXPORTED,
    ]
    _METHOD_MAP = {
        Stage.CARDED: "carded",
        Stage.SCENE_MATCHED: "scene_matched",
        Stage.PACED: "paced",
        Stage.REWRITTEN: "rewritten",
        Stage.SCORED: "scored",
        Stage.STORYBOARDED: "storyboarded",
        Stage.EXPORTED: "exported",
    }

    def resume_to(self, target: Stage) -> None:
        """从当前 stage 跑到 target(包含).SELECTED 需用户介入,自动跳过."""
        target_idx = STAGE_ORDER.index(target)
        current_idx = STAGE_ORDER.index(self.state.stage)
        for stage in STAGE_ORDER[current_idx + 1:target_idx + 1]:
            if stage == Stage.SELECTED:
                if self.state.selected_variant_idx is None:
                    self._emit(Stage.SELECTED, "等待用户选择变体,pipeline 暂停")
                    return
                with self.state._lock:
                    self.state.advance_to(Stage.SELECTED)
                continue
            method_name = self._METHOD_MAP.get(stage)
            if method_name:
                getattr(self, method_name)()
