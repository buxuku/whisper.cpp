# GitCode Release 同步设计

**日期**: 2026-06-13  
**状态**: 已实现  
**目标仓库**: https://gitcode.com/buxuku1/whisper.node  
**触发流水线**: `builder` 分支 `.github/workflows/builder.yml`

## 背景

当前 `builder.yml` 在 `create-update-release` job 中将构建产物发布到 GitHub Releases（`release-时间戳` + 可覆盖的 `latest` tag）。需要增加将相同（或部分）产物同步到 GitCode 仓库 Release 的能力，供国内用户下载。

## 目标

1. 每次 `builder` 构建成功后，将产物同步到 `buxuku1/whisper.node` 的 `latest` Release。
2. 历史遗留资产（CUDA 11.8/12.2）仅在 GitCode 上不存在时上传一次，后续跳过。
3. 每次构建的新产物（约 15 个平台包 + `addon-versions.json`）均上传并覆盖同名旧文件。
4. GitCode 同步失败**不阻断**主流水线（GitHub Release 仍视为成功）。

## 非目标

- 不同步 GitHub 的 `release-时间戳` tag 到 GitCode。
- 不在 GitCode 上维护多个版本 tag（仅 `latest`）。
- 不将访问令牌写入代码或提交记录。
- 不改造现有构建矩阵或产物命名规则。

## 架构

```
build-macos / build-windows / build-linux
        │
        ▼
create-update-release
  ├─ 汇总 release_files/
  ├─ 生成 addon-versions.json
  └─ 发布 GitHub: release-时间戳 + latest
        │ (needs, result == success)
        ▼
sync-gitcode-release          continue-on-error: true
  ├─ 下载 artifacts，flatten → release_files/
  ├─ 补传历史遗留文件（按需）
  └─ 上传/覆盖本次构建产物 → GitCode latest
```

### 新增组件

| 组件 | 路径 | 职责 |
|---|---|---|
| CI Job | `.github/workflows/builder.yml` → `sync-gitcode-release` | 编排：下载产物、调用脚本、写 step summary |
| 上传脚本 | `scripts/sync-gitcode-release.sh` | GitCode API：创建 Release、列附件、删/传文件、重试 |

## 文件分类与上传策略

### A. 每次构建必传（覆盖更新）

来源：本次 CI `release_files/`（与 GitHub Release 相同）。

约 16 个文件：

- macOS: `addon-macos-x64.node`, `addon-macos-arm64.node`, `addon-macos-arm64-coreml.node`
- Windows CPU: `addon-windows-x64.node`
- Linux CPU: `addon-linux-x64.node`
- Windows/Linux CUDA 12.4/13.0: 各 `.node.gz` + `.tar.gz`（共 8 个）
- Windows/Linux Vulkan: 各 `.node.gz`（共 2 个）
- `addon-versions.json`

**策略**：若 GitCode `latest` Release 上已有同名附件 → **先 DELETE 再 PUT**，确保二进制内容更新（不可将 409 视为成功而跳过）。

### B. 历史遗留（仅首次补传）

来源：从 GitHub `buxuku/whisper.cpp` 的 `latest` Release 下载（仅当 GitCode 上不存在时上传）。

固定清单（6 个）：

```
addon-windows-cuda-1180-optimized.node
addon-windows-cuda-1180-optimized.node.gz
windows-cuda-1180-optimized.tar.gz
addon-windows-cuda-1220-optimized.node
addon-windows-cuda-1220-optimized.node.gz
windows-cuda-1220-optimized.tar.gz
```

**策略**：列出 GitCode 已有附件；若文件名已存在 → 跳过；若不存在 → 从 GitHub 下载后上传。上传时 409/已存在同样视为成功。

## GitCode API 流程

**基址**: `https://api.gitcode.com/api/v5`  
**认证**: `Authorization: Bearer $GITCODE_TOKEN`（GitHub Actions Secret）

