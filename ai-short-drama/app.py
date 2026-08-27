"""短剧钩子重构 Agent — Streamlit UI.

后台线程跑 pipeline,主线程读 state.json 轮询(避开 streamlit rerun 断
ThreadPoolExecutor 的坑).每 1.5s rerun 一次,直到 pipeline 到达目标 stage.
"""
from __future__ import annotations

import json
import logging
import time
from pathlib import Path

import streamlit as st

from agent.llm import setup_llm_logging
from agent.exporter import export_rewrite, export_storyboard_word, export_video_prompts
from agent.parser import parse_docx
from agent.quality_metrics import assess_storyboard_quality, assess_variant_quality
from agent.run_summary import build_run_summary
from agent.serde import to_serializable
from agent.state import STAGE_ORDER, DramaState, Stage
from ui.pipeline_runner import maybe_start_pipeline, pipeline_alive

WORKSPACE_ROOT = Path(".workspaces")
WORKSPACE_ROOT.mkdir(exist_ok=True)
POLL_INTERVAL = 1.5  # seconds

log = logging.getLogger("app")
setup_llm_logging()

STAGE_LABELS = {
    Stage.PARSED: "📄 上传",
    Stage.CARDED: "📚 故事卡",
    Stage.SCENE_MATCHED: "🎯 场景匹配",
    Stage.PACED: "⚖️ 节奏",
    Stage.REWRITTEN: "✍️ 5 变体",
    Stage.SCORED: "📊 评分",
    Stage.SELECTED: "✅ 选定",
    Stage.STORYBOARDED: "🎬 分镜",
    Stage.EXPORTED: "📦 导出",
}


def render_target_minutes_panel(state: DramaState) -> None:
    """Sidebar:动态目标时长配置(自动决议 / 手动覆盖)."""
    from agent.state import _resolve_target_minutes

    with st.sidebar:
        st.divider()
        st.subheader("⏱️ 目标时长")

        current_target, source = _resolve_target_minutes(state)
        # 估算镜头数
        est_shots = int(current_target * 60 / 15)
        st.caption(f"生效: **{current_target:.1f} 分钟** ≈ {est_shots} 镜头")
        st.caption(f"来源: `{source}`")

        manual = st.checkbox(
            "手动指定(覆盖自动)",
            value=state.user_target_minutes is not None,
            key="target_manual_chk",
            help="勾选 = 你自己定;不勾 = LLM 故事判断 / 字数启发 / 25 分钟兜底",
        )

        if manual:
            default_val = float(state.user_target_minutes or current_target)
            new_target = st.number_input(
                "目标分钟(8-50)",
                min_value=8.0, max_value=50.0,
                value=default_val,
                step=1.0, key="target_value",
            )
            apply_btn = st.button("✅ 应用 + 重跑节奏", use_container_width=True, type="primary")
            if apply_btn:
                state.user_target_minutes = float(new_target)
                state.save()
                if STAGE_ORDER.index(state.stage) >= STAGE_ORDER.index(Stage.PACED):
                    state.invalidate_from(Stage.PACED)
                    maybe_start_pipeline(state.workspace, Stage.SCORED)
                st.rerun()
        else:
            # 切回自动:清掉 user_target_minutes(若有)
            if state.user_target_minutes is not None:
                state.user_target_minutes = None
                state.save()


def render_run_summary_download(state: DramaState) -> None:
    """Sidebar: export a compact JSON summary for debugging and downstream review."""
    summary = build_run_summary(state)
    payload = json.dumps(to_serializable(summary), ensure_ascii=False, indent=2)
    with st.sidebar:
        st.divider()
        st.download_button(
            "📥 下载运行摘要 JSON",
            data=payload.encode("utf-8"),
            file_name=f"{state.project_id or 'project'}_run_summary.json",
            mime="application/json",
            use_container_width=True,
        )


