from __future__ import annotations

import logging
from dataclasses import dataclass
from agent.llm import call_llm_messages_json, call_llm_messages
from prompts.hook_rewrite import PROMPT, REWRITE_PROMPT, TEXT_PROMPT, EMOTION_TYPES

log = logging.getLogger("hook_rewriter")


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


@dataclass
class Variant:
    emotion_type: str
    opening_lines: str
    visual_description: str
    emotion_positioning: str
    hook_summary: str
    full_rewrite: str


def _parse_variant(v: dict) -> Variant:
    return Variant(
        emotion_type=v["emotion_type"],
        opening_lines=v["opening_lines"],
        visual_description=v["visual_description"],
        emotion_positioning=v["emotion_positioning"],
        hook_summary=v["hook_summary"],
        full_rewrite=v["full_rewrite"],
    )


def rewrite_single(script_text: str, emotion_type: str, emotion_desc: str) -> Variant:
    messages = _format_messages(
        PROMPT,
        script_text=script_text,
        emotion_type=emotion_type,
        emotion_desc=emotion_desc,
    )
    v = call_llm_messages_json(messages)
    return _parse_variant(v)


def rewrite_hooks(script_text: str, on_progress=None) -> list[Variant]:
    from concurrent.futures import ThreadPoolExecutor, as_completed

    def _task(i, emotion_type, emotion_desc):
        log.info("开始生成变体 [%d/%d]: %s", i + 1, len(EMOTION_TYPES), emotion_type)
        variant = rewrite_single(script_text, emotion_type, emotion_desc)
        log.info("完成生成变体 [%d/%d]: %s", i + 1, len(EMOTION_TYPES), emotion_type)
        return i, emotion_type, variant

    log.info("并行生成 %d 个变体...", len(EMOTION_TYPES))
    variants = [None] * len(EMOTION_TYPES)
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = {
            pool.submit(_task, i, et, ed): i
            for i, (et, ed) in enumerate(EMOTION_TYPES)
        }
        done_count = 0
        for future in as_completed(futures):
            i, emotion_type, variant = future.result()
            variants[i] = variant
            done_count += 1
            log.info("进度 %d/%d，刚完成: %s", done_count, len(EMOTION_TYPES), emotion_type)
            if on_progress:
                on_progress(done_count, emotion_type)

    log.info("全部 %d 个变体生成完成", len(EMOTION_TYPES))
    return variants


def rewrite_single_text(script_text: str, emotion_type: str, emotion_desc: str) -> str:
    messages = _format_messages(
        TEXT_PROMPT,
        script_text=script_text,
        emotion_type=emotion_type,
        emotion_desc=emotion_desc,
    )
    return call_llm_messages(messages)


def rewrite_single_variant(variant: Variant, suggestions: str) -> Variant:
    messages = _format_messages(
        REWRITE_PROMPT,
        emotion_type=variant.emotion_type,
        full_rewrite=variant.full_rewrite,
        suggestions=suggestions,
    )
    v = call_llm_messages_json(messages)
    return _parse_variant(v)
