#!/usr/bin/env bash
# 在「国内机器」上手动执行：从 GitHub latest 拉取 whisper.cpp addon / CUDA 产物，再推送到 GitCode。
# 上传段复用 scripts/sync-gitcode-release.sh（SYNC_SOURCE=artifacts）。
#
# 解决的问题（对应 builder.yml 里 sync-gitcode-release job 在境外 runner 上传 GitCode 卡死）：
#   - 「下载 + 上传」整段放到国内本机执行 → 上传 GitCode 走域内网络，快且稳；
#   - GitHub 下载段可选走 ghproxy 镜像加速（USE_GHPROXY=1），CUDA tar.gz 单个 ~1GB+ 收益明显；
#   - 先比对 GitHub 与 GitCode 的 addon-versions.json：一致且产物齐全则跳过，不重复传；
#   - 下载后按 addon-versions.json 里的 sha256 校验 CUDA/Vulkan 产物完整性（ghproxy 偶发坏包）；
#   - 仅在上传成功后删除本地临时文件。
#
# 用法：
#   export GITCODE_TOKEN=<你的 GitCode 个人令牌>
#   bash scripts/sync-gitcode-from-github.sh                  # 默认走 ghproxy 加速下载
#   USE_GHPROXY=0 bash scripts/sync-gitcode-from-github.sh    # 直连 GitHub 下载
#   FORCE=1 bash scripts/sync-gitcode-from-github.sh          # 跳过新鲜度检查强制同步
#   SKIP_VERIFY=1 bash scripts/sync-gitcode-from-github.sh    # 跳过 sha256 校验
#
# 依赖：curl、jq、python3（上传复用 sync-gitcode-release.sh，需要 bash）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GH_REPO="${GH_REPO:-buxuku/whisper.cpp}"
GH_TAG="${GH_TAG:-latest}"
GITCODE_OWNER="${GITCODE_OWNER:-buxuku1}"
GITCODE_REPO="${GITCODE_REPO:-whisper.node}"
GITCODE_TAG="${GITCODE_TAG:-latest}"
# 默认走 ghproxy 镜像加速 GitHub 下载（国内直连 GitHub Release 通常很慢）；
# 如需直连改 USE_GHPROXY=0。
USE_GHPROXY="${USE_GHPROXY:-1}"
GHPROXY_BASE="${GHPROXY_BASE:-https://ghfast.top}"
FORCE="${FORCE:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
WORKDIR="${WORKDIR:-$REPO_ROOT/.gitcode-sync-tmp}"
DL_DIR="$WORKDIR/artifacts"

# 当前构建产物（与 sync-gitcode-release.sh 的 BUILD_FILES 保持一致；
# legacy CUDA 11.8/12.2 由上传脚本按需「缺失才补传」，不在此处下载）。
FILES=(
  "addon-macos-x64.node"
  "addon-macos-arm64.node"
  "addon-macos-arm64-coreml.node"
  "addon-windows-x64.node"
  "addon-linux-x64.node"
  "addon-windows-cuda-1240-optimized.node.gz"
  "windows-cuda-1240-optimized.tar.gz"
  "addon-windows-cuda-1302-optimized.node.gz"
  "windows-cuda-1302-optimized.tar.gz"
  "addon-linux-cuda-1240-optimized.node.gz"
  "linux-cuda-1240-optimized.tar.gz"
  "addon-linux-cuda-1302-optimized.node.gz"
  "linux-cuda-1302-optimized.tar.gz"
  "addon-windows-vulkan.node.gz"
  "addon-linux-vulkan.node.gz"
  "addon-versions.json"
)

log() { echo "[sync] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令: $1" >&2
    exit 1
  }
}

# GitHub 下载基址（USE_GHPROXY=1 时前置 ghproxy 镜像）
gh_base() {
  local base="https://github.com/${GH_REPO}/releases/download/${GH_TAG}"
  if [ "$USE_GHPROXY" = "1" ]; then echo "${GHPROXY_BASE}/${base}"; else echo "$base"; fi
}
gh_url() { echo "$(gh_base)/$1"; }
gitcode_url() { echo "https://gitcode.com/${GITCODE_OWNER}/${GITCODE_REPO}/releases/download/${GITCODE_TAG}/$1"; }

# 读取远端 addon-versions.json（取不到返回空，不报错）
remote_versions() {
  curl -fsSL --connect-timeout 20 --max-time 120 "$1" 2>/dev/null || true
}

# GitCode 上当前构建产物是否齐全（HEAD 探测，任一缺失即返回非 0）
gitcode_has_all_files() {
  local name
  for name in "${FILES[@]}"; do
    curl -fsI --connect-timeout 20 --max-time 60 "$(gitcode_url "$name")" >/dev/null 2>&1 || return 1
  done
  return 0
}

