from __future__ import annotations

import argparse
import html
import re
from pathlib import Path
from typing import Iterable

import pandas as pd

from analysis.hongguo_public_sample_report import heat_label, format_date
from analysis.hongguo_rank_analysis import (
    PRIMARY_TAG_COLORS,
    resolve_level2_tags,
    resolve_primary_tag,
    safe_pct,
)

MANJU_KEYWORDS = ("漫剧", "AI", "仿真人漫", "真人AI", "一AI新剧")

MANJU_MANUAL_EVENTS = [
    {
        "snapshot_date": "2026-01-07",
        "signal_type": "榜单排名样本",
        "title": "我在末世开超市，S级诡异抢着来上班",
        "heat_w": 5331.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5331W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5331W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-01-13",
        "signal_type": "榜单排名样本",
        "title": "西游后传真假大圣",
        "heat_w": 5015.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5015W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5015W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-01-17",
        "signal_type": "榜单排名样本",
        "title": "斩仙台真人AI版",
        "heat_w": 5428.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5428W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5428W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-01-21",
        "signal_type": "榜单排名样本",
        "title": "斩仙台真人AI版",
        "heat_w": 5757.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5757W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5757W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-01-24",
        "signal_type": "榜单排名样本",
        "title": "从赖皮蛇开始吞噬进化",
        "heat_w": 5421.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5421W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5421W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-01-31",
        "signal_type": "播放增量信号",
        "title": "末日寒潮我有移动堡垒我怕谁",
        "heat_w": 23700.0,
        "rank_desc": "1月播放增量Top1",
        "metric_desc": "AI仿真人漫剧，1月播放增量约2.37亿；不是红果热度口径",
        "manju_count": 1,
        "notes": "AI仿真人漫剧，1月播放增量约2.37亿；不是红果热度口径",
        "source_url": "https://www.sohu.com/a/990484220_121956424",
    },
    {
        "snapshot_date": "2026-01-31",
        "signal_type": "播放增量信号",
        "title": "我在末世开超市S级诡异抢着来上班",
        "heat_w": 22700.0,
        "rank_desc": "1月播放增量Top2",
        "metric_desc": "2D/3D漫剧，1月播放增量约2.27亿；不是红果热度口径",
        "manju_count": 1,
        "notes": "2D/3D漫剧，1月播放增量约2.27亿；不是红果热度口径",
        "source_url": "https://www.sohu.com/a/990484220_121956424",
    },
    {
        "snapshot_date": "2026-01-31",
        "signal_type": "播放增量信号",
        "title": "从赖皮蛇开始吞噬进化",
        "heat_w": 21300.0,
        "rank_desc": "1月播放增量Top3",
        "metric_desc": "2D漫剧，1月播放增量约2.13亿；不是红果热度口径",
        "manju_count": 1,
        "notes": "2D漫剧，1月播放增量约2.13亿；不是红果热度口径",
        "source_url": "https://www.sohu.com/a/990484220_121956424",
    },
    {
        "snapshot_date": "2026-02-02",
        "signal_type": "榜单排名样本",
        "title": "这是规则怪谈啊，让我多子多福？",
        "heat_w": 5205.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5205W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5205W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-02-03",
        "signal_type": "榜单排名样本",
        "title": "这是规则怪谈啊，让我多子多福？",
        "heat_w": 5637.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5637W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5637W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-02-10",
        "signal_type": "榜单排名样本",
        "title": "这是规则怪谈啊，让我多子多福？",
        "heat_w": 5517.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5517W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5517W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-02-10",
        "signal_type": "榜单排名样本",
        "title": "我的东莞姐姐",
        "heat_w": 5108.0,
        "rank_desc": "Top2",
        "metric_desc": "DataEye红果漫剧热播榜Top2，热度5108W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top2，热度5108W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-02-10",
        "signal_type": "榜单排名样本",
        "title": "福运加冕，狼人哥哥对我追着宠",
        "heat_w": 4625.0,
        "rank_desc": "Top3",
        "metric_desc": "DataEye红果漫剧热播榜Top3，热度4625W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top3，热度4625W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-02-15",
        "signal_type": "榜单排名样本",
        "title": "这是规则怪谈啊，让我多子多福？",
        "heat_w": 5236.0,
        "rank_desc": "Top1/连续霸榜",
        "metric_desc": "红果漫剧热播榜连续霸榜14期，2月15日热度5236W",
        "manju_count": 1,
        "notes": "红果漫剧热播榜连续霸榜14期，2月15日热度5236W",
        "source_url": "https://k.sina.cn/article_7879922982_1d5ae15260190a4n1g.html",
    },
    {
        "snapshot_date": "2026-02-15",
        "signal_type": "榜单排名样本",
        "title": "三千庇护",
        "heat_w": 5164.0,
        "rank_desc": "Top2",
        "metric_desc": "红果漫剧热播榜2月15日Top2，热度5164W",
        "manju_count": 1,
        "notes": "红果漫剧热播榜2月15日Top2，热度5164W",
        "source_url": "https://k.sina.cn/article_7879922982_1d5ae15260190a4n1g.html",
    },
    {
        "snapshot_date": "2026-02-17",
        "signal_type": "结构信号",
        "title": "AI仿真人剧Top30占10席",
        "heat_w": 4200.0,
        "rank_desc": "TOP30门槛",
        "metric_desc": "红果漫剧热播榜TOP30中AI仿真人剧占10席，热度值全线突破4200W",
        "manju_count": 10,
        "notes": "红果漫剧热播榜TOP30中AI仿真人剧占10席，热度值全线突破4200W",
        "source_url": "https://k.sina.cn/article_7879922982_1d5ae15260190a4n1g.html",
    },
    {
        "snapshot_date": "2026-02-17",
        "signal_type": "榜单排名样本",
        "title": "三千庇护",
        "heat_w": 5338.0,
        "rank_desc": "Top2",
        "metric_desc": "红果漫剧热播榜2月17日Top2，热度5338W",
        "manju_count": 1,
        "notes": "红果漫剧热播榜2月17日Top2，热度5338W",
        "source_url": "https://k.sina.cn/article_7879922982_1d5ae15260190a4n1g.html",
    },
    {
        "snapshot_date": "2026-02-23",
        "signal_type": "榜单排名样本",
        "title": "西游，错把玉帝当亲爹",
        "heat_w": 6234.0,
        "rank_desc": "Top1/连续登顶7期",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度6234W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度6234W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-02-23",
        "signal_type": "榜单排名样本",
        "title": "气运三角洲，我凭操作吊打全球",
        "heat_w": 5880.0,
        "rank_desc": "Top2",
        "metric_desc": "DataEye红果漫剧热播榜Top2，热度5880W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top2，热度5880W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-02-23",
        "signal_type": "榜单排名样本",
        "title": "让你悟道，没让你起飞",
        "heat_w": 5292.0,
        "rank_desc": "Top3",
        "metric_desc": "DataEye红果漫剧热播榜Top3，热度5292W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top3，热度5292W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-04",
        "signal_type": "榜单排名样本",
        "title": "儿媳的重生棋局",
        "heat_w": 5213.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5213W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5213W",
        "source_url": "https://ent.sina.cn/2026-03-16/detail-inhrctqy2842703.d.html?vt=4",
    },
    {
        "snapshot_date": "2026-03-04",
        "signal_type": "榜单排名样本",
        "title": "风雪开局：我乱世称王",
        "heat_w": 5151.0,
        "rank_desc": "Top2",
        "metric_desc": "DataEye红果漫剧热播榜Top2，热度5151W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top2，热度5151W",
        "source_url": "https://ent.sina.cn/2026-03-16/detail-inhrctqy2842703.d.html?vt=4",
    },
    {
        "snapshot_date": "2026-03-04",
        "signal_type": "榜单排名样本",
        "title": "西游，错把玉帝当亲爹",
        "heat_w": 5061.0,
        "rank_desc": "Top3",
        "metric_desc": "DataEye红果漫剧热播榜Top3，热度5061W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top3，热度5061W",
        "source_url": "https://ent.sina.cn/2026-03-16/detail-inhrctqy2842703.d.html?vt=4",
    },
    {
        "snapshot_date": "2026-03-06",
        "signal_type": "榜单排名样本",
        "title": "诡异婚配：我诡帝，老婆软糯校花",
        "heat_w": 5131.0,
        "rank_desc": "Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度5131W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度5131W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-06",
        "signal_type": "榜单排名样本",
        "title": "儿媳的重生棋局",
        "heat_w": 5123.0,
        "rank_desc": "Top2",
        "metric_desc": "DataEye红果漫剧热播榜Top2，热度5123W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top2，热度5123W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-06",
        "signal_type": "榜单排名样本",
        "title": "风雪开局：我乱世称王",
        "heat_w": 5017.0,
        "rank_desc": "Top3",
        "metric_desc": "DataEye红果漫剧热播榜Top3，热度5017W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top3，热度5017W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-21",
        "signal_type": "榜单排名样本",
        "title": "风水天师",
        "heat_w": 6982.0,
        "rank_desc": "Top1/蝉联3期",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度6982W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度6982W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-21",
        "signal_type": "榜单排名样本",
        "title": "重生1985，他靠空间发家致富",
        "heat_w": 5672.0,
        "rank_desc": "Top2",
        "metric_desc": "DataEye红果漫剧热播榜Top2，热度5672W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top2，热度5672W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-21",
        "signal_type": "榜单排名样本",
        "title": "万兽独尊",
        "heat_w": 5542.0,
        "rank_desc": "Top3",
        "metric_desc": "DataEye红果漫剧热播榜Top3，热度5542W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top3，热度5542W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-21",
        "signal_type": "榜单排名样本",
        "title": "贾二虎的妖孽人生之皓男出狱",
        "heat_w": None,
        "rank_desc": "Top5/AI仿真人漫剧",
        "metric_desc": "AI仿真人漫剧位列红果漫剧热播榜第五",
        "manju_count": 1,
        "notes": "AI仿真人漫剧位列红果漫剧热播榜第五",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-24",
        "signal_type": "榜单排名样本",
        "title": "风水天师",
        "heat_w": 6539.0,
        "rank_desc": "Top1/连续霸榜6天",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度6539W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度6539W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-03-24",
        "signal_type": "榜单排名样本",
        "title": "聚宝仙盆之杂灵根才是真BOSS",
        "heat_w": 5776.0,
        "rank_desc": "Top3",
        "metric_desc": "DataEye红果漫剧热播榜Top3，热度5776W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top3，热度5776W",
        "source_url": "https://baike.baidu.com/item/DataEye%E7%BA%A2%E6%9E%9C%E6%BC%AB%E5%89%A7%E7%83%AD%E6%92%AD%E6%A6%9C/67362571",
    },
    {
        "snapshot_date": "2026-04-09",
        "signal_type": "榜单排名样本",
        "title": "菩提临世真人AI版",
        "heat_w": 8658.0,
        "rank_desc": "Top1/超过真人榜Top1",
        "metric_desc": "DataEye红果漫剧热播榜Top1，热度8658W；超过同日红果真人短剧Top1热度7800W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top1，热度8658W；超过同日红果真人短剧Top1热度7800W",
        "source_url": "https://ent.sina.cn/2026-04-10/detail-inhtyrwh0348124.d.html?vt=4",
    },
    {
        "snapshot_date": "2026-04-09",
        "signal_type": "榜单排名样本",
        "title": "初心未改，逆袭不负韶华",
        "heat_w": 5555.0,
        "rank_desc": "Top2",
        "metric_desc": "DataEye红果漫剧热播榜Top2，热度5555W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top2，热度5555W",
        "source_url": "https://ent.sina.cn/2026-04-10/detail-inhtyrwh0348124.d.html?vt=4",
    },
    {
        "snapshot_date": "2026-04-09",
        "signal_type": "榜单排名样本",
        "title": "团宠狗师妹，我的师门全是大妖",
        "heat_w": 5480.0,
        "rank_desc": "Top3",
        "metric_desc": "DataEye红果漫剧热播榜Top3，热度5480W",
        "manju_count": 1,
        "notes": "DataEye红果漫剧热播榜Top3，热度5480W",
        "source_url": "https://ent.sina.cn/2026-04-10/detail-inhtyrwh0348124.d.html?vt=4",
    },
    {
        "snapshot_date": "2026-05-25",
        "signal_type": "播放峰值信号",
        "title": "未披露：一AI新剧",
        "heat_w": 33000.0,
        "rank_desc": "日播3.3亿",
        "metric_desc": "公开摘要称一AI新剧日播3.3亿、断层领先；未披露具体剧名，且为播放量口径",
        "manju_count": 1,
        "notes": "公开摘要称一AI新剧日播3.3亿、断层领先；未披露具体剧名，且为播放量口径",
        "source_url": "https://www.thepaper.cn/newsDetail_forward_33226293",
    },
]
CONTENT_STRATEGIES = [
    {
        "direction": "AI仿真人漫总榜冲榜",
        "why": "公开样本出现“3部AI漫剧闯入TOP3”和“AI仿真人漫包揽总榜TOP4”的结构性信号，说明漫剧在部分节点具备压过真人短剧头部的能力。",
        "actions": [
            "把AI漫剧与真人短剧拆成两个榜单口径追踪，不要只看红果总榜。",
            "重点记录是否进入Top3/Top4，以及是否超过同日真人榜Top1。",
            "对高峰样本回溯素材风格、题材壳、更新节奏和投流节点。",
        ],
        "risks": [
            "当前公开样本剧名缺失较多，不能直接推导所有AI漫剧题材偏好。",
            "榜单口径可能混合热度、播放量和总榜排名，需要在采集表里分列指标。",
        ],
    },
    {
        "direction": "真人AI版/玄幻强设定",
        "why": "可确认单剧《菩提临世真人AI版》热度8658W，且超过同日真人榜Top1，说明“真人AI版 + 奇幻/修仙”具有可见爆点。",
        "actions": [
            "优先测试一句话能讲清楚的强设定：天命、修仙、神魔、系统、末世、预知。",
            "标题里保留“真人AI版/AI/漫剧”等识别词，便于用户理解形态差异。",
            "每集设置高可视化桥段：变身、技能、异象、战力碾压、命运反转。",
        ],
        "risks": [
            "纯玄幻门槛较高，建议绑定亲情、复仇、婚恋或家族危机。",
            "AI画面一致性和动作完成度会直接影响留存。",
        ],
    },
    {
        "direction": "高播放AI新剧专项追踪",
        "why": "2026-05-25公开摘要出现“一AI新剧日播3.3亿”，虽未披露剧名，但量级显著高于常规千万级热度样本。",
        "actions": [
            "后续采集时增加“播放量/热度/峰值/日均”四列，避免不同指标混算。",
            "对日播破亿样本单独建立案例库，补齐剧名、题材、出品方、上榜周期。",
            "将“爆发当天前后3天”的排名与热度纳入趋势图。",
        ],
        "risks": [
            "日播3.3亿不等同DataEye热度3.3亿，展示时必须显式标注指标口径。",
            "标题级摘要不可替代完整榜单，不能直接判断市场均值。",
        ],
    },
]

