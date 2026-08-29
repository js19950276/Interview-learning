import json
import logging
import os
import re
from pathlib import Path

import httpx

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("llm_debug.log", encoding="utf-8"),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("llm")

DCC_CONFIG_PATH = Path.home() / ".dcc" / "config.json"
DEFAULT_API_URL = "http://llm-proxy.intra.xiaojukeji.com"
MODEL = "auto-max"
REQUEST_TIMEOUT = 3000


def _load_config() -> dict:
    if DCC_CONFIG_PATH.exists():
        return json.loads(DCC_CONFIG_PATH.read_text())
    return {}


def _get_api_key() -> str:
    key = os.environ.get("LLM_PROXY_API_KEY")
    if key:
        return key
    config = _load_config()
    key = config.get("api_key")
    if key:
        return key.strip()
    raise RuntimeError("未找到 API Key，请在 ~/.dcc/config.json 中配置 api_key 或设置环境变量 LLM_PROXY_API_KEY")


def _get_api_url() -> str:
    config = _load_config()
    return config.get("api_url") or DEFAULT_API_URL


def call_llm(
    system_prompt: str, user_prompt: str, max_tokens: int = 81920, json_mode: bool = False,
) -> str:
    api_url = _get_api_url()
    api_key = _get_api_key()

    body = {
        "model": MODEL,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }
    if json_mode:
        body["response_format"] = {"type": "json_object"}

    log.info(">>> LLM 请求: model=%s, json_mode=%s, messages=%d条, max_tokens=%d",
             MODEL, json_mode, len(body["messages"]), max_tokens)
    for i, msg in enumerate(body["messages"]):
        log.debug("  [msg %d] role=%s, content=%s", i, msg["role"], msg["content"][:200])

    response = httpx.post(
        f"{api_url}/v1/chat/completions",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=None,
    )

    log.info("<<< LLM 响应: status=%d", response.status_code)
    if response.status_code != 200:
        log.error("<<< 错误响应体: %s", response.text[:1000])
    response.raise_for_status()

    data = response.json()
    content = data["choices"][0]["message"]["content"]
    usage = data.get("usage", {})
    log.info("<<< usage: prompt_tokens=%s, completion_tokens=%s, total_tokens=%s",
             usage.get("prompt_tokens"), usage.get("completion_tokens"), usage.get("total_tokens"))
    log.debug("<<< 完整返回内容:\n%s", content[:2000])
    return content


def _fix_json(text: str) -> str:
    # 修复 JSON 字符串值内部的未转义换行符
    def _escape_newlines_in_strings(s: str) -> str:
        result = []
        in_string = False
        escape_next = False
        for ch in s:
            if escape_next:
                result.append(ch)
                escape_next = False
                continue
            if ch == '\\':
                result.append(ch)
                escape_next = True
                continue
            if ch == '"':
                in_string = not in_string
                result.append(ch)
                continue
            if in_string and ch == '\n':
                result.append('\\n')
                continue
            result.append(ch)
        return ''.join(result)

    text = _escape_newlines_in_strings(text)
    # 移除尾随逗号 (e.g. ",}" or ",]")
    text = re.sub(r',\s*([}\]])', r'\1', text)
    return text


def call_llm_json(system_prompt: str, user_prompt: str, max_tokens: int = 81920) -> dict:
    raw = call_llm(system_prompt, user_prompt, max_tokens, json_mode=True)
    return _parse_json(raw)


def call_llm_messages(messages: list[dict], max_tokens: int = 81920, json_mode: bool = False) -> str:
    api_url = _get_api_url()
    api_key = _get_api_key()

    body = {
        "model": MODEL,
        "max_tokens": max_tokens,
        "messages": messages,
    }
    if json_mode:
        body["response_format"] = {"type": "json_object"}

    log.info(">>> LLM 请求(messages): model=%s, json_mode=%s, messages=%d条, max_tokens=%d",
             MODEL, json_mode, len(messages), max_tokens)
    for i, msg in enumerate(messages):
        log.debug("  [msg %d] role=%s, content=%s", i, msg["role"], msg["content"][:200])

    response = httpx.post(
        f"{api_url}/v1/chat/completions",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=None,
    )

    log.info("<<< LLM 响应(messages): status=%d", response.status_code)
    if response.status_code != 200:
        log.error("<<< 错误响应体: %s", response.text[:1000])
    response.raise_for_status()

    data = response.json()
    content = data["choices"][0]["message"]["content"]
    usage = data.get("usage", {})
    log.info("<<< usage: prompt_tokens=%s, completion_tokens=%s, total_tokens=%s",
             usage.get("prompt_tokens"), usage.get("completion_tokens"), usage.get("total_tokens"))
    log.debug("<<< 完整返回内容:\n%s", content[:2000])
    return content


def call_llm_messages_json(messages: list[dict], max_tokens: int = 81920) -> dict:
    raw = call_llm_messages(messages, max_tokens, json_mode=True)
    return _parse_json(raw)


def _strip_codeblock(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        first_newline = text.find("\n")
        if first_newline != -1:
            text = text[first_newline + 1:]
        else:
            text = text[3:]
    if text.endswith("```"):
        text = text[:-3]
    return text.strip()


def _parse_json(raw: str) -> dict:
    raw = _strip_codeblock(raw)
    start = raw.find("{")
    end = raw.rfind("}") + 1
    if start == -1 or end == 0:
        start = raw.find("[")
        end = raw.rfind("]") + 1
    fragment = raw[start:end]
    try:
        return json.loads(fragment)
    except json.JSONDecodeError as e:
        log.warning("JSON 解析失败，尝试修复: %s", e)
        log.debug("原始 fragment :\n%s", fragment)
        try:
            fixed = _fix_json(fragment)
            result = json.loads(fixed)
            log.info("JSON 修复成功")
            return result
        except json.JSONDecodeError as e2:
            log.error("JSON 修复后仍然失败: %s", e2)
            log.error("修复后 fragment :\n%s", fixed)
            raise
