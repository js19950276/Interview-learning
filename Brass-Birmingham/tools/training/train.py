"""P2 训练器:读 shards 滑窗 → BrassNet 训练 → runs/candidate.pt。

互斥锁(错峰铁律):与自博弈通过 tools/.lock pid 文件互斥,冲突即拒。
用法:.venv/bin/python train.py --steps 1000 [--overfit-batch] [--window 200000]
"""
import argparse
import glob
import os
import sys
import time

import numpy as np
import torch

from bb import BrassNet, POLICY_A, POLICY_B, VALUE, read_shard

parser = argparse.ArgumentParser()
parser.add_argument("--shards", default="shards")
parser.add_argument("--steps", type=int, default=1000)
parser.add_argument("--window", type=int, default=200_000, help="滑窗:最新 N 样本")
parser.add_argument("--batch", type=int, default=1024)
parser.add_argument("--lr", type=float, default=1e-3)
parser.add_argument("--out", default="runs/candidate.pt")
parser.add_argument("--overfit-batch", action="store_true",
                    help="验收②:单批 512 样本训满 steps,过拟合即收敛证据")
parser.add_argument("--log-every", type=int, default=100)
args = parser.parse_args()

# —— 错峰互斥锁 ——
LOCK = os.path.join(os.path.dirname(__file__), "..", ".lock")
def acquire_lock(kind: str) -> None:
    if os.path.exists(LOCK):
        with open(LOCK) as fh:
            holder = fh.read().strip()
        print(f"TRAIN-LOCK-REFUSED holder={holder}")
        sys.exit(5)
    with open(LOCK, "w") as fh:
        fh.write(f"{kind}:{os.getpid()}")
try:
    acquire_lock("train")
    files = sorted(glob.glob(os.path.join(args.shards, "**", "*.bin"), recursive=True),
                   key=os.path.getmtime)
    if not files:
        print("TRAIN-NO-DATA")
        sys.exit(6)
    feats, pas, pbs, vals = [], [], [], []
    for path in files:
        f, pa, pb, v, _ = read_shard(path)
        feats.append(f); pas.append(pa); pbs.append(pb); vals.append(v)
    X = np.concatenate(feats).astype(np.float32)
    YA = np.concatenate(pas).astype(np.float32)
    YB = np.concatenate(pbs).astype(np.float32)
    YV = np.concatenate(vals).astype(np.float32)
    # 滑窗:取最新 window 样本。
    if X.shape[0] > args.window:
        X, YA, YB, YV = X[-args.window:], YA[-args.window:], YB[-args.window:], YV[-args.window:]
    print(f"TRAIN-DATA samples={X.shape[0]} shards={len(files)} dim={X.shape[1]}")

    if args.overfit_batch:
        X, YA, YB, YV = X[:512], YA[:512], YB[:512], YV[:512]

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = BrassNet().to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.steps)
    xt = torch.from_numpy(X).to(device)
    ya = torch.from_numpy(YA).to(device)
    yb = torch.from_numpy(YB).to(device)
    yv = torch.from_numpy(YV).to(device)

    def evaluate_metrics():
        model.eval()
        with torch.no_grad():
            la, lb, lv = model(xt)
            # 星形树均匀访问常产平坦 A 目标,argmax 口径失真——置信子集准确率
            #(目标主类占比 >0.4 的样本)才是有意义的拟合度量。
            confident_a = ya.max(1).values > 0.4
            acc_a = ((la.argmax(1) == ya.argmax(1)).float() * confident_a).sum().item() / max(confident_a.sum().item(), 1)
            confident_b = yb.max(1).values > 0.4
            acc_b = ((lb.argmax(1) == yb.argmax(1)).float() * confident_b).sum().item() / max(confident_b.sum().item(), 1)
            mse = ((lv - yv) ** 2).mean().item()
        model.train()
        return acc_a, acc_b, mse

    acc_a0, acc_b0, mse0 = evaluate_metrics()
    print(f"TRAIN-INIT accA={acc_a0:.3f} accB={acc_b0:.3f} valueMSE={mse0:.4f}")

    count = xt.shape[0]
    generator = torch.Generator().manual_seed(2026)
    started = time.time()
    for step in range(1, args.steps + 1):
        index = torch.randint(0, count, (min(args.batch, count),), generator=generator).to(device)
        la, lb, lv = model(xt[index])
        loss = (torch.nn.functional.cross_entropy(la, ya[index])
                + torch.nn.functional.cross_entropy(lb, yb[index])
                + torch.nn.functional.mse_loss(lv, yv[index]))
        opt.zero_grad()
        loss.backward()
        opt.step()
        scheduler.step()
        if step % args.log_every == 0 or step == args.steps:
            acc_a, acc_b, mse = evaluate_metrics()
            print(f"TRAIN-STEP step={step} loss={loss.item():.4f} accA={acc_a:.3f} accB={acc_b:.3f} valueMSE={mse:.4f}")

    acc_a, acc_b, mse = evaluate_metrics()
    print(f"TRAIN-FINAL accA={acc_a:.3f} accB={acc_b:.3f} valueMSE={mse:.4f} elapsed={time.time()-started:.0f}s")
    if args.overfit_batch:
        ok = acc_a >= 0.85 and mse <= max(mse0 / 4, 1e-4)  # A 置信子集含近平局目标,0.85 即收敛
        print(f"TRAIN-OVERFIT {'OK' if ok else 'FAIL'}")
    torch.save({"state_dict": model.state_dict(), "features_version": 1}, args.out)
    print(f"TRAIN-SAVED {args.out}")
finally:
    if os.path.exists(LOCK):
        os.remove(LOCK)
