#!/usr/bin/env bash
# GitCode 上传能力探针（一次性验证，跑完即删，不碰生产 latest release）
#
# 用法:
#   GITCODE_TOKEN=xxx bash scripts/gitcode-probe.sh
#
# 可选环境变量:
#   SIZES_MB="18 20 22 25 30 50"   # Release API 试传的文件大小(MB)梯度
#   DO_LFS=1                        # 是否测试 git/LFS 推送 (1/0)
#   LFS_PLAIN_MB=50                 # 普通 git push 测试文件大小(应 <100MB)
#   LFS_BIG_MB=150                  # git LFS 测试文件大小(应 >100MB)
#   GITCODE_GIT_USER=buxuku1        # GitCode HTTPS 推送用户名(默认=owner)
#
# 目的:
#   1) 精确定位 Release 附件上传 API 的单文件大小硬上限(预期 ~20MB)
#   2) 验证 git push(<=100MB) 与 Git LFS(>100MB) 能否绕过该上限, 并粗测吞吐
set -uo pipefail

GITCODE_OWNER="${GITCODE_OWNER:-buxuku1}"
GITCODE_REPO="${GITCODE_REPO:-whisper.node}"
API="${GITCODE_API_URL:-https://api.gitcode.com/api/v5}"
TAG="${PROBE_TAG:-probe-tmp-$$}"
SIZES_MB="${SIZES_MB:-18 20 22 25 30 50}"
DO_LFS="${DO_LFS:-1}"
LFS_PLAIN_MB="${LFS_PLAIN_MB:-50}"
LFS_BIG_MB="${LFS_BIG_MB:-150}"
GIT_USER="${GITCODE_GIT_USER:-$GITCODE_OWNER}"

: "${GITCODE_TOKEN:?请先 export GITCODE_TOKEN=<你的GitCode令牌>}"
command -v jq >/dev/null || { echo "缺少 jq"; exit 1; }

AUTH=(-H "Authorization: Bearer ${GITCODE_TOKEN}")
WORK="$(mktemp -d)"
RELEASE_ID=""
trap 'rm -rf "$WORK"' EXIT

fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }
mkfile() { # bytes path
  dd if=/dev/urandom of="$2" bs=1048576 count="$1" status=none 2>/dev/null \
    || head -c "$(( $1 * 1048576 ))" /dev/urandom > "$2"
}

echo "============================================================"
echo " GitCode 探针  ->  ${GITCODE_OWNER}/${GITCODE_REPO}  (tag=${TAG})"
echo "============================================================"

# ---------- PART A: Release 附件上传 API 大小梯度试传 ----------
echo ""
echo "### PART A: Release 附件上传 API 大小上限探测"

# 创建一次性 release(从 create 响应里抓 id, 用于结束时删除)
curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' -X POST \
  -d "{\"tag_name\":\"${TAG}\",\"refs\":\"main\",\"tag_message\":\"probe\"}" \
  "${API}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/tags" >/dev/null 2>&1 || true

create_resp="$(curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' -X POST \
  -d "{\"tag_name\":\"${TAG}\",\"name\":\"probe\",\"body\":\"probe (safe to delete)\",\"target_commitish\":\"main\"}" \
  "${API}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases" 2>/dev/null)"
RELEASE_ID="$(echo "$create_resp" | jq -r '.id // empty' 2>/dev/null)"
echo "  创建 release: id=${RELEASE_ID:-<none>}"

printf '  %-8s | %-9s | %-8s | %-8s | %s\n' "size" "http" "curl_rc" "elapsed" "speed"
printf '  %s\n' "---------+-----------+----------+----------+--------------"
for mb in $SIZES_MB; do
  f="${WORK}/probe_${mb}mb.bin"
  mkfile "$mb" "$f"
  name="probe_${mb}mb.bin"
  enc="$(printf '%s' "$name" | jq -sRr @uri)"

  info="$(curl -sS "${AUTH[@]}" --max-time 60 \
    "${API}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases/${TAG}/upload_url?file_name=${enc}" 2>/dev/null)"
  url="$(echo "$info" | jq -r '.url // empty' 2>/dev/null)"
  if [ -z "$url" ]; then
    printf '  %-8s | %-9s | %-8s | %-8s | %s\n' "${mb}MB" "NO_URL" "-" "-" "$(echo "$info" | head -c 80)"
    continue
  fi
  echo "$info" | jq -r '.headers | to_entries[] | "header = \"" + .key + ": " + .value + "\""' > "${WORK}/h.txt"

  t0=$(date +%s)
  code="$(curl -sS -o "${WORK}/put.out" -w '%{http_code}' -X PUT \
    --connect-timeout 30 --max-time 1800 --speed-time 60 --speed-limit 2048 \
    -K "${WORK}/h.txt" --data-binary "@${f}" "$url" 2>/dev/null)"; rc=$?
  t1=$(date +%s); el=$((t1 - t0)); [ "$el" -lt 1 ] && el=1
  spd="$(( mb * 1024 / el ))KB/s"
  printf '  %-8s | %-9s | %-8s | %-8s | %s\n' "${mb}MB" "$code" "$rc" "${el}s" "$spd"
