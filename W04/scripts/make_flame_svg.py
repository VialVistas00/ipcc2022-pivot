#!/usr/bin/env python3
"""Render flame.svg from the perf report/annotate text captured on hzcu-hpct.

The original perf.data is not committed; this script uses the two text
reports that were produced from it. Frame widths are sample percentages,
not a replay of individual stack samples.
"""

import argparse
import html
import re
from pathlib import Path

REPORT_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)%\s+(\d+(?:\.\d+)?)%\s+\[\.\]\s+(\S+)")
ANNOTATE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*:\s*[0-9a-fA-F]+:\s*(.+?)\s*$")

COLORS = {
    "root": "#7f1d1d",
    "libc": "#991b1b",
    "main": "#b45309",
    "comb1": "#c2410c",
    "comb2": "#d97706",
    "sum": "#ea580c",
}
INSTR_COLORS = [
    "#fbbf24", "#fcd34d", "#fde68a", "#f59e0b",
    "#fca5a5", "#fdba74", "#fed7aa", "#fef3c7", "#e5e7eb",
]


def esc(text):
    return html.escape(str(text), quote=True)


def parse_report(path):
    funcs = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = REPORT_RE.match(line)
        if m:
            funcs[m.group(3)] = (float(m.group(1)), float(m.group(2)))
    return funcs


def parse_annotate(path, top):
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = ANNOTATE_RE.match(line)
        if not m:
            continue
        pct = float(m.group(1))
        if pct > 0:
            rows.append((pct, m.group(2).strip()))
    rows.sort(key=lambda r: r[0], reverse=True)
    top_rows = rows[:top]
    other = 100.0 - sum(p for p, _ in top_rows)
    if other > 0.01:
        top_rows.append((other, "other instructions"))
    return top_rows


def short_label(ins):
    ins = " ".join(ins.split())
    replacements = {
        "jne 19a0 <SumDistance+0x1b0>": "jne (loop)",
        "jmp 1988 <SumDistance+0x198>": "jmp",
        "mov %r11,%rdx": "mov (ptr reset)",
        "mov %edx,%r8d": "mov (ki reset)",
        "maxsd %xmm1,%xmm0": "maxsd (max)",
        "movsd (%rdx),%xmm0": "movsd (load)",
        "addsd %xmm1,%xmm3": "addsd (sum)",
        "andpd %xmm2,%xmm0": "andpd (fabs)",
    }
    if ins in replacements:
        return replacements[ins]
    return " ".join(ins.split()[:2])


def svg_text(x, y, text, size=13, fill="#111827", anchor="start", weight="400"):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" '
        f'text-anchor="{anchor}" font-weight="{weight}">{esc(text)}</text>'
    )


def frame(parts, x, y, w, h, color, label, pct, tooltip, tag=None, dark_text=False):
    fill = "#3f2a00" if dark_text else "#ffffff"
    parts.append(
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 1.2):.1f}" height="{h}" '
        f'rx="3" fill="{color}" stroke="#fffaf0" stroke-width="1">'
        f'<title>{esc(tooltip)}</title></rect>'
    )
    if w >= 150:
        parts.append(svg_text(x + 8, y + h / 2 + 4.5, f"{label} · {pct:.2f}%", 12.5, fill, weight="600"))
    elif w >= 82:
        parts.append(svg_text(x + 6, y + h / 2 + 4.5, f"{pct:.2f}%", 11.5, fill, weight="600"))
    elif tag is not None:
        cx, cy = x + w / 2, y + h / 2
        parts.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="9" fill="#fffdf8" stroke="#9a3412"/>')
        parts.append(svg_text(cx, cy + 3.5, str(tag), 10, "#9a3412", "middle", "700"))


