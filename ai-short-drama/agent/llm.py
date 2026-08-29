from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

import httpx

RETRYABLE_HTTP_STATUSES = {429, 500, 502, 503, 504}
DEFAULT_MODEL = "auto-max"
DEFAULT_REQUEST_TIMEOUT = 600.0
DEFAULT_MAX_RETRIES = int(os.environ.get("LLM_PROXY_MAX_RETRIES", "2"))

log = logging.getLogger("llm")


def setup_llm_logging(log_path: str = "llm_debug.log") -> None:
    """显式初始化 LLM 日志.

    文件保留 DEBUG 细节但带轮转上限(10MB × 3),控制台只看 INFO 降噪.
    该函数幂等,避免 import agent.llm 时修改全局 logging 配置.
    """
    root = logging.getLogger()
    marker = "_llm_debug_handler"
    if any(getattr(h, marker, False) for h in root.handlers):
        return

    file_handler = RotatingFileHandler(
        log_path, maxBytes=10 * 1024 * 1024, backupCount=3, encoding="utf-8"
    )
    file_handler.setLevel(logging.DEBUG)
    setattr(file_handler, marker, True)

    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    setattr(console_handler, marker, True)

    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    file_handler.setFormatter(formatter)
    console_handler.setFormatter(formatter)

    root.setLevel(min(root.level or logging.DEBUG, logging.DEBUG))
    root.addHandler(file_handler)
    root.addHandler(console_handler)

DCC_CONFIG_PATH = Path.home() / ".dcc" / "config.json"
DEFAULT_API_URL = "http://llm-proxy.intra.xiaojukeji.com"
MODEL = os.environ.get("LLM_PROXY_MODEL", DEFAULT_MODEL)
# 单次 HTTP 请求超时(秒).超时后 _retry_json 会自动重试,避免无限等待.
# auto-max 大模型 + 长剧本(>5000 字)可能要 5-10 分钟生成,留 10 分钟给慢响应.
# 配合 2 次 retry,最坏情况一次 LLM 调用最多等 ~30 分钟.
REQUEST_TIMEOUT = float(os.environ.get("LLM_PROXY_TIMEOUT", str(DEFAULT_REQUEST_TIMEOUT)))


# 复用单个 httpx.Client(线程安全,可跨线程并发),省去每次调用重建连接/TLS 握手.
# 一次 pipeline run 有 30+ 次 LLM 调用,连接复用收益明显.
_client: httpx.Client | None = None
_client_lock = threading.Lock()


def _get_client() -> httpx.Client:
    global _client
    if _client is None:
        with _client_lock:
            if _client is None:
                _client = httpx.Client(timeout=REQUEST_TIMEOUT)
    return _client


# 缓存配置:api_key/url 运行期不变,避免每次 LLM 调用重复读盘
# (一次 pipeline run 30+ 次调用,每次 _get_api_url + _get_api_key 各读一遍 = 60+ 次磁盘读).
_config_cache: dict | None = None
_config_lock = threading.Lock()


def _load_config() -> dict:
    global _config_cache
    if _config_cache is None:
        with _config_lock:
            if _config_cache is None:
                _config_cache = (
                    json.loads(DCC_CONFIG_PATH.read_text())
                    if DCC_CONFIG_PATH.exists()
                    else {}
                )
    return _config_cache


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
    env_url = os.environ.get("LLM_PROXY_API_URL")
    if env_url:
        return env_url.rstrip("/")
    config = _load_config()
    return (config.get("api_url") or DEFAULT_API_URL).rstrip("/")


# Anthropic 式 prompt 缓存:proxy 透传 cache_control 到 Claude.
# 在「稳定且重复」的前缀块上打断点,后续相同前缀的请求按 ~0.1x 计费.
# 注:prefix 必须够长(Claude 端有最小可缓存 token 阈值)才会真正命中.
CACHE_CONTROL = {"type": "ephemeral"}


def _cache_system(messages: list[dict]) -> list[dict]:
    """给首条 system 消息的文本加 cache_control(系统提示是每类调用的稳定前缀).
    已是 content-block 列表的消息原样保留(调用方可能自带更细粒度的断点)."""
    out = []
    cached = False
    for m in messages:
        if not cached and m.get("role") == "system" and isinstance(m.get("content"), str):
            out.append({
                "role": "system",
                "content": [{"type": "text", "text": m["content"], "cache_control": CACHE_CONTROL}],
            })
            cached = True
        else:
            out.append(m)
    return out


