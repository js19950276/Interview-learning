"""IP/侵权风险初筛测试。"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.ip_risk import _build_messages, assess


def test_ip_risk_report_normalized():
    def mock_judge(source_text, rewritten_text):
        return {
            "risk_level": "高",
            "launch_advice": "暂不建议上线",
            "summary": "人物关系和关键桥段过近",
            "basis": ["主线顺序相似"],
            "risk_points": [
                {
                    "dimension": "主线结构",
                    "severity": "high",
                    "detail": "开局、反转、结局顺序接近",
                    "suggestion": "重排关键爆点",
                }
            ],
            "must_change": ["改掉开场触发事件"],
            "safe_points": ["未发现逐句台词照搬"],
            "disclaimer": "仅供测试",
        }

    report = assess("原稿", "魔改稿", target_id="variant-0", judge_fn=mock_judge)
    assert report.target_id == "variant-0"
    assert report.risk_level == "高"
    assert report.launch_advice == "暂不建议上线"
    assert report.has_high_risk
    assert report.risk_points[0].dimension == "主线结构"
    assert report.must_change == ["改掉开场触发事件"]
    print("[PASS] test_ip_risk_report_normalized")


def test_ip_risk_failure_fallback():
    def bad_judge(source_text, rewritten_text):
        raise RuntimeError("boom")

    report = assess("原稿", "魔改稿", target_id="variant-1", judge_fn=bad_judge)
    assert report.risk_level == "中"
    assert report.launch_advice == "修改后上线"
    assert report.risk_points
    print("[PASS] test_ip_risk_failure_fallback")


def test_build_messages_caches_source_prefix():
    """source_text 应落在带 cache_control 的前缀块,rewritten_text 在断点之后的块."""
    msgs = _build_messages("原始剧本素材XYZ", "魔改后文本ABC")
    assert msgs[0]["role"] == "system"
    user = msgs[1]
    assert user["role"] == "user"
    blocks = user["content"]
    assert isinstance(blocks, list) and len(blocks) == 2
    # 前缀块:含原稿 + cache_control;不含魔改文本(否则缓存键随变体变化失效)
    assert blocks[0]["cache_control"] == {"type": "ephemeral"}
    assert "原始剧本素材XYZ" in blocks[0]["text"]
    assert "魔改后文本ABC" not in blocks[0]["text"]
    # 易变块:含魔改文本 + schema,无 cache_control
    assert "cache_control" not in blocks[1]
    assert "魔改后文本ABC" in blocks[1]["text"]
    assert '"risk_level"' in blocks[1]["text"]
    print("[PASS] test_build_messages_caches_source_prefix")


if __name__ == "__main__":
    test_ip_risk_report_normalized()
    test_ip_risk_failure_fallback()
    test_build_messages_caches_source_prefix()
    print("\nAll IP risk tests passed.")
