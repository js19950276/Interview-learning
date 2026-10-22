"""P2 共享常量、模型与分片 IO(与 Swift NeuralProtocol 逐一对应,双端同步改动)。"""
import struct

import numpy as np
import torch
from torch import nn

FEATURES_VERSION = 1
FEATURE_DIM = 1549
POLICY_A = 8
POLICY_B = 31
VALUE = 4
RESPONSE_FLOATS = POLICY_A + POLICY_B + VALUE
SHARD_MAGIC = b"BBSP"
EXPECTED_LAYOUT16 = 55594  # 与 Swift StateEncoder.layoutHash16() 对拍锁定


class BrassNet(nn.Module):
    """spec §6:8×128 残差 MLP;头 A(8 logits)/头 B(31)/价值(4)。"""

    def __init__(self, feature_dim: int = FEATURE_DIM, width: int = 128, depth: int = 8):
        super().__init__()
        self.embed = nn.Linear(feature_dim, width)
        self.blocks = nn.ModuleList([nn.Linear(width, width) for _ in range(depth)])
        self.head_a = nn.Linear(width, POLICY_A)
        self.head_b = nn.Linear(width, POLICY_B)
        self.value = nn.Linear(width, VALUE)

    def forward(self, x: torch.Tensor):
        hidden = torch.relu(self.embed(x))
        for block in self.blocks:
            hidden = torch.relu(hidden + block(hidden))
        return self.head_a(hidden), self.head_b(hidden), self.value(hidden)


def shard_header(features_version: int, layout16: int, sample_count: int, dim: int) -> bytes:
    return SHARD_MAGIC + struct.pack("<HHIII", features_version, layout16, sample_count, dim, 0)


def write_shard(path, features_f16: np.ndarray, policy_a: np.ndarray,
                policy_b: np.ndarray, values: np.ndarray, layout16: int):
    """features_f16: [N, dim] float16;policy_a/b: [N, *] float32;values: [N, 4] float32。"""
    assert features_f16.dtype == np.float16
    count = features_f16.shape[0]
    with open(path, "wb") as fh:
        fh.write(shard_header(FEATURES_VERSION, layout16, count, features_f16.shape[1]))
        fh.write(features_f16.tobytes())
        fh.write(policy_a.astype(np.float32).tobytes())
        fh.write(policy_b.astype(np.float32).tobytes())
        fh.write(values.astype(np.float32).tobytes())


def read_shard(path):
    """返回 (features_f16, policy_a, policy_b, values, header 元组)。"""
    import os
    with open(path, "rb") as fh:
        header = fh.read(20)
        if len(header) < 20 or header[:4] != SHARD_MAGIC:
            raise ValueError(f"非分片或截断文件: {path}")
        version, layout16, count, dim, _ = struct.unpack("<HHIII", header[4:])
        if version != FEATURES_VERSION:
            raise ValueError(f"featuresVersion 不匹配: {version} != {FEATURES_VERSION} ({path})")
        if layout16 != EXPECTED_LAYOUT16:
            raise ValueError(f"布局哈希不匹配: {layout16} != {EXPECTED_LAYOUT16} ({path})")
        if dim != FEATURE_DIM:
            raise ValueError(f"维度不匹配: {dim} != {FEATURE_DIM} ({path})")
        size = os.fstat(fh.fileno()).st_size - 20
        expected = count * (dim * 2 + (POLICY_A + POLICY_B + VALUE) * 4)
        if size != expected:
            raise ValueError(f"截断分片: {size} 字节,期望 {expected} ({path})")
        features = np.frombuffer(fh.read(count * dim * 2), dtype="<f2").reshape(count, dim)
        policy_a = np.frombuffer(fh.read(count * POLICY_A * 4), dtype="<f4").reshape(count, POLICY_A)
        policy_b = np.frombuffer(fh.read(count * POLICY_B * 4), dtype="<f4").reshape(count, POLICY_B)
        values = np.frombuffer(fh.read(count * VALUE * 4), dtype="<f4").reshape(count, VALUE)
        return features, policy_a, policy_b, values, (version, layout16, count, dim)