# 依据 addon-versions.json 里的 sha256 生成校验清单并校验（仅校验存在的 CUDA/Vulkan 产物；
# macOS / CPU 版 .node 上游未提供 checksum，跳过）。
verify_checksums() {
  (
    cd "$DL_DIR"
    [ -f addon-versions.json ] || { echo "缺少 addon-versions.json，无法校验" >&2; exit 1; }

    python3 - <<'PY' > checksums.sha256
import json, os
with open("addon-versions.json") as f:
    data = json.load(f)

lines = []
def add(sha, name):
    if sha and os.path.isfile(name):
        lines.append(f"{sha}  {name}")

for cuda_ver, prefix in [("11.8.0","1180"),("12.2.0","1220"),("12.4.0","1240"),("13.0.2","1302")]:
    cs = (data.get(cuda_ver) or {}).get("checksum", {})
    add(cs.get("windows-tar"),  f"windows-cuda-{prefix}-optimized.tar.gz")
    add(cs.get("windows-node"), f"addon-windows-cuda-{prefix}-optimized.node.gz")
    add(cs.get("linux-tar"),    f"linux-cuda-{prefix}-optimized.tar.gz")
    add(cs.get("linux-node"),   f"addon-linux-cuda-{prefix}-optimized.node.gz")

vk = (data.get("vulkan") or {}).get("checksum", {})
add(vk.get("windows-node"), "addon-windows-vulkan.node.gz")
add(vk.get("linux-node"),   "addon-linux-vulkan.node.gz")

print("\n".join(lines))
PY

    if [ ! -s checksums.sha256 ]; then
      log "  addon-versions.json 未提供可校验的 checksum，跳过校验。"
      exit 0
    fi

    log "  校验文件："
    sed 's/^/    /' checksums.sha256
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -c checksums.sha256
    else
      shasum -a 256 -c checksums.sha256
    fi
  )
}

cleanup_local() {
  rm -rf "$WORKDIR"
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd python3
  : "${GITCODE_TOKEN:?需要设置 GITCODE_TOKEN（GitCode 个人令牌）}"

  if [ "$FORCE" != "1" ]; then
    log "比对 GitHub / GitCode 的 addon-versions.json ..."
    local gh_ver gc_ver
    gh_ver="$(remote_versions "$(gh_url addon-versions.json)" | jq -S . 2>/dev/null || true)"
    gc_ver="$(remote_versions "$(gitcode_url addon-versions.json)" | jq -S . 2>/dev/null || true)"
    if [ -n "$gh_ver" ] && [ "$gh_ver" = "$gc_ver" ] && gitcode_has_all_files; then
      log "GitCode 已是最新（addon-versions.json 一致且产物齐全），无需同步。"
      exit 0
    fi
    [ -n "$gh_ver" ] || log "  读取 GitHub addon-versions.json 失败（可加 USE_GHPROXY=1 重试），继续走同步。"
  else
    log "FORCE=1：跳过新鲜度检查。"
  fi

  log "需要同步 → 下载 GitHub 产物到 $DL_DIR"
  mkdir -p "$DL_DIR"
  local name
  for name in "${FILES[@]}"; do
    log "  下载: $name"
    curl -fL --retry 3 --retry-delay 5 \
      --connect-timeout 30 --max-time 3600 \
      -o "$DL_DIR/$name" "$(gh_url "$name")"
  done

  if [ "$SKIP_VERIFY" != "1" ]; then
    log "校验下载完整性 (sha256) ..."
    verify_checksums
  else
    log "SKIP_VERIFY=1：跳过 sha256 校验。"
  fi

  log "推送到 GitCode（复用 sync-gitcode-release.sh，上传段在国内本机执行）..."
  # 上传脚本以 artifacts 模式消费 DL_DIR，并据实际下载的产物重算 addon-versions.json；
  # GITHUB_LEGACY_RELEASE_URL 指向（可选 ghproxy 的）GitHub，用于「缺失才补传」的 legacy 包。
  SYNC_SOURCE=artifacts \
  WORK_DIR="$WORKDIR" \
  ARTIFACTS_DIR="$DL_DIR" \
  GITHUB_LEGACY_RELEASE_URL="$(gh_base)" \
  GITCODE_OWNER="$GITCODE_OWNER" \
  GITCODE_REPO="$GITCODE_REPO" \
  GITCODE_TAG="$GITCODE_TAG" \
    bash "$SCRIPT_DIR/sync-gitcode-release.sh"

  log "上传成功 → 清理本地临时文件 ..."
  cleanup_local
  log "完成：GitCode 已同步 whisper.cpp ${GH_TAG} 产物。"
}

main "$@"
