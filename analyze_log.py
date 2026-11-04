#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析设备 livecap.log：RTT 分布 / 超时率 / 是否双路重复上传 / 分片时长分布。"""
import re
import sys
from collections import Counter

path = sys.argv[1] if len(sys.argv) > 1 else "livecap.log"

data = open(path, "rb").read().decode("utf-8", "replace")
lines = data.splitlines()

rtts = []
chunks = []
fmt_counter = Counter()
send_bytes = []
rtt_bytes = []

for ln in lines:
    m = re.search(r"asr: rtt=(\d+)ms audio=([\d.]+)s bytes=(\d+) fmt=(\w+)", ln)
    if m:
        rtts.append(int(m.group(1)))
        chunks.append(float(m.group(2)))
        fmt_counter[m.group(4)] += 1
        rtt_bytes.append(int(m.group(3)))
    m2 = re.search(r"asr: sending (\d+) bytes \(\S+ fmt=(\w+)\)", ln)
    if m2:
        send_bytes.append(int(m2.group(1)))
        fmt_counter["send_" + m2.group(2)] += 1

print("=" * 76)
print("日志分析：%s" % path)
print("=" * 76)
print("ASR 请求数(rtt 行): %d   sending 行数: %d" % (len(rtts), len(send_bytes)))
print("格式分布: %s" % dict(fmt_counter))

if rtts:
    rs = sorted(rtts)
    n = len(rs)
    print("\nRTT 分布(ms):")
    print("  min=%d  p25=%d  中位=%d  p75=%d  max=%d  均值=%.0f" % (
        rs[0], rs[n // 4], rs[n // 2], rs[3 * n // 4], rs[-1], sum(rs) / n))
    timeouts = [r for r in rs if r >= 9900]
    print("  硬超时(>=9900ms，占 req.timeoutInterval=10s): %d 次 = %.0f%%" % (
        len(timeouts), 100.0 * len(timeouts) / n))
    fast = [r for r in rs if r < 4000]
    print("  快速(<4s): %d 次 = %.0f%%" % (len(fast), 100.0 * len(fast) / n))

    print("\n分片时长分布(s):")
    cs = Counter(chunks)
    for k in sorted(cs):
        print("    %.2fs : %d 次" % (k, cs[k]))
    print("  平均分片 = %.2fs（配置 asrChunkSeconds = 2.5）" % (sum(chunks) / len(chunks)))

    print("\n单请求上传体积(KB):")
    kb = sorted(b // 1024 for b in rtt_bytes)
    print("  min=%dKB  中位=%dKB  max=%dKB" % (kb[0], kb[len(kb) // 2], kb[-1]))
    print("  → 上行时间占比估算：按手机实测 ~25KB/s 有效上行")
    med = kb[len(kb) // 2]
    print("     中位 %dKB ÷ 25KB/s ≈ %.1fs 纯上传时间" % (med, med / 25.0))

# 检查是否双路重复：sending 的字节序列 vs rtt 的字节序列
if send_bytes and rtt_bytes:
    sset = Counter(send_bytes)
    rset = Counter(rtt_bytes)
    print("\nsending 字节多重集: %s" % dict(list(sset.items())[:6]))
    print("rtt     字节多重集: %s" % dict(list(rset.items())[:6]))
    only_send = sset - rset
    if only_send:
        print("  ⚠ 有 %d 字节从未对应到 rtt → 存在【请求发出但没收到回包】(超时丢弃)" %
              sum(only_send.values()))
