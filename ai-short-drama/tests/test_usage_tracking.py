"""Token 用量追踪测试:累计器 / 标签分组 / 快照差值 / state roundtrip."""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.llm import (
    get_usage_tag,
    record_usage,
    reset_usage,
    set_usage_tag,
    usage_delta,
    usage_snapshot,
)
from agent.state import DramaState


def _u(prompt=100, completion=50, cache_read=0):
    return {"prompt_tokens": prompt, "completion_tokens": completion,
            "total_tokens": prompt + completion, "cache_read_input_tokens": cache_read}


def test_record_and_snapshot():
    reset_usage()
    set_usage_tag("rewritten")
    record_usage(_u(prompt=100))
    record_usage(_u(prompt=30, completion=70))
    set_usage_tag("scored")
    record_usage(_u(prompt=10, completion=5, cache_read=8))
    snap = usage_snapshot()
    assert snap["rewritten"]["calls"] == 2
    assert snap["rewritten"]["prompt_tokens"] == 130
    assert snap["rewritten"]["completion_tokens"] == 120
    assert snap["scored"]["cache_read_tokens"] == 8
    reset_usage()
    assert usage_snapshot() == {}
    print("[PASS] test_record_and_snapshot")


def test_record_empty_usage_is_noop():
    reset_usage()
    record_usage({})
    record_usage(None)
    assert usage_snapshot() == {}
    print("[PASS] test_record_empty_usage_is_noop")


def test_usage_delta():
    before = {"scored": {"calls": 2, "prompt_tokens": 100}}
    after = {"scored": {"calls": 5, "prompt_tokens": 300},
             "rewritten": {"calls": 1, "prompt_tokens": 10}}
    delta = usage_delta(before, after)
    assert delta["scored"] == {"calls": 3, "prompt_tokens": 200}
    assert delta["rewritten"] == {"calls": 1, "prompt_tokens": 10}
    # 无增量 → 空
    assert usage_delta(after, after) == {}
    print("[PASS] test_usage_delta")


def test_usage_tag_roundtrip():
    set_usage_tag("")   # reset_usage 只清累计,不清标签;这里显式复位
    assert get_usage_tag() == "other"
    set_usage_tag("paced")
    assert get_usage_tag() == "paced"
    set_usage_tag("")
    assert get_usage_tag() == "other"
    print("[PASS] test_usage_tag_roundtrip")


def test_usage_by_stage_roundtrip():
    with tempfile.TemporaryDirectory() as tmp:
        state = DramaState.create(workspace_root=Path(tmp))
        state.usage_by_stage = {"rewritten": {"calls": 4, "prompt_tokens": 1000,
                                              "completion_tokens": 500, "total_tokens": 1500,
                                              "cache_read_tokens": 200, "cache_write_tokens": 0}}
        state.save()
        loaded = DramaState.load(Path(tmp) / state.project_id)
        assert loaded.usage_by_stage["rewritten"]["calls"] == 4
        assert loaded.usage_by_stage["rewritten"]["prompt_tokens"] == 1000
    print("[PASS] test_usage_by_stage_roundtrip")


if __name__ == "__main__":
    test_record_and_snapshot()
    test_record_empty_usage_is_noop()
    test_usage_delta()
    test_usage_tag_roundtrip()
    test_usage_by_stage_roundtrip()
    print("\nAll usage tracking tests passed.")
