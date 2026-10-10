#!/usr/bin/env bash
# 检查编出来的 addon 里确实带着补丁 0002（逐 token 时间戳 + VAD 语音段）。
#
# 缺了它不会让构建或运行报错：SmartSub 只会悄悄回退到粗粒度的段级时间轴，所以在构建阶段就拦住。
# 检查产物里的两个 C 字符串常量：
#   token_timestamps  JS 侧的参数名
#   vadSegments       返回结果里的字段名
# 要求常量独立存在（前面不是标识符字符、后面紧跟 NUL），不能只是子串匹配：
# whisper 核心里有一句 "dtw_token_timestamps is not supported with flash_attn"，
# 没打补丁的产物里也含有 token_timestamps 这个子串（在 v1.9.5 上实测）。
#
# 用法：check-addon-features.sh <addon.node 文件>...
# 注意：要检查压缩前的 .node，不是 .gz / .tar.gz。
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "用法: check-addon-features.sh <addon.node 文件>..." >&2
  exit 2
fi

# Windows 上 python3 可能只是应用商店的占位程序，所以要真的跑一下确认能用
py=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys' >/dev/null 2>&1; then
    py="$cand"
    break
  fi
done
if [ -z "$py" ]; then
  echo "::error::找不到可用的 python3 / python" >&2
  exit 2
fi

"$py" - "$@" <<'PY'
import re
import sys

KEYS = ["token_timestamps", "vadSegments"]
failed = False
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        print(f"::error::无法读取 {path}: {e}", file=sys.stderr)
        failed = True
        continue
    missing = [
        k for k in KEYS
        if not re.search(rb"(?<![A-Za-z0-9_])" + re.escape(k.encode()) + rb"\x00", data)
    ]
    if missing:
        print(f"::error::{path} 里没有 {', '.join(missing)}：补丁 0002（tokens / vadSegments）没有编进产物", file=sys.stderr)
        failed = True
    else:
        print(f"ok: {path}")
sys.exit(1 if failed else 0)
PY