done

echo ""
echo "  PART A 解读: http=2xx 即该尺寸可传; 出现 502/NO_URL/curl_rc=28 的最小尺寸 ≈ 硬上限。"

# ---------- PART B: git push / Git LFS 可行性 ----------
if [ "$DO_LFS" = "1" ]; then
  echo ""
  echo "### PART B: git push(<=100MB) 与 Git LFS(>100MB) 可行性"
  if ! command -v git-lfs >/dev/null && ! git lfs version >/dev/null 2>&1; then
    echo "  [跳过] 未安装 git-lfs。安装: brew install git-lfs && git lfs install"
  else
    REPO_URL="https://${GIT_USER}:${GITCODE_TOKEN}@gitcode.com/${GITCODE_OWNER}/${GITCODE_REPO}.git"
    BR="probe-lfs-tmp-$$"
    cd "$WORK"
    echo "  克隆(浅) ${GITCODE_OWNER}/${GITCODE_REPO} ..."
    if ! git clone --depth 1 "$REPO_URL" repo >/tmp/gc_clone.log 2>&1; then
      echo "  [失败] git clone 失败(可能是 HTTPS 令牌不可用于 git 推送):"; tail -n 5 /tmp/gc_clone.log
    else
      cd repo
      git lfs install --local >/dev/null 2>&1 || true
      git checkout -b "$BR" >/dev/null 2>&1

      # 普通 git push: <100MB 文件
      mkfile "$LFS_PLAIN_MB" "plain_${LFS_PLAIN_MB}mb.bin"
      git add "plain_${LFS_PLAIN_MB}mb.bin"
      git -c user.email=probe@local -c user.name=probe commit -q -m "probe plain ${LFS_PLAIN_MB}MB"
      echo "  推送普通文件 ${LFS_PLAIN_MB}MB ..."
      t0=$(date +%s)
      if git push -q origin "$BR" >/tmp/gc_push_plain.log 2>&1; then
        t1=$(date +%s); el=$((t1-t0)); [ "$el" -lt 1 ] && el=1
        echo "    [OK] 普通 push ${LFS_PLAIN_MB}MB 用时 ${el}s ($(( LFS_PLAIN_MB*1024/el ))KB/s)"
      else
        echo "    [失败] 普通 push ${LFS_PLAIN_MB}MB:"; tail -n 8 /tmp/gc_push_plain.log
      fi

      # Git LFS: >100MB 文件
      git lfs track "*.biglfs" >/dev/null 2>&1
      git add .gitattributes
      mkfile "$LFS_BIG_MB" "big_${LFS_BIG_MB}mb.biglfs"
      git add "big_${LFS_BIG_MB}mb.biglfs"
      git -c user.email=probe@local -c user.name=probe commit -q -m "probe lfs ${LFS_BIG_MB}MB"
      echo "  推送 LFS 文件 ${LFS_BIG_MB}MB ..."
      t0=$(date +%s)
      if git push -q origin "$BR" >/tmp/gc_push_lfs.log 2>&1; then
        t1=$(date +%s); el=$((t1-t0)); [ "$el" -lt 1 ] && el=1
        echo "    [OK] LFS push ${LFS_BIG_MB}MB 用时 ${el}s ($(( LFS_BIG_MB*1024/el ))KB/s)"
      else
        echo "    [失败] LFS push ${LFS_BIG_MB}MB:"; tail -n 12 /tmp/gc_push_lfs.log
      fi

      echo "  清理临时分支 ${BR} ..."
      git push -q origin --delete "$BR" >/dev/null 2>&1 || echo "    (分支删除失败,请手动删 ${BR})"
    fi
  fi
fi

# ---------- 清理 PART A 的 release ----------
echo ""
echo "### 清理"
if [ -n "$RELEASE_ID" ]; then
  dc="$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" -X DELETE \
    "${API}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases/${RELEASE_ID}" 2>/dev/null)"
  echo "  删除 probe release id=${RELEASE_ID}: http=${dc}"
else
  echo "  未拿到 release id(create 响应无 id)，请手动删除 GitCode 上的 tag/release: ${TAG}"
fi
dt="$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" -X DELETE \
  "${API}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/tags/${TAG}" 2>/dev/null)"
echo "  删除 probe tag ${TAG}: http=${dt}"

echo ""
echo "============================================================"
echo " 探针结束。把上面 PART A 表格 + PART B 结果发我即可。"
echo "============================================================"
