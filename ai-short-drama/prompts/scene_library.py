"""漫剧场景库:题材 × 爬点 粒度的静态数据。

每条 = {
  id: 稳定唯一 slug
  channel: "男频" | "女频"
  genre: 题材(粗筛主键)
  hook_tags: 爬点标签(粗筛加分项,也用于生成变体标签)
  keywords: 用于规则粗筛的中文关键词(在故事卡文本里子串命中)
  one_liner: 一句话场景描述(喂给 LLM 精选 + 作为变体 desc)
}

纯数据,后续随时增删。匹配逻辑在 agent/scene_match.py。
"""
from __future__ import annotations

VERSION = "1.0.0"

CHANNELS = {"男频", "女频"}

SCENE_LIBRARY: list[dict] = [
    # ---------------- 男频 ----------------
    {
        "id": "M-zhuixu-dalian",
        "channel": "男频", "genre": "都市赘婿",
        "hook_tags": ["打脸", "扮猪吃虎", "身份反转"],
        "keywords": ["赘婿", "上门", "女婿", "豪门", "退婚", "看不起", "隐藏身份", "家族"],
        "one_liner": "上门赘婿被全家欺压到极致,真实身份(隐藏大佬)曝光后强势打脸所有看不起他的人",
    },
    {
        "id": "M-bingwang-huigui",
        "channel": "男频", "genre": "战神兵王",
        "hook_tags": ["王者归来", "护短", "降维打击"],
        "keywords": ["兵王", "战神", "退役", "归来", "雇佣兵", "特种兵", "军", "保护"],
        "one_liner": "退役战神回归都市,为守护亲人/旧爱出手,昔日战友与强敌纷纷现身,降维碾压宵小",
    },
    {
        "id": "M-shenyi-xiapin",
        "channel": "男频", "genre": "神医回归",
        "hook_tags": ["金手指", "扮猪吃虎", "打脸"],
        "keywords": ["神医", "医术", "透视", "医院", "救人", "庸医", "妙手", "针灸"],
        "one_liner": "深藏不露的绝世神医被当成江湖骗子,一次次出手救下专家束手无策的病人,打脸权威",
    },
    {
        "id": "M-xianxia-feichai",
        "channel": "男频", "genre": "玄幻修仙",
        "hook_tags": ["废柴逆袭", "金手指", "升级"],
        "keywords": ["修仙", "灵根", "宗门", "废柴", "天才", "丹药", "突破", "境界", "修炼"],
        "one_liner": "被视为废柴的少年觉醒逆天金手指,在宗门大比中一鸣惊人,踩着天才一路飙升境界",
    },
    {
        "id": "M-xitong-qiandao",
        "channel": "男频", "genre": "系统签到",
        "hook_tags": ["金手指", "无敌升级", "扮猪吃虎"],
        "keywords": ["系统", "签到", "奖励", "面板", "任务", "宿主", "兑换", "升级"],
        "one_liner": "主角绑定签到系统,每天领取逆天奖励,实力暴涨却深藏功与名,关键时刻一鸣惊人",
    },
    {
        "id": "M-chongsheng-fuchou",
        "channel": "男频", "genre": "重生复仇",
        "hook_tags": ["重生", "复仇", "打脸", "先知先觉"],
        "keywords": ["重生", "重活", "前世", "复仇", "报仇", "背叛", "上一世", "记忆"],
        "one_liner": "含恨而死的主角重生回到悲剧之前,带着前世记忆精准复仇,扳倒曾经背叛、害死他的人",
    },
    {
        "id": "M-dushi-shenhao",
        "channel": "男频", "genre": "都市神豪",
        "hook_tags": ["花钱流", "打脸", "凡尔赛"],
        "keywords": ["首富", "花钱", "豪车", "破产", "暴富", "土豪", "亿", "刷卡"],
        "one_liner": "主角必须花钱才能变更强/不破产,被当成穷光蛋羞辱,转头亮出惊人财力当场打脸",
    },
    {
        "id": "M-mori-qiusheng",
        "channel": "男频", "genre": "末世废土",
        "hook_tags": ["生存", "金手指", "逆袭"],
        "keywords": ["末世", "丧尸", "病毒", "避难所", "变异", "废土", "求生", "物资"],
        "one_liner": "末世爆发丧尸围城,主角凭先知/异能在绝境中建立据点,从被抛弃的废柴成为人类希望",
    },
    {
        "id": "M-lishi-chuanyue",
        "channel": "男频", "genre": "历史穿越",
        "hook_tags": ["金手指", "争霸", "降维打击"],
        "keywords": ["穿越", "古代", "王朝", "皇帝", "争霸", "种田", "现代知识", "封王"],
        "one_liner": "现代人穿越古代,用超前知识改写历史,从草根一路封侯拜相、纵横朝堂",
    },
    {
        "id": "M-xiaoyao-longwang",
        "channel": "男频", "genre": "校园龙王",
        "hook_tags": ["王者归来", "打脸", "护短"],
        "keywords": ["龙王", "校园", "回归", "传说", "兄弟", "称霸", "学校", "守护"],
        "one_liner": "传说级大佬隐姓埋名回到校园,目睹兄弟/旧人受欺,被迫摘下面具震慑全场",
    },
    {
        "id": "M-jianbao-toushi",
        "channel": "男频", "genre": "鉴宝透视",
        "hook_tags": ["金手指", "扮猪吃虎", "打脸"],
        "keywords": ["鉴宝", "透视", "古董", "捡漏", "赌石", "文物", "眼力", "真假"],
        "one_liner": "拥有透视异能的主角在鉴宝/赌石场上屡屡捡漏,被嘲讽外行后反手鉴出真品打脸专家",
    },
    {
        "id": "M-wuxia-enchou",
        "channel": "男频", "genre": "武侠江湖",
        "hook_tags": ["复仇", "武功秘籍", "逆袭"],
        "keywords": ["江湖", "武林", "门派", "秘籍", "灭门", "仇", "侠", "高手"],
        "one_liner": "灭门遗孤偶得绝世武学,隐忍修炼后重出江湖,逐一手刃当年屠戮师门的仇敌",
    },
    {
        "id": "M-yineng-juexing",
        "channel": "男频", "genre": "都市异能",
        "hook_tags": ["觉醒金手指", "扮猪吃虎", "降维打击"],
        "keywords": ["异能", "觉醒", "超能力", "组织", "封印", "血脉", "力量", "秘密"],
        "one_liner": "平凡青年突然觉醒隐秘异能,卷入超凡组织的纷争,从被保护者成长为最强王牌",
    },
    {
        "id": "M-yuwang-fanshen",
        "channel": "男频", "genre": "赘婿入赘豪门",
        "hook_tags": ["隐藏富豪", "打脸", "宠妻"],
        "keywords": ["岳父", "岳母", "妻子", "公司", "继承", "财阀", "瞧不起", "身家"],
        "one_liner": "被岳家当成吃软饭废物的女婿,其实是隐形财阀继承人,危机时刻力挽狂澜反向碾压",
    },
    {
        "id": "M-zhanshen-hubing",
        "channel": "男频", "genre": "都市修真",
        "hook_tags": ["修真高手", "降维打击", "扮猪吃虎"],
        "keywords": ["修真", "下山", "师父", "法术", "凡人", "灵气", "炼丹", "符箓"],
        "one_liner": "修真者奉师命下山入世历练,在满是凡人的都市里低调行事,遇邪祟与恶人时一招制敌",
    },

    # ---------------- 女频 ----------------
    {
        "id": "F-haomen-nuelian",
        "channel": "女频", "genre": "豪门虐恋",
        "hook_tags": ["追妻火葬场", "误会", "破镜重圆"],
        "keywords": ["豪门", "总裁", "离婚", "误会", "追妻", "霸道", "前夫", "挽回"],
        "one_liner": "女主被误会伤透心后决绝离开,冷酷总裁追悔莫及上演追妻火葬场,层层误会终被揭开",
    },
    {
        "id": "F-zhenjia-qianjin",
        "channel": "女频", "genre": "真假千金",
        "hook_tags": ["身份反转", "打脸", "团宠"],
        "keywords": ["千金", "真假", "豪门", "亲生", "调包", "假千金", "认亲", "家族"],
        "one_liner": "被错抱的真千金回归豪门,假千金处处打压,真千金凭真才实学反杀,被全家团宠",
    },
    {
        "id": "F-chongsheng-difu",
        "channel": "女频", "genre": "重生复仇",
        "hook_tags": ["重生", "复仇", "打脸", "虐渣"],
        "keywords": ["重生", "前世", "重活", "复仇", "渣男", "白莲花", "报仇", "嫡女"],
        "one_liner": "被渣男贱女害死的女主重生归来,带着记忆步步为营,虐渣打脸、夺回属于自己的一切",
    },
    {
        "id": "F-majia-dalao",
        "channel": "女频", "genre": "马甲大佬",
        "hook_tags": ["马甲掉落", "扮猪吃虎", "全员沉迷"],
        "keywords": ["马甲", "身份", "隐藏", "大佬", "黑客", "影后", "神医", "秘密", "曝光"],
        "one_liner": "被当成废物的女主其实身怀无数隐藏身份(影后/黑客/神医),马甲一个个掉落惊掉全场下巴",
    },
    {
        "id": "F-gudai-gongdou",
        "channel": "女频", "genre": "古言宫斗",
        "hook_tags": ["权谋", "复仇", "上位"],
        "keywords": ["宫", "妃", "皇后", "皇上", "后宫", "争宠", "陷害", "嫔妃", "晋位"],
        "one_liner": "出身低微的女主入宫,在尔虞我诈的后宫中智斗群妃,一步步从答应熬成掌权者",
    },
    {
        "id": "F-chuanshu-nixi",
        "channel": "女频", "genre": "穿书逆袭",
        "hook_tags": ["穿越", "改命", "打脸炮灰"],
        "keywords": ["穿书", "炮灰", "剧情", "原著", "穿越", "女配", "改写", "命运"],
        "one_liner": "女主穿成书中注定惨死的炮灰女配,凭借对剧情的先知逆天改命,活成全场最佳",
    },
    {
        "id": "F-tianchong-xianhun",
        "channel": "女频", "genre": "甜宠先婚后爱",
        "hook_tags": ["甜宠", "契约婚姻", "双向奔赴"],
        "keywords": ["闪婚", "契约", "结婚", "宠", "老公", "甜", "先婚后爱", "心动"],
        "one_liner": "一纸契约闪婚的两人从相敬如宾到日久生情,高冷老公宠妻无下限,撒糖到齁",
    },
    {
        "id": "F-mengbao-tuanchong",
        "channel": "女频", "genre": "萌宝团宠",
        "hook_tags": ["带球跑", "萌宝助攻", "失而复得"],
        "keywords": ["萌宝", "孩子", "宝宝", "带球", "认爹", "团宠", "双胞胎", "亲子"],
        "one_liner": "女主带着高智商萌宝低调回归,萌宝助攻寻找/试探生父,全家被萌宝团宠攻陷",
    },
    {
        "id": "F-nuzun-nuqiang",
        "channel": "女频", "genre": "女强独立",
        "hook_tags": ["大女主", "事业逆袭", "打脸"],
        "keywords": ["女强", "独立", "事业", "总裁", "创业", "逆袭", "不靠男人", "翻身"],
        "one_liner": "被低估的女主在职场/商场强势崛起,不靠任何人单枪匹马打下江山,打脸所有轻视她的人",
    },
    {
        "id": "F-xianxia-nuelian",
        "channel": "女频", "genre": "仙侠虐恋",
        "hook_tags": ["情劫", "虐恋", "宿命"],
        "keywords": ["仙", "上神", "情劫", "渡劫", "仙界", "宿命", "轮回", "魔尊"],
        "one_liner": "仙界尊者与女主历经数世情劫,爱而不得、为护苍生反目,在虐恋宿命中艰难相守",
    },
    {
        "id": "F-xiaoyuan-poliang",
        "channel": "女频", "genre": "校园破镜重圆",
        "hook_tags": ["青春", "错过", "重逢"],
        "keywords": ["校园", "青春", "初恋", "暗恋", "同学", "重逢", "毕业", "遗憾"],
        "one_liner": "曾因误会错过的校园恋人多年后重逢,旧情难却又满是隔阂,在追忆与试探中破镜重圆",
    },
    {
        "id": "F-dizhi-zhenqianjin",
        "channel": "女频", "genre": "嫡女宅斗",
        "hook_tags": ["宅斗", "复仇", "翻身"],
        "keywords": ["嫡女", "庶女", "宅", "府", "继母", "陷害", "家族", "联姻"],
        "one_liner": "被庶母庶妹算计的嫡女觉醒手段,在深宅大院中步步为营,夺回当家主母之位",
    },
    {
        "id": "F-cuihuan-rensheng",
        "channel": "女频", "genre": "错换人生",
        "hook_tags": ["身世之谜", "反转", "亲情"],
        "keywords": ["错换", "抱错", "亲生", "身世", "医院", "认亲", "血缘", "真相"],
        "one_liner": "两个被抱错的女孩人生交错,真相揭开时亲情与利益激烈碰撞,女主在风暴中守护真心",
    },
    {
        "id": "F-zongcai-zhuiqi",
        "channel": "女频", "genre": "总裁追妻",
        "hook_tags": ["追妻火葬场", "失忆", "复合"],
        "keywords": ["总裁", "追妻", "失忆", "离开", "后悔", "挽回", "冷战", "复合"],
        "one_liner": "高冷总裁错失真爱后才醒悟,女主已心灰意冷甚至失忆/远走,他放下身段苦苦追回",
    },
    {
        "id": "F-niangqin-fuhei",
        "channel": "女频", "genre": "腹黑甜妻",
        "hook_tags": ["扮猪吃虎", "马甲", "宠妻"],
        "keywords": ["腹黑", "甜妻", "伪装", "低调", "实力", "隐藏", "护妻", "反差"],
        "one_liner": "看似柔弱的甜妻其实腹黑又强大,被人欺负时老公还没出手她已暗中反杀,反差拉满",
    },
    {
        "id": "F-bailian-nizhuan",
        "channel": "女频", "genre": "虐渣打脸",
        "hook_tags": ["打脸", "虐渣", "爽感"],
        "keywords": ["白莲花", "绿茶", "渣男", "撕", "打脸", "扯下面具", "心机", "反击"],
        "one_liner": "被白莲花/渣男联手算计的女主不再忍气吞声,当众撕下对方伪善面具,大快人心地反击",
    },
    {
        "id": "F-qiyue-haomen",
        "channel": "女频", "genre": "替嫁豪门",
        "hook_tags": ["替嫁", "先婚后爱", "身份反转"],
        "keywords": ["替嫁", "代嫁", "豪门", "联姻", "顶替", "嫁给", "婚约", "新娘"],
        "one_liner": "女主被迫替姐姐嫁入豪门,本以为是冷宫般的婚姻,却意外收获深情,身份反转惊艳全场",
    },
]


def validate_library(library: list[dict] | None = None) -> None:
    """启动期校验:id 唯一、channel 合法、必填字段齐全。"""
    lib = library if library is not None else SCENE_LIBRARY
    seen_ids = set()
    for entry in lib:
        sid = entry.get("id")
        assert sid, f"场景缺少 id: {entry}"
        assert sid not in seen_ids, f"场景 id 重复: {sid}"
        seen_ids.add(sid)
        assert entry.get("channel") in CHANNELS, f"{sid} channel 非法: {entry.get('channel')}"
        assert entry.get("genre"), f"{sid} 缺少 genre"
        assert entry.get("one_liner"), f"{sid} 缺少 one_liner"
        assert isinstance(entry.get("hook_tags"), list), f"{sid} hook_tags 必须是 list"
        assert isinstance(entry.get("keywords"), list), f"{sid} keywords 必须是 list"
