#!/usr/bin/env python3
"""兼容档指令闸门：反汇编 x86-64 目标文件（.o/.obj/.a/.lib）或动态库，检查是否含有该档位不允许的指令。

  avx   = SSE4.2 + AVX（ggml 的 sandybridge 档）：禁 AVX2 / FMA / F16C / BMI / LZCNT / ADX / AVX-512 / AMX / AVX-VNNI
  sse42 = 仅 SSE4.2：在 avx 的基础上再禁所有 VEX 编码（v 开头）指令
退出码：0 干净；1 发现禁用指令；2 反汇编失败，或扫到的指令总数低于 --min-insns（路径写错时不能静默通过）
"""
import argparse, collections, re, subprocess, sys

AVX1_VP_OK = {'vptest', 'vpermilps', 'vpermilpd', 'vperm2f128'}  # 以 vp 开头但属于 AVX1 的浮点类指令
RULES = [  # (类别, 判定函数(助记符, 操作数))
    ('FMA', lambda m, o: re.match(r'^v(fn?m(add|sub)|fmaddsub|fmsubadd)(132|213|231)(ps|pd|ss|sd)$', m)),
    ('BMI', lambda m, o: re.match(r'^(andn|bextr|blsi|blsmsk|blsr|bzhi|mulx|pdep|pext|rorx|sarx|shlx|shrx)$', m)),
    ('LZCNT', lambda m, o: m == 'lzcnt'),  # tzcnt 不计：GCC 常把 rep bsf 写成它，老 CPU 上语义一致
    ('ADX', lambda m, o: m in ('adcx', 'adox')),
    ('F16C', lambda m, o: m in ('vcvtph2ps', 'vcvtps2ph')),
    ('AVX-VNNI', lambda m, o: re.match(r'^vpdp(busd|busds|wssd|wssds)$', m)),
    ('AMX', lambda m, o: re.match(r'^(tile\w+|tdp\w+|ldtilecfg|sttilecfg)$', m)),
    ('AVX-512', lambda m, o: re.search(r'\bzmm\d+\b|\{k[0-7]\}|\bk[0-7]\b|\b[xy]mm(1[6-9]|2\d|3[01])\b|\{z\}', o)),
    ('AVX2', lambda m, o: (
        re.match(r'^(vinserti128|vextracti128|vbroadcasti128|vperm2i128)$', m)
        or (m.startswith('vp') and m not in AVX1_VP_OK
            and (re.search(r'\bymm\d+\b', o)
                 or re.match(r'^(vpbroadcast[bwdq]|vpsllv[dq]|vpsrlv[dq]|vpsravd|vpblendd|vpmaskmov[dq]|vpgather\w*)$', m)))
        or (m in ('vbroadcastss', 'vbroadcastsd') and re.match(r'^\s*\w+\s*,\s*xmm', o))  # 寄存器源才是 AVX2
        or re.match(r'^vgather\w*$', m)
        or (m == 'vmovntdqa' and re.search(r'\bymm\d+\b', o)))),
]
LINE = re.compile(r'^\s*([0-9a-f]+):\s+([a-z][a-z0-9.]*)\s*(.*)$')
LABEL = re.compile(r'^[0-9a-f]+ <(.+)>:$')


def scan(objdump, path, tier, allow):
    p = subprocess.run([objdump, '-d', '--no-show-raw-insn', '-M', 'intel', path], capture_output=True, text=True, errors='replace')
    if p.returncode != 0:
        print(f'反汇编失败: {path}\n{p.stderr[:300]}', file=sys.stderr)
        sys.exit(2)
    total, hits, sym = 0, [], '?'
    for line in p.stdout.splitlines():
        if (m := LABEL.match(line)):
            sym = m.group(1)
        elif (m := LINE.match(line)):
            total += 1
            addr, mn, ops = m.group(1), m.group(2), m.group(3).split('#')[0]
            if any(a in sym for a in allow):
                continue
            cats = [c for c, f in RULES if f(mn, ops)]
            if tier == 'sse42' and mn.startswith('v') and mn not in ('verr', 'verw'):
                cats.append('VEX')
            hits += [(c, addr, f'{mn} {ops.strip()}', sym) for c in cats]
    return total, hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--objdump', default='llvm-objdump')
    ap.add_argument('--tier', choices=['avx', 'sse42'], default='avx')
    ap.add_argument('--min-insns', type=int, default=1)
    ap.add_argument('--allow-sym', action='append', default=[], help='符号名含该子串的函数不计（如 ma_dr_：miniaudio 里有运行时 cpuid 保护的 lzcnt）')
    ap.add_argument('--max-hits', type=int, default=10)
    ap.add_argument('files', nargs='+')
    a = ap.parse_args()
    grand, allhits = 0, []
    for f in a.files:
        t, h = scan(a.objdump, f, a.tier, a.allow_sym)
        grand += t
        allhits += [(f, *x) for x in h]
    print(f'扫描 {len(a.files)} 个文件，共 {grand} 条指令，档位 {a.tier}')
    if grand < a.min_insns:
        print(f'指令数低于 --min-insns={a.min_insns}：路径或文件类型可能不对，按失败处理')
        return 2
    if not allhits:
        print('干净：没有该档位不允许的指令')
        return 0
    cnt = collections.Counter(x[1] for x in allhits)
    print('命中: ' + ', '.join(f'{k}={v}' for k, v in cnt.most_common()))
    for f, c, addr, ins, sym in allhits[: a.max_hits]:
        print(f'  [{c}] {f} {addr}  {ins}   <{sym}>')
    return 1


if __name__ == '__main__':
    # Windows runner 上管道的默认编码不是 UTF-8，输出中文会触发 UnicodeEncodeError，闸门会因此误判失败
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
