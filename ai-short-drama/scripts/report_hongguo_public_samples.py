#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from analysis.hongguo_public_sample_report import main


if __name__ == "__main__":
    raise SystemExit(main())
