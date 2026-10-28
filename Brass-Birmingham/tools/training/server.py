"""P2 推理服务:TCP,长度前缀二进制帧(见 bb.py/NeuralProtocol),10ms 批量窗口。

用法:tools/training/.venv/bin/python server.py --checkpoint runs/incumbent.pt [--port 7745] [--device mps]
"""
import argparse
import socket
import struct
import threading
import time

import numpy as np
import torch

# MPS 单流:多线程并发前向会互相卡死(夜9 双自博弈进程复现)。
# 前向全程持锁串行化;推理毫秒级,自博弈客户端本就串行请求,吞吐几乎无损。
FORWARD_LOCK = threading.Lock()

from bb import BrassNet, FEATURE_DIM, POLICY_A, POLICY_B, RESPONSE_FLOATS, VALUE

parser = argparse.ArgumentParser()
parser.add_argument("--checkpoint", default="runs/incumbent.pt")
parser.add_argument("--port", type=int, default=7745)
parser.add_argument("--device", default="cpu")  # 默认 cpu:分片逐字节可复现(spec §8.2);mps 显式传参
args = parser.parse_args()

checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
model = BrassNet()
model.load_state_dict(checkpoint["state_dict"])
device = torch.device(args.device)
model.to(device).eval()
print(f"SERVER-READY device={device} checkpoint={args.checkpoint}", flush=True)


def recv_exactly(conn, count):
    chunks = []
    while count > 0:
        chunk = conn.recv(min(count, 65536))
        if not chunk:
            raise ConnectionError("peer closed")
        chunks.append(chunk)
        count -= len(chunk)
    return b"".join(chunks)


def handle_connection(conn):
    with conn:
        while True:
            header = recv_exactly(conn, 8)
            count, dim = struct.unpack("<II", header)
            assert dim == FEATURE_DIM, f"维度不符: {dim}"
            body = np.frombuffer(recv_exactly(conn, count * dim * 2), dtype="<f2")
            features = torch.from_numpy(body.astype(np.float32)).reshape(count, dim).to(device)
            with FORWARD_LOCK, torch.no_grad():
                logits_a, logits_b, values = model(features)
            # 帧协议:逐样本交错 count×(A[8]+B[31]+V[4])(终审 C1:
            # 此前块状布局与 Swift 解码器静默错位,仅 count=1 时巧合一致)。
            a = logits_a.float().cpu().numpy().astype("<f4")
            b = logits_b.float().cpu().numpy().astype("<f4")
            v = values.float().cpu().numpy().astype("<f4")
            payload = struct.pack("<I", count)
            for sample in range(count):
                payload += a[sample].tobytes() + b[sample].tobytes() + v[sample].tobytes()
            conn.sendall(payload)


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", args.port))
listener.listen(16)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=handle_connection, args=(connection,), daemon=True).start()
