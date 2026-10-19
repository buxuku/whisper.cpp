#!/usr/bin/env bash
# 检查编出来的 Linux addon 的动态依赖（DT_NEEDED）只落在白名单里。
#
# 依赖是 CMake 在构建机上自动探测、自动链进去的：换基础镜像、构建机多装一个 -dev 包，
# 产物就可能悄悄多出一个依赖。构建机上什么都不会报错（那里这个库就在），
# 报错的是用户机器：dlopen 失败，SmartSub 只能回退到别的后端。
# 2026-06-12 起 Linux CUDA 包多出的 libnccl.so.2 就是这样来的：构建换进 nvidia/cuda:*-devel 容器后，
# ggml 默认开启的 GGML_CUDA_NCCL 找到了镜像自带的 libnccl-dev，于是链了上去（NCCL 只用于多卡通信）。
#
# 用白名单而不是黑名单：以后再多出任何依赖（cudnn / nvrtc / ...），都要有人确认
# 「用户机器上有，或者会随包提供」之后在下面的 ALLOWED 里放行，而不是等用户报错。
#
# 用法：check-addon-needed.sh <addon.node 文件>...
# 注意：要检查压缩前的 .node，不是 .gz / .tar.gz。
# 退出码：0 全部在白名单内；1 有白名单之外的依赖；2 用法错误 / 读不了文件 / 没有 readelf
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "用法: check-addon-needed.sh <addon.node 文件>..." >&2
  exit 2
fi

if ! command -v readelf >/dev/null 2>&1; then
  echo "::error::找不到 readelf（binutils）" >&2
  exit 2
fi

# 允许的 SONAME，每项是一个整串匹配的正则。
ALLOWED=(
  'libcuda\.so\.1'            # 显卡驱动提供，装了驱动就有
  'libcudart\.so\.[0-9]+'     # CUDA runtime：Lite 包用用户装的 toolkit，Full 包随包提供
  'libcublas\.so\.[0-9]+'     # 同上
  'libcublasLt\.so\.[0-9]+'   # 同上（libcublas 的依赖，addon 自己通常不直接引用）
  'libgomp\.so\.1'            # OpenMP 运行库，GCC 自带
  'libstdc\+\+\.so\.6'
  'libgcc_s\.so\.1'
  'libm\.so\.6'               # 下面是 glibc：老版本（< 2.34）里 dl / pthread / rt 是独立的库
  'libc\.so\.6'
  'libdl\.so\.2'
  'libpthread\.so\.0'
  'librt\.so\.1'
  'ld-linux-x86-64\.so\.2'
)
pattern=$(
  IFS='|'
  echo "^(${ALLOWED[*]})\$"
)

bad=0
err=0
for f in "$@"; do
  echo "== $f"
  if ! dyn=$(readelf -d "$f" 2>&1); then
    # 变量后面紧跟全角标点时必须加花括号：非 UTF-8 locale 下 bash 会把多字节字符的首字节当成变量名的一部分
    echo "::error::readelf 读不了 ${f}：${dyn}" >&2
    err=1
    continue
  fi
  # 留在日志里，事后能直接看到这个包依赖了什么、RUNPATH 是什么
  grep -E '\((NEEDED|SONAME|RPATH|RUNPATH)\)' <<<"$dyn" || true

  needed=$(sed -n 's/.*(NEEDED)[^[]*\[\(.*\)\]/\1/p' <<<"$dyn")
  if [ -z "$needed" ]; then
    # 动态库不可能一个依赖都没有：说明读到的不是预期的 readelf 输出，不能当作通过
    echo "::error::${f} 没读到任何 NEEDED 条目（不是动态库，或 readelf 输出格式变了）" >&2
    err=1
    continue
  fi

  unexpected=()
  while IFS= read -r lib; do
    [[ "$lib" =~ $pattern ]] || unexpected+=("$lib")
  done <<<"$needed"

  if [ "${#unexpected[@]}" -gt 0 ]; then
    echo "::error::${f} 依赖了白名单之外的库：${unexpected[*]}" >&2
    echo "  先查是谁把它链进来的（CMake 的 find_package，或某个默认开启的选项），能关就关；" >&2
    echo "  确实需要、并且用户机器上会有（或随包提供）的，再加进本脚本的 ALLOWED。" >&2
    bad=1
  else
    echo "ok: $f"
  fi
done

if [ "$err" -ne 0 ]; then
  exit 2
fi
exit "$bad"
