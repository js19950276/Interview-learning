from langchain_core.prompts import ChatPromptTemplate

PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一位专业的短剧分镜脚本编写专家，擅长将文字剧本转化为可执行的分镜脚本。
你熟悉短视频的拍摄节奏，知道如何通过镜头语言强化情绪表达。

分镜脚本要求：
- 每个镜头时长控制在2-8秒（短视频节奏）
- 景别灵活切换，制造视觉节奏感
- 台词精炼，适合短视频呈现
- 注明关键音效和BGM情绪

重要：你的输出必须是合法的 JSON。文本内容中的特殊字符必须正确转义：
- 双引号 " → \\"
- 换行符 → \\n
- 反斜杠 \\ → \\\\
- 制表符 → \\t"""),
    ("human", """请将以下剧本转化为详细的分镜脚本：

---
剧本标题：{title}
情绪类型：{emotion_type}

完整剧本：
{full_rewrite}
---

请严格按以下 JSON 格式返回（不要添加任何其他文字）：

{{
  "title": "分镜脚本标题",
  "emotion_type": "{emotion_type}",
  "total_duration_seconds": 0,
  "shots": [
    {{
      "shot_number": 1,
      "shot_type": "景别（远景/全景/中景/近景/特写）",
      "duration_seconds": 0,
      "visual_description": "画面描述（场景、人物动作、光影氛围）",
      "dialogue": "台词/旁白（无则留空）",
      "sound_effects": "音效提示",
      "bgm_mood": "BGM情绪（紧张/温暖/激昂/悲伤等）",
      "emotion_note": "本镜头的情绪标注",
      "camera_movement": "运镜方式（固定/推/拉/摇/跟/航拍等）"
    }}
  ]
}}"""),
])