def _check_prompt_versions(state: DramaState) -> None:
    """检测 state 记录的 prompt 版本与当前代码版本是否一致.
    不一致 → UI 红条提示用户重跑相应 stage."""
    from prompts.story_card import VERSION as V_STORY_CARD
    from prompts.scene_match import VERSION as V_SCENE_MATCH
    from prompts.hook_rewrite import VERSION as V_HOOK_REWRITE
    from prompts.emotion_score import VERSION as V_EMOTION_SCORE
    from prompts.compliance import VERSION as V_COMPLIANCE
    from prompts.storyboard import VERSION as V_STORYBOARD

    current = {
        "story_card": V_STORY_CARD,
        "scene_match": V_SCENE_MATCH,
        "hook_rewrite": V_HOOK_REWRITE,
        "emotion_score": V_EMOTION_SCORE,
        "compliance": V_COMPLIANCE,
        "storyboard": V_STORYBOARD,
    }
    stage_dep = {
        "story_card": Stage.CARDED,
        "scene_match": Stage.SCENE_MATCHED,
        "hook_rewrite": Stage.REWRITTEN,
        "emotion_score": Stage.SCORED,
        "compliance": Stage.SCORED,
        "storyboard": Stage.STORYBOARDED,
    }
    mismatches = []
    for module, recorded in state.prompt_versions.items():
        cur = current.get(module)
        if cur and cur != recorded:
            mismatches.append((module, recorded, cur, stage_dep.get(module)))
    if mismatches:
        with st.expander("⚠️ Prompt 已升级,部分阶段产物可能过期", expanded=True):
            for mod, old, new, stage in mismatches:
                st.markdown(f"- **{mod}** 用 v{old} 生成,当前 v{new}(建议重跑 `{stage.value if stage else '?'}` 阶段)")


# ---------------- UI components ----------------

def render_breadcrumb(state: DramaState) -> None:
    cols = st.columns(len(STAGE_ORDER))
    current_idx = STAGE_ORDER.index(state.stage)
    busy = pipeline_alive(state)

    for i, stage in enumerate(STAGE_ORDER):
        with cols[i]:
            label = STAGE_LABELS[stage]
            if i < current_idx:
                if busy:
                    st.button(f"✓ {label}", key=f"bc_{stage.value}", disabled=True, use_container_width=True)
                else:
                    if st.button(f"✓ {label}", key=f"bc_{stage.value}", use_container_width=True,
                                 help=f"重跑此阶段(会清除之后产物,自动 snapshot)"):
                        rerun_stage = stage
                        # 旧项目无 scene_match:重跑 PACED/REWRITTEN 会缺前置产物,
                        # 自动回退到 SCENE_MATCHED 先生成动态场景
                        if (state.scene_match is None
                                and STAGE_ORDER.index(stage) > STAGE_ORDER.index(Stage.SCENE_MATCHED)):
                            rerun_stage = Stage.SCENE_MATCHED
                        state.invalidate_from(rerun_stage)
                        target = Stage.SCORED if rerun_stage in [Stage.CARDED, Stage.SCENE_MATCHED, Stage.PACED, Stage.REWRITTEN, Stage.SCORED] else Stage.STORYBOARDED
                        maybe_start_pipeline(state.workspace, target)
                        st.rerun()
            elif i == current_idx:
                spinner = "🔄" if busy else "🔵"
                st.markdown(f"**{spinner} {label}**")
            else:
                st.markdown(f":gray[{label}]")


def render_story_card(state: DramaState) -> None:
    if not state.story_card:
        st.info("故事卡尚未生成")
        return
    card = state.story_card
    cols = st.columns(2)
    fields = [
        ("主角", card.protagonist), ("核心动机", card.motivation),
        ("世界观", card.world_setting), ("激励事件", card.inciting_incident),
        ("攀升", card.rising_action), ("中点反转", card.midpoint_twist),
        ("高潮", card.climax), ("结局", card.resolution),
    ]
    for i, (label, value) in enumerate(fields):
        with cols[i % 2]:
            st.markdown(f"**{label}**:{value or '_(待生成)_'}")


