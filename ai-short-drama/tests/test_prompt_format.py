"""测试 prompt 模板格式化是否正确生成 messages，以及 JSON 示例中的大括号不被吞掉。"""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prompts.hook_rewrite import PROMPT, REWRITE_PROMPT, SEGMENT_FIRST_PROMPT, SEGMENT_CONT_PROMPT
from prompts.emotion_score import PROMPT as SCORE_PROMPT, PERSONA_ROLES
from prompts.storyboard import PROMPT as STORYBOARD_PROMPT
from prompts.story_card import PROMPT as STORY_CARD_PROMPT
from prompts.compliance import PROMPT as COMPLIANCE_PROMPT
from prompts.scene_match import PROMPT as SCENE_MATCH_PROMPT


def _format_messages(prompt_template, **kwargs):
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


def test_hook_rewrite_prompt():
    messages = _format_messages(
        PROMPT,
        script_text="测试剧本内容",
        emotion_type="复仇爽感",
        emotion_desc="主角反杀",
        story_card_summary="主角=A,动机=B",
        pacing_constraints="起势 15%",
    )
    assert len(messages) == 2
    assert messages[0]["role"] == "system"
    assert messages[1]["role"] == "user"
    assert "测试剧本内容" in messages[1]["content"]
    assert "复仇爽感" in messages[1]["content"]
    assert "主角反杀" in messages[1]["content"]
    assert "主角=A,动机=B" in messages[1]["content"]
    assert "起势 15%" in messages[1]["content"]
    assert '"emotion_type"' in messages[1]["content"]
    assert '"full_rewrite"' in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  hook_rewrite prompt: OK")


def test_rewrite_single_prompt():
    messages = _format_messages(
        REWRITE_PROMPT,
        emotion_type="治愈暖心",
        full_rewrite="原始剧本",
        suggestions="建议加强情感",
        story_card_summary="共享故事卡",
        pacing_constraints="节奏分段",
    )
    assert len(messages) == 2
    assert "治愈暖心" in messages[1]["content"]
    assert "原始剧本" in messages[1]["content"]
    assert "建议加强情感" in messages[1]["content"]
    assert "共享故事卡" in messages[1]["content"]
    assert "节奏分段" in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  rewrite_single prompt: OK")


def test_emotion_score_prompt():
    messages = _format_messages(
        SCORE_PROMPT,
        emotion_type="职场共鸣",
        full_text="完整剧本文本",
        persona_role=PERSONA_ROLES["primary"],
    )
    assert len(messages) == 2
    assert "职场共鸣" in messages[1]["content"]
    assert "完整剧本文本" in messages[1]["content"]
    assert "运营总监" in messages[0]["content"]  # primary persona
    assert '"scores"' in messages[1]["content"]
    assert '"爽感"' in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  emotion_score prompt: OK")


def test_emotion_score_personas_distinct():
    """三个 persona 应注入不同的 system 文本."""
    text_for = lambda p: _format_messages(
        SCORE_PROMPT, emotion_type="x", full_text="y",
        persona_role=PERSONA_ROLES[p],
    )[0]["content"]
    sys_primary = text_for("primary")
    sys_secondary = text_for("secondary")
    sys_arbiter = text_for("arbiter")
    assert sys_primary != sys_secondary != sys_arbiter
    assert "运营总监" in sys_primary
    assert "用户研究员" in sys_secondary
    assert "编剧主编" in sys_arbiter
    print("  emotion_score personas distinct: OK")


def test_story_card_prompt():
    messages = _format_messages(STORY_CARD_PROMPT, raw_text="某个完整剧本")
    assert len(messages) == 2
    assert "某个完整剧本" in messages[1]["content"]
    assert '"protagonist"' in messages[1]["content"]
    assert '"climax"' in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  story_card prompt: OK")


def test_compliance_prompt():
    messages = _format_messages(
        COMPLIANCE_PROMPT,
        category="暴力", keyword="杀人", context="她拿起刀杀人",
    )
    assert len(messages) == 2
    assert "暴力" in messages[1]["content"]
    assert "杀人" in messages[1]["content"]
    assert '"is_violation"' in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  compliance prompt: OK")