TITLE_IDEAS = [
    ("真人AI玄幻", [
        "《菩提临世，真人AI版》",
        "《天命崩坏后，我成了唯一变量》",
        "《真人AI版：魔尊归来》",
        "《我被天道选中后，全城跪了》",
        "《灵气复苏当天，我觉醒神级弹幕》",
        "《AI重启：我看见所有人的结局》",
        "《仿真人漫：全城等我认输》",
        "《神明降临前，我先改写家族命运》",
    ]),
    ("系统爽感漫剧", [
        "《绑定改命系统后，全家逆天翻盘》",
        "《末世前三天，我靠预知囤满全城》",
        "《神豪系统觉醒后，前夫全家跪了》",
        "《我能听见弹幕，反派全员破防》",
        "《开局获得满级战力，我只想回家吃饭》",
        "《系统逼我成神，全城却叫我废物》",
        "《一集一个神技能，我把仇人送进火葬场》",
        "《天道给我开挂后，豪门全家听见心声》",
    ]),
    ("家庭/婚恋融合漫剧", [
        "《AI漫剧：太奶奶重启家族荣耀》",
        "《修仙归来，我成了豪门月嫂》",
        "《真人AI版：离婚后我成了他的天命白月光》",
        "《绑定读心术后，我治好了豪门全家》",
        "《魔尊带娃回家后，全家命运改写了》",
        "《白月光重生为AI后，前夫悔疯了》",
        "《三岁小祖宗会改国运》",
        "《全家炮灰命觉醒，我用AI改剧本》",
    ]),
]


