'use strict';
/**
 * ISA 验证用：在普通 Node 进程里加载真实 whisper addon，转写一小段音频，分阶段打印标记。
 * 不依赖 Electron；用于 qemu-user（-cpu 指定 CPU 型号）与 Windows runner。
 * 只用于验证，不被应用引用，也不改任何业务代码。
 *
 * 用法：node addon-harness.js <addon.node> <ggml-model.bin> <audio>
 *
 * 标记一律走 fs.writeSync：进程被 SIGILL 打死时也不会丢最后一行，
 * 据此可判断崩溃发生在「dlopen 时」「whisper() 刚开始」还是「推理中途」。
 * no_prints 为 false：让 addon 打印 system_info（编译期启用的指令集），
 * 这是被验证的二进制自己报出的基线，比反汇编推断直接。
 *
 * 转写完成后还会检查返回结果带有 tokens / vadSegments（fork 补丁 0002 的产出），缺失时退出码为 3。
 */
const fs = require('fs');
const { promisify } = require('util');

const [addonPath, modelPath, audioPath] = process.argv.slice(2);
if (!addonPath || !modelPath || !audioPath) {
  fs.writeSync(2, '用法: node addon-harness.js <addon.node> <model.bin> <audio>\n');
  process.exit(64);
}

const t0 = Date.now();
const mark = (s) => fs.writeSync(1, `[h +${Date.now() - t0}ms] ${s}\n`);

async function main() {
  mark(`node ${process.version} ${process.platform}/${process.arch}`);
  mark(`addon: ${addonPath}`);
  const mod = { exports: {} };
  // 用绝对路径：Windows 上相对路径（尤其带 / 的）交给 LoadLibrary 的行为不如绝对路径可靠
  process.dlopen(mod, require('path').resolve(addonPath));
  mark(`dlopen ok, exports=${Object.keys(mod.exports).join(',')}`);

  // 记录 addon 在本进程里的映射（Linux）。SIGILL 后可据此把 PC 换算成 addon 内偏移
  try {
    for (const line of fs.readFileSync('/proc/self/maps', 'utf8').split('\n')) {
      if (/addon[^/]*\.node/.test(line)) mark(`maps: ${line}`);
    }
  } catch {
    // Windows 没有 /proc
  }

  const whisper = promisify(mod.exports.whisper);
  mark('whisper() 开始');
  let lastProgress = -1;
  const result = await whisper({
    language: 'en',
    model: modelPath,
    fname_inp: audioPath,
    use_gpu: false,
    flash_attn: false,
    no_prints: false,
    comma_in_time: false,
    translate: false,
    no_timestamps: false,
    audio_ctx: 0,
    token_timestamps: true,
    max_len: 0,
    print_progress: true,
    max_context: -1,
    vad: false,
    progress_callback: (p) => {
      if (p !== lastProgress) {
        lastProgress = p;
        mark(`progress ${p}`);
      }
    },
  });
  const raw = JSON.stringify(result ?? null);
  mark(`done: ${raw.slice(0, 240)}`);

  // 补丁 0002 的产出：tokens（逐 token 时间戳）和 vadSegments（VAD 语音段，没开 VAD 时是空数组）。
  // 缺了它们转写照样成功，SmartSub 只会悄悄回退到段级时间轴，所以在这里直接判失败。
  const nTok = Array.isArray(result?.tokens) ? result.tokens.length : -1;
  const nVad = Array.isArray(result?.vadSegments) ? result.vadSegments.length : -1;
  mark(`emit: tokens=${nTok} vadSegments=${nVad}`);
  if (nTok <= 0 || nVad < 0) {
    mark('FAIL: 返回结果里缺少 tokens / vadSegments（补丁 0002 没有生效）');
    process.exit(3);
  }
}

main().then(
  () => process.exit(0),
  (err) => {
    mark(`JS 异常: ${err?.stack ?? err}`);
    process.exit(2);
  },
);
