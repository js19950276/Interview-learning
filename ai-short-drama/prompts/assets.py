from langchain_core.prompts import ChatPromptTemplate

VERSION = "1.0.0"   # 1.0: 资产实体提取(借鉴 Jellyfish 一致性资产管理),供分镜引用 + video_prompts 携带

EXTRACT_PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一位短剧美术制片,任务是从来稿中提取"资产清单",供后续分镜保持视觉一致性。

【资产类型】
- character: 有名字/有戏份的人物
- location: 出现的主要场景地点
- prop: 关键叙事道具(推动剧情或多次出现)
- costume: 有标志性意义的服装造型(可选)

【appearance 外观锚点要求】(最重要)
每个资产的 appearance 是一段 40-80 字的**外观锚点描述**,后续所有分镜镜头将直接复用这段描述来保证跨镜头一致:
- character: 年龄段/性别/发型发色/瞳色/体型/标志性服装/气质关键词
- location: 空间类型/时代风格/主色调/光线氛围/标志性陈设
- prop: 形态/材质/颜色/尺寸/独特细节
- costume: 款式/颜色/面料/穿着场合
只写"长什么样",不要写剧情。

重要：你的输出必须是合法的 JSON,文本中特殊字符正确转义。"""),
    ("human", """【故事内核】
{story_card_summary}

【选定变体全文】
{variant_text}

请提取资产清单,严格按以下 JSON 返回(不要添加任何其他文字):

{{
  "assets": [
    {{
      "kind": "character",
      "name": "角色或资产名",
      "appearance": "40-80字外观锚点描述",
      "aliases": ["别名/其他称呼"]
    }}
  ]
}}

要求:
- character 按出场重要度排序,主角放第一个
- 只收关键项:全部资产合计不超过 15 条;一次性道具/路人不要收
- name 用原文中最常用的称呼,aliases 收集其他叫法(如 "林总"/"老公")"""),
])
