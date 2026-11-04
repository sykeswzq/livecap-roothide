#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析 LiveCap 日志中的翻译延迟链路"""
import base64
import io
import os
import re
import subprocess
import sys
from datetime import datetime

HOST = "root@10.10.201.107"
LOG = "/var/mobile/Containers/Data/Application/C7E7F401-7808-465F-8787-F05AE203D242/Documents/livecap.log"


def fetch_log():
    """通过 base64 传输避免 Windows 终端 GBK 乱码"""
    r = subprocess.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", HOST,
         "base64 -i %s" % LOG],
        capture_output=True)
    if r.returncode != 0:
        print("SSH failed:", r.stderr.decode("utf-8", "replace")[:300])
        return None
    txt = r.stdout.decode("ascii", "replace").strip()
    txt = re.sub(r"\s+", "", txt)
    try:
        return base64.b64decode(txt).decode("utf-8", "replace")
    except Exception as e:
        print("decode failed:", e)
        return None


def parse_ts(line):
    m = re.match(r"\[(\d{2}):(\d{2}):(\d{2})\]", line)
    if not m:
        return None
    h, mi, s = map(int, m.groups())
    return h * 3600 + mi * 60 + s


def main():
    text = fetch_log()
    if not text:
        return 1
    lines = text.splitlines()
    print("日志行数:", len(lines))

    # 找出所有关键事件
    events = []  # (time, kind, payload)
    for ln in lines:
        ts = parse_ts(ln)
        if ts is None:
            continue
        body = ln.split("]", 1)[1] if "]" in ln else ln

        if "asr:" in body.lower() or "ASR" in body:
            events.append((ts, "asr", body))
        if "translate" in body.lower() or "trans" in body.lower() or "译文" in body:
            events.append((ts, "trans", body))
        if "showPair" in body or "showPending" in body or "showFailed" in body:
            events.append((ts, "show", body))

    print("\n=== 关键事件类型统计 ===")
    from collections import Counter
    c = Counter(k for _, k, _ in events)
    for k, v in c.items():
        print("  %-8s %d" % (k, v))

    # 打印 ASR 相关原始样本
    print("\n=== 含 asr / 语音 / 识别 的原始行样本（最后 12 条）===")
    cand = [ln for ln in lines if re.search(r"asr|ASR|vad|VAD|识别|end|speech", ln, re.I)]
    for ln in cand[-12:]:
        print("  ", ln[:200])

    print("\n=== 翻译相关行样本（最后 15 条）===")
    cand2 = [ln for ln in lines if re.search(r"trans|translate|agnes|mymemory|api|http", ln, re.I)]
    for ln in cand2[-15:]:
        print("  ", ln[:200])

    print("\n=== show* 相关行样本（最后 15 条）===")
    cand3 = [ln for ln in lines if re.search(r"showPair|showPending|showFailed|drop stale", ln)]
    for ln in cand3[-15:]:
        print("  ", ln[:200])

    print("\n=== 全部日志首 25 行（看初始化与配置）===")
    for ln in lines[:25]:
        print("  ", ln[:200])

    return 0


if __name__ == "__main__":
    sys.exit(main())