def render_scene_match(state: DramaState) -> None:
    from prompts.scene_library import SCENE_LIBRARY
    from agent.state import SceneMatchResult, SelectedScene

    if not state.scene_match or not state.scene_match.selected:
        st.info("场景尚未匹配")
        return

    sm = state.scene_match
    st.markdown(f"**匹配频道**:{sm.channel_inferred or '未判定'} | 共 {len(sm.selected)} 个场景")
    rows = [
        {
            "#": i,
            "频道": s.channel,
            "题材": s.genre,
            "爬点": "/".join(s.hook_tags),
            "入选理由": s.reason or "—",
        }
        for i, s in enumerate(sm.selected)
    ]
    st.dataframe(rows, hide_index=True, use_container_width=True)

    # 人工换场景:每个槽位可从全库替换
    busy = pipeline_alive(state)
    with st.expander("✏️ 手动调整场景(替换后会重跑重构 + 评分)", expanded=False):
        if busy:
            st.caption("pipeline 运行中,暂不可调整")
            return
        lib_ids = [e["id"] for e in SCENE_LIBRARY]
        by_id = {e["id"]: e for e in SCENE_LIBRARY}

        def _fmt(eid: str) -> str:
            e = by_id[eid]
            return f"{e['channel']}·{e['genre']}｜{'/'.join(e['hook_tags'])}"

        new_ids = []
        for i, s in enumerate(sm.selected):
            default_idx = lib_ids.index(s.id) if s.id in lib_ids else 0
            picked = st.selectbox(
                f"槽位 {i}", options=lib_ids, index=default_idx,
                format_func=_fmt, key=f"scene_slot_{i}",
            )
            new_ids.append(picked)

        changed = new_ids != [s.id for s in sm.selected]
        if st.button("✅ 应用场景调整并重跑", type="primary", disabled=not changed):
            new_selected = [
                SelectedScene(
                    id=e["id"], channel=e["channel"], genre=e["genre"],
                    hook_tags=list(e["hook_tags"]), one_liner=e["one_liner"],
                    reason="手动指定",
                )
                for e in (by_id[i] for i in new_ids)
            ]
            state.scene_match = SceneMatchResult(
                selected=new_selected, channel_inferred=sm.channel_inferred,
            )
            state.save()
            # 场景变了 → 重构起的产物失效;scene_match 自身保留(在 REWRITTEN 之前)
            if STAGE_ORDER.index(state.stage) >= STAGE_ORDER.index(Stage.REWRITTEN):
                state.invalidate_from(Stage.REWRITTEN)
            maybe_start_pipeline(state.workspace, Stage.SCORED)
            st.rerun()


def render_pacing(state: DramaState) -> None:
    if not state.pacing_plan:
        st.info("节奏未规划")
        return
    p = state.pacing_plan
    seg_data = [
        {"段名": s.name, "占比": f"{int(s.proportion * 100)}%",
         "目标字数": s.word_target, "目标镜头": s.shot_target}
        for s in p.segments
    ]
    st.dataframe(seg_data, hide_index=True, use_container_width=True)
    hd = p.hook_distribution
    total = hd.suspense + hd.twist + hd.emotion + hd.info + hd.crisis
    st.markdown(
        f"**钩子分布**(共 {total} 个):"
        f"悬疑 {hd.suspense} | 反转 {hd.twist} | 情感 {hd.emotion} | 信息 {hd.info} | 危机 {hd.crisis}"
    )


