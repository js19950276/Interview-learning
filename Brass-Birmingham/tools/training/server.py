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

from bb import BrassNet, FEATURE_DIM, POLICY_A, POLICY_B, RESPONSE_FLOATS, VALUE

parser = argparse.ArgumentParser()
parser.add_argument("--checkpoint", default="runs/incumbent.pt")
parser.add_argument("--port", type=int, default=7745)
parser.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
parser.add_argument("--batch-window-ms", type=int, default=10)
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
            body = np.frombuffer(recv_exactly(conn, count * dim * 2), dtype="<f2")
            features = torch.from_numpy(body.astype(np.float32)).reshape(count, dim).to(device)
            with torch.no_grad():
                logits_a, logits_b, values = model(features)
            payload = struct.pack("<I", count)
            payload += logits_a.float().cpu().numpy().astype("<f4").tobytes()
            payload += logits_b.float().cpu().numpy().astype("<f4").tobytes()
            payload += values.float().cpu().numpy().astype("<f4").tobytes()
            conn.sendall(payload)


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", args.port))
listener.listen(16)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=handle_connection, args=(connection,), daemon=True).start()
