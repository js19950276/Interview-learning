from langchain_core.prompts import ChatPromptTemplate

VERSION = "1.0.0"

# 候选场景已由规则粗筛得到,LLM 只负责从候选里精选 n 个最贴合的并给理由。
PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一位资深漫剧(动态漫/条漫短剧)选题策划,精通男频/女频各类爽点套路。
你的任务:根据给定剧本的故事内核,从候选场景库中挑出最适合用来"魔改重构"这个剧本的 {n} 个场景。

挑选原则:
- 优先贴合剧本的题材、人物关系、主线与核心爽点
- {n} 个场景之间要有差异度(不同爬点/方向),便于后续横向比较
- 只能从给定候选里选,id 必须原样照抄
- 每个入选场景给一句话"入选理由"(为什么适合这个剧本)

输出必须是合法 JSON,不要添加任何额外文字。"""),
    ("human", """【剧本故事内核】
{story_card_summary}

【候选场景(只能从这里选)】
{candidates}

请从候选中精选 {n} 个最适合魔改本剧本的场景。严格按以下 JSON 返回:

{{
  "channel_inferred": "男频|女频(你判断本剧本更偏哪个频道)",
  "selected": [
    {{"id": "候选中的场景id(原样照抄)", "reason": "一句话入选理由"}}
  ]
}}"""),
])
