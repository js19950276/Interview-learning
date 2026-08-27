"""DramaState: 中央状态机 + 持久化.

数据容器(StoryCard/PacingPlan/ComplianceReport)在此定义,
behavior 模块(story_card.py/pacing.py/compliance.py)从此处导入.

state.json 仅存索引;大字段 variants/storyboard 拆到独立 JSON,
原子写入(.tmp + os.replace)避免半写状态.
"""
from __future__ import annotations

import json
import logging
import os
import socket
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Callable, Optional

from agent.emotion_scorer import ScoreResult
from agent.hook_rewriter import Variant
from agent.parser import Script
from agent.serde import from_dict, to_serializable
from agent.storyboard import Storyboard

log = logging.getLogger("state")


class Stage(str, Enum):
    PARSED = "parsed"
    CARDED = "carded"
    SCENE_MATCHED = "scene_matched"
    PACED = "paced"
    REWRITTEN = "rewritten"
    SCORED = "scored"
    SELECTED = "selected"
    STORYBOARDED = "storyboarded"
    EXPORTED = "exported"


STAGE_ORDER: list[Stage] = list(Stage)


@dataclass
class StoryCard:
    protagonist: str = ""
    motivation: str = ""
    world_setting: str = ""
    inciting_incident: str = ""
    rising_action: str = ""
    midpoint_twist: str = ""
    climax: str = ""
    resolution: str = ""
    estimated_minutes: float = 0.0   # LLM 看完剧本估计的合适成片时长


@dataclass
class SelectedScene:
    id: str = ""
    channel: str = ""        # 男频 / 女频
    genre: str = ""          # 题材
    hook_tags: list[str] = field(default_factory=list)
    one_liner: str = ""
    reason: str = ""         # LLM 入选理由(或"粗筛兜底"/"手动指定")


@dataclass
class SceneMatchResult:
    selected: list[SelectedScene] = field(default_factory=list)
    channel_inferred: str = ""


@dataclass
class PacingSegment:
    name: str = ""        # 起势/攀升/风暴/决战
    proportion: float = 0.0
    word_target: int = 0
    shot_target: int = 0


@dataclass
class HookDistribution:
    suspense: int = 0
    twist: int = 0
    emotion: int = 0
    info: int = 0
    crisis: int = 0


@dataclass
class PacingPlan:
    segments: list[PacingSegment] = field(default_factory=list)
    hook_distribution: HookDistribution = field(default_factory=HookDistribution)


@dataclass
class ComplianceIssue:
    severity: str = "info"   # block / warn / info
    category: str = ""       # 政治 / 未成年 / 广告法 / 暴力 / 低俗
    text_span: str = ""
    reason: str = ""
    suggestion: str = ""


@dataclass
class ComplianceReport:
    target_id: str = ""      # variant-N / storyboard
    issues: list[ComplianceIssue] = field(default_factory=list)

    @property
    def has_blockers(self) -> bool:
        return any(i.severity == "block" for i in self.issues)


@dataclass
class IPRiskPoint:
    dimension: str = ""      # 题材 / 人物关系 / 主线结构 / 核心桥段 / 台词表达等
    severity: str = "medium" # low / medium / high / critical
    detail: str = ""
    suggestion: str = ""


@dataclass
class IPRiskReport:
    target_id: str = ""      # variant-N
    risk_level: str = "中"   # 低 / 中 / 高 / 极高
    launch_advice: str = "修改后上线"  # 可上线 / 修改后上线 / 暂不建议上线
    summary: str = ""
    basis: list[str] = field(default_factory=list)
    risk_points: list[IPRiskPoint] = field(default_factory=list)
    must_change: list[str] = field(default_factory=list)
    safe_points: list[str] = field(default_factory=list)
    disclaimer: str = "本结果仅为创作风控初筛,不能替代律师法律意见。"

    @property
    def has_high_risk(self) -> bool:
        return self.risk_level in {"高", "极高"} or any(
            p.severity in {"high", "critical"} for p in self.risk_points
        )


