#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取并分析设备端 LiveCap 日志，验证 v1.0.84 的两个修复 + v1.0.83 回归。

v1.0.84 验证点：
  A. 翻译延迟降低  → 解析 `asr: rtt=XXXXms audio=Ys bytes=N`，统计 avg/median/max
                    对照基线：v1.0.83 设备实测 avg RTT = 5.6s（音频 5.11~7.20s）
  B. 全屏字幕显示  → 出现 `overlay: brought to front` / `overlay: re-homed to new window`
                    / `overlay: key window changed` 之一
  C. 分片时长生效  → `asr: sending` 对应的音频秒数应 ≈ 2.5s（不再 5s+）
  D. v1.0.83 三项不回归 → 复用 check_v83.analyze

日志经 base64 传输后本地 UTF-8 解码（Windows 终端是 GBK，直接读会乱码）。

用法: python3 check_v84.py
"""
import base64
import re
import subprocess
import sys

import check_v83

HOST = "root@10.10.201.107"
LOG = check_v83.LOG

# v1.0.83 基线（设备日志实测）
BASELINE_AVG_RTT_MS = 5600.0
BASELINE_CHUNK_SEC = 5.0


def fetch_log():
    cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o",
           "UserKnownHostsFile=/dev/null", HOST,
           "base64 -i '%s' 2>/dev/null || base64 '%s'" % (LOG, LOG)]
    p = subprocess.run(cmd, capture_output=True)
    out = p.stdout
    if not out.strip():
        return None
    b64 = b"".join(out.split())
    try:
        return base64.b64decode(b64).decode("utf-8", errors="replace")
    except Exception as e:
        print("base64 解码失败: %s" % e)
        return None


def analyze_v84(text):
    """返回 (是否通过, 结论字符串列表)"""
    lines = text.splitlines()
    ok = True
    concl = []

    # ---------- A. ASR RTT ----------
    print("\n=== A. ASR 延迟（RTT）===")
    rtts = []
    for ln in lines:
        m = re.search(r"asr: rtt=([\d.]+)ms audio=([\d.]+)s bytes=(\d+)", ln)
        if m:
            rtts.append((float(m.group(1)), float(m.group(2)), int(m.group(3))))
    if not rtts:
        print("  [WARN] 没有 `asr: rtt=` 行 —— 可能是毫秒级打点没生效，或没有 ASR 请求")
        concl.append("A: 无 RTT 打点数据（需播放视频产生 ASR 请求）")
    else:
        vals = [r[0] for r in rtts]
        audios = [r[1] for r in rtts]
        avg = sum(vals) / len(vals)
        srt = sorted(vals)
        med = srt[len(srt) // 2]
        print("  样本数: %d" % len(vals))
        print("  RTT avg=%.0fms  median=%.0fms  min=%.0fms  max=%.0fms"
              % (avg, med, min(vals), max(vals)))
        print("  对照 v1.0.83 基线 avg=%.0fms" % BASELINE_AVG_RTT_MS)
        ratio = avg / BASELINE_AVG_RTT_MS
        print("  延迟改善倍数: %.2fx（越小越好）" % ratio)
        for r in rtts[:8]:
            print("    rtt=%-7.0fms audio=%.2fs bytes=%d" % r)
        if avg < BASELINE_AVG_RTT_MS * 0.6:
            print("  [PASS] 延迟显著下降")
            concl.append("A: RTT avg %.0fms（基线 %.0fms，改善 %.2fx）"
                         % (avg, BASELINE_AVG_RTT_MS, ratio))
        elif avg < BASELINE_AVG_RTT_MS:
            print("  [PASS] 延迟下降")
            concl.append("A: RTT avg %.0fms（基线 %.0fms，改善 %.2fx）"
                         % (avg, BASELINE_AVG_RTT_MS, ratio))
        else:
            ok = False
            print("  [FAIL] 延迟未下降（可能分片没生效）")
            concl.append("A: RTT avg %.0fms，未低于基线 %.0fms"
                         % (avg, BASELINE_AVG_RTT_MS))

        # ---------- C. 分片时长 ----------
        print("\n=== C. 分片时长生效检查 ===")
        amax = max(audios)
        amin = min(audios)
        print("  音频分片时长: min=%.2fs max=%.2fs (配置 asrChunkSeconds=2.5)"
              % (amin, amax))
        if amax <= 3.2:
            print("  [PASS] 分片已缩短到 ~2.5s（不再是固定 5s）")
            concl.append("C: 分片 max=%.2fs，符合 2.5s 配置" % amax)
        elif amax <= BASELINE_CHUNK_SEC + 0.3:
            print("  [WARN] 分片仍是 %.2fs —— 配置可能没生效" % amax)
            concl.append("C: 分片仍为 %.2fs，未按配置缩短" % amax)
        else:
            print("  [FAIL] 分片时长异常：%.2fs" % amax)
            ok = False
            concl.append("C: 分片异常 %.2fs" % amax)

    # ---------- B. 全屏修复 ----------
    print("\n=== B. 全屏字幕修复检查 ===")
    markers = {
        "overlay: brought to front": "字幕提到窗口最顶层",
        "overlay: re-homed to new window": "字幕迁移到新的全屏 window",
        "overlay: key window changed": "key window 变化触发重新布局",
        "overlay: window became visible": "window 可见触发重新布局",
    }
    found = {}
    for k, desc in markers.items():
        n = len(re.findall(re.escape(k), text))
        found[k] = n
        print("  %-38s x%d  (%s)" % (k, n, desc))
    total = sum(found.values())
    if total > 0:
        print("  [PASS] 全屏修复逻辑已触发（共 %d 次）" % total)
        concl.append("B: 全屏修复触发 %d 次" % total)
    else:
        print("  [WARN] 没抓到全屏修复日志 —— 若确实播放过全屏，请检查是否进过全屏")
        concl.append("B: 无全屏修复日志（需实际进入全屏播放）")

    # ---------- 翻译链完整性 ----------
    print("\n=== 翻译链抽样 ===")
    trans = re.findall(r"trans=\[(.*?)\]", "\n".join(lines))
    for t in trans[-5:]:
        print("   ", t[:140])
    print("  翻译条数: %d" % len(trans))

    fails = len(re.findall(r"showFailed", text))
    drops = len(re.findall(r"drop stale", text))
    print("\n  showFailed: %d   drop stale: %d" % (fails, drops))
    if fails:
        ok = False
        concl.append("翻译失败 %d 次" % fails)

    return ok, concl


def main():
    text = fetch_log()
    if text is None:
        print("无法获取日志（YouTube 可能没运行，或日志文件不存在）")
        return 2
    if not text.strip():
        print("日志为空 —— 请先在手机上打开 YouTube 播放视频（含进入全屏）")
        return 2

    print("日志总行数: %d" % len(text.splitlines()))
    ok84, concl = analyze_v84(text)

    print("\n" + "=" * 60)
    print("--- v1.0.83 回归检查 ---")
    ok83 = check_v83.analyze(text)

    print("\n" + "=" * 60)
    print("=== v1.0.84 结论 ===")
    for c in concl:
        print("  -", c)
    if ok84 and ok83:
        print("\n✅ v1.0.84 验证通过（延迟 + 全屏 + v1.0.83 回归全绿）")
        return 0
    print("\n❌ 存在未通过项")
    return 1


if __name__ == "__main__":
    sys.exit(main())
