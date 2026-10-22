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
    import errno
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, f"{kind}:{os.getpid()}".encode())
        os.close(fd)
        return
    except FileExistsError:
        pass
    # 锁已存在:读 pid 判存活,死进程的残留锁接管(终审 I4:kill -9 残留不死锁)。
    try:
        with open(LOCK) as fh:
            holder = fh.read().strip()
        pid = int(holder.split(":")[-1])
        os.kill(pid, 0)  # 存活则抛错;不存在抛 ProcessLookupError
        print(f"TRAIN-LOCK-REFUSED holder={holder}")
        sys.exit(5)
    except (ValueError, ProcessLookupError, PermissionError):
        pass  # 残留/损坏锁:接管
    except OSError:
        print(f"TRAIN-LOCK-REFUSED holder={holder}")
        sys.exit(5)
    os.remove(LOCK)
    acquire_lock(kind)
try:
    acquire_lock("train")
    files = sorted(glob.glob(os.path.join(args.shards, "**", "*.bin"), recursive=True),
                   key=os.path.getmtime)
    if not files:
        print("TRAIN-NO-DATA")
        sys.exit(6)
    # I8:特征保持 f16 常驻(内存 减半以上),训练步按批物化 f32(spec §9.1 memmap 精神)。
    feats, pas, pbs, vals = [], [], [], []
    for path in files:
        f, pa, pb, v, _ = read_shard(path)
        feats.append(f); pas.append(pa); pbs.append(pb); vals.append(v)
    X16 = np.concatenate(feats)
    YA = np.concatenate(pas).astype(np.float32)
    YB = np.concatenate(pbs).astype(np.float32)
    YV = np.concatenate(vals).astype(np.float32)
    # 滑窗:取最新 window 样本。
    if X16.shape[0] > args.window:
        X16, YA, YB, YV = X16[-args.window:], YA[-args.window:], YB[-args.window:], YV[-args.window:]
    print(f"TRAIN-DATA samples={X16.shape[0]} shards={len(files)} dim={X16.shape[1]}")

    if args.overfit_batch:
        X16, YA, YB, YV = X16[:512], YA[:512], YB[:512], YV[:512]

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = BrassNet().to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.steps)
    xt16 = torch.from_numpy(X16)  # f16 常驻 CPU;按批转 f32 上设备
    xt = None
    ya = torch.from_numpy(YA).to(device)
    yb = torch.from_numpy(YB).to(device)
    yv = torch.from_numpy(YV).to(device)

    def full_features() -> torch.Tensor:
        return xt16.to(device).float()

    def evaluate_metrics():
        model.eval()
        with torch.no_grad():
            la, lb, lv = model(full_features())
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

    count = xt16.shape[0]
    generator = torch.Generator().manual_seed(2026)
    started = time.time()
    for step in range(1, args.steps + 1):
        index = torch.randint(0, count, (min(args.batch, count),), generator=generator)
        xb = xt16[index].to(device).float()
        la, lb, lv = model(xb)
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
        ok = acc_a >= 0.9 and mse <= max(mse0 / 4, 1e-4)  # 0.904 实测过线,维持原计划线
        print(f"TRAIN-OVERFIT {'OK' if ok else 'FAIL'}")
    torch.save({"state_dict": model.state_dict(), "features_version": 1}, args.out)
    print(f"TRAIN-SAVED {args.out}")
finally:
    if os.path.exists(LOCK):
        os.remove(LOCK)