@dataclass
class DramaState:
    project_id: str = ""
    workspace: Path = field(default_factory=lambda: Path("."))
    stage: Stage = Stage.PARSED
    script: Optional[Script] = None
    story_card: Optional[StoryCard] = None
    scene_match: Optional[SceneMatchResult] = None
    pacing_plan: Optional[PacingPlan] = None
    variants: list[Variant] = field(default_factory=list)
    primary_scores: list[ScoreResult] = field(default_factory=list)
    cross_scores: list[ScoreResult] = field(default_factory=list)
    arbiter_scores: dict[int, ScoreResult] = field(default_factory=dict)
    final_scores: list[float] = field(default_factory=list)
    rewrite_counts: list[int] = field(default_factory=list)
    compliance_reports: list[ComplianceReport] = field(default_factory=list)
    ip_risk_reports: list[IPRiskReport] = field(default_factory=list)
    selected_variant_idx: Optional[int] = None
    storyboard: Optional[Storyboard] = None

    # 用户 UI 手动指定目标时长(覆盖 LLM 估计 + 字数启发).None=自动推导
    user_target_minutes: Optional[float] = None
    # 实际用于 pacing 的最终时长(各 fallback 决定后写入,UI 显示用)
    effective_target_minutes: float = 0.0

    # 失败可见化 (#1):variant_idx → 错误描述
    score_errors: dict[int, str] = field(default_factory=dict)
    # 生成阶段失败 (storyboarded 等):stage_name → 错误描述
    stage_errors: dict[str, str] = field(default_factory=dict)
    # Prompt 版本快照 (#4):module_name → version,记录每个 stage 用的 prompt 版本
    prompt_versions: dict[str, str] = field(default_factory=dict)
    # 当前正在跑的阶段开始时间戳 (#3-lite),供 UI 显示已运行时长
    current_work_started_at: float = 0.0

    _lock: threading.RLock = field(
        default_factory=threading.RLock,
        repr=False,
        compare=False,
        metadata={"transient": True},
    )

    @classmethod
    def create(cls, workspace_root: Path) -> "DramaState":
        project_id = uuid.uuid4().hex[:12]
        workspace = workspace_root / project_id
        workspace.mkdir(parents=True, exist_ok=True)
        (workspace / "snapshots").mkdir(exist_ok=True)
        s = cls(project_id=project_id, workspace=workspace, stage=Stage.PARSED)
        s.save()
        log.info("DramaState 已创建 | id=%s | path=%s", project_id, workspace)
        return s

    @classmethod
    def load(cls, workspace: Path) -> "DramaState":
        state_path = workspace / "state.json"
        if not state_path.exists():
            raise FileNotFoundError(f"state.json 不存在: {state_path}")
        data = json.loads(state_path.read_text(encoding="utf-8"))
        data.pop("variants_count", None)
        data.pop("has_storyboard", None)

        variants_path = workspace / "variants.json"
        if variants_path.exists():
            data["variants"] = json.loads(variants_path.read_text(encoding="utf-8"))
        storyboard_path = workspace / "storyboard.json"
        if storyboard_path.exists():
            data["storyboard"] = json.loads(storyboard_path.read_text(encoding="utf-8"))

        s = from_dict(cls, data)
        s.workspace = Path(workspace)
        log.info("DramaState 已加载 | id=%s | stage=%s", s.project_id, s.stage)
        return s

    def save(self) -> None:
        with self._lock:
            self._save_locked()

    def _save_locked(self) -> None:
        ws = self.workspace
        ws.mkdir(parents=True, exist_ok=True)
        full = to_serializable(self)
        variants_data = full.pop("variants", []) or []
        storyboard_data = full.pop("storyboard", None)
        index = {
            **full,
            "variants_count": len(variants_data),
            "has_storyboard": storyboard_data is not None,
        }
        self._atomic_write(ws / "state.json", index)
        self._atomic_write(ws / "variants.json", variants_data)
        sb_path = ws / "storyboard.json"
        if storyboard_data is not None:
            self._atomic_write(sb_path, storyboard_data)
        elif sb_path.exists():
            sb_path.unlink()

    @staticmethod
    def _atomic_write(path: Path, data) -> None:
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)

    def snapshot(self) -> Path:
        ts = datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
        snap_dir = self.workspace / "snapshots" / ts
        snap_dir.mkdir(parents=True, exist_ok=True)
        for fname in ("state.json", "variants.json", "storyboard.json"):
            src = self.workspace / fname
            if src.exists():
                (snap_dir / fname).write_bytes(src.read_bytes())
        log.info("snapshot 已保存 | %s", snap_dir)
        return snap_dir

    def update(self, **fields_to_set) -> None:
        with self._lock:
            for k, v in fields_to_set.items():
                if not hasattr(self, k):
                    raise AttributeError(f"DramaState 无字段 '{k}'")
                setattr(self, k, v)
            self._save_locked()

    def advance_to(self, stage: Stage) -> None:
        with self._lock:
            if STAGE_ORDER.index(stage) >= STAGE_ORDER.index(self.stage):
                self.stage = stage
            self._save_locked()

    # ---------- pipeline lock (#2) ----------
    @property
    def lock_path(self) -> Path:
        return self.workspace / ".pipeline.lock"

    def read_pipeline_lock(self) -> dict:
        """读取 pipeline lock 元信息.旧格式(pid 文本)也兼容返回."""
        if not self.lock_path.exists():
            return {}
        try:
            raw = self.lock_path.read_text(encoding="utf-8")
        except OSError:
            return {}
        try:
            data = json.loads(raw)
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
        return {"pid": raw.strip(), "legacy": True, "started_at": self.lock_path.stat().st_mtime}

    def acquire_pipeline_lock(self, target_stage: Optional[Stage] = None) -> bool:
        """原子获取文件锁.True=获得,False=已有人在跑(且 lock 不超过 1 小时)."""
        payload = {
            "pid": os.getpid(),
            "hostname": socket.gethostname(),
            "started_at": time.time(),
            "project_id": self.project_id,
            "target_stage": target_stage.value if target_stage else "",
        }
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        while True:
            try:
                fd = os.open(self.lock_path, flags, 0o644)
            except FileExistsError:
                age = time.time() - self.lock_path.stat().st_mtime
                if age < 3600:
                    return False
                log.warning("pipeline.lock 已陈旧 (%ds),清理并重新获取", int(age))
                self.lock_path.unlink(missing_ok=True)
                continue
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=2)
            break
        return True

    def release_pipeline_lock(self) -> None:
        self.lock_path.unlink(missing_ok=True)

    def is_pipeline_locked(self) -> bool:
        if not self.lock_path.exists():
            return False
        age = time.time() - self.lock_path.stat().st_mtime
        if age > 3600:
            self.lock_path.unlink(missing_ok=True)
            return False
        return True

    def invalidate_from(self, stage: Stage) -> None:
        """清除 `stage` 及之后阶段的产物,先 snapshot 再清."""
        with self._lock:
            self.snapshot()
            target_idx = STAGE_ORDER.index(stage)
            stage_to_field: list[tuple[Stage, str, object]] = [
                (Stage.CARDED, "story_card", None),
                (Stage.SCENE_MATCHED, "scene_match", None),
                (Stage.PACED, "pacing_plan", None),
                (Stage.REWRITTEN, "variants", []),
                (Stage.SCORED, "primary_scores", []),
                (Stage.SCORED, "cross_scores", []),
                (Stage.SCORED, "arbiter_scores", {}),
                (Stage.SCORED, "final_scores", []),
                (Stage.SCORED, "rewrite_counts", []),
                (Stage.SCORED, "compliance_reports", []),
                (Stage.SCORED, "ip_risk_reports", []),
                (Stage.SCORED, "score_errors", {}),
                (Stage.SELECTED, "selected_variant_idx", None),
                (Stage.STORYBOARDED, "storyboard", None),
                (Stage.STORYBOARDED, "stage_errors", {}),
            ]
            for st, attr, default in stage_to_field:
                if STAGE_ORDER.index(st) >= target_idx:
                    if isinstance(default, list):
                        setattr(self, attr, [])
                    elif isinstance(default, dict):
                        setattr(self, attr, {})
                    else:
                        setattr(self, attr, default)
            self.stage = STAGE_ORDER[max(0, target_idx - 1)]
            self._save_locked()
            log.info("invalidated from %s | new stage=%s", stage, self.stage)


