"""Streamlit-aware pipeline thread management helpers."""
from __future__ import annotations

import threading
import time
import traceback
from pathlib import Path
from typing import Optional

import streamlit as st

from agent.pipeline import PipelineRun
from agent.state import DramaState, Stage


def maybe_start_pipeline(workspace: Path, target_stage: Stage) -> None:
    """Start a background pipeline thread if no session/workspace lock is active."""
    existing: Optional[threading.Thread] = st.session_state.get("pipeline_thread")
    if existing is not None and existing.is_alive():
        return

    state = DramaState.load(workspace)
    if not state.acquire_pipeline_lock(target_stage=target_stage):
        return

    def _run() -> None:
        try:
            s = DramaState.load(workspace)
            run = PipelineRun(s)
            run.resume_to(target_stage)
        except Exception as e:
            err_path = workspace / "error.log"
            with err_path.open("a", encoding="utf-8") as f:
                f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {e}\n")
                f.write(traceback.format_exc())
                f.write("\n---\n")
            try:
                s = DramaState.load(workspace)
                s.stage_errors["pipeline"] = f"{type(e).__name__}: {str(e)[:200]}"
                s.save()
            except Exception:
                pass
        finally:
            try:
                DramaState.load(workspace).release_pipeline_lock()
            except Exception:
                (workspace / ".pipeline.lock").unlink(missing_ok=True)

    t = threading.Thread(target=_run, daemon=True, name=f"pipeline-{workspace.name}")
    t.start()
    st.session_state["pipeline_thread"] = t


def pipeline_alive(state: Optional[DramaState] = None) -> bool:
    """Check both the Streamlit session thread and workspace lock."""
    t: Optional[threading.Thread] = st.session_state.get("pipeline_thread")
    if t is not None and t.is_alive():
        return True
    if state is not None:
        return state.is_pipeline_locked()
    return False