参考：[获取 Release 附件上传地址](https://docs.gitcode.com/docs/apis/get-api-v-5-repos-owner-repo-releases-tag-upload-url/)，以及 [Cherry Studio 实现](https://github.com/CherryHQ/cherry-studio/commit/c73f901)。

### 步骤

1. **确保 Release 存在**
   - `GET /repos/buxuku1/whisper.node/releases/latest`
   - 若 404：`POST /repos/buxuku1/whisper.node/releases` 创建 tag=`latest`、name=`Latest whisper.cpp builds`

2. **列出已有附件**
   - 从 Release 详情 JSON 提取 `attach_files`（或等价字段），建立 `filename → attach_id` 映射

3. **上传单个文件**（带重试，最多 3 次）
   - `GET /repos/buxuku1/whisper.node/releases/latest/upload_url?file_name=<urlencoded>`
   - 解析返回的 `url` 与 `headers`
   - `PUT` 文件二进制到 `url`，携带 headers
   - 大文件（CUDA tar.gz 可达 ~1.5GB）：`--connect-timeout 30 --max-time 3600`

4. **删除已有附件**（仅 A 类文件需要覆盖时）
   - `DELETE /repos/buxuku1/whisper.node/releases/:release_id/attach_files/:attach_id`
   - 若 GitCode API 路径与 Gitee 有差异，实现时以官方文档或试探响应为准

5. **更新 Release 描述**
   - `PATCH /repos/buxuku1/whisper.node/releases/:release_id`
   - body 含构建时间、产物清单摘要（与 GitHub `latest` body 结构类似，可精简）

## 密钥与安全

| 项 | 要求 |
|---|---|
| Secret 名称 | `GITCODE_TOKEN` |
| 创建方式 | `gh secret set GITCODE_TOKEN --repo buxuku/whisper.cpp`（不写入 workflow 明文） |
| 日志 | 禁止 echo token；curl 失败时只输出 HTTP 状态码与响应摘要 |
| 令牌轮换 | 曾在对话中暴露的令牌应在 GitCode 撤销并重新生成 |

## 错误处理

| 层级 | 行为 |
|---|---|
| Job | `continue-on-error: true` — GitCode job 失败不使 workflow 失败 |
| 单文件 | 最多 3 次重试；仍失败则记录到 `$GITHUB_STEP_SUMMARY`，继续处理其余文件 |
| Job 退出码 | 任一文件最终失败 → job 退出码 1（黄），但主 workflow 仍为 success |
| 历史文件 | GitHub 下载失败 → 记 warning，不阻断本次构建产物上传 |

## CI Job 配置要点

```yaml
sync-gitcode-release:
  needs: [create-update-release]
  if: ${{ needs.create-update-release.result == 'success' && github.event_name != 'pull_request' }}
  runs-on: ubuntu-latest
  timeout-minutes: 120
  continue-on-error: true
  env:
    GITCODE_OWNER: buxuku1
    GITCODE_REPO: whisper.node
    GITCODE_TAG: latest
    GITCODE_API_URL: https://api.gitcode.com/api/v5
    GITHUB_LEGACY_RELEASE_URL: https://github.com/buxuku/whisper.cpp/releases/download/latest
  steps:
    - uses: actions/download-artifact@v8   # 复用 flatten 逻辑
    - run: bash scripts/sync-gitcode-release.sh
      env:
        GITCODE_TOKEN: ${{ secrets.GITCODE_TOKEN }}
```

脚本依赖：`curl`, `jq`, `python3`（ubuntu-latest 自带）。

## 测试计划

1. **首次运行**：GitCode 出现 `latest` Release；含 16 个构建产物；若 GitHub 有历史文件则额外补传 6 个。
2. **第二次运行**：16 个构建产物被覆盖（校验 sha256 或文件大小变化）；6 个历史文件日志显示 `skip (already exists)`。
3. **故障注入**：错误 token → GitCode job 黄，GitHub Release 仍绿；step summary 有失败明细。
4. **大文件**：CUDA tar.gz 上传成功，无超时（或重试后成功）。

## 实现顺序

1. 创建 `scripts/sync-gitcode-release.sh`（可本地 `dry-run` 模式仅打印计划）
2. 在 `builder.yml` 增加 `sync-gitcode-release` job
3. 通过 `gh secret set` 配置 `GITCODE_TOKEN`
4. 推送 `builder` 分支触发构建并验证

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| GitCode DELETE 附件 API 与文档不一致 | 实现前用 curl 试探；备选方案为删整个 Release 后重建 |
| 大文件上传超时 | 加长 max-time + 分文件重试 |
| GitCode API 限流 | 文件间加短 sleep；重试带退避 |
| 历史文件在 GitHub latest 已移除 | 脚本对 404 记 warning 并继续，不阻断 |
