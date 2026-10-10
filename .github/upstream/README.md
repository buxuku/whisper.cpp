# 构建源：上游 release tag + 补丁

`builder.yml` / `builder-compat.yml` 不再从某个分支构建，而是：

    上游 ggml-org/whisper.cpp 的 release tag（如 v1.9.5） + patches/ 里的补丁  →  编译

每次构建都会生成 `build-info.json`（随 Release 一起发布），记录实际用到的上游 tag 和 commit、
每个补丁的 sha256、补丁后的源码树哈希，以及本仓库的提交与运行链接。
拿到任何一个已发布的包，下载同一个 Release 里的 `build-info.json` 就能知道它是怎么来的。

## 文件

- `tag`：本次构建用哪个上游 tag。push 触发的构建，以及手动触发时不填 `upstream_tag`，都读这个文件。
  写具体的 tag（如 `v1.9.5`，默认）= 固定版本，每次构建结果可复现；写 `latest` = 每次构建时取上游当时最新的 vX.Y.Z。
  两种写法下，实际用到的 tag 和 commit 都会记进 `build-info.json`。
- `patches/*.patch`：按文件名顺序叠加到上游 tag 上的补丁。
- `../scripts/resolve-upstream-tag.sh`：解出 tag 指向的 commit，核实 tag 存在；`latest` = 上游最新的 vX.Y.Z。
- `../scripts/apply-patches.sh`：套补丁、核对源码树哈希、写 `build-info.json`。
- `../workflows/prepare-source.yml`：所有构建任务之前先跑，解出 tag 并试套补丁。补丁套不上会在几分钟内失败，不会等 CUDA 构建跑完。

目录叫 `upstream/` 而不是 `build/`：builder 分支带着上游的 `.gitignore`，它会忽略所有名为 `build/` 的目录，
放进去的文件 `git add` 不上，用 `git add -A` 也会漏掉。

## 补丁清单

- `0001-addon.node-cancel-via-AbortSignal.patch`：addon.node 支持用 AbortSignal 取消转写。
  对应上游 PR #3909。上游合并并发布后，新 tag 里已经带了这个改动，补丁会套不上：删掉这个文件即可。
- `0002-addon.node-emit-tokens-and-vad-segments.patch`：addon.node 增加 `token_timestamps` 参数，
  返回 `tokens`（逐 token 的时间戳）和 `vadSegments`（内置 VAD 找到的语音段）。仅 fork 使用，没有提交上游。
  SmartSub 的细粒度字幕时间轴依赖它；缺了它构建出的包会让 SmartSub 回退到段级时间轴。

## 日常操作

升级上游版本：把 `tag` 改成新 tag 再 push 到 `builder`。注意 push 到 `builder` 会触发构建，
全部成功后会发布 `release-<时间戳>` 并更新 `latest`。想先看看补丁能不能套上、能不能编过，
用手动触发并取消勾选 `publish`。

只验证不发布：Actions → Build whisper.cpp addons → Run workflow，取消勾选 `publish`，
`upstream_tag` 可填 `latest` 或具体的 tag（留空 = 用 `tag` 里的）。

补丁套不上时重新生成：

    git clone --branch vX.Y.Z https://github.com/ggml-org/whisper.cpp.git /tmp/src && cd /tmp/src
    # 逐个叠加补丁（解决冲突后 git am --continue）
    git am --3way <builder>/.github/upstream/patches/*.patch
    git format-patch --no-numbered --no-signature --zero-commit --full-index \
      -o <builder>/.github/upstream/patches vX.Y.Z..HEAD

本地复现 CI 的补丁步骤：

    bash .github/scripts/resolve-upstream-tag.sh            # 打印 tag 和 commit
    git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git /tmp/src
    bash .github/scripts/apply-patches.sh /tmp/src /tmp/build-info.json
