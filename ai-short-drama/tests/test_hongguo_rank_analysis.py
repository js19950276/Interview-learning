from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from analysis.hongguo_rank_analysis import export_analysis


def make_sample_frame() -> pd.DataFrame:
    rows = []
    base_rows = [
        ("2026-05-01", 1, "闪婚后总裁老公天天宠", 9800, "总裁,闪婚", "先婚后爱，甜宠"),
        ("2026-05-01", 2, "重生后我在侯府杀疯了", 9600, "重生,侯府", "重生复仇"),
        ("2026-05-01", 3, "团宠萌宝帮妈妈打脸", 9200, "萌宝,亲情", "亲情萌宝"),
        ("2026-05-02", 1, "闪婚后总裁老公天天宠", 9950, "总裁,闪婚", "先婚后爱，甜宠"),
        ("2026-05-02", 2, "末世觉醒后我绑定神豪系统", 9700, "末世,系统", "末世系统爽文"),
        ("2026-05-02", 3, "团宠萌宝帮妈妈打脸", 9100, "萌宝,亲情", "亲情萌宝"),
        ("2026-05-03", 1, "末世觉醒后我绑定神豪系统", 9990, "末世,系统", "末世系统爽文"),
        ("2026-05-03", 2, "重生后我在侯府杀疯了", 9750, "重生,侯府", "重生复仇"),
        ("2026-05-03", 3, "山村神医从退婚开始", 9000, "乡村,神医", "乡村逆袭"),
        ("2026-05-04", 1, "末世觉醒后我绑定神豪系统", 10020, "末世,系统", "末世系统爽文"),
        ("2026-05-04", 2, "闪婚后总裁老公天天宠", 9700, "总裁,闪婚", "先婚后爱，甜宠"),
        ("2026-05-04", 3, "山村神医从退婚开始", 9150, "乡村,神医", "乡村逆袭"),
    ]
    for row in base_rows:
        rows.append(
            {
                "snapshot_date": row[0],
                "rank": row[1],
                "title": row[2],
                "heat_value": row[3],
                "source_tags": row[4],
                "synopsis": row[5],
            }
        )
    return pd.DataFrame(rows)


def main() -> None:
    frame = make_sample_frame()
    with tempfile.TemporaryDirectory() as tmpdir:
        output_dir = Path(tmpdir) / "analysis"
        outputs = export_analysis(frame, output_dir)

        required = {
            "cleaned",
            "title_summary",
            "daily_summary",
            "weekly_summary",
            "new_title_summary",
            "insights",
            "report",
        }
        assert required == set(outputs.keys())
        for path in outputs.values():
            assert path.exists(), f"missing output: {path}"

        cleaned = pd.read_csv(outputs["cleaned"])
        assert "primary_tag_l1" in cleaned.columns
        assert set(cleaned["primary_tag_l1"]) >= {"现代情感", "穿越/重生", "奇幻/系统", "家庭/亲情"}

        daily = pd.read_csv(outputs["daily_summary"])
        assert "rank_share_7d" in daily.columns
        latest = daily[daily["snapshot_date"] == "2026-05-04"]
        assert abs(latest["rank_share"].sum() - 1.0) < 1e-9

        report_html = outputs["report"].read_text(encoding="utf-8")
        assert "DataEye 红果热榜 Top100 标签趋势报告" in report_html

    print("[PASS] hongguo_rank_analysis")


if __name__ == "__main__":
    main()
