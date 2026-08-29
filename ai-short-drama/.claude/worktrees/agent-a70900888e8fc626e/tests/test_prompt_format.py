"""测试 prompt 模板格式化是否正确生成 messages，以及 JSON 示例中的大括号不被吞掉。"""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prompts.hook_rewrite import PROMPT, REWRITE_PROMPT, EMOTION_TYPES
from prompts.emotion_score import PROMPT as SCORE_PROMPT
from prompts.storyboard import PROMPT as STORYBOARD_PROMPT


def _format_messages(prompt_template, **kwargs):
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


def test_hook_rewrite_prompt():
    messages = _format_messages(
        PROMPT,
        script_text="测试剧本内容",
        emotion_type="复仇爽感",
        emotion_desc="主角反杀",
    )
    assert len(messages) == 2
    assert messages[0]["role"] == "system"
    assert messages[1]["role"] == "user"
    # 变量被替换
    assert "测试剧本内容" in messages[1]["content"]
    assert "复仇爽感" in messages[1]["content"]
    assert "主角反杀" in messages[1]["content"]
    # JSON 示例中的大括号是单大括号（不是 {{ }}）
    assert '"emotion_type"' in messages[1]["content"]
    assert '"full_rewrite"' in messages[1]["content"]
    # 不应有残留的 {{ 或 }}
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  hook_rewrite prompt: OK")


def test_rewrite_single_prompt():
    messages = _format_messages(
        REWRITE_PROMPT,
        emotion_type="治愈暖心",
        full_rewrite="原始剧本",
        suggestions="建议加强情感",
    )
    assert len(messages) == 2
    assert "治愈暖心" in messages[1]["content"]
    assert "原始剧本" in messages[1]["content"]
    assert "建议加强情感" in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  rewrite_single prompt: OK")


def test_emotion_score_prompt():
    messages = _format_messages(
        SCORE_PROMPT,
        emotion_type="职场共鸣",
        opening_lines="开头台词",
        visual_description="画面描述",
        full_rewrite="完整剧本",
    )
    assert len(messages) == 2
    assert "职场共鸣" in messages[1]["content"]
    assert '"scores"' in messages[1]["content"]
    assert '"爽感"' in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  emotion_score prompt: OK")


def test_storyboard_prompt():
    messages = _format_messages(
        STORYBOARD_PROMPT,
        title="测试标题",
        emotion_type="悬疑反转",
        full_rewrite="完整剧本内容",
    )
    assert len(messages) == 2
    assert "测试标题" in messages[1]["content"]
    assert "悬疑反转" in messages[1]["content"]
    assert '"shots"' in messages[1]["content"]
    assert '"shot_number"' in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  storyboard prompt: OK")


def test_all_emotion_types_format():
    for emotion_type, emotion_desc in EMOTION_TYPES:
        messages = _format_messages(
            PROMPT,
            script_text="剧本",
            emotion_type=emotion_type,
            emotion_desc=emotion_desc,
        )
        assert emotion_type in messages[1]["content"]
        assert "{{" not in messages[1]["content"]
    print(f"  all {len(EMOTION_TYPES)} emotion types: OK")


def test_json_fix():
    from agent.llm import _fix_json
    # 测试尾随逗号修复
    assert json.loads(_fix_json('{"a": 1, "b": 2,}')) == {"a": 1, "b": 2}
    # 测试未转义换行修复
    fixed = _fix_json('{"text": "hello\nworld"}')
    assert json.loads(fixed) == {"text": "hello\nworld"}
    print("  json_fix: OK")


if __name__ == "__main__":
    print("Running prompt format tests...")
    test_hook_rewrite_prompt()
    test_rewrite_single_prompt()
    test_emotion_score_prompt()
    test_storyboard_prompt()
    test_all_emotion_types_format()
    test_json_fix()
    print("All tests passed!")