def title_to_tags(title: str) -> tuple[str, str]:
    primary = resolve_primary_tag(title, [])
    secondary = "、".join(resolve_level2_tags(title, []))
    return primary, secondary


def extract_manju_events(input_path: Path) -> pd.DataFrame:
    base = pd.read_csv(input_path)
    base["snapshot_date"] = pd.to_datetime(base["snapshot_date"])
    rows = MANJU_MANUAL_EVENTS.copy()
    # 保留输入CSV里命中的原始上下文，便于审计。
    context = base[
        base.apply(
            lambda r: any(k in str(r.get("notes", "")) or k in " ".join(str(r.get(c, "")) for c in ["top1_title", "top2_title", "top3_title"]) for k in MANJU_KEYWORDS),
            axis=1,
        )
    ][["snapshot_date", "top1_title", "top1_heat_w", "top2_title", "top2_heat_w", "top3_title", "top3_heat_w", "notes", "source_url"]]
    events = pd.DataFrame(rows)
    events["snapshot_date"] = pd.to_datetime(events["snapshot_date"])
    tags = events["title"].map(title_to_tags)
    events["primary_tag_l1"] = tags.map(lambda x: x[0])
    events["secondary_tags_l2"] = tags.map(lambda x: x[1])
    events["is_title_disclosed"] = ~events["title"].str.startswith("未披露")
    return events.sort_values("snapshot_date").reset_index(drop=True), context.sort_values("snapshot_date").reset_index(drop=True)