def render_variants(state: DramaState) -> None:
    if not state.variants:
        st.info("变体尚未生成")
        return

    n = len(state.variants)
    st.markdown(f"**{n} 个场景变体**(主评/副评/仲裁三视角)")

    rows = []
    failed_indices = []  # 评分失败的变体
    for i, v in enumerate(state.variants):
        # 失败可见化 (#1)
        err = state.score_errors.get(i)
        if err:
            failed_indices.append((i, v.emotion_type, err))

        primary = state.primary_scores[i].total if i < len(state.primary_scores) and state.primary_scores[i] else 0.0
        cross = state.cross_scores[i].total if i < len(state.cross_scores) and state.cross_scores[i] else 0.0
        final = state.final_scores[i] if i < len(state.final_scores) else 0.0
        arb = state.arbiter_scores.get(i)
        report = next((r for r in state.compliance_reports if r.target_id == f"variant-{i}"), None)
        ip_report = next((r for r in state.ip_risk_reports if r.target_id == f"variant-{i}"), None)
        blocks = sum(1 for x in (report.issues if report else []) if x.severity == "block")
        warns = sum(1 for x in (report.issues if report else []) if x.severity == "warn")
        rewrite_cnt = state.rewrite_counts[i] if i < len(state.rewrite_counts) else 0

        if err:
            final_disp = "⚠️ 失败"
            primary_disp = cross_disp = "—"
        else:
            final_disp = f"{final:.1f}"
            primary_disp = f"{primary:.1f}"
            cross_disp = f"{cross:.1f}"

        rows.append({
            "#": i,
            "场景": v.emotion_type,
            "final": final_disp,
            "主评": primary_disp,
            "副评": cross_disp,
            "仲裁": f"{arb.total:.1f}" if arb else "—",
            "重写": rewrite_cnt,
            "合规": ("⛔" * blocks + "⚠️" * warns) or "✓",
            "侵权风险": f"{ip_report.risk_level}/{ip_report.launch_advice}" if ip_report else "—",
        })
    st.dataframe(rows, hide_index=True, use_container_width=True)

    # 评分失败警告 + 重试入口
    if failed_indices and not pipeline_alive(state):
        for idx, et, err in failed_indices:
            st.warning(f"⚠️ 变体 {idx} ({et}) 评分失败: {err}")
        if st.button("🔁 重新评分(只重跑评分阶段)", key="retry_score"):
            state.invalidate_from(Stage.SCORED)
            maybe_start_pipeline(state.workspace, Stage.SCORED)
            st.rerun()

    # 详情 + 选择
    if state.stage in [Stage.SCORED, Stage.SELECTED, Stage.STORYBOARDED, Stage.EXPORTED]:
        default_idx = state.selected_variant_idx if state.selected_variant_idx is not None else 0
        def _variant_label(i: int) -> str:
            if state.score_errors.get(i):
                return f"【{state.variants[i].emotion_type}】⚠️ 失败"
            final = state.final_scores[i] if i < len(state.final_scores) else 0.0
            return f"【{state.variants[i].emotion_type}】final={final:.1f}"

        chosen = st.radio(
            "选定一个变体进入分镜阶段:",
            options=list(range(n)),
            format_func=_variant_label,
            index=default_idx,
            horizontal=True,
            key="variant_radio",
        )

        v = state.variants[chosen]
        with st.expander(f"📖 详情 — {v.emotion_type}", expanded=True):
            quality = assess_variant_quality(v, state.pacing_plan)
            target_text = str(quality.target_chars) if quality.target_chars else "-"
            ratio_text = f"{quality.target_ratio:.0%}" if quality.target_chars else "-"
            st.markdown(
                f"**质量指标**：字数 {quality.char_count}/{target_text} "
                f"| 目标比例 {ratio_text} "
                f"| 段标记 {quality.segment_markers_present}/4"
            )
            for check in quality.checks:
                if not check.ok:
                    st.caption(f"⚠️ {check.name}: {check.detail}")
            st.markdown(f"**钩子总结**:{v.hook_summary}")
            st.markdown(f"**情绪定位**:{v.emotion_positioning}")
            st.markdown(f"**开场**:{v.opening_lines}")
            st.markdown("**完整重写**:")
            st.text(v.full_rewrite)

            ip_report = next((r for r in state.ip_risk_reports if r.target_id == f"variant-{chosen}"), None)
            if ip_report:
                risk_icon = {"低": "🟢", "中": "🟡", "高": "🟠", "极高": "🔴"}.get(ip_report.risk_level, "🟡")
                st.markdown(f"**侵权风险初筛**：{risk_icon} {ip_report.risk_level}｜{ip_report.launch_advice}")
                if ip_report.summary:
                    st.caption(ip_report.summary)
                with st.expander("查看侵权风险依据与修改建议"):
                    if ip_report.basis:
                        st.markdown("**判断依据**")
                        for item in ip_report.basis:
                            st.markdown(f"- {item}")
                    if ip_report.risk_points:
                        st.markdown("**风险点**")
                        for point in ip_report.risk_points:
                            st.markdown(f"- [{point.severity}] **{point.dimension}**：{point.detail}")
                            if point.suggestion:
                                st.caption(f"建议：{point.suggestion}")
                    if ip_report.must_change:
                        st.markdown("**必须修改**")
                        for item in ip_report.must_change:
                            st.markdown(f"- {item}")
                    if ip_report.safe_points:
                        st.markdown("**相对安全点**")
                        for item in ip_report.safe_points:
                            st.markdown(f"- {item}")
                    st.caption(ip_report.disclaimer)

            report = next((r for r in state.compliance_reports if r.target_id == f"variant-{chosen}"), None)
            if report and report.issues:
                st.markdown("**合规问题**")
                for issue in report.issues:
                    icon = {"block": "⛔", "warn": "⚠️", "info": "ℹ️"}.get(issue.severity, "•")
                    st.markdown(f"{icon} [{issue.category}] **{issue.text_span}** — {issue.reason}")
                    if issue.suggestion:
                        st.caption(f"建议:{issue.suggestion}")

            # 单变体下载(仅重写文本)
            buf = export_rewrite(state.script.title if state.script else "重写", v.emotion_type, v.full_rewrite)
            st.download_button(
                "📥 仅下载此变体重写文本",
                data=buf,
                file_name=f"{state.script.title if state.script else '重写'}_{v.emotion_type}.docx",
                mime="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                key=f"dl_variant_{chosen}",
            )

        if state.stage == Stage.SCORED and not pipeline_alive():
            chosen_failed = bool(state.score_errors.get(chosen))
            if chosen_failed:
                st.warning(f"变体 {chosen} 评分失败，请选择其他变体或重新评分后再生成分镜。")
            if st.button("🎬 选定此变体并生成分镜", type="primary", disabled=chosen_failed):
                state.selected_variant_idx = chosen
                state.advance_to(Stage.SELECTED)
                maybe_start_pipeline(state.workspace, Stage.STORYBOARDED)
                st.rerun()


