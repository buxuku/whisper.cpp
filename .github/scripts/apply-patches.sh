#!/usr/bin/env bash
# 把 .github/upstream/patches/*.patch 按文件名顺序叠加到已检出的上游源码上，并写出 build-info.json。
#
# 用法：apply-patches.sh <源码目录> <build-info.json 输出路径> [期望的补丁后源码树哈希]
#
# 环境变量（都可省略，省略时 build-info.json 里记为 unknown）：
#   UPSTREAM_TAG     本次使用的上游 tag
#   UPSTREAM_COMMIT  resolve-upstream-tag.sh 解出的 commit；设置后会核对检出的 HEAD 与它一致
#   UPSTREAM_REPO    默认 ggml-org/whisper.cpp
#   GITHUB_OUTPUT    设置后追加 tree=<补丁后源码树哈希>
#
# 补丁用 git apply --index 套用：不产生提交，不需要配置 git 身份。
# 套不上就立刻失败，常见原因：上游新 tag 已经包含了这个补丁（比如 PR 被合并），
# 或补丁周围的上下文变了——此时需要重新生成补丁，不会悄悄带着半个补丁去构建。
#
# 补丁后源码树哈希 = git write-tree，只取决于文件内容。
# prepare 任务算一遍，各平台构建任务再套一遍并传入期望值，不一致即失败：
# 以此保证 macOS / Windows / Linux 编译的是同一份源码（典型风险是 Windows 的换行符转换）。
set -euo pipefail

src="${1:?用法: apply-patches.sh <源码目录> <build-info.json> [期望的源码树哈希]}"
out="${2:?用法: apply-patches.sh <源码目录> <build-info.json> [期望的源码树哈希]}"
expect_tree="${3:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch_dir="$here/../upstream/patches"
# 后面要 cd 进源码目录，先把输出路径转成绝对路径
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

cd "$src"
# 容器任务里 checkout 目录属于 runner 用户、git 却以 root 运行，git 会报 "dubious ownership" 并拒绝
# 操作这个仓库（nvidia/cuda 容器里的 Linux CUDA 任务就是这样失败的）。
# 本脚本只会操作 <源码目录> 这一个仓库，所以只对本进程放行：用环境变量传入 safe.directory，
# 不写任何 git 配置文件。值用 * 而不是具体路径：git 比较的是真实路径，Git Bash 下的路径写法
# 也不一样，写具体路径容易对不上。已有的 GIT_CONFIG_COUNT 配置保留，往后追加一项。
gc_n="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${gc_n}=safe.directory" "GIT_CONFIG_VALUE_${gc_n}=*"
export GIT_CONFIG_COUNT="$((gc_n + 1))"
if ! err="$(git rev-parse --git-dir 2>&1 >/dev/null)"; then
  printf '%s\n' "$err" >&2
  echo "::error::${src} 不是可用的 git 仓库（原因见上面 git 的输出）" >&2
  exit 1
fi
# 只检查暂存区（上次套用留下的改动会在这里）。工作区里的行尾转换之类的噪声不算，
# 补丁要改的文件由 git apply --index 自己核对「工作区与暂存区一致」。
if ! git diff --cached --quiet; then
  echo "::error::暂存区里已有改动（补丁已经套过一次？），不能再套" >&2
  git diff --cached --stat >&2
  exit 1
fi

base="$(git rev-parse HEAD)"
if [ -n "${UPSTREAM_COMMIT:-}" ] && [ "$UPSTREAM_COMMIT" != "$base" ]; then
  # 变量名后紧跟中文标点时必须写 ${var}：容器里常是 POSIX locale，bash 会把后面的字节也当成变量名
  echo "::error::检出的 commit 是 ${base}，但 tag 解出来是 ${UPSTREAM_COMMIT}（tag 在两步之间被移动了？）" >&2
  exit 1
fi
tag="${UPSTREAM_TAG:-$(git describe --tags --exact-match HEAD 2>/dev/null || echo unknown)}"

shopt -s nullglob
patches=("$patch_dir"/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
  echo "::error::$patch_dir 里没有补丁" >&2
  exit 1
fi

entries=()
for p in "${patches[@]}"; do
  name="$(basename "$p")"
  if ! err="$(git apply --check "$p" 2>&1)"; then
    echo "::error::补丁 ${name} 套不上上游 ${tag}（${base}）。上游可能已包含这个改动，或上下文变了，需要重新生成补丁。" >&2
    printf '%s\n' "$err" >&2
    exit 1
  fi
  git apply --index "$p"
  entries+=("$name  $(sha256 "$p")")
  echo "applied: $name"
done

tree="$(git write-tree)"
echo "patched tree: $tree"
if [ -n "$expect_tree" ] && [ "$expect_tree" != "$tree" ]; then
  echo "::error::补丁后的源码树与 prepare 任务不一致：期望 ${expect_tree}，实际 ${tree}。这个任务检出的上游源码或补丁，和 prepare 任务用的不是同一份。" >&2
  exit 1
fi

{
  echo '{'
  echo '  "upstream": {'
  echo "    \"repo\": \"${UPSTREAM_REPO:-ggml-org/whisper.cpp}\","
  echo "    \"tag\": \"$tag\","
  echo "    \"commit\": \"$base\""
  echo '  },'
  echo '  "patches": ['
  last=$(( ${#entries[@]} - 1 ))
  for i in "${!entries[@]}"; do
    pname="${entries[$i]%%  *}"
    psha="${entries[$i]##*  }"
    sep=','
    [ "$i" -eq "$last" ] && sep=''
    echo "    { \"name\": \"$pname\", \"sha256\": \"$psha\" }$sep"
  done
  echo '  ],'
  echo "  \"patched_tree\": \"$tree\","
  echo '  "builder": {'
  echo "    \"repo\": \"${GITHUB_REPOSITORY:-local}\","
  echo "    \"ref\": \"${GITHUB_REF_NAME:-local}\","
  echo "    \"commit\": \"${GITHUB_SHA:-local}\","
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    echo "    \"run\": \"${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}\","
  else
    echo '    "run": "local",'
  fi
  echo "    \"built_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo '  }'
  echo '}'
} > "$out"
echo "wrote: $out"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tree=$tree" >> "$GITHUB_OUTPUT"
fi