# ---------------------------------------------------------------------------
# 目标时长动态决议 (3 层 fallback)
# ---------------------------------------------------------------------------

def _derive_minutes_from_length(total_chars: int) -> float:
    """字数启发:中文短剧典型 ~350 字幕字/分钟,clamp 到 [8, 50]."""
    if total_chars <= 0:
        return 0.0
    raw = total_chars / 350.0
    return max(8.0, min(50.0, raw))


def _resolve_target_minutes(state: "DramaState") -> tuple[float, str]:
    """3 层 fallback:用户指定 > LLM 故事卡估计 > 字数启发 > 默认.
    返回 (minutes, source_label)."""
    from agent.pacing import DEFAULT_TARGET_MINUTES

    if state.user_target_minutes and state.user_target_minutes > 0:
        return state.user_target_minutes, "用户指定"
    if state.story_card and state.story_card.estimated_minutes > 0:
        return state.story_card.estimated_minutes, "LLM 故事判断"
    if state.script:
        derived = _derive_minutes_from_length(len(state.script.raw_text))
        if derived > 0:
            return derived, "字数启发"
    return DEFAULT_TARGET_MINUTES, "兜底默认"


def __getattr__(name: str):
    """Lazy compatibility export for older imports from agent.state."""
    if name == "PipelineRun":
        from agent.pipeline import PipelineRun

        return PipelineRun
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