def render_storyboard(state: DramaState) -> None:
    if not state.storyboard:
        st.info("分镜尚未生成")
        return
    sb = state.storyboard
    quality = assess_storyboard_quality(sb, state.pacing_plan)
    target_text = str(quality.target_shots) if quality.target_shots else "-"
    ratio_text = f"{quality.target_ratio:.0%}" if quality.target_shots else "-"
    st.markdown(f"**【{sb.emotion_type}】总时长 {sb.total_duration_seconds}s | 镜头 {len(sb.shots)}**")
    st.markdown(
        f"**质量指标**：镜头 {quality.shot_count}/{target_text} "
        f"| 目标比例 {ratio_text} "
        f"| 统计/声明时长 {quality.total_duration_seconds}s/{quality.declared_duration_seconds}s "
        f"| 时长差 {quality.duration_delta_seconds:+d}s "
        f"| 后置问题 {quality.validation_issue_count} "
        f"| negative prompt 异常 {quality.invalid_negative_prompt_count}"
    )
    for check in quality.checks:
        if not check.ok:
            st.caption(f"⚠️ {check.name}: {check.detail}")

    rows = []
    flagged_shots = []  # 后置验证标记问题的镜头
    for shot in sb.shots:
        flag = "⚠️" if shot.validation_issues else ""
        rows.append({
            "#": shot.shot_number,
            "校验": flag,
            "片段编号": shot.fragment_id,
            "源段": shot.source_anchor or "-",
            "景别": shot.shot_type,
            "时长": f"{shot.duration_seconds}秒",
            "画面描述": shot.visual_description[:80],
            "BGM": shot.bgm_mood,
            "运镜": shot.camera_movement,
        })
        if shot.validation_issues:
            flagged_shots.append(shot)
    st.dataframe(rows, hide_index=True, use_container_width=True)

    # 后置验证发现的逻辑问题
    if flagged_shots:
        with st.expander(f"⚠️ 后置验证标记 {len(flagged_shots)} 个问题镜头", expanded=True):
            for s in flagged_shots:
                st.markdown(f"**{s.fragment_id}** (source: {s.source_anchor})")
                for iss in s.validation_issues:
                    t = iss.get("type", "?") if isinstance(iss, dict) else "?"
                    d = iss.get("detail", "") if isinstance(iss, dict) else str(iss)
                    st.markdown(f"  - 🔴 [{t}] {d}")
                st.caption(f"画面: {s.visual_description[:120]}")
                st.divider()

    sb_report = next((r for r in state.compliance_reports if r.target_id == "storyboard"), None)
    if sb_report and sb_report.issues:
        with st.expander("⚠️ 分镜合规扫描"):
            for issue in sb_report.issues:
                icon = {"block": "⛔", "warn": "⚠️", "info": "ℹ️"}.get(issue.severity, "•")
                st.markdown(f"{icon} [{issue.category}] **{issue.text_span}** — {issue.reason}")

    col1, col2 = st.columns(2)
    title = state.script.title if state.script else "分镜"
    with col1:
        word_buf = export_storyboard_word(title, sb)
        st.download_button(
            "📥 下载分镜 Word",
            data=word_buf,
            file_name=f"{title}_{sb.emotion_type}_分镜.docx",
            mime="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            type="primary",
            use_container_width=True,
        )
    with col2:
        json_buf = export_video_prompts(sb)
        st.download_button(
            "📥 下载 video_prompts.json",
            data=json_buf,
            file_name=f"{title}_{sb.emotion_type}_video_prompts.json",
            mime="application/json",
            use_container_width=True,
        )


