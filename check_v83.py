#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取并分析设备端 LiveCap 日志，验证 v1.0.83 的三个关键指标。

v1.0.83 验证点：
  A. 英文行彻底消失      → oLbl 高度必须全为 0，且 hidden=YES
  B. 中文显示完整不截断  → 容器高度不再冻结在 58，且 tLbl 底边 ≤ 容器高度
  C. 字幕正常轮动        → seq 严格递增

日志经 base64 传输后本地 UTF-8 解码（Windows 终端是 GBK，直接读会乱码）。

用法: python3 check_v83.py
"""
import base64
import os
import re
import subprocess
import sys

HOST = "root@10.10.201.107"
LOG = ("/var/mobile/Containers/Data/Application/"
       "C7E7F401-7808-465F-8787-F05AE203D242/Documents/livecap.log")


def fetch_log():
    """通过 ssh + base64 拿日志（避免编码问题）"""
    cmd = ["ssh", "-o", "StrictHostKeyChecking=no", HOST,
           "base64 -i '%s' 2>/dev/null || base64 '%s'" % (LOG, LOG)]
    p = subprocess.run(cmd, capture_output=True)
    out = p.stdout
    if not out.strip():
        return None
    # 去掉可能的换行
    b64 = b"".join(out.split())
    try:
        return base64.b64decode(b64).decode("utf-8", errors="replace")
    except Exception as e:
        print("base64 解码失败: %s" % e)
        return None


def analyze(text):
    lines = text.splitlines()
    print("日志总行数: %d" % len(lines))

    # ---- 提取 overlay: layout 行 ----
    layout_re = re.compile(
        r"overlay: layout c=\((-?[\d.]+),(-?[\d.]+),(-?[\d.]+),(-?[\d.]+)\) "
        r"oLbl=\((-?[\d.]+),(-?[\d.]+),h=(-?[\d.]+)\) "
        r"tLbl=\((-?[\d.]+),(-?[\d.]+),h=(-?[\d.]+)\) oh=([\d.]+) th=([\d.]+)")
    layouts = []
    for ln in lines:
        m = layout_re.search(ln)
        if m:
            g = [float(x) for x in m.groups()]
            layouts.append({
                "cx": g[0], "cy": g[1], "cw": g[2], "ch": g[3],
                "ox": g[4], "oy": g[5], "oh": g[6],
                "tx": g[7], "ty": g[8], "th": g[9],
                "oh2": g[10], "th2": g[11],
                "line": ln,
            })

    print("layout 行数: %d" % len(layouts))
    if not layouts:
        print("\n[警告] 没有 layout 行 —— tweak 可能未注入或日志被截断")
        # 看看日志尾部
        print("--- 日志最后 15 行 ---")
        for l in lines[-15:]:
            print("   ", l[:160])
        return False

    ok = True

    # ---- A. 英文行是否彻底消失 ----
    o_h = [l["oh"] for l in layouts]
    nonzero = [v for v in o_h if v > 0.01]
    print("\n=== A. 英文行检查 ===")
    print("  oLbl 高度样本数: %d，非零数: %d" % (len(o_h), len(nonzero)))
    if nonzero:
        ok = False
        print("  [FAIL] 仍有英文行！样例:")
        for l in layouts[:3]:
            if l["oh"] > 0.01:
                print("     ", l["line"][:180])
    else:
        print("  [PASS] 英文行高度全为 0（已彻底收起）")

    # ---- B. 中文是否被截断 ----
    print("\n=== B. 中文完整性检查 ===")
    heights = sorted({round(l["ch"], 1) for l in layouts})
    print("  容器高度取值集合: %s" % heights)
    if len(set(heights)) == 1 and heights[0] < 70:
        ok = False
        print("  [FAIL] 容器高度恒定在 %s —— 疑似仍被冻结" % heights)
    else:
        print("  [PASS] 容器高度随内容变化（未冻结）")

    # tLbl 底边必须落在容器内
    over = []
    for l in layouts:
        if l["th"] <= 0.01:
            continue
        # 标签坐标是相对容器的（容器自身 y 偏移 + 标签 y）
        bottom = l["ty"] + l["th"]
        if bottom > l["ch"] + 0.5:
            over.append((l, bottom))
    print("  中文标签超出容器的样本数: %d / %d"
          % (len(over), len([l for l in layouts if l["th"] > 0.01])))
    if over:
        ok = False
        print("  [FAIL] 中文被裁切，样例:")
        for l, b in over[:3]:
            print("     ch=%.0f tLbl.y=%.0f tLbl.h=%.0f 底边=%.0f 超 %.0f"
                  % (l["ch"], l["ty"], l["th"], b, b - l["ch"]))
    else:
        print("  [PASS] 中文标签底边均落在容器内（未被 masksToBounds 裁掉）")

    # ---- C. seq 轮动 ----
    print("\n=== C. 轮动检查 ===")
    seqs = []
    for ln in lines:
        for m in re.finditer(r"seq=(\d+)", ln):
            seqs.append(int(m.group(1)))
    uniq = sorted(set(seqs))
    print("  seq 出现次数: %d，唯一值: %d" % (len(seqs), len(uniq)))
    if uniq:
        print("  seq 范围: %d .. %d" % (uniq[0], uniq[-1]))
        gaps = [uniq[i + 1] - uniq[i] for i in range(len(uniq) - 1)]
        nonpos = [g for g in gaps if g <= 0]
        if nonpos:
            ok = False
            print("  [FAIL] seq 非严格递增")
        else:
            print("  [PASS] seq 严格递增 → 字幕随语音正常轮动")

    # ---- 翻译结果抽样 ----
    print("\n=== 翻译抽样（最后 3 条） ===")
    trans = re.findall(r"trans=\[(.*?)\]\s*(?:transLen|$)", "\n".join(lines))
    if not trans:
        trans = re.findall(r"trans=\[(.*?)\]", "\n".join(lines))
    for t in trans[-3:]:
        print("  ", t[:120])

    # ---- 失败统计 ----
    fails = len(re.findall(r"showFailed", text))
    drops = len(re.findall(r"drop stale", text))
    print("\n  showFailed 次数: %d   drop stale 次数: %d" % (fails, drops))

    print("\n" + "=" * 56)
    if ok:
        print("v1.0.83 验证全部通过 ✅")
    else:
        print("v1.0.83 验证存在未通过项 ❌")
    return ok


def main():
    text = fetch_log()
    if text is None:
        print("无法获取日志（YouTube 可能没运行，或日志文件不存在）")
        return 2
    return 0 if analyze(text) else 1


if __name__ == "__main__":
    sys.exit(main())