def render_signal_svg(events: pd.DataFrame) -> str:
    plot = events.copy()
    width, height = 1060, 360
    left, right, top, bottom = 72, 28, 38, 64
    inner_w, inner_h = width - left - right, height - top - bottom
    dates = pd.to_datetime(plot["snapshot_date"]).tolist()
    min_date, max_date = min(dates), max(dates)
    span_days = max((max_date - min_date).days, 1)
    max_heat = max(pd.to_numeric(plot["heat_w"], errors="coerce").max(skipna=True) or 0, 10000) * 1.15

    def x_of(date):
        return left + ((pd.to_datetime(date) - min_date).days / span_days) * inner_w

    def y_of(value):
        return top + inner_h * (1 - float(value) / max_heat)

    elements = []
    for i in range(6):
        value = max_heat * i / 5
        y = y_of(value)
        elements.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}" stroke="#e2e8f0"/>')
        elements.append(f'<text x="{left-10}" y="{y+4:.1f}" text-anchor="end" font-size="12" fill="#64748b">{heat_label(value)}</text>')

    points = []
    for row in plot.dropna(subset=["heat_w"]).itertuples(index=False):
        points.append((x_of(row.snapshot_date), y_of(row.heat_w)))
    if points:
        elements.append('<path d="' + 'M ' + ' L '.join(f'{x:.1f},{y:.1f}' for x, y in points) + '" fill="none" stroke="#8b5cf6" stroke-width="3"/>')

    for row in plot.itertuples(index=False):
        x = x_of(row.snapshot_date)
        if pd.isna(row.heat_w):
            y = top + inner_h - 8
            color = "#f97316"
            label = row.rank_desc
            elements.append(f'<path d="M{x:.1f},{y-8:.1f} l8,8 l-8,8 l-8,-8 z" fill="{color}"><title>{format_date(row.snapshot_date)} {html.escape(row.title)}：{html.escape(row.metric_desc)}</title></path>')
        else:
            y = y_of(row.heat_w)
            color = "#8b5cf6" if row.heat_w < 20000 else "#ef4444"
            label = heat_label(row.heat_w)
            elements.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="6" fill="{color}"><title>{format_date(row.snapshot_date)} {html.escape(row.title)} {html.escape(row.metric_desc)}</title></circle>')
        elements.append(f'<text x="{x:.1f}" y="{height-34}" text-anchor="middle" font-size="11" fill="#64748b">{pd.to_datetime(row.snapshot_date).strftime("%m-%d")}</text>')
        elements.append(f'<text x="{x:.1f}" y="{max(18, y-12):.1f}" text-anchor="middle" font-size="11" fill="#334155">{html.escape(label)}</text>')

    legend = '<rect x="76" y="12" width="12" height="12" fill="#8b5cf6" rx="2"/><text x="94" y="23" font-size="12" fill="#334155">可量化热度/播放信号</text><path d="M250,18 l7,7 l-7,7 l-7,-7 z" fill="#f97316"/><text x="264" y="23" font-size="12" fill="#334155">仅排名/结构信号</text>'
    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="漫剧公开信号趋势">' + ''.join(elements) + legend + '</svg>'