def _log_usage(usage: dict, tag: str = "") -> None:
    details = usage.get("prompt_tokens_details") or {}
    cache_read = usage.get("cache_read_input_tokens") or details.get("cached_tokens")
    cache_write = usage.get("cache_creation_input_tokens")
    log.info(
        "<<< usage%s: prompt=%s completion=%s total=%s | cache_read=%s cache_write=%s",
        tag, usage.get("prompt_tokens"), usage.get("completion_tokens"),
        usage.get("total_tokens"), cache_read, cache_write,
    )


def _http_post(
    api_url: str,
    api_key: str,
    body: dict,
    max_retries: int = DEFAULT_MAX_RETRIES,
    log_tag: str = "",
) -> dict:
    """发送 LLM 请求,带超时/网络/可重试 HTTP 状态码的自动重试(指数退避).

    返回解析后的响应 JSON dict.非可重试错误或重试耗尽后抛出原异常.
    """
    url = f"{api_url}/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    last_err: Exception | None = None
    for attempt in range(max_retries + 1):
        try:
            response = _get_client().post(url, headers=headers, json=body)
            log.info("<<< LLM 响应%s: status=%d", log_tag, response.status_code)
            if response.status_code != 200:
                log.error("<<< 错误响应体%s: %s", log_tag, response.text[:1000])
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as e:
            if e.response.status_code not in RETRYABLE_HTTP_STATUSES:
                raise
            last_err = e
            log.warning("HTTP %d (attempt %d/%d) 可重试%s",
                        e.response.status_code, attempt + 1, max_retries + 1, log_tag)
        except (httpx.RequestError, httpx.TimeoutException) as e:
            last_err = e
            log.warning("网络/超时异常 (attempt %d/%d): %s%s",
                        attempt + 1, max_retries + 1, type(e).__name__, log_tag)

        if attempt < max_retries:
            wait = 2 ** attempt
            log.info("%ds 后重试", wait)
            time.sleep(wait)

    log.error("HTTP 请求重试 %d 次仍失败: %s", max_retries + 1, last_err)
    raise last_err if last_err else RuntimeError("Unknown HTTP error")


def call_llm(
    system_prompt: str, user_prompt: str, max_tokens: int = 81920, json_mode: bool = False,
) -> str:
    api_url = _get_api_url()
    api_key = _get_api_key()

    body = {
        "model": MODEL,
        "max_tokens": max_tokens,
        "messages": _cache_system([
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]),
    }
    if json_mode:
        body["response_format"] = {"type": "json_object"}

    log.info(">>> LLM 请求: model=%s, json_mode=%s, messages=%d条, max_tokens=%d",
             MODEL, json_mode, len(body["messages"]), max_tokens)
    log.debug("  [system] %s", system_prompt[:200])
    log.debug("  [user] %s", user_prompt[:200])

    data = _http_post(api_url, api_key, body)
    content = data["choices"][0]["message"]["content"]
    _log_usage(data.get("usage", {}) or {})
    log.debug("<<< 完整返回内容:\n%s", content[:2000])
    return content


def _fix_json(text: str) -> str:
    """修复 LLM 常见 JSON 输出问题:
    1. 字符串值内部未转义的换行/制表符
    2. 字符串值内部未转义的双引号(典型: 中文对话用了半角 ")
    3. 尾随逗号(",}" / ",]")

    算法: 状态机扫描. in_string 时遇 ", 向后看下一个非空白字符:
    - 是 JSON 终结符 (, ] } :) → 是合法闭合
    - 否则 → 是内嵌引号,自动转义为 \\"
    """
    def _walk(s: str) -> str:
        result = []
        in_string = False
        escape_next = False
        i = 0
        n = len(s)
        while i < n:
            ch = s[i]
            if escape_next:
                result.append(ch)
                escape_next = False
                i += 1
                continue
            if ch == '\\':
                result.append(ch)
                escape_next = True
                i += 1
                continue
            if ch == '"':
                if not in_string:
                    result.append(ch)
                    in_string = True
                else:
                    # 向后看:跳过空白后的下一个字符
                    j = i + 1
                    while j < n and s[j] in ' \t\r\n':
                        j += 1
                    next_ch = s[j] if j < n else ''
                    if next_ch in ',]}:' or next_ch == '':
                        # 合法闭合
                        result.append(ch)
                        in_string = False
                    else:
                        # 内嵌引号,转义
                        result.append('\\')
                        result.append('"')
                i += 1
                continue
            if in_string:
                if ch == '\n':
                    result.append('\\n')
                    i += 1
                    continue
                if ch == '\r':
                    result.append('\\r')
                    i += 1
                    continue
                if ch == '\t':
                    result.append('\\t')
                    i += 1
                    continue
            result.append(ch)
            i += 1
        return ''.join(result)

    text = _walk(text)
    # 尾随逗号
    text = re.sub(r',\s*([}\]])', r'\1', text)
    return text


