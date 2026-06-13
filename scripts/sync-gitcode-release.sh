#!/usr/bin/env bash
# Sync whisper.cpp builder artifacts to GitCode Release (tag=latest).
# See docs/superpowers/specs/2026-06-13-gitcode-release-sync-design.md
set -euo pipefail

GITCODE_OWNER="${GITCODE_OWNER:-buxuku1}"
GITCODE_REPO="${GITCODE_REPO:-whisper.node}"
GITCODE_TAG="${GITCODE_TAG:-latest}"
GITCODE_API_URL="${GITCODE_API_URL:-https://api.gitcode.com/api/v5}"
GITHUB_LEGACY_RELEASE_URL="${GITHUB_LEGACY_RELEASE_URL:-https://github.com/buxuku/whisper.cpp/releases/download/latest}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
RELEASE_FILES_DIR="${RELEASE_FILES_DIR:-release_files}"
SYNC_SOURCE="${SYNC_SOURCE:-artifacts}"
WORK_DIR="${WORK_DIR:-.}"
MAX_RETRIES="${MAX_RETRIES:-3}"
GITCODE_DRY_RUN="${GITCODE_DRY_RUN:-0}"

LEGACY_FILES=(
  # 仅同步压缩包；未压缩 .node 约 800MB，上传过慢且 .node.gz 已包含相同内容
  "addon-windows-cuda-1180-optimized.node.gz"
  "windows-cuda-1180-optimized.tar.gz"
  "addon-windows-cuda-1220-optimized.node.gz"
  "windows-cuda-1220-optimized.tar.gz"
)

