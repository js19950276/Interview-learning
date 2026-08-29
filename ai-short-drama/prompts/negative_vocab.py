"""受控中文 negative prompt 词汇表.

LLM 只能从此挑选(防自由发挥导致下游 AI 视频模型不稳定).
分类便于注入 prompt 时分组展示.
"""

QUALITY_DEFECTS = [
    "模糊", "低质量", "低分辨率", "像素化",
    "压缩伪影", "噪点", "颗粒感",
]

ANATOMY_DEFECTS = [
    "多手指", "缺手指", "多肢体", "缺肢体",
    "面部畸形", "面部扭曲", "解剖错误",
    "眼睛不对称", "手指融合", "手部畸形",
]

COMPOSITION_DEFECTS = [
    "构图差", "主体偏离中心", "主体被裁切",
    "背景杂乱", "水印", "商标",
    "字幕伪影", "文字叠加",
]

PHYSICS_DEFECTS = [
    "物体悬浮", "光照错误", "硬阴影",
    "过曝", "欠曝",
]

ALL_TERMS: list[str] = (
    QUALITY_DEFECTS + ANATOMY_DEFECTS + COMPOSITION_DEFECTS + PHYSICS_DEFECTS
)

DEFAULT_NEGATIVE = "模糊, 低质量, 面部畸形, 多手指, 解剖错误, 水印"


def vocab_listing() -> str:
    """格式化 prompt 注入用的词汇分组列表."""
    return (
        "画质类: " + ", ".join(QUALITY_DEFECTS) + "\n"
        "人体类: " + ", ".join(ANATOMY_DEFECTS) + "\n"
        "构图类: " + ", ".join(COMPOSITION_DEFECTS) + "\n"
        "光物理类: " + ", ".join(PHYSICS_DEFECTS)
    )
