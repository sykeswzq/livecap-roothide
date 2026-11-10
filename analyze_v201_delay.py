#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.0.1 真机延迟全量量化：把设备日志拉回本地，逐句拆出延迟链路。

链路：攒音频(分片) -> asr sending -> ASR RTT -> asr text -> 翻译竞速 -> showPair
输出：各段耗时分布、端到端延迟、失败率、seq 节奏。
"""
import base64
import os
import re
import statistics
import subprocess
import sys
from collections import Counter

SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST = 'root@10.10.201.107'
SSH_OPTS = ['-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=20']
HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL_LOG = os.path.join(HERE, 'device_livecap_20261110.log')


def ssh(cmd, timeout=90):
    p = subprocess.run(['ssh'] + SSH_OPTS + [HOST, cmd],
                       capture_output=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr.decode('utf-8', 'replace')


def fetch():
    rc, out, err = ssh(
        "f=$(ls -1t /var/mobile/Containers/Data/Application/*/Documents/livecap.log | head -1); "
        "base64 -i \"$f\"")
    if rc != 0:
        print('SSH 取日志失败:', err[:300])
        return None
    raw = re.sub(rb'\s+', b'', out)
    try:
        text = base64.b64decode(raw).decode('utf-8', 'replace')
    except Exception as e:
        print('base64 解码失败:', e)
        return None
    with open(LOCAL_LOG, 'w', encoding='utf-8', errors='replace') as f:
        f.write(text)
    return text


def pct(name, vals):
    if not vals:
        print('  %-22s 无样本' % name)
        return
    v = sorted(vals)
    def q(p):
        return v[min(len(v) - 1, int(len(v) * p))]
    print('  %-22s n=%-4d avg=%-7.0f p50=%-7.0f p90=%-7.0f min=%-7.0f max=%-7.0f'
          % (name, len(v), statistics.mean(v), q(.5), q(.9), v[0], v[-1]))


def main():
    text = fetch()
    if not text:
        return 1
    lines = text.splitlines()
    print('日志总行数:', len(lines), '-> 本地存档:', LOCAL_LOG)

    # 只取 v2.0.1 会话（含 inflight rtt 的那一段之后）
    start = 0
    for i, ln in enumerate(lines):
        if 'inflight rtt=' in ln:
            start = i
            break
    seg = lines[max(0, start - 200):]
    print('分析区间: 第 %d 行起，共 %d 行' % (max(0, start - 200), len(seg)))

    asr_rtt, asr_audio, trans_rtt = [], [], []
    sending_ts, text_ts, pair_ts = {}, {}, {}
    last_sending, last_text = None, None
    seq_order = []
    events = Counter()
    e2e = []          # showPair.ts - 对应 asr text.ts（秒精度）
    send2pair = []    # showPair.ts - sending.ts

    for ln in seg:
        m = re.match(r'\[(\d+)\]\s*(.*)', ln)
        if not m:
            continue
        ts, body = int(m.group(1)), m.group(2)

        m = re.search(r'asr: rtt=(\d+)ms audio=([\d.]+)s', body)
        if m:
            asr_rtt.append(int(m.group(1)))
            asr_audio.append(float(m.group(2)))
            events['asr_result'] += 1
        if 'asr: sending' in body:
            last_sending = ts
            events['asr_send'] += 1
        if body.startswith('asr: text ['):
            last_text = ts
            events['asr_text'] += 1
        m = re.search(r'translate: inflight rtt=(\d+)ms len=(\d+)', body)
        if m:
            trans_rtt.append(int(m.group(1)))
            events['trans_done'] += 1
        m = re.search(r'overlay: showPair seq=(\d+)', body)
        if m:
            seq = int(m.group(1))
            seq_order.append((ts, seq))
            events['showPair'] += 1
            if last_text is not None:
                e2e.append((ts - last_text) * 1000)
            if last_sending is not None:
                send2pair.append((ts - last_sending) * 1000)
        if 'queue overflow' in body:
            events['queue_drop'] += 1
        if 'showFailed' in body:
            events['showFailed'] += 1
        if 'provider' in body and 'WON' in body:
            events['race_win'] += 1
        if 'provider' in body and 'failed' in body:
            events['provider_fail'] += 1
        if '速率限制' in body or 'rate' in body.lower() and 'limit' in body.lower():
            events['rate_limit'] += 1

    print('\n=== 事件计数 ===')
    for k, v in sorted(events.items()):
        print('  %-16s %d' % (k, v))

    print('\n=== 各段耗时 (ms) ===')
    pct('ASR RTT', asr_rtt)
    pct('翻译 inflight RTT', trans_rtt)
    pct('ASR结果→中文上屏', e2e)
    pct('发ASR→中文上屏', send2pair)
    print('  分片音频时长(s): %s' % (Counter(round(x, 2) for x in asr_audio).most_common(5)))

    # 逐句节奏：showPair 之间的间隔
    gaps = [(seq_order[i][0] - seq_order[i-1][0]) * 1000
            for i in range(1, len(seq_order))]
    print('\n=== 上屏节奏 ===')
    pct('相邻中文字幕间隔', gaps)

    # 理论端到端：平均攒音 = 分片时长/2
    if asr_audio:
        chunk = statistics.median(asr_audio)
        print('\n=== 从「说话」到「看见中文」的理论总延迟 ===')
        print('  分片常数 %.2fs → 平均攒音等待 ≈ %.0f ms' % (chunk, chunk * 500))
        if asr_rtt:
            print('  + ASR RTT 均值            ≈ %.0f ms' % statistics.mean(asr_rtt))
        if trans_rtt:
            print('  + 翻译竞速 均值           ≈ %.0f ms' % statistics.mean(trans_rtt))
        total = chunk * 500 + (statistics.mean(asr_rtt) if asr_rtt else 0) \
                + (statistics.mean(trans_rtt) if trans_rtt else 0)
        print('  = 平均端到端               ≈ %.0f ms (%.1f 秒)' % (total, total / 1000.0))

    return 0


if __name__ == '__main__':
    sys.exit(main())