# ---------------- main ----------------

def main():
    st.set_page_config(page_title="短剧钩子重构 Agent", page_icon="🎬", layout="wide")
    st.title("🎬 短剧钩子重构 Agent")
    st.caption("上传 .docx → 8 张故事卡 → 漫剧场景匹配 → 节奏规划 → 5 场景变体并行 → 三视角评分循环 → 选定 → 分镜 → 双格式导出")

    # Sidebar:项目管理
    with st.sidebar:
        st.subheader("📂 项目")
        existing = sorted([p for p in WORKSPACE_ROOT.iterdir()
                          if p.is_dir() and (p / "state.json").exists()],
                         key=lambda p: p.stat().st_mtime, reverse=True)
        if existing:
            options = ["（新建）"] + [p.name for p in existing[:20]]
            picked = st.selectbox("打开历史项目", options, index=0)
            if picked != "（新建）":
                ws = WORKSPACE_ROOT / picked
                st.session_state["workspace_path"] = str(ws)
        if st.button("🆕 新建项目", use_container_width=True):
            st.session_state.pop("workspace_path", None)
            st.session_state.pop("pipeline_thread", None)
            st.rerun()

        st.divider()
        st.caption("**工作区**:`./.workspaces/<id>/`")
        st.caption("- `state.json` 索引")
        st.caption("- `variants.json` / `storyboard.json` 大字段")
        st.caption("- `snapshots/` 时间戳快照")

    # 无 workspace → 等待上传
    if "workspace_path" not in st.session_state:
        uploaded = st.file_uploader("上传剧本（.docx）", type=["docx"])
        if uploaded:
            with st.spinner("解析剧本..."):
                state = DramaState.create(workspace_root=WORKSPACE_ROOT)
                state.script = parse_docx(uploaded)
                state.advance_to(Stage.PARSED)
                st.session_state["workspace_path"] = str(state.workspace)
            maybe_start_pipeline(state.workspace, Stage.SCORED)
            st.rerun()
        st.info("👈 选择历史项目或上传新剧本")
        return

    # 加载 workspace
    workspace = Path(st.session_state["workspace_path"])
    try:
        state = DramaState.load(workspace)
    except FileNotFoundError:
        st.error(f"workspace 不存在:{workspace}")
        st.session_state.pop("workspace_path", None)
        return

    # 目标时长和运行摘要 sidebar 面板
    render_target_minutes_panel(state)
    render_run_summary_download(state)

    # 顶部信息
    if state.script:
        st.success(
            f"📄 **{state.script.title}** | 场景 {len(state.script.scenes)} | "
            f"原文字数 {len(state.script.raw_text)} | 项目 ID `{state.project_id}`"
        )

    # Breadcrumb
    render_breadcrumb(state)

    # 续跑按钮:pipeline 死了但还没到终点(典型:重启后想接着跑)
    busy = pipeline_alive(state)
    if busy:
        info = state.read_pipeline_lock()
        started_at = float(info.get("started_at") or state.current_work_started_at or 0)
        lock_elapsed = int(time.time() - started_at) if started_at else 0
        target_label = info.get("target_stage") or "?"
        holder = f"pid={info.get('pid', '?')}@{info.get('hostname', '?')}"
        st.caption(f"🔒 Pipeline lock: `{target_label}` | {holder} | 已持有 {lock_elapsed}s")
    needs_resume = (
        not busy
        and state.stage not in (Stage.SCORED, Stage.EXPORTED)
        and state.script is not None
    )
    if needs_resume:
        if state.stage == Stage.SELECTED:
            target = Stage.STORYBOARDED
            label = "▶️ 继续生成分镜"
        else:
            target = Stage.SCORED
            label = "▶️ 继续运行 pipeline(从当前阶段)"
        if st.button(label, type="primary"):
            maybe_start_pipeline(state.workspace, target)
            st.rerun()

    st.divider()

    # 错误日志(若有)
    err_path = workspace / "error.log"
    if err_path.exists() and err_path.stat().st_size > 0:
        with st.expander("⚠️ 错误日志"):
            st.code(err_path.read_text(encoding="utf-8")[-2000:])

    # Stage 错误(state.stage_errors 来自 maybe_start_pipeline 异常捕获)
    if state.stage_errors:
        for stage_name, err in state.stage_errors.items():
            st.error(f"⚠️ 阶段 [{stage_name}] 失败: {err}")

    # Prompt 版本 mismatch 警告 (#4)
    _check_prompt_versions(state)

    # 阶段产物
    with st.expander("📚 故事卡(8 张)", expanded=(state.stage == Stage.CARDED)):
        render_story_card(state)

    with st.expander("🎯 漫剧场景匹配(5 选)", expanded=(state.stage == Stage.SCENE_MATCHED)):
        render_scene_match(state)

    with st.expander("⚖️ 节奏规划", expanded=(state.stage == Stage.PACED)):
        render_pacing(state)

    with st.expander(
        "✍️ 5 变体 + 三视角评分",
        expanded=(state.stage in [Stage.REWRITTEN, Stage.SCORED, Stage.SELECTED]),
    ):
        render_variants(state)

    with st.expander(
        "🎬 分镜 + 导出",
        expanded=(state.stage in [Stage.STORYBOARDED, Stage.EXPORTED]),
    ):
        render_storyboard(state)

    # 自动轮询:pipeline 还在跑就 1.5s 后 rerun
    if pipeline_alive(state):
        # 当前阶段已运行时长 (#3-lite)
        elapsed = int(time.time() - state.current_work_started_at) if state.current_work_started_at else 0
        next_stage_idx = min(STAGE_ORDER.index(state.stage) + 1, len(STAGE_ORDER) - 1)
        running_label = STAGE_LABELS[STAGE_ORDER[next_stage_idx]]
        elapsed_str = f"{elapsed // 60} 分 {elapsed % 60} 秒" if elapsed >= 60 else f"{elapsed} 秒"
        with st.spinner(f"⏳ 运行中: {running_label} | 已运行 {elapsed_str}"):
            time.sleep(POLL_INTERVAL)
        st.rerun()


if __name__ == "__main__":
    main()
else:
    # streamlit 直接运行时也调用
    main()
