"""生成随机初始化 checkpoint(冷启动:selfplay 对着一个随机网收集第一批数据)。"""
import argparse

import torch

from bb import BrassNet

parser = argparse.ArgumentParser()
parser.add_argument("--out", default="runs/incumbent.pt")
args = parser.parse_args()

torch.manual_seed(20261022)
model = BrassNet()
torch.save({"state_dict": model.state_dict(), "features_version": 1}, args.out)
print(f"INIT-CHECKPOINT saved {args.out}")
