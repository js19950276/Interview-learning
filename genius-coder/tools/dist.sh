#!/bin/zsh
# Layer ① distribution: one folder, one command.
#   dist/genius-bridge/genius-bridge serve
set -e
cd "$(dirname "$0")/.."
OUT=dist/genius-bridge
rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> release binary"
swift build --scratch-path /tmp/gc-build -c release --product genius-bridge-cli
cp /tmp/gc-build/out/Products/Release/genius-bridge-cli "$OUT/genius-bridge"

echo "==> SPM resource bundle (ClaudeHost helper)"
BUNDLE=$(ls -d /tmp/gc-build/out/Products/Release/*.bundle 2>/dev/null | head -1)
[ -n "$BUNDLE" ] && cp -R "$BUNDLE" "$OUT/" || echo "    !! resource bundle not found in build products"

echo "==> bundling libzstd (dlopen'd by absolute path)"
ZSTD=/Library/Frameworks/Python.framework/Versions/3.14/lib/libzstd.dylib
[ -f "$ZSTD" ] && cp "$ZSTD" "$OUT/libzstd.dylib" || echo "    !! CPython libzstd missing; dsh history will need GENIUS_CODER_LIBZSTD"

TS_HELPER=""
if [ -x vendor/bin/gc-tsnet-helper ]; then
    TS_HELPER=vendor/bin/gc-tsnet-helper
elif [ -x "$HOME/.gc-toolchain/go/bin/go" ]; then
    echo "==> building embedded tailscale helper from source (Go)"
    (cd tools/tsnet-helper && GOPROXY=https://goproxy.cn GOTOOLCHAIN=local CGO_ENABLED=0 \
        "$HOME/.gc-toolchain/go/bin/go" build -ldflags="-s -w" -o ../../vendor/bin/gc-tsnet-helper .) \
        && TS_HELPER=vendor/bin/gc-tsnet-helper || true
fi
if [ -n "$TS_HELPER" ]; then
    echo "==> bundling embedded tailscale (tsnet helper)"
    cp "$TS_HELPER" "$OUT/gc-tsnet-helper"
else
    echo "    !! tsnet helper unavailable (remote access disabled; LAN still works)"
fi

echo "==> README"
cat > "$OUT/README.txt" <<'TXT'
genius-coder bridge — 运行:  ./genius-bridge serve
  首次: 终端会打印配对二维码, 用手机 app 扫码。
  远程(可选): 设置 TS_AUTHKEY 环境变量(或首次按终端提示浏览器登录),
             手机 app 内置 tsnet, 无需安装 Tailscale。
  Claude 续聊(可选): 见主仓库 Apps/Bridge 文档, npm install 钉版本。
TXT
echo "==> done: $OUT"
ls -la "$OUT"