BUILD_FILES=(
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

FAILED_FILES=()
UPLOADED_COUNT=0
SKIPPED_COUNT=0
# Per-file PUT timeout (seconds). Large legacy archives may exceed this and be skipped.
UPLOAD_PUT_TIMEOUT="${UPLOAD_PUT_TIMEOUT:-7200}"
LEGACY_PUT_TIMEOUT="${LEGACY_PUT_TIMEOUT:-1800}"

log() { echo "$*"; }
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_env() {
  if [ -z "${GITCODE_TOKEN:-}" ]; then
    echo "GITCODE_TOKEN is not set" >&2
    exit 1
  fi
}

api_request() {
  local method="$1"
  local url="$2"
  shift 2
  if [ "$GITCODE_DRY_RUN" = "1" ]; then
    echo "[dry-run] $method $url"
    return 0
  fi
  curl -sS -w "\n%{http_code}" -X "$method" \
    -H "Authorization: Bearer ${GITCODE_TOKEN}" \
    "$@" \
    "$url"
}

asset_already_exists() {
  local http_code="$1"
  local body="$2"
  if [ "$http_code" = "409" ] || [ "$http_code" = "422" ]; then
    return 0
  fi
  echo "$body" | grep -qiE 'already exist|已存在|duplicate' && return 0
  return 1
}

prepare_release_files() {
  if [ "$SYNC_SOURCE" = "github" ]; then
    prepare_from_github_latest
  else
    prepare_release_files_from_artifacts
  fi
}

prepare_release_files_from_artifacts() {
  log "Preparing ${RELEASE_FILES_DIR}/ from ${ARTIFACTS_DIR}/"
  mkdir -p "${RELEASE_FILES_DIR}"
  find "${ARTIFACTS_DIR}" -type f \( -name "*.node" -o -name "*.gz" \) -exec cp {} "${RELEASE_FILES_DIR}/" \;

  (
    cd "${RELEASE_FILES_DIR}"
    curl -sL -o _existing_versions.json \
      "${GITHUB_LEGACY_RELEASE_URL}/addon-versions.json" 2>/dev/null || echo '{}' > _existing_versions.json
    python3 -c "import json; json.load(open('_existing_versions.json'))" 2>/dev/null || echo '{}' > _existing_versions.json

    python3 - <<'PYSCRIPT'
import json, subprocess, os
from datetime import datetime

try:
    with open("_existing_versions.json") as f:
        existing = json.load(f)
except Exception:
    existing = {}

version = datetime.utcnow().strftime("%Y.%m.%d")
configs = [("11.8.0", "1180"), ("12.2.0", "1220"), ("12.4.0", "1240"), ("13.0.2", "1302")]

def sha256_file(filepath):
    if os.path.isfile(filepath):
        result = subprocess.run(["sha256sum", filepath], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.split()[0]
    return ""

result = {}
for cuda_ver, prefix in configs:
    win_tar = sha256_file(f"windows-cuda-{prefix}-optimized.tar.gz")
    win_node = sha256_file(f"addon-windows-cuda-{prefix}-optimized.node.gz")
    linux_tar = sha256_file(f"linux-cuda-{prefix}-optimized.tar.gz")
    linux_node = sha256_file(f"addon-linux-cuda-{prefix}-optimized.node.gz")
    has_new = any([win_tar, win_node, linux_tar, linux_node])
    if has_new:
        result[cuda_ver] = {
            "version": version,
            "updateNotes": "Auto-built from whisper.cpp master branch",
            "checksum": {
                "windows-tar": win_tar,
                "windows-node": win_node,
                "linux-tar": linux_tar,
                "linux-node": linux_node,
            },
        }
    elif cuda_ver in existing:
        result[cuda_ver] = existing[cuda_ver]

vulkan_win = sha256_file("addon-windows-vulkan.node.gz")
vulkan_linux = sha256_file("addon-linux-vulkan.node.gz")
if vulkan_win or vulkan_linux:
    result["vulkan"] = {
        "version": version,
        "updateNotes": "Auto-built from whisper.cpp master branch",
        "checksum": {"windows-node": vulkan_win, "linux-node": vulkan_linux},
    }
elif "vulkan" in existing:
    result["vulkan"] = existing["vulkan"]

with open("addon-versions.json", "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYSCRIPT
    rm -f _existing_versions.json
  )

  log "Release files:"
  ls -lh "${RELEASE_FILES_DIR}/"
}

prepare_from_github_latest() {
  log "Downloading build artifacts from GitHub latest into ${RELEASE_FILES_DIR}/"
  mkdir -p "${RELEASE_FILES_DIR}"
  for filename in "${BUILD_FILES[@]}"; do
    log "  Downloading ${filename}"
    if ! curl -fsSL --connect-timeout 30 --max-time 3600 \
      -o "${RELEASE_FILES_DIR}/${filename}" \
      "${GITHUB_LEGACY_RELEASE_URL}/${filename}"; then
      echo "Failed to download ${filename} from GitHub latest" >&2
      exit 1
    fi
  done
  ls -lh "${RELEASE_FILES_DIR}/"
}

fetch_release_json() {
  local response http_code body
  response=$(api_request GET \
    "${GITCODE_API_URL}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases/tags/${GITCODE_TAG}" \
    2>/dev/null || true)
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" = "200" ]; then
    echo "$body"
    return 0
  fi
  return 1
}

ensure_release() {
  if release_json=$(fetch_release_json); then
    log "GitCode release '${GITCODE_TAG}' already exists (id=$(echo "$release_json" | jq -r '.id'))"
    return 0
  fi

  log "Creating GitCode tag and release '${GITCODE_TAG}'..."
  if [ "$GITCODE_DRY_RUN" = "1" ]; then
    log "[dry-run] would create tag and release"
    return 0
  fi

  # Create tag on main if missing (GitCode/Gitee-compatible API)
  local tag_response tag_code
  tag_response=$(curl -sS -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${GITCODE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"${GITCODE_TAG}\",\"refs\":\"main\",\"tag_message\":\"Latest whisper.cpp addon builds\"}" \
    "${GITCODE_API_URL}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/tags" || true)
  tag_code=$(echo "$tag_response" | tail -n1)
  if [ "$tag_code" != "201" ] && [ "$tag_code" != "200" ]; then
    log "Tag create returned HTTP ${tag_code} (may already exist, continuing)"
  fi

  local create_response create_code
  create_response=$(curl -sS -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${GITCODE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"${GITCODE_TAG}\",\"name\":\"Latest whisper.cpp builds\",\"body\":\"Auto-synced from whisper.cpp builder CI\",\"target_commitish\":\"main\"}" \
    "${GITCODE_API_URL}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases")
  create_code=$(echo "$create_response" | tail -n1)
  if [ "$create_code" != "201" ] && [ "$create_code" != "200" ]; then
    echo "Failed to create GitCode release (HTTP ${create_code})" >&2
    echo "$create_response" | sed '$d' >&2
    exit 1
  fi
  log "Created GitCode release '${GITCODE_TAG}'"
}

# GitCode release assets omit attach id; match by name and ignore auto source bundles.
attachment_exists_by_name() {
  local release_json="$1"
  local filename="$2"
  echo "$release_json" | jq -r --arg name "$filename" '
    (.assets // .attach_files // [])[]
    | select(.name == $name and (.type // "attach") != "source")
    | .name
  ' | head -n1
}

get_attach_id_by_name() {
  local release_json="$1"
  local filename="$2"
  echo "$release_json" | jq -r --arg name "$filename" '
    (.assets // .attach_files // [])[]
    | select(.name == $name and (.type // "attach") != "source")
    | (.id // .attach_id // empty)
    | tostring
  ' | head -n1
}

file_size_bytes() {
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1"
}

human_size() {
  local bytes="$1"
  if [ "$bytes" -lt 1048576 ]; then
    echo "$((bytes / 1024))KB"
  else
    echo "$((bytes / 1048576))MB"
  fi
}

delete_attachment() {
  local release_id="$1"
  local attach_id="$2"
  local filename="$3"
  if [ -z "$attach_id" ] || [ "$attach_id" = "null" ]; then
    return 0
  fi
  log "  Deleting existing attachment: ${filename} (id=${attach_id})"
  if [ "$GITCODE_DRY_RUN" = "1" ]; then
    return 0
  fi
  local response http_code
  response=$(curl -sS -w "\n%{http_code}" -X DELETE \
    -H "Authorization: Bearer ${GITCODE_TOKEN}" \
    "${GITCODE_API_URL}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases/${release_id}/attach_files/${attach_id}")
  http_code=$(echo "$response" | tail -n1)
  if [ "$http_code" = "204" ] || [ "$http_code" = "200" ] || [ "$http_code" = "404" ]; then
    return 0
  fi
  log "  Warning: delete ${filename} returned HTTP ${http_code}"
  return 1
}

upload_file() {
  local file_path="$1"
  local replace="${2:-false}"
  local put_timeout="${3:-$UPLOAD_PUT_TIMEOUT}"
  local filename release_json release_id attach_id file_size
  filename=$(basename "$file_path")

  if [ ! -f "$file_path" ]; then
    log "  Skip missing file: ${filename}"
    return 0
  fi

  file_size=$(file_size_bytes "$file_path")

  release_json=$(fetch_release_json || echo '{}')
  release_id=$(echo "$release_json" | jq -r '.id // empty')

  if [ "$replace" = "false" ]; then
    if [ -n "$(attachment_exists_by_name "$release_json" "$filename")" ]; then
      log "  Skip (already exists): ${filename}"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      return 0
    fi
  else
    attach_id=$(get_attach_id_by_name "$release_json" "$filename")
    if [ -n "$attach_id" ] && [ -n "$release_id" ]; then
      delete_attachment "$release_id" "$attach_id" "$filename" || true
    fi
  fi

  local encoded_filename retry curl_status http_code response_body upload_info upload_url
  encoded_filename=$(printf '%s' "$filename" | jq -sRr @uri)

  for ((retry = 0; retry < MAX_RETRIES; retry++)); do
    log "  Uploading: ${filename} ($(human_size "$file_size"), attempt $((retry + 1))/${MAX_RETRIES})"
    if [ "$GITCODE_DRY_RUN" = "1" ]; then
      UPLOADED_COUNT=$((UPLOADED_COUNT + 1))
      return 0
    fi

    curl_status=0
    upload_response=""
    upload_response=$(curl -sS -w "\n%{http_code}" --connect-timeout 30 --max-time 120 \
      -H "Authorization: Bearer ${GITCODE_TOKEN}" \
      "${GITCODE_API_URL}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases/${GITCODE_TAG}/upload_url?file_name=${encoded_filename}") || curl_status=$?

    if [ "$curl_status" -ne 0 ]; then
      log "  Failed to get upload URL (curl exit ${curl_status})"
      sleep $((10 * (retry + 1)))
      continue
    fi

    http_code=$(echo "$upload_response" | tail -n1)
    upload_info=$(echo "$upload_response" | sed '$d')
    upload_url=$(echo "$upload_info" | jq -r '.url // empty')

    if [ -z "$upload_url" ]; then
      if asset_already_exists "$http_code" "$upload_info"; then
        log "  Already exists: ${filename}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
      fi
      log "  Failed to get upload URL (HTTP ${http_code}): ${upload_info}"
      sleep $((10 * (retry + 1)))
      continue
    fi

    local headers_file
    headers_file=$(mktemp)
    echo "$upload_info" | jq -r '.headers | to_entries[] | "header = \"" + .key + ": " + .value + "\""' > "$headers_file"

    curl_status=0
    put_response=""
    # Do not use --retry-all-errors on PUT: it restarts multi-GB uploads from scratch.
    put_response=$(curl -sS -w "\n%{http_code}" -X PUT \
      --connect-timeout 30 --max-time "$put_timeout" \
      -K "$headers_file" \
      --data-binary "@${file_path}" \
      "$upload_url") || curl_status=$?
    rm -f "$headers_file"

    if [ "$curl_status" -ne 0 ]; then
      if [ "$curl_status" -eq 28 ]; then
        log "  Upload timed out after ${put_timeout}s: ${filename}"
      else
        log "  Upload request failed (curl exit ${curl_status})"
      fi
      sleep $((15 * (retry + 1)))
      continue
    fi

    http_code=$(echo "$put_response" | tail -n1)
    response_body=$(echo "$put_response" | sed '$d')

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      log "  Uploaded: ${filename}"
      UPLOADED_COUNT=$((UPLOADED_COUNT + 1))
      return 0
    fi

    if asset_already_exists "$http_code" "$response_body"; then
      if [ "$replace" = "true" ]; then
        log "  Asset exists but replace requested; retry after delete (HTTP ${http_code})"
        release_json=$(fetch_release_json || echo '{}')
        release_id=$(echo "$release_json" | jq -r '.id // empty')
        attach_id=$(get_attach_id_by_name "$release_json" "$filename")
        delete_attachment "$release_id" "$attach_id" "$filename" || true
      else
        log "  Already exists: ${filename}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
      fi
    else
      log "  Failed (HTTP ${http_code}), response: ${response_body}"
    fi
    sleep $((15 * (retry + 1)))
  done

  log "  ERROR: gave up uploading ${filename}"
  FAILED_FILES+=("$filename")
  return 1
}

sync_legacy_files() {
  local legacy_dir="${WORK_DIR}/legacy_files"
  mkdir -p "$legacy_dir"

  log "=== Legacy assets (upload once if missing on GitCode; runs after build files) ==="
  for filename in "${LEGACY_FILES[@]}"; do
    release_json=$(fetch_release_json || echo '{}')
    if [ -n "$(attachment_exists_by_name "$release_json" "$filename")" ]; then
      log "  Skip (already on GitCode): ${filename}"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi

    local dest="${legacy_dir}/${filename}"
    log "  Downloading legacy from GitHub: ${filename}"
    if ! curl -fsSL --connect-timeout 30 --max-time 3600 \
      -o "$dest" "${GITHUB_LEGACY_RELEASE_URL}/${filename}"; then
      log "  Warning: legacy file not found on GitHub, skipping: ${filename}"
      summary "- ⚠️ Legacy file missing on GitHub: \`${filename}\`"
      rm -f "$dest"
      continue
    fi

    upload_file "$dest" false "$LEGACY_PUT_TIMEOUT" || true
  done
}

sort_files_by_size() {
  local -a paths=("$@")
  local -a sorted=()
  local path size line

  while IFS= read -r line; do
    sorted+=("$line")
  done < <(
    for path in "${paths[@]}"; do
      size=$(file_size_bytes "$path")
      printf '%s\t%s\n' "$size" "$path"
    done | sort -n | cut -f2-
  )

  printf '%s\n' "${sorted[@]}"
}

sync_build_files() {
  log "=== Build artifacts (always upload, replace existing; smallest files first) ==="
  shopt -s nullglob
  local files=("${RELEASE_FILES_DIR}"/*)
  shopt -u nullglob

  if [ "${#files[@]}" -eq 0 ]; then
    echo "No files found in ${RELEASE_FILES_DIR}/" >&2
    exit 1
  fi

  local -a ordered=()
  local versions_json="${RELEASE_FILES_DIR}/addon-versions.json"
  if [ -f "$versions_json" ]; then
    ordered+=("$versions_json")
  fi

  local -a rest=()
  for file_path in "${files[@]}"; do
    [ "$file_path" = "$versions_json" ] && continue
    rest+=("$file_path")
  done

  if [ "${#rest[@]}" -gt 0 ]; then
    while IFS= read -r file_path; do
      [ -n "$file_path" ] && ordered+=("$file_path")
    done < <(sort_files_by_size "${rest[@]}")
  fi

  for file_path in "${ordered[@]}"; do
    upload_file "$file_path" true || true
    sleep 1
  done
}

update_release_body() {
  local release_json release_id build_date file_list body
  release_json=$(fetch_release_json || return 0)
  release_id=$(echo "$release_json" | jq -r '.id // empty')
  [ -n "$release_id" ] || return 0

  build_date=$(date -u +'%Y-%m-%d %H:%M:%S UTC')
  file_list=$(ls -1 "${RELEASE_FILES_DIR}" | sed 's/^/- `/; s/$/`/' | head -20)
  body=$(cat <<EOF
Latest whisper.cpp addon builds mirrored from GitHub CI.

Last synced: ${build_date}

**Build artifacts in this sync:**
${file_list}

Legacy CUDA 11.8/12.2 packages are uploaded once when missing.
EOF
)

  if [ "$GITCODE_DRY_RUN" = "1" ]; then
    log "[dry-run] would update release body"
    return 0
  fi

  curl -sS -X PATCH \
    -H "Authorization: Bearer ${GITCODE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg tag "$GITCODE_TAG" --arg name "Latest whisper.cpp builds" --arg body "$body" \
      '{tag_name:$tag,name:$name,body:$body}')" \
    "${GITCODE_API_URL}/repos/${GITCODE_OWNER}/${GITCODE_REPO}/releases/${release_id}" >/dev/null
  log "Updated GitCode release description"
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd python3
  require_env

  cd "$WORK_DIR"
  summary "## GitCode Release Sync"
  summary "- Target: \`${GITCODE_OWNER}/${GITCODE_REPO}\` tag \`${GITCODE_TAG}\`"

  prepare_release_files
  ensure_release
  # Upload build artifacts first so a slow legacy archive cannot block the main payload.
  sync_build_files
  sync_legacy_files
  update_release_body

  summary "- Uploaded: ${UPLOADED_COUNT}"
  summary "- Skipped: ${SKIPPED_COUNT}"
  if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
    summary "- Failed:"
    for f in "${FAILED_FILES[@]}"; do
      summary "  - \`${f}\`"
    done
    echo "GitCode sync completed with failures: ${FAILED_FILES[*]}" >&2
    exit 1
  fi

  log "GitCode sync completed successfully"
  summary "- Result: ✅ success"
}

main "$@"
