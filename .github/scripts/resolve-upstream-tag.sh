#!/usr/bin/env bash
# 解析本次构建使用的上游 release tag，并核实它真实存在。
#
# 用法：resolve-upstream-tag.sh [<tag>|latest]
#   不带参数   → 用 .github/upstream/tag 里写的（具体 tag 或 latest）
#   latest     → 上游当前最新的 vX.Y.Z（不含 v1.7.4-pre-1 这类预发布 tag）
#   <tag>      → 指定的 tag，如 v1.9.4
#
# 输出到 stdout（可直接 >> "$GITHUB_OUTPUT"）：
#   tag=<tag>
#   commit=<该 tag 指向的 commit SHA；注解 tag 已解引用成 commit>
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ggml-org/whisper.cpp.git}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

want="${1:-}"
if [ -z "$want" ]; then
  want="$(tr -d '[:space:]' < "$here/../upstream/tag")"
fi

if [ "$want" = latest ]; then
  # --refs 去掉注解 tag 的 ^{} 行；再只保留 vX.Y.Z。
  # 取第一行用 sed -n '1p'，不用 head：pipefail 下 head 提前退出会让上游命令吃 SIGPIPE。
  all="$(git ls-remote --tags --refs --sort=-v:refname "$UPSTREAM_URL" 'v[0-9]*')"
  want="$(printf '%s\n' "$all" | sed -n -E 's#.*refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+)$#\1#p' | sed -n '1p')"
  if [ -z "$want" ]; then
    echo "::error::在 $UPSTREAM_URL 找不到 vX.Y.Z 形式的 tag" >&2
    exit 1
  fi
fi

if ! printf '%s' "$want" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "::error::tag 必须形如 vX.Y.Z，实际是：'$want'" >&2
  exit 1
fi

# 注解 tag 返回两行（tag 对象 + ^{} 解引用后的 commit），轻量 tag 只有一行
refs="$(git ls-remote "$UPSTREAM_URL" "refs/tags/$want" "refs/tags/$want^{}")"
commit="$(printf '%s\n' "$refs" | sed -n -E 's#^([0-9a-f]{40})[[:space:]]+refs/tags/.*\^\{\}$#\1#p' | sed -n '1p')"
if [ -z "$commit" ]; then
  commit="$(printf '%s\n' "$refs" | sed -n -E 's#^([0-9a-f]{40})[[:space:]]+refs/tags/[^^]*$#\1#p' | sed -n '1p')"
fi
if [ -z "$commit" ]; then
  echo "::error::上游 $UPSTREAM_URL 没有 tag '$want'" >&2
  exit 1
fi

echo "tag=$want"
echo "commit=$commit"