def render_type_bar_svg(events: pd.DataFrame) -> str:
    summary = events.groupby("signal_type").agg(count=("title", "count"), manju_count=("manju_count", "sum")).reset_index()
    max_value = max(summary["manju_count"].max(), 1)
    width, height = 760, 220
    left, top = 150, 28
    inner_w = width - left - 70
    elements = []
    colors = ["#8b5cf6", "#f97316", "#06b6d4", "#ef4444"]
    for idx, row in enumerate(summary.itertuples(index=False)):
        y = top + idx * 42
        w = inner_w * row.manju_count / max_value
        color = colors[idx % len(colors)]
        elements.append(f'<text x="{left-10}" y="{y+19}" text-anchor="end" font-size="12" fill="#334155">{html.escape(row.signal_type)}</text>')
        elements.append(f'<rect x="{left}" y="{y}" width="{w:.1f}" height="24" rx="5" fill="{color}"/>')
        elements.append(f'<text x="{left+w+8:.1f}" y="{y+17}" font-size="12" fill="#0f172a">{row.manju_count:.0f}</text>')
    return f'<svg viewBox="0 0 {width} {height}" class="chart-svg" role="img" aria-label="漫剧信号类型分布">' + ''.join(elements) + '</svg>'


def render_strategy_cards() -> str:
    cards = []
    for item in CONTENT_STRATEGIES:
        actions = ''.join(f'<li>{html.escape(x)}</li>' for x in item['actions'])
        risks = ''.join(f'<li>{html.escape(x)}</li>' for x in item['risks'])
        cards.append(f"""
        <div class="idea-card">
          <h3>{html.escape(item['direction'])}</h3>
          <p>{html.escape(item['why'])}</p>
          <div class="idea-grid">
            <div><strong>动作建议</strong><ul>{actions}</ul></div>
            <div><strong>风险提醒</strong><ul>{risks}</ul></div>
          </div>
        </div>
        """)
    return ''.join(cards)


