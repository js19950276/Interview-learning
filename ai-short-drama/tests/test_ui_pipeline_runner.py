from __future__ import annotations

import tempfile
from pathlib import Path

from agent.state import DramaState, Stage
from ui.pipeline_runner import pipeline_alive


def test_pipeline_alive_uses_workspace_lock_when_no_session_thread():
    with tempfile.TemporaryDirectory() as tmp:
        state = DramaState.create(Path(tmp))
        assert pipeline_alive(state) is False
        assert state.acquire_pipeline_lock(target_stage=Stage.SCORED) is True
        try:
            assert pipeline_alive(state) is True
        finally:
            state.release_pipeline_lock()