def call_llm_json(
    system_prompt: str,
    user_prompt: str,
    max_tokens: int = 81920,
    max_retries: int = DEFAULT_MAX_RETRIES,
) -> dict:
    return _retry_json(
        lambda: call_llm(system_prompt, user_prompt, max_tokens, json_mode=True),
        max_retries=max_retries,
    )


def call_llm_messages(messages: list[dict], max_tokens: int = 81920, json_mode: bool = False) -> str:
    api_url = _get_api_url()
    api_key = _get_api_key()

    body = {
        "model": MODEL,
        "max_tokens": max_tokens,
        "messages": _cache_system(messages),
    }
    if json_mode:
        body["response_format"] = {"type": "json_object"}

    log.info(">>> LLM 请求(messages): model=%s, json_mode=%s, messages=%d条, max_tokens=%d",
             MODEL, json_mode, len(messages), max_tokens)
    for i, msg in enumerate(messages):
        content = msg["content"]
        preview = content[:200] if isinstance(content, str) else str(content)[:200]
        log.debug("  [msg %d] role=%s, content=%s", i, msg["role"], preview)

    data = _http_post(api_url, api_key, body, log_tag="(messages)")
    content = data["choices"][0]["message"]["content"]
    _log_usage(data.get("usage", {}) or {}, "(messages)")
    log.debug("<<< 完整返回内容:\n%s", content[:2000])
    return content


def call_llm_messages_json(
    messages: list[dict],
    max_tokens: int = 81920,
    max_retries: int = DEFAULT_MAX_RETRIES,
) -> dict:
    return _retry_json(
        lambda: call_llm_messages(messages, max_tokens, json_mode=True),
        max_retries=max_retries,
    )


def _retry_json(call_fn, max_retries: int = DEFAULT_MAX_RETRIES) -> dict:
    """JSON 调用带重试: 解析失败 / 空 {} → 指数退避.

    HTTP 层超时/网络/可重试状态码已由 _http_post 自动重试,此处只重试 JSON 语义问题.
    """
    last_err: Exception | None = None
    for attempt in range(max_retries + 1):
        try:
            raw = call_fn()
            result = _parse_json(raw)
            if not result:
                raise ValueError("LLM 返回空 JSON {} (无字段)")
            return result
        except json.JSONDecodeError as e:
            last_err = e
            log.warning("JSON 解析失败 (attempt %d/%d): %s",
                        attempt + 1, max_retries + 1, e)
        except ValueError as e:
            last_err = e
            log.warning("空 JSON (attempt %d/%d): %s",
                        attempt + 1, max_retries + 1, e)

        if attempt < max_retries:
            wait = 2 ** attempt
            log.info("%ds 后重试", wait)
            time.sleep(wait)

    log.error("LLM JSON 重试 %d 次仍失败: %s", max_retries + 1, last_err)
    raise last_err if last_err else RuntimeError("Unknown LLM error")


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


def safe_extract(data: dict, defaults: dict) -> dict:
    """从 LLM 返回的 dict 中安全提取字段。

    缺字段或类型不符时用 default 填充，不抛 KeyError/TypeError。
    """
    result = {}
    for key, default in defaults.items():
        val = data.get(key, default)
        if default is not None and not isinstance(val, type(default)):
            log.warning("safe_extract: 字段 '%s' 类型不符(期望 %s, 得到 %s)，使用默认值",
                        key, type(default).__name__, type(val).__name__)
            val = default
        result[key] = val
    return result
