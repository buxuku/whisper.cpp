# whisper.cpp addon builder

> SmartSub（[video-subtitle-master](https://github.com/buxuku/video-subtitle-master)）语音转写加速包的自动构建流水线。
>
> EN: This branch is a CI pipeline that builds prebuilt `addon.node` binaries of [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) for the SmartSub app. It is NOT a source branch.

## 这个分支是什么

本仓库 fork 自 [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)，`builder` 分支（默认分支）专门承载构建流水线：

- **构建源是上游 `master` 的最新代码**——workflow 运行时直接 checkout `ggml-org/whisper.cpp@master`，本分支里的 C++ 源码不参与构建，仅 `.github/workflows/` 目录生效
- 产物发布到本仓库的 [Releases](https://github.com/buxuku/whisper.cpp/releases)：每次构建创建一个时间戳 release（`release-YYYYMMDD-HHMMSS`），并同步更新 [`latest`](https://github.com/buxuku/whisper.cpp/releases/tag/latest) tag
- SmartSub 客户端从 `latest` 下载加速包与 [`addon-versions.json`](https://github.com/buxuku/whisper.cpp/releases/download/latest/addon-versions.json) 校验清单，**下载 URL 已硬编码在存量客户端中，请勿迁移或重命名本仓库**

## 触发方式

| 方式 | 说明 |
|------|------|
| push 到 `builder` 分支 | 修改 workflow 后自动验证构建（`*.md` 文档改动不触发） |
| 手动 `workflow_dispatch` | Actions 页面手动触发（需要跟进上游新代码时手动跑一次） |

并发控制：同一时间只允许一个流水线运行，新触发会自动取消进行中的旧构建，保证 `latest` 始终由最新构建写入。

## 产物清单（15 个 + 1 个清单文件）

| 分类 | 产物 | 说明 |
|------|------|------|
| macOS | `addon-macos-x64.node` / `addon-macos-arm64.node` / `addon-macos-arm64-coreml.node` | Intel / Apple Silicon（Metal）/ CoreML |
| CPU | `addon-windows-x64.node` / `addon-linux-x64.node` | 通用 CPU 版（`GGML_NATIVE=OFF`，全机型兼容） |
| CUDA 12.4 | `addon-{windows,linux}-cuda-1240-optimized.node.gz` + `{windows,linux}-cuda-1240-optimized.tar.gz` | N 卡专用；`node.gz` 需本机 CUDA Toolkit，`tar.gz` 内含运行时库 |
| CUDA 13.0 | `addon-{windows,linux}-cuda-1302-optimized.node.gz` + `{windows,linux}-cuda-1302-optimized.tar.gz` | 同上，面向新驱动 |
| Vulkan | `addon-windows-vulkan.node.gz` / `addon-linux-vulkan.node.gz` | **NVIDIA / AMD / Intel 全厂商通用 GPU 加速**，单文件约 17MB，仅依赖显卡驱动自带的 Vulkan 运行库 |
| 清单 | `addon-versions.json` | 各包版本号与 SHA-256 校验和（含 `vulkan` 键） |

另外 `latest` 上保留 CUDA 11.8 / 12.2 的历史资产（含未压缩 `.node` 源文件），由 `repackage-cuda.yml` 手动重新打包维护，供旧版客户端使用。

## 工作流文件

| 文件 | 用途 |
|------|------|
| `.github/workflows/builder.yml` | 主流水线：10 个构建 job + 发布 job |
| `.github/workflows/repackage-cuda.yml` | 手动触发：为不再构建的旧 CUDA 版本（11.8/12.2）重新打包压缩产物 |

## 修改流水线

1. 在 `builder` 分支编辑 `.github/workflows/builder.yml`
2. push 后自动触发完整验证构建（约 2~3 小时，以 Windows CUDA job 最长）
3. 构建全绿即自动发布；只改文档请确认提交仅含 `*.md`（不会触发构建），或在 commit message 加 `[skip ci]`

## 构建参数要点

- 所有 Windows 产物均使用 `GGML_NATIVE=OFF` 编译，避免二进制携带 CI runner 的 AVX512 等指令导致老 CPU 崩溃
- CUDA 包使用 `CMAKE_CUDA_ARCHITECTURES=all-major`（12.4）/ 显式架构列表（13.0），覆盖 PTX JIT 前向兼容
- Vulkan 包使用 `GGML_VULKAN=ON`，SPIR-V 着色器编译期嵌入，运行时由显卡驱动 JIT，天然全架构通用
- 运行时(electron 30.1.0) 与 SmartSub 主程序保持一致