def render_title_ideas() -> str:
    blocks = []
    rows = []
    for direction, titles in TITLE_IDEAS:
        items = ''.join(f'<li>{html.escape(t)}</li>' for t in titles)
        blocks.append(f"<div class='title-block'><h3>{html.escape(direction)}</h3><ol>{items}</ol></div>")
        for title in titles:
            primary, secondary = title_to_tags(title)
            rows.append({"direction": direction, "title": title, "primary_tag_l1": primary, "secondary_tags_l2": secondary})
    return ''.join(blocks), pd.DataFrame(rows)


def render_report(events: pd.DataFrame, context: pd.DataFrame, output_path: Path) -> None:
    date_min = events["snapshot_date"].min().date()
    date_max = events["snapshot_date"].max().date()
    disclosed = int(events["is_title_disclosed"].sum())
    quant = int(events["heat_w"].notna().sum())
    max_row = events.sort_values("heat_w", ascending=False, na_position="last").iloc[0]
    title_blocks, title_df = render_title_ideas()

    insights = [
        f"公开样本中漫剧/AI相关信号共 {len(events)} 条，时间集中在 {date_min} ~ {date_max}，覆盖今年1月以来可检索到的公开样本。",
        "其中既包含红果漫剧热播榜Top1/Top3样本，也包含少量播放增量和AI仿真人结构信号；热度与播放量已在明细中分口径标注。",
        "可确认具体剧名的红果热度最高样本是《菩提临世真人AI版》，2026-04-09 热度8658W，超过同日真人榜Top1。",
        f"最高量级信号来自 {format_date(max_row.snapshot_date)} 的“{max_row.title}”：{max_row.metric_desc}。注意该指标可能不是DataEye热度，需单独标注播放口径。",
        "当前样本缺少完整漫剧Top100/Top30明细，适合做机会判断和采集框架，不适合替代正式榜单。",
    ]

    event_rows = ''.join(
        f"<tr><td>{format_date(r.snapshot_date)}</td><td>{html.escape(r.signal_type)}</td><td>{html.escape(r.title)}</td><td>{heat_label(r.heat_w)}</td><td>{html.escape(r.rank_desc)}</td><td>{html.escape(r.metric_desc)}</td><td>{html.escape(r.notes)}</td><td>{html.escape(r.source_url)}</td></tr>"
        for r in events.itertuples(index=False)
    )
    context_rows = ''.join(
        f"<tr><td>{format_date(r.snapshot_date)}</td><td>{html.escape(str(r.top1_title))}</td><td>{heat_label(r.top1_heat_w)}</td><td>{html.escape(str(r.top2_title))}</td><td>{html.escape(str(r.top3_title))}</td><td>{html.escape(str(r.notes))}</td></tr>"
        for r in context.itertuples(index=False)
    )

    html_doc = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>DataEye 红果漫剧公开样本趋势报告</title>
  <style>
    body {{ margin: 0; background: #f8fafc; color: #0f172a; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    .page {{ max-width: 1220px; margin: 0 auto; padding: 28px 24px 56px; }}
    h1, h2 {{ margin: 0 0 12px; }}
    p, li {{ line-height: 1.65; }}
    .subtle {{ color: #64748b; }}
    .cards {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin: 22px 0; }}
    .card, .panel {{ background: white; border: 1px solid #e2e8f0; border-radius: 16px; box-shadow: 0 10px 30px rgba(15,23,42,.08); }}
    .card {{ padding: 18px 20px; }}
    .label {{ color: #64748b; font-size: 13px; }}
    .value {{ font-size: 28px; font-weight: 700; margin-top: 6px; }}
    .panel {{ padding: 18px 20px; margin-top: 18px; overflow: auto; }}
    .grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }}
    .chart-svg {{ width: 100%; height: auto; display: block; }}
    .idea-card {{ border: 1px solid #e2e8f0; border-radius: 14px; padding: 16px 18px; margin-top: 14px; background: #f8fafc; }}
    .idea-card h3 {{ margin: 0 0 8px; }}
    .idea-grid {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }}
    .title-block {{ border-top: 1px solid #e2e8f0; padding-top: 12px; margin-top: 12px; }}
    .title-block ol {{ columns: 2; column-gap: 28px; }}
    .badge {{ display: inline-block; padding: 3px 8px; border-radius: 999px; background:#ede9fe; color:#6d28d9; font-size:12px; font-weight:600; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
    th, td {{ padding: 9px 8px; border-bottom: 1px solid #e2e8f0; text-align: left; vertical-align: top; }}
    th {{ color: #64748b; font-weight: 600; }}
    @media (max-width: 980px) {{ .cards, .grid, .idea-grid {{ grid-template-columns: 1fr; }} .title-block ol {{ columns: 1; }} }}
  </style>
</head>
<body>
  <div class="page">
    <h1>DataEye 红果漫剧公开样本趋势报告 <span class="badge">AI/漫剧口径</span></h1>
    <p class="subtle">样本区间：{date_min} ~ {date_max}。本报告基于现有红果公开样本中提到“漫剧 / AI / 仿真人漫 / 真人AI版”的摘要整理；不是完整漫剧榜单。</p>
    <div class="cards">
      <div class="card"><div class="label">漫剧相关信号</div><div class="value">{len(events)}</div></div>
      <div class="card"><div class="label">可确认具体剧名</div><div class="value">{disclosed}</div></div>
      <div class="card"><div class="label">有数值信号</div><div class="value">{quant}</div></div>
      <div class="card"><div class="label">结构性席位数</div><div class="value">{int(events['manju_count'].sum())}</div></div>
    </div>
    <div class="panel">
      <h2>结论速览</h2>
      <ul>{''.join(f'<li>{html.escape(x)}</li>' for x in insights)}</ul>
    </div>
    <div class="panel">
      <h2>漫剧公开信号趋势</h2>
      <p class="subtle">紫色/红色圆点为可量化热度或播放信号；橙色菱形为仅披露排名/结构、不披露具体热度的信号。</p>
      {render_signal_svg(events)}
    </div>
    <div class="grid">
      <div class="panel">
        <h2>信号类型分布</h2>
        <p class="subtle">按公开摘要中的漫剧席位数/单剧数粗略计数。</p>
        {render_type_bar_svg(events)}
      </div>
      <div class="panel">
        <h2>口径提醒</h2>
        <ul>
          <li>“热度8658W”与“日播3.3亿”可能不是同一指标，不能直接相加或做均值。</li>
          <li>“包揽总榜TOP4 / 闯入TOP3”是结构信号，说明位置强，但不能反推出单剧热度。</li>
          <li>下一步最好补齐独立漫剧榜单CSV：日期、排名、剧名、热度、播放量、题材、出品方、来源链接。</li>
        </ul>
      </div>
    </div>
    <div class="panel">
      <h2>内容策略建议</h2>
      {render_strategy_cards()}
    </div>
    <div class="panel">
      <h2>漫剧标题生成器</h2>
      <p class="subtle">按“真人AI玄幻 / 系统爽感 / 家庭婚恋融合”三类生成，适合做选题会初筛；上线前需查重、合规和视觉可实现性评估。</p>
      {title_blocks}
    </div>
    <div class="panel">
      <h2>漫剧信号明细</h2>
      <table>
        <thead><tr><th>日期</th><th>信号类型</th><th>剧名/描述</th><th>数值</th><th>排名/位置</th><th>指标说明</th><th>备注</th><th>来源</th></tr></thead>
        <tbody>{event_rows}</tbody>
      </table>
    </div>
    <div class="panel">
      <h2>原始公开样本上下文</h2>
      <table>
        <thead><tr><th>日期</th><th>真人/原榜Top1</th><th>Top1热度</th><th>Top2</th><th>Top3</th><th>公开摘要</th></tr></thead>
        <tbody>{context_rows}</tbody>
      </table>
    </div>
  </div>
</body>
</html>"""
    output_path.write_text(html_doc, encoding="utf-8")
    return title_df


def export_manju_report(input_path: Path, output_dir: Path) -> dict[str, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    events, context = extract_manju_events(input_path)
    report_path = output_dir / "manju_public_sample_report.html"
    titles_path = output_dir / "manju_generated_titles.csv"
    events_path = output_dir / "manju_public_signals.csv"
    context_path = output_dir / "manju_source_context.csv"
    title_df = render_report(events, context, report_path)
    events.to_csv(events_path, index=False)
    context.to_csv(context_path, index=False)
    title_df.to_csv(titles_path, index=False)
    return {"report": report_path, "signals": events_path, "context": context_path, "generated_titles": titles_path}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="基于红果公开样本中AI/漫剧相关摘要生成漫剧趋势报告。")
    parser.add_argument("--input", default="output/hongguo_public_samples/dataeye_hongguo_public_samples.csv")
    parser.add_argument("--output-dir", default="output/hongguo_manju_public_samples/report")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    outputs = export_manju_report(Path(args.input), Path(args.output_dir))
    print("漫剧公开样本趋势报告已生成：")
    for name, path in outputs.items():
        print(f"- {name}: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