def test_storyboard_prompt():
    from prompts.negative_vocab import vocab_listing
    messages = _format_messages(
        STORYBOARD_PROMPT,
        title="测试标题",
        emotion_type="悬疑反转",
        full_rewrite="完整剧本内容",
        pacing_constraints="起势 15%",
        negative_vocab=vocab_listing(),
    )
    assert len(messages) == 2
    assert "测试标题" in messages[1]["content"]
    assert "悬疑反转" in messages[1]["content"]
    assert '"shots"' in messages[1]["content"]
    assert '"shot_number"' in messages[1]["content"]
    assert '"fragment_id"' in messages[1]["content"]
    assert '"negative_prompt"' in messages[1]["content"]
    assert "模糊" in messages[1]["content"]  # 中文 vocab listing 注入
    assert "起势 15%" in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  storyboard prompt: OK")


def test_storyboard_segment_prompt():
    """分段分镜 prompt 用紧凑 story_synopsis 替代整篇 full_rewrite,省重复 token."""
    from prompts.storyboard import SEGMENT_PROMPT
    from prompts.negative_vocab import vocab_listing
    messages = _format_messages(
        SEGMENT_PROMPT,
        segment_name="风暴",
        segment_pct=35,
        segment_num=3,
        segment_num_str="03",
        segment_text="本段剧本片段正文",
        story_synopsis="场景方向: 复仇爽感\n钩子核心: 反杀打脸",
        target_shots=12,
        starting_shot_num=20,
        negative_vocab=vocab_listing(),
    )
    assert len(messages) == 2
    assert "本段剧本片段正文" in messages[1]["content"]
    assert "复仇爽感" in messages[1]["content"]
    assert "反杀打脸" in messages[1]["content"]
    assert '"shots"' in messages[1]["content"]
    assert "模糊" in messages[1]["content"]
    # full_rewrite 占位已移除:模板不再要求该字段(否则 format 会 KeyError)
    assert "{full_rewrite}" not in messages[1]["content"]
    assert "{{" not in messages[1]["content"] and "}}" not in messages[1]["content"]
    print("  storyboard segment prompt: OK")


def test_hook_rewrite_segment_prompts():
    first = _format_messages(
        SEGMENT_FIRST_PROMPT,
        segment_source="起势段对应的原稿片段",
        story_card_summary="主角=赘婿",
        emotion_type="都市赘婿·打脸",
        emotion_desc="赘婿逆袭",
        segment_name="起势",
        segment_pct=15,
        word_target=1440,
    )
    assert "都市赘婿·打脸" in first[1]["content"]
    assert "1440" in first[1]["content"]
    assert "起势" in first[1]["content"]
    assert "起势段对应的原稿片段" in first[1]["content"]
    assert '"segment_text"' in first[1]["content"]
    assert '"opening_lines"' in first[1]["content"]
    # 整篇 script_text 占位已移除,改为本段对应原稿片段 segment_source
    assert "{script_text}" not in first[1]["content"]
    assert "{{" not in first[1]["content"] and "}}" not in first[1]["content"]

    cont = _format_messages(
        SEGMENT_CONT_PROMPT,
        segment_source="攀升段对应的原稿片段",
        story_card_summary="主角=赘婿",
        emotion_type="都市赘婿·打脸",
        emotion_desc="赘婿逆袭",
        prev_tail="前文结尾...",
        segment_name="攀升",
        segment_pct=30,
        word_target=2880,
    )
    assert "攀升" in cont[1]["content"]
    assert "攀升段对应的原稿片段" in cont[1]["content"]
    assert "前文结尾" in cont[1]["content"]
    assert '"segment_text"' in cont[1]["content"]
    assert '"opening_lines"' not in cont[1]["content"]  # 后续段不带元数据
    assert "{script_text}" not in cont[1]["content"]
    assert "{{" not in cont[1]["content"] and "}}" not in cont[1]["content"]
    print("  hook_rewrite segment prompts: OK")


def test_scene_match_prompt():
    messages = _format_messages(
        SCENE_MATCH_PROMPT,
        n=5,
        story_card_summary="主角=赘婿,动机=打脸",
        candidates="- [M-zhuixu-dalian] (男频/都市赘婿｜打脸) 赘婿逆袭打脸",
    )
    assert len(messages) == 2
    assert "主角=赘婿" in messages[1]["content"]
    assert "M-zhuixu-dalian" in messages[1]["content"]
    assert '"selected"' in messages[1]["content"]
    assert '"channel_inferred"' in messages[1]["content"]
    assert "{{" not in messages[1]["content"]
    assert "}}" not in messages[1]["content"]
    print("  scene_match prompt: OK")


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
    test_emotion_score_personas_distinct()
    test_story_card_prompt()
    test_compliance_prompt()
    test_storyboard_prompt()
    test_storyboard_segment_prompt()
    test_hook_rewrite_segment_prompts()
    test_scene_match_prompt()
    test_json_fix()
    print("All tests passed!")
