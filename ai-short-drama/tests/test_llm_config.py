from __future__ import annotations

import importlib
import logging
import sys


def test_llm_env_overrides_runtime_config(monkeypatch):
    monkeypatch.setenv("LLM_PROXY_MODEL", "test-model")
    monkeypatch.setenv("LLM_PROXY_TIMEOUT", "12.5")
    monkeypatch.setenv("LLM_PROXY_MAX_RETRIES", "4")
    monkeypatch.setenv("LLM_PROXY_API_URL", "http://example.test/")
    sys.modules.pop("agent.llm", None)

    llm = importlib.import_module("agent.llm")

    assert llm.MODEL == "test-model"
    assert llm.REQUEST_TIMEOUT == 12.5
    assert llm.DEFAULT_MAX_RETRIES == 4
    assert llm._get_api_url() == "http://example.test"


def test_import_does_not_configure_llm_logging(monkeypatch):
    root = logging.getLogger()
    before = list(root.handlers)
    sys.modules.pop("agent.llm", None)

    importlib.import_module("agent.llm")

    assert list(root.handlers) == before


def test_setup_llm_logging_is_idempotent(tmp_path):
    import agent.llm as llm

    root = logging.getLogger()
    before = len(root.handlers)
    log_path = tmp_path / "llm_debug.log"

    llm.setup_llm_logging(str(log_path))
    after_first = len(root.handlers)
    llm.setup_llm_logging(str(log_path))

    assert len(root.handlers) == after_first
    assert after_first <= before + 2
