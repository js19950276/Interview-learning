"""合规扫描测试: 关键词命中 + 误报洗除(mock LLM)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.compliance import _extract_context, _scan_keywords, scan


def test_keyword_hits():
    text = "他犯下了凶杀案,无人能挡。"
    hits = _scan_keywords(text)
    cats = {h[0] for h in hits}
    assert "暴力" in cats, f"应命中'暴力'类别,实际: {cats}"
    print("[PASS] test_keyword_hits")


def test_extract_context_window():
    text = "abcdefghij" * 10
    ctx = _extract_context(text, 50, window=10)
    assert len(ctx) <= 21
    assert text[50] in ctx
    print("[PASS] test_extract_context_window")


def test_scan_violation_recorded():
    def mock_judge(category, keyword, context):
        return {
            "is_violation": True,
            "severity": "warn",
            "reason": "测试理由",
            "suggestion": "改写为更柔和的表达",
        }

    text = "他被强奸了。"
    report = scan(text, target_id="t1", llm_judge_fn=mock_judge)
    assert len(report.issues) == 1
    assert report.issues[0].category == "暴力"
    assert report.issues[0].severity == "warn"
    assert report.issues[0].suggestion == "改写为更柔和的表达"
    print("[PASS] test_scan_violation_recorded")


def test_scan_false_positive_filtered():
    """LLM 判为不违规(误报),issue 不被记录."""
    def mock_judge(category, keyword, context):
        return {"is_violation": False, "severity": "info", "reason": "上下文中性", "suggestion": ""}

    text = "未成年保护法是重要法律。"  # "未成年" 命中但中性
    report = scan(text, target_id="t2", llm_judge_fn=mock_judge)
    assert len(report.issues) == 0
    assert not report.has_blockers
    print("[PASS] test_scan_false_positive_filtered")


def test_blocker_severity():
    def mock_judge(category, keyword, context):
        return {"is_violation": True, "severity": "block", "reason": "红线", "suggestion": ""}

    text = "涉及未成年的不当情节。"
    report = scan(text, target_id="t3", llm_judge_fn=mock_judge)
    assert report.has_blockers
    print("[PASS] test_blocker_severity")


def test_dedup_same_keyword():
    """同一 (category, keyword) 多次命中只判一次."""
    call_count = [0]

    def mock_judge(category, keyword, context):
        call_count[0] += 1
        return {"is_violation": True, "severity": "warn", "reason": "x", "suggestion": ""}

    text = "凶杀。凶杀。凶杀。"
    report = scan(text, target_id="t4", llm_judge_fn=mock_judge)
    assert call_count[0] == 1, f"预期 1 次 LLM 调用,实际 {call_count[0]}"
    assert len(report.issues) == 1
    print("[PASS] test_dedup_same_keyword")


def test_judge_exception_falls_to_warn():
    def failing_judge(category, keyword, context):
        raise RuntimeError("LLM 不可用")

    text = "他被强奸了。"
    report = scan(text, target_id="t5", llm_judge_fn=failing_judge)
    assert len(report.issues) == 1
    assert report.issues[0].severity == "warn"
    print("[PASS] test_judge_exception_falls_to_warn")


def test_clean_text_no_issues():
    """完全干净的文本应无任何 issue."""
    def should_not_be_called(category, keyword, context):
        raise AssertionError("不应触发 LLM 判定")

    text = "今天天气真好,我们一起去公园散步。"
    report = scan(text, target_id="t6", llm_judge_fn=should_not_be_called)
    assert len(report.issues) == 0
    print("[PASS] test_clean_text_no_issues")


if __name__ == "__main__":
    test_keyword_hits()
    test_extract_context_window()
    test_scan_violation_recorded()
    test_scan_false_positive_filtered()
    test_blocker_severity()
    test_dedup_same_keyword()
    test_judge_exception_falls_to_warn()
    test_clean_text_no_issues()
    print("\nAll Phase 3 compliance tests passed.")
