#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 设备日志分析：验证【ADTS 压缩是否真的生效】+【延迟是否下降】+【字号热重载】。

对比基线（v1.0.86 设备实测，662880 字节日志）：
    格式分布      send_aac 4 次 / send_wav 78 次   ← AAC 几乎全程被禁用
    RTT           min=1477 / 中位=4875 / max=11264 ms
    硬超时        17 次 = 21%（req.timeoutInterval=10s）
    单请求体积    中位 79KB（手机上行 ~25KB/s → 光上传就 3.2s）
    分片时长      平均 2.79s（配置 2.5），但有 3.48~4.41s 长尾

v1.0.87 期望：
    格式分布      send_aac 占绝大多数
    单请求体积    中位 ≈ 8KB（离线实测：PyAV 编 2.5s @24kbps ADTS = 8230 字节）
    RTT           中位应显著低于 4875ms
    硬超时        应接近 0
    压缩比        8KB vs 79KB ≈ 9.6 倍；纯上传 0.33s vs 3.2s

离线已验证（verify_adts.py，不用上真机）：
    - ADTS 头与 FFmpeg 官方 muxer 输出 41/41 帧逐字节一致
    - ISO/IEC 13818-7 独立解析同样一致
    - 回灌 FFmpeg 解复用器读出 16000Hz / mono / 帧数一致
    → 剩下唯一未验证环节：Apple AudioConverter 产出的 AAC 是否被腾讯云接受
"""
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
rtt_by_fmt = {"aac": [], "wav": []}
aac_fail = 0
direct_fail = 0
trimmed = 0
watcher_started = 0
font_changed = []
aac_cooldown = 0
direct_cooldown = 0

for ln in lines:
    m = re.search(r"asr(?:16)?: rtt=(\d+)ms audio=([\d.]+)s bytes=(\d+) fmt=(\w+)", ln)
    if m:
        rtts.append(int(m.group(1)))
        chunks.append(float(m.group(2)))
        rtt_bytes.append(int(m.group(3)))
        fmt_counter["rtt_" + m.group(4)] += 1
        rtt_by_fmt.setdefault(m.group(4), []).append(int(m.group(1)))
    m2 = re.search(r"asr(?:16)?: sending (\d+) bytes \(\S+ fmt=(\w+)\)", ln)
    if m2:
        send_bytes.append(int(m2.group(1)))
        fmt_counter["send_" + m2.group(2)] += 1
    if "aac failure #" in ln:
        aac_fail += 1
    if "aac cooldown over" in ln:
        aac_cooldown += 1
    if "direct failed" in ln:
        direct_fail += 1
    if "direct cooldown over" in ln:
        direct_cooldown += 1
    if "pcm trimmed" in ln or "pcm16 trimmed" in ln:
        trimmed += 1
    if "config watcher started" in ln:
        watcher_started += 1
    m3 = re.search(r"fontSize changed ([\d.]+) -> ([\d.]+)", ln)
    if m3:
        font_changed.append((m3.group(1), m3.group(2)))


def pct(vals, q):
    if not vals:
        return 0
    v = sorted(vals)
    i = int(len(v) * q)
    return v[min(i, len(v) - 1)]


print("=" * 74)
print("v1.0.87 日志分析：%s（%d 行 / %d 字节）" % (path, len(lines), len(data)))
print("=" * 74)

print("\n[1] 压缩是否生效（核心）")
print("  格式分布: %s" % dict(fmt_counter))
aac_send = fmt_counter.get("send_aac", 0)
wav_send = fmt_counter.get("send_wav", 0)
tot_send = aac_send + wav_send
if tot_send:
    print("  → AAC 占比 %.0f%%（v1.0.86 只有 5%%）" % (100.0 * aac_send / tot_send))
    print("  → 判定: %s" % ("✅ 压缩已生效" if aac_send >= wav_send else
                            "❌ 压缩仍未生效（AAC 被拒/编码器不可用）"))
if send_bytes:
    sizes = sorted(b / 1024.0 for b in send_bytes)
    med = sizes[len(sizes) // 2]
    print("  单请求体积: min=%.1fKB 中位=%.1fKB max=%.1fKB" % (sizes[0], med, sizes[-1]))
    print("  → 按手机实测 ~25KB/s 上行，纯上传约 %.2fs（v1.0.86 中位 79KB ≈ 3.2s，压缩 %.1fx）"
          % (med / 25.0, (79.0 / med) if med else 0))
    if med <= 12:
        print("  → 判定: ✅ 体积符合 ADTS-AAC 预期（离线实测 2.5s@24kbps = 8.2KB）")
    else:
        print("  → 判定: ⚠️ 体积偏大，可能仍在发 WAV，或 AAC 编码器未生效")
print("  AAC 失败次数: %d   AAC 冷却恢复: %d" % (aac_fail, aac_cooldown))
print("  直连失败次数: %d   直连冷却恢复: %d" % (direct_fail, direct_cooldown))
print("  分片裁剪次数(trim): %d" % trimmed)

print("\n[2] 延迟")
if rtts:
    rs = sorted(rtts)
    n = len(rs)
    print("  RTT(ms): min=%d p25=%d 中位=%d p75=%d max=%d 均值=%.0f"
          % (rs[0], pct(rs, .25), rs[n // 2], pct(rs, .75), rs[-1], sum(rs) / n))
    print("  基线(v1.0.86): min=1477 p25=3190 中位=4875 p75=8130 max=11264 均值=5522")
    to = [r for r in rs if r >= 9900]
    print("  硬超时(>=9900ms): %d 次 = %.0f%%（v1.0.86 是 21%%）"
          % (len(to), 100.0 * len(to) / n))
    print("  快速(<4s): %d 次 = %.0f%%" % (len([r for r in rs if r < 4000]),
                                          100.0 * len([r for r in rs if r < 4000]) / n))
    for f in ("aac", "wav"):
        v = rtt_by_fmt.get(f) or []
        if v:
            print("  %s 路径 RTT: n=%d 中位=%dms 最大=%dms" % (f, len(v), sorted(v)[len(v) // 2], max(v)))
else:
    print("  （没有 rtt 行 —— ASR 还没跑起来）")

if chunks:
    cs = Counter(chunks)
    print("\n[3] 分片时长分布(s)")
    for k in sorted(cs):
        print("    %.2fs : %d 次" % (k, cs[k]))
    print("  平均 = %.2fs（配置 2.5）  长尾(>3.2s) = %d 次"
          % (sum(chunks) / len(chunks), len([c for c in chunks if c > 3.2])))

print("\n[4] 字号热重载")
print("  配置监听启动次数: %d" % watcher_started)
if font_changed:
    print("  字号变化事件: %s" % font_changed)
else:
    print("  字号变化事件: 无（还没在面板里改过字号）")

if not rtts and not send_bytes:
    print("\n提示: 日志里还没有 ASR 记录 —— 请完全退出 YouTube 后重开并播放一个有声音的视频。")
