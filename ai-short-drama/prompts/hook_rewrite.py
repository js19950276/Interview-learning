from langchain_core.prompts import ChatPromptTemplate

VERSION = "1.4.0"   # 1.4: 分段重写每段只发本段对应原稿片段(替代整篇重发,省重复 token);1.3: 分段重写(按节奏段逐段铺满字数,防 LLM 单次压缩);1.2: 动态场景驱动;1.1: 注入 story_card_summary + pacing_constraints

PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一位顶级短剧编剧和爆款内容策划专家，精通抖音/红果短剧的流量密码。
你深谙"强钩子"法则：每集开头必须让用户停留超过3秒不划走。

核心公式：悬念/冲突/情感暴击 + 视觉冲击

你的任务是对给定剧本进行"钩子重构"，按照指定的情绪维度生成一个高质量变体。

重要：你的输出必须是合法的 JSON。文本内容中的特殊字符必须正确转义：
- 双引号 " → \\"
- 换行符 → \\n
- 反斜杠 \\ → \\\\
- 制表符 → \\t"""),
    ("human", """以下是原始剧本内容：

---
{script_text}
---

【故事内核（共享于 5 变体）】
{story_card_summary}

【节奏与钩子约束】
{pacing_constraints}

请按照【{emotion_type}】这一情绪维度对剧本进行"钩子重构"。

情绪维度说明：{emotion_desc}

要求：
- **严格遵循上述故事内核**：不偏离主角动机/世界观/转折/结局，只在情绪着色与表达上做诠释
- **严格遵循节奏分段字数比例**（±5% 容差）和钩子分布
- 遵循"悬念/冲突/情感暴击 + 视觉冲击"公式
- 开头10秒必须抓住观众注意力
- 完整重写剧本，不是只改开头

请严格按以下 JSON 格式返回（不要添加任何其他文字）：

{{
  "emotion_type": "{emotion_type}",
  "opening_lines": "前10秒的台词（2-3句对白）",
  "visual_description": "画面描述（镜头语言、场景氛围）",
  "emotion_positioning": "情绪定位说明",
  "hook_summary": "一句话概括这个钩子的核心吸引力",
  "full_rewrite": "基于此情绪维度重写的完整剧本"
}}"""),
])

REWRITE_PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一位顶级短剧编剧和爆款内容策划专家，精通抖音/红果短剧的流量密码。
你深谙"强钩子"法则：每集开头必须让用户停留超过3秒不划走。

核心公式：悬念/冲突/情感暴击 + 视觉冲击

你的任务是对给定剧本进行"钩子重构"，按照指定的情绪维度生成一个高质量变体。

重要：你的输出必须是合法的 JSON。文本内容中的特殊字符必须正确转义：
- 双引号 " → \\"
- 换行符 → \\n
- 反斜杠 \\ → \\\\
- 制表符 → \\t"""),
    ("human", """以下是一个需要优化的短剧变体：

情绪类型：{emotion_type}

当前版本：
{full_rewrite}

评审给出的改进建议：
{suggestions}

【故事内核（共享于 5 变体）】
{story_card_summary}

【节奏与钩子约束】
{pacing_constraints}

请基于改进建议重写这个变体，保持相同的情绪类型与故事内核，但提升整体质量。

请严格按以下 JSON 格式返回（不要添加任何其他文字）：

{{
  "emotion_type": "{emotion_type}",
  "opening_lines": "优化后的前10秒台词",
  "visual_description": "优化后的画面描述",
  "emotion_positioning": "情绪定位说明",
  "hook_summary": "一句话概括钩子核心吸引力",
  "full_rewrite": "优化后的完整剧本"
}}"""),
])

_SEGMENT_SYSTEM = """你是一位顶级短剧编剧和爆款内容策划专家，精通抖音/红果短剧的流量密码，正在做剧本的"钩子重构"。
本次采用【分段重写】：整部剧按 起势/攀升/风暴/决战 四段推进，你每次只负责写其中一段。

铁律：
- **必须写满本段目标字数**(允许 ±10%),宁可把场景、对白、动作、心理铺细,也不要概括或跳写。字数不足是严重失败。
- 严格遵循给定的故事内核(主角动机/世界观/转折/结局),只在情绪着色与节奏上做诠释。全剧脉络以【故事内核】为准。
- 你只会拿到本段对应的那一段原始剧本素材(全剧脉络看故事内核),据此改写本段即可,不要臆造其他段的情节。
- 只输出本段正文,不要写其他段的内容,不要复述前文。

重要：你的输出必须是合法的 JSON。文本中的特殊字符必须正确转义(双引号 \\" / 换行 \\n / 反斜杠 \\\\)。"""

# 首段(起势):额外产出变体的元数据(开场/钩子等)
SEGMENT_FIRST_PROMPT = ChatPromptTemplate.from_messages([
    ("system", _SEGMENT_SYSTEM),
    ("human", """本段【{segment_name}】对应的原始剧本片段:
---
{segment_source}
---

【故事内核(共享于所有变体,全剧脉络以此为准)】
{story_card_summary}

【场景方向】【{emotion_type}】— {emotion_desc}

【本段任务】写第一段【{segment_name}】({segment_pct}%),目标约 {word_target} 字。
这是开篇,前 10 秒必须强钩子抓人(悬念/冲突/情感暴击 + 视觉冲击)。

请严格按以下 JSON 返回(不要添加任何其他文字):

{{
  "opening_lines": "前10秒的台词(2-3句对白)",
  "visual_description": "画面描述(镜头语言、场景氛围)",
  "emotion_positioning": "整部变体的情绪定位说明",
  "hook_summary": "一句话概括这个钩子的核心吸引力",
  "segment_text": "本段【{segment_name}】完整正文,约 {word_target} 字,务必写满"
}}"""),
])

# 后续段(攀升/风暴/决战):承接前文,只产出本段正文
SEGMENT_CONT_PROMPT = ChatPromptTemplate.from_messages([
    ("system", _SEGMENT_SYSTEM),
    ("human", """本段【{segment_name}】对应的原始剧本片段:
---
{segment_source}
---

【故事内核(共享于所有变体,全剧脉络以此为准)】
{story_card_summary}

【场景方向】【{emotion_type}】— {emotion_desc}

【已写前文结尾(仅用于衔接,不要重复)】
{prev_tail}

【本段任务】承接前文,写【{segment_name}】({segment_pct}%),目标约 {word_target} 字。
只写本段,自然承接上文,把冲突/情绪继续推进。

请严格按以下 JSON 返回(不要添加任何其他文字):

{{
  "segment_text": "本段【{segment_name}】完整正文,约 {word_target} 字,务必写满"
}}"""),
])

TEXT_PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一位顶级短剧编剧和爆款内容策划专家，精通抖音/红果短剧的流量密码。
你深谙"强钩子"法则：每集开头必须让用户停留超过3秒不划走。

核心公式：悬念/冲突/情感暴击 + 视觉冲击

你的任务是对给定剧本进行"钩子重构"，按照指定的情绪维度重写整个剧本。
直接输出重写后的小说/剧本文字，不要输出 JSON，不要添加任何格式标记。"""),
    ("human", """以下是原始剧本内容：

---
{script_text}
---

请按照【{emotion_type}】这一情绪维度对剧本进行"钩子重构"。

情绪维度说明：{emotion_desc}

要求：
- 遵循"悬念/冲突/情感暴击 + 视觉冲击"公式
- 开头10秒必须抓住观众注意力
- 完整重写剧本，不是只改开头
- 直接输出重写后的剧本文字，不要任何额外说明"""),
])