def main():
    here = Path(__file__).resolve().parent
    default_data = here.parent / "data"
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--report", type=Path, default=default_data / "perf-report.txt")
    ap.add_argument("--annotate", type=Path, default=default_data / "perf-annotate.txt")
    ap.add_argument("--out", type=Path, default=here.parent / "flame.svg")
    ap.add_argument("--top", type=int, default=8)
    args = ap.parse_args()

    funcs = parse_report(args.report)
    instr = parse_annotate(args.annotate, args.top)

    libc = funcs.get("__libc_start_call_main", (99.98, 0.0))[0]
    main_pct = funcs.get("main", (99.98, 0.0))[0]
    comb = funcs.get("Combination", (99.98, 0.35))
    sumd = funcs.get("SumDistance", (99.61, 99.55))
    comb_pct, comb_self = comb
    sum_pct, sum_self = sumd
    recursive_pct = 99.63
    recursive_self = max(recursive_pct - sum_pct, 0.0)

    width, height = 1280, 900
    left, right, top = 92, 52, 154
    plot_w = width - left - right
    level_h = 48
    levels = 7
    plot_bottom = top + levels * level_h

    def px(pct):
        return plot_w * pct / 100.0

    def x_at(pct):
        return left + px(pct)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        '<title id="title">pivot baseline 热点火焰图</title>',
        '<desc id="desc">2022 IPCC pivot baseline 在 hzcu-hpct 上的 perf 采样热点，'
        '按调用栈与 perf annotate 指令占比绘制。</desc>',
        '<rect width="100%" height="100%" fill="#fffdf8"/>',
    ]

    parts.append(svg_text(left, 38, "pivot baseline 热点火焰图", 24, "#7c2d12", weight="700"))
    parts.append(svg_text(
        left, 64,
        "2022 IPCC pivot · dim=2, n=500, k=2 · C(500,2)=124,750 组枢轴 · hzcu-hpct / Xeon Gold 6430",
        13.5, "#374151",
    ))
    parts.append(svg_text(
        left, 88,
        "perf record -F 999 -g -o perf.data -- taskset -c 8 ./pivot_O2 uniformvector-2dim-5h.txt",
        12.5, "#4b5563",
    ))
    parts.append(svg_text(
        left, 110,
        "perf report: 60K cycles samples（Lost=0） · perf annotate: 59,730 samples · 采样时长约 59.9 s",
        12.5, "#4b5563",
    ))
    parts.append(svg_text(
        left, 132,
        "x 轴：累计样本占比（%）  ·  y 轴：调用栈深度  ·  帧宽 = 该帧样本数 / 总样本数",
        12.5, "#6b7280",
    ))

    plot_top = top
    for tick in range(0, 101, 20):
        x = x_at(tick)
        parts.append(
            f'<line x1="{x:.1f}" y1="{plot_top - 4}" x2="{x:.1f}" y2="{plot_bottom + 4}" '
            f'stroke="#e5e7eb" stroke-width="1"/>'
        )
    parts.append(
        f'<line x1="{left}" y1="{plot_bottom + 4}" x2="{left + plot_w}" y2="{plot_bottom + 4}" '
        f'stroke="#9ca3af" stroke-width="1"/>'
    )
    for tick in range(0, 101, 20):
        parts.append(svg_text(x_at(tick), plot_bottom + 24, f"{tick}%", 11.5, "#6b7280", "middle"))

    y = top
    frame(parts, left, y, px(100), level_h - 4, COLORS["root"], "pivot_O2（全部样本）", 100.0,
          "根节点：pivot_O2 全部 cycles 样本")

    y += level_h
    frame(parts, left, y, px(libc), level_h - 4, COLORS["libc"], "__libc_start_call_main", libc,
          "__libc_start_call_main · children 99.98% · self 0.00%")

    y += level_h
    frame(parts, left, y, px(main_pct), level_h - 4, COLORS["main"], "main", main_pct,
          "main · children 99.98% · self 0.00%", dark_text=True)

    y += level_h
    frame(parts, left, y, px(comb_pct), level_h - 4, COLORS["comb1"], "Combination", comb_pct,
          f"Combination · children {comb_pct:.2f}% · self {comb_self:.2f}%")

    y += level_h
    frame(parts, x_at(comb_self), y, px(recursive_pct), level_h - 4, COLORS["comb2"],
          "Combination（递归）", recursive_pct,
          f"Combination 递归调用 · {recursive_pct:.2f}%")

    y += level_h
    frame(parts, x_at(recursive_self + comb_self), y, px(sum_pct), level_h - 4, COLORS["sum"],
          "SumDistance", sum_pct,
          f"SumDistance · children {sum_pct:.2f}% · self {sum_self:.2f}%")

    y += level_h
    instr_x = x_at(comb_self + recursive_self)
    for i, (pct_in_sum, ins) in enumerate(instr):
        w = px(sum_pct) * pct_in_sum / 100.0
        color = INSTR_COLORS[i % len(INSTR_COLORS)]
        frame(parts, instr_x, y, w, level_h - 4, color, short_label(ins), pct_in_sum,
              f"{ins} · {pct_in_sum:.2f}% of SumDistance", tag=i + 1, dark_text=True)
        instr_x += w

    axis_y = plot_bottom + 52
    parts.append(svg_text(left, axis_y, "指令级热点（perf annotate，按 SumDistance 内占比排序）", 14, "#7c2d12", weight="700"))

    legend_y = axis_y + 26
    row_h = 24
    parts.append(svg_text(left, legend_y, "#", 11.5, "#6b7280", weight="700"))
    parts.append(svg_text(left + 34, legend_y, "指令", 11.5, "#6b7280", weight="700"))
    parts.append(svg_text(left + 560, legend_y, "占 SumDistance", 11.5, "#6b7280", weight="700"))
    parts.append(svg_text(left + 760, legend_y, "占总 cycles 样本", 11.5, "#6b7280", weight="700"))
    parts.append(svg_text(left + 980, legend_y, "说明", 11.5, "#6b7280", weight="700"))

    for i, (pct_in_sum, ins) in enumerate(instr):
        ry = legend_y + row_h * (i + 1)
        color = INSTR_COLORS[i % len(INSTR_COLORS)]
        parts.append(f'<circle cx="{left + 10}" cy="{ry - 4}" r="8" fill="{color}" stroke="#9a3412"/>')
        parts.append(svg_text(left + 10, ry - 0.5, str(i + 1), 9.5, "#7c2d12", "middle", "700"))
        parts.append(svg_text(left + 34, ry, ins, 11.5, "#111827"))
        parts.append(svg_text(left + 560, ry, f"{pct_in_sum:.2f}%", 11.5, "#111827"))
        parts.append(svg_text(left + 760, ry, f"{pct_in_sum * sum_pct / 100.0:.2f}%", 11.5, "#111827"))
        note = ""
        if "addsd" in ins:
            note = "唯一累加器，串行依赖"
        elif "maxsd" in ins:
            note = "切比雪夫核心 max"
        elif "jne" in ins or "jmp" in ins:
            note = "循环回边 / 跳转"
        elif "movsd" in ins:
            note = "读 rebuiltCoord"
        elif "andpd" in ins:
            note = "fabs 位掩码"
        elif "other" in ins:
            note = "剩余指令"
        parts.append(svg_text(left + 980, ry, note, 11.5, "#4b5563"))

    footer_y = legend_y + row_h * (len(instr) + 1) + 26
    parts.append(svg_text(
        left, footer_y,
        "数据说明：原始 perf.data 未入库；本图由 scripts/make_flame_svg.py 从 data/perf-report.txt 与 "
        "data/perf-annotate.txt 的聚合占比重建。",
        11.5, "#6b7280",
    ))
    parts.append(svg_text(
        left, footer_y + 18,
        "帧宽 = 样本占比，不是逐样本栈重放；SumDistance 的 self 为 99.55%，其子帧为 annotate 的指令级占比。",
        11.5, "#6b7280",
    ))
    parts.append("</svg>")

    args.out.write_text("\n".join(parts) + "\n", encoding="utf-8")
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
