#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.0.2 真机延迟复测：与 v2.0.1 基线（29 句样本）逐项对比。

用法:
  py -3.11 verify_v202_latency.py            # 自动取日志里最后一段会话
  py -3.11 verify_v202_latency.py 600        # 只统计最近 600 秒

前提: 部署 v2.0.2 后，完全退出 YouTube 重开并播放有声音的视频 1 分钟以上。
"""
import base64
import os
import re
import statistics
import subprocess
import sys
from collections import Counter

KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST = 'root@10.10.201.107'
OPTS = ['-i', KEY, '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=20']
HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(HERE, 'device_livecap_20261110.log')

# v2.0.1 设备实测基线（29 句，2.5 秒分片）
BASE = {'audio': 2.55, 'asr': 2002, 'trans': 1159, 'e2e': 4436, 'gap': 2739}


def pct(name, vals, base=None):
    if not vals:
        print('  %-20s 无样本' % name)
        return
    v = sorted(vals)
    avg = statistics.mean(v)
    p50 = v[int(len(v) * .5)]
    p90 = v[min(len(v) - 1, int(len(v) * .9))]
    extra = ''
    if base:
        extra = ' | 基线 %-6.0f  变化 %+.0f%%' % (base, (avg / base - 1) * 100)
    print('  %-20s n=%-4d avg=%-7.0f p50=%-7.0f p90=%-7.0f max=%-7.0f%s'
          % (name, len(v), avg, p50, p90, v[-1], extra))


def main():
    window = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    p = subprocess.run(['ssh'] + OPTS + [HOST,
        "f=$(ls -1t /var/mobile/Containers/Data/Application/*/Documents/livecap.log | head -1); "
        "base64 -i \"$f\""], capture_output=True, timeout=120)
    if p.returncode != 0:
        print('取日志失败:', p.stderr.decode('utf-8', 'replace')[:300])
        return 1
    text = base64.b64decode(re.sub(rb'\s+', b'', p.stdout)).decode('utf-8', 'replace')
    open(LOCAL, 'w', encoding='utf-8', errors='replace').write(text)
    lines = text.splitlines()
    print('日志总行数: %d' % len(lines))

    ts_all = [int(m.group(1)) for ln in lines
              if (m := re.match(r'\[(\d+)\]', ln))]
    if not ts_all:
        print('日志里没有时间戳')
        return 1
    last_ts = ts_all[-1]
    if window:
        start_ts = last_ts - window
        seg = [ln for ln in lines
               if (m := re.match(r'\[(\d+)\]', ln)) and int(m.group(1)) >= start_ts]
    else:
        # 自动切最后一段会话：相邻事件间隔 > 90 秒视为新会话
        cut = 0
        for i in range(1, len(ts_all)):
            if ts_all[i] - ts_all[i - 1] > 90:
                cut = i
        start_ts = ts_all[cut]
        seg = [ln for ln in lines
               if (m := re.match(r'\[(\d+)\]', ln)) and int(m.group(1)) >= start_ts]
    print('分析区间: ts %d ~ %d, 共 %d 行' % (start_ts, last_ts, len(seg)))

    asr_rtt, audio_secs, trans_rtt, e2e, gaps = [], [], [], [], []
    events = Counter()
    last_text, last_sending = None, None
    pairs = []

    for ln in seg:
        m = re.match(r'\[(\d+)\]\s*(.*)', ln)
        if not m:
            continue
        ts, body = int(m.group(1)), m.group(2)
        m = re.search(r'asr: rtt=(\d+)ms audio=([\d.]+)s', body)
        if m:
            asr_rtt.append(int(m.group(1)))
            audio_secs.append(float(m.group(2)))
        if 'asr: sending' in body:
            last_sending = ts
        if body.startswith('asr: text ['):
            last_text = ts
        m = re.search(r'translate: inflight rtt=(\d+)ms len=(\d+)', body)
        if m:
            trans_rtt.append(int(m.group(1)))
        m = re.search(r'overlay: showPair seq=(\d+)', body)
        if m:
            pairs.append(ts)
            events['showPair'] += 1
            if last_text is not None:
                e2e.append((ts - last_text) * 1000)
        if 'skip short chunk' in body:
            events['skip_short'] += 1
        if 'race -> agnes' in body:
            events['race_agnes'] += 1
        if 'agnes rate-limited' in body or 'pause 90s' in body:
            events['agnes_paused'] += 1
        if 'queue overflow' in body:
            events['queue_drop'] += 1
        if 'showFailed' in body:
            events['showFailed'] += 1
        if 'WON' in body:
            events['race_win'] += 1

    gaps = [(pairs[i] - pairs[i - 1]) * 1000 for i in range(1, len(pairs))]

    print('\n=== v2.0.2 实测 vs v2.0.1 基线 ===')
    if audio_secs:
        pct('分片音频时长(s)', [x * 1000 for x in audio_secs], BASE['audio'] * 1000)
    pct('ASR RTT(ms)', asr_rtt, BASE['asr'])
    pct('翻译 RTT(ms)', trans_rtt, BASE['trans'])
    pct('ASR结果→上屏(ms)', e2e)
    pct('相邻上屏间隔(ms)', gaps, BASE['gap'])

    total = None
    if audio_secs and asr_rtt and trans_rtt:
        total = statistics.median(audio_secs) * 500 \
                + statistics.mean(asr_rtt) + statistics.mean(trans_rtt)
        print('\n  端到端估算 ≈ %.0f ms (%.2f 秒) | 基线 %.0f ms (%.2f 秒) | %+.0f%%'
              % (total, total / 1000, BASE['e2e'], BASE['e2e'] / 1000,
                 (total / BASE['e2e'] - 1) * 100))
    print('\n=== 新机制生效情况 ===')
    print('  分片时长分布:', Counter(round(x, 2) for x in audio_secs).most_common(5))
    print('  短片段跳过: %d 次' % events['skip_short'])
    print('  agnes 参赛 %d 次 / 限流熔断 %d 次' % (events['race_agnes'], events['agnes_paused']))
    print('  队列丢弃 %d 次 / showFailed %d 次 / 成功上屏 %d 次'
          % (events['queue_drop'], events['showFailed'], events['showPair']))
    ok = bool(audio_secs) and statistics.median(audio_secs) < 2.0
    print('\n  %s' % ('✅ 1.5 秒分片已生效' if ok else '⚠ 分片仍是旧值，检查 plist 的 asrChunkSeconds'))
    return 0 if ok else 2


if __name__ == '__main__':
    sys.exit(main())
