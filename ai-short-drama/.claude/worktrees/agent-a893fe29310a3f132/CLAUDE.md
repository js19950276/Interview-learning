# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

短剧钩子重构 Agent — 输入 Word 剧本，通过 llm-proxy 进行钩子重构、情绪评分、分镜脚本生成，输出 Word 格式分镜脚本。面向抖音/红果短剧场景。

## Tech Stack

- Python 3.9+
- llm-proxy (OpenAI 兼容接口，模型: auto-std，API key 从 ~/.dcc/config.json 读取)
- httpx (HTTP 客户端)
- python-docx (Word 文档读写)
- Streamlit (Web UI)

## Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Run the app
streamlit run app.py
```

## Architecture

```
agent/          # 核心业务逻辑
  llm.py        — llm-proxy 封装 (OpenAI 兼容 /v1/chat/completions)
  parser.py     — Word 文档解析
  hook_rewriter.py — 钩子重构，生成5个情绪变体
  emotion_scorer.py — 情绪价值评分 (< 7分自动重写)
  storyboard.py — 分镜脚本生成
  exporter.py   — Word 分镜文档导出

prompts/        # Prompt 模板（与业务逻辑分离）
  hook_rewrite.py
  emotion_score.py
  storyboard.py

app.py          # Streamlit 入口
```

## Pipeline Flow

1. 上传 .docx 剧本 → `parser.py` 解析
2. `hook_rewriter.py` 生成 5 个情绪变体（复仇爽/治愈暖/职场共鸣/悬疑反转/女性觉醒）
3. `emotion_scorer.py` 评分（爽感/治愈/共鸣/逻辑/视觉），< 7 分重写（最多2次）
4. 用户选择变体 → `storyboard.py` 生成分镜
5. `exporter.py` 导出 Word 分镜文档

## Environment Variables

- `LLM_PROXY_API_KEY` — 可选，优先使用；未设置时从 `~/.dcc/config.json` 的 `api_key` 字段读取
