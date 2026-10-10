#!/usr/bin/env python3
"""兼容档指令闸门：反汇编 x86-64 目标文件（.o/.obj/.a/.lib）或动态库，检查是否含有该档位不允许的指令。

  avx   = SSE4.2 + AVX（ggml 的 sandybridge 档）：禁 AVX2 / FMA / F16C / BMI / LZCNT / ADX / AVX-512 / AMX / AVX-VNNI
  sse42 = 仅 SSE4.2：在 avx 的基础上再禁所有 VEX 编码（v 开头）指令

运行时保护：MSVC 即使没开 /arch:AVX2，也可能在自动向量化的循环里生成 AVX2 代码，并在函数内先比较 CRT 的
__isa_available（CPU 能力变量）再进入。反汇编加 -r 后能在重定位里看到这个引用；引用了它的函数里的命中
按「受运行时保护」单独列出、不判失败，其余命中一律判失败。--explain N 会把这些函数里保护判断和命中指令
前后 N 行打印出来，便于人工复核。

退出码：0 干净（或只有受运行时保护的命中）；1 发现无保护的禁用指令；2 反汇编失败，或扫到的指令总数低于 --min-insns（路径写错时不能静默通过）
"""
import argparse, collections, os, re, subprocess, sys

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
RELOC = re.compile(r'^\s*[0-9a-f]+:\s+(?:IMAGE_REL_|R_X86_64_)\w+\s+(\S+)')  # -r 时跟在指令后面的重定位行
GUARD_SYMS = ('__isa_available',)  # 引用了它的函数，里面的命中视为运行时分发


def new_func(sym):
    # lines：该函数的反汇编行（指令和重定位交错），hits：(类别, 地址, 指令文本, 在 lines 里的下标)
    return {'sym': sym, 'lines': [], 'guard': False, 'hits': []}


def scan(objdump, path, tier, allow):
    p = subprocess.run([objdump, '-d', '-r', '--no-show-raw-insn', '-M', 'intel', path], capture_output=True, text=True, errors='replace')
    if p.returncode != 0:
        print(f'反汇编失败: {path}\n{p.stderr[:300]}', file=sys.stderr)
        sys.exit(2)
    total, with_hits, cur = 0, [], new_func('?')
    for line in p.stdout.splitlines():
        if (m := LABEL.match(line)):
            if cur['hits']:
                with_hits.append(cur)
            cur = new_func(m.group(1))  # 没有命中的函数随之丢弃，不在内存里累积
        elif (m := RELOC.match(line)):
            cur['lines'].append(line.strip())
            if any(g in m.group(1) for g in GUARD_SYMS):
                cur['guard'] = True
        elif (m := LINE.match(line)):
            total += 1
            addr, mn, ops = m.group(1), m.group(2), m.group(3).split('#')[0]
            text = f'{mn} {ops.strip()}'
            cur['lines'].append(f'{addr}: {text}')
            if any(a in cur['sym'] for a in allow):
                continue
            cats = [c for c, f in RULES if f(mn, ops)]
            if tier == 'sse42' and mn.startswith('v') and mn not in ('verr', 'verw'):
                cats.append('VEX')
            cur['hits'] += [(c, addr, text, len(cur['lines']) - 1) for c in cats]
    if cur['hits']:
        with_hits.append(cur)
    return total, with_hits


def count_text(items):
    cnt = collections.Counter(h[0] for _, x in items for h in x['hits'])
    return ', '.join(f'{k}={v}' for k, v in cnt.most_common())


FULL_MAX = 200  # --explain 时，行数不超过这个数的函数整体打印（短函数的保护逻辑要看完整）


def excerpt(x, n):
    """保护判断（对 GUARD_SYMS 的重定位）和命中指令前后各 n 行；命中的指令行前面加 >>。"""
    lines, hit_idx = x['lines'], {h[3] for h in x['hits']}
    marks = {min(hit_idx)} | {i for i, ln in enumerate(lines) if any(g in ln for g in GUARD_SYMS)}
    keep = set()
    for i in marks:
        keep.update(range(max(0, i - n), min(len(lines), i + n + 1)))
    if len(lines) <= FULL_MAX:
        keep = set(range(len(lines)))
    out, prev = [], None
    for i in sorted(keep):
        if prev is not None and i != prev + 1:
            out.append('        ...')
        out.append(f'      {">>" if i in hit_idx else "  "} {lines[i]}')
        prev = i
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--objdump', default='llvm-objdump')
    ap.add_argument('--tier', choices=['avx', 'sse42'], default='avx')
    ap.add_argument('--min-insns', type=int, default=1)
    ap.add_argument('--allow-sym', action='append', default=[], help='符号名含该子串的函数不计（如 ma_dr_：miniaudio 里有运行时 cpuid 保护的 lzcnt）')
    ap.add_argument('--max-hits', type=int, default=10, help='最多列出多少个函数')
    ap.add_argument('--explain', type=int, default=0, metavar='N', help='对列出的函数，打印保护判断和命中指令前后各 N 行反汇编')
    ap.add_argument('files', nargs='+')
    a = ap.parse_args()
    grand, funcs = 0, []
    for f in a.files:
        t, fs = scan(a.objdump, f, a.tier, a.allow_sym)
        grand += t
        funcs += [(f, x) for x in fs]
    print(f'扫描 {len(a.files)} 个文件，共 {grand} 条指令，档位 {a.tier}')
    if grand < a.min_insns:
        print(f'指令数低于 --min-insns={a.min_insns}：路径或文件类型可能不对，按失败处理')
        return 2
    bad = [(f, x) for f, x in funcs if not x['guard']]
    guarded = [(f, x) for f, x in funcs if x['guard']]

    def show(tag, items):
        for f, x in items[: a.max_hits]:
            cats = sorted({h[0] for h in x['hits']})
            first = x['hits'][0]
            print(f'  [{tag}] {os.path.basename(f)} <{x["sym"]}> {"/".join(cats)} ×{len(x["hits"])}  例: {first[2]} @{first[1]}')
            if a.explain:
                print('\n'.join(excerpt(x, a.explain)))

    if guarded:
        print(f'受运行时保护的命中（函数内引用了 {"/".join(GUARD_SYMS)}，已放行）: {count_text(guarded)}，涉及 {len(guarded)} 个函数')
        show('已放行', guarded)
    if not bad:
        print('干净：没有无保护的禁用指令')
        return 0
    print(f'无保护的命中: {count_text(bad)}，涉及 {len(bad)} 个函数')
    show('失败', bad)
    return 1


if __name__ == '__main__':
    # Windows runner 上管道的默认编码不是 UTF-8，输出中文会触发 UnicodeEncodeError，闸门会因此误判失败
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
