from langchain_core.prompts import ChatPromptTemplate

VERSION = "1.1.0"   # 1.1: 加 estimated_minutes 字段(LLM 判断剧本合适时长)

PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一位短剧叙事结构专家,擅长从原始剧本中抽取"故事卡"(Story Card)——一种中性、结构化的叙事抽象。

故事卡是 5 个情绪变体共享的"故事内核",不带任何情绪倾向(不评判好坏、不下结论),
确保后续基于此卡生成的所有变体都围绕同一故事内核展开,从而具备横向可比性。

你需要抽取 8 张卡(对应短剧"起承转合"的关键节点)+ 1 个时长估计:
1. 主角(protagonist): 人物 + 性格 + 处境(中性描述)
2. 核心动机(motivation): 主角想要什么、为什么
3. 世界观(world_setting): 时空背景 + 关键设定
4. 激励事件(inciting_incident): 打破日常的第一个事件
5. 攀升(rising_action): 矛盾如何递增
6. 中点反转(midpoint_twist): 信息揭示或处境变化
7. 高潮(climax): 主角面对的终极冲突
8. 结局(resolution): 故事如何收束
9. 估计时长(estimated_minutes): 综合考虑故事密度、对话量、情节节点数,判断这个故事**最合适**的成片时长(8-50 分钟之间)
   - 简短独白/单场冲突 → 8-15 分钟
   - 标准短剧(3-5 个场景,1 个主线)→ 15-30 分钟
   - 复杂短剧(多线/多反转)→ 30-50 分钟
   - 注意:不是按字数线性算,而是看故事**应该**多长

重要:
- 所有抽取必须基于原文事实,不增删情节
- 文字简洁,每张卡 1-3 句话
- estimated_minutes 是 float(可带小数)
- 输出必须是合法的 JSON,特殊字符正确转义(\\" \\n \\\\ \\t)"""),
    ("human", """请从以下原始短剧剧本中抽取 8 张故事卡:

---
{raw_text}
---

请严格按以下 JSON 格式返回(不要添加任何其他文字):

{{
  "protagonist": "主角人物 + 性格特征 + 初始处境",
  "motivation": "主角的核心动机/欲望",
  "world_setting": "时空背景 + 关键世界观设定",
  "inciting_incident": "打破日常的激励事件",
  "rising_action": "矛盾递增的关键节点",
  "midpoint_twist": "中点的信息反转或处境转折",
  "climax": "故事高潮的核心冲突",
  "resolution": "故事的最终走向/结局",
  "estimated_minutes": 25.0
}}"""),
])
