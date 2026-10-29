"""P3 导出:torch checkpoint → CoreML(spec §9.3)。

附带数值对拍:同批输入下 PyTorch vs CoreML 输出容差断言(< 1e-4),
对拍失败即退出非零——绝不把未验证的模型交进 App。
用法:.venv/bin/python export.py [--checkpoint runs/incumbent.pt] [--out runs/BrassNet.mlpackage]
"""
import argparse

import numpy as np
import torch

from bb import BrassNet, FEATURE_DIM, FEATURES_VERSION

parser = argparse.ArgumentParser()
parser.add_argument("--checkpoint", default="runs/incumbent.pt")
parser.add_argument("--out", default="runs/BrassNet.mlpackage")
args = parser.parse_args()

checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
model = BrassNet()
model.load_state_dict(checkpoint["state_dict"])
model.eval()


class Wrapper(torch.nn.Module):
    """CoreML 转换入口:三头一次前向。"""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        a, b, v = self.net(x)
        return torch.softmax(a, dim=-1), torch.softmax(b, dim=-1), torch.sigmoid(v)


wrapper = Wrapper(model).eval()
example = torch.rand(1, FEATURE_DIM)
traced = torch.jit.trace(wrapper, example)

import coremltools as ct

mlmodel = ct.convert(
    traced,
    # Apple Silicon 默认 FP16 计算精度,MLP 上实测偏差 4e-2——强制 FP32
    # (spec §9.3 对拍 <1e-4;1.35MB 模型 FP32 端上推理仍为毫秒级)。
    compute_precision=ct.precision.FLOAT32,
    inputs=[ct.TensorType(name="features", shape=(1, FEATURE_DIM), dtype=np.float32)],
    outputs=[ct.TensorType(name="policyA"), ct.TensorType(name="policyB"), ct.TensorType(name="value")],
    minimum_deployment_target=ct.target.iOS17,
)
mlmodel.author = "brass-birmingham-selfplay"
mlmodel.short_description = f"AlphaZero V1 net;featuresVersion={FEATURES_VERSION};checkpoint={args.checkpoint}"
mlmodel.save(args.out)
print(f"EXPORT-SAVED {args.out}")

# —— 数值对拍(spec §9.3 容差断言)——
rng = np.random.RandomState(2026)
batch = rng.rand(64, FEATURE_DIM).astype(np.float32)
with torch.no_grad():
    ta, tb, tv = wrapper(torch.from_numpy(batch))
pred = mlmodel.predict({"features": batch[:1]})
# CoreML 逐样本预测(实现为批=1;64 样本抽样 8 个对拍足够)。
worst = 0.0
for index in rng.choice(64, 8, replace=False):
    out = mlmodel.predict({"features": batch[index:index + 1]})
    for torch_vec, coreml_key in [(ta[index], "policyA"), (tb[index], "policyB"), (tv[index], "value")]:
        diff = float(np.abs(torch_vec.numpy() - out[coreml_key][0]).max())
        worst = max(worst, diff)
print(f"EXPORT-PARITY worst-abs-diff={worst:.2e}")
assert worst < 1e-4, f"对拍超差: {worst}"
print("EXPORT-OK")
