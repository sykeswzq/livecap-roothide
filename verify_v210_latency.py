#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.1.0 真机复测：流式是否生效 + 译文是否真的由 agnes 出。

前置：tweak 只在进程启动时注入，必须【完全退出 YouTube 再重开】并播放
1~2 分钟有声视频，否则日志里仍是 v2.0.2 的 `asr: pcm trimmed`。

用法: py -3.11 verify_v210_latency.py
会自动 SSH 取最新 livecap.log 并缓存到 device_livecap_v210.log。
"""
import os
import re
import statistics
import subprocess
import sys

KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST = 'root@10.10.201.107'
OPTS = ['-i', KEY, '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=20']
HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(HERE, 'device_livecap_v210.log')
CMD = ('f=$(ls -1t /var/mobile/Containers/Data/Application/*/Documents/'
       'livecap.log 2>/dev/null | head -1); echo "## $f"; cat "$f"')

TS = re.compile(r'^\[(\d+)\]\s*(.*)$')


def main():
    src = LOCAL
    if len(sys.argv) < 2 or sys.argv[1] != '--local':
        p = subprocess.run(['ssh'] + OPTS + [HOST, CMD],
                           capture_output=True, timeout=120)
        if p.returncode != 0:
            print('SSH 取日志失败:', p.stderr.decode('utf-8', 'replace')[:200])
            return 1
        raw = p.stdout.decode('utf-8', 'replace')
        open(LOCAL, 'w', encoding='utf-8').write(raw)
        src = LOCAL
        print('已拉取设备日志 ->', LOCAL)
    lines = open(src, encoding='utf-8', errors='replace').read().splitlines()

    events = []
    for ln in lines:
        m = TS.match(ln)
        if m:
            events.append((int(m.group(1)), m.group(2)))

    ws_handshake = [t for t, s in events if 'asr: ws handshake ok' in s]
    ws_partial = [t for t, s in events if 'asr: ws partial' in s]
    ws_final = [t for t, s in events if 'asr: ws final sentence' in s]
    ws_err = [(t, s) for t, s in events if 'asr: ws code=' in s or 'asr: ws fatal' in s]
    ws_reconn = [t for t, s in events if 'asr: ws reconnect' in s]
    won = [(t, re.search(r"provider '([^']+)' WON", s).group(1))
           for t, s in events if "provider '" in s and ' WON' in s]
    show_pair = [t for t, s in events if 'showPair' in s or 'translation result' in s]
    old_http = [t for t, s in events if 'asr: sending' in s or 'asr: pcm trimmed' in s]

    print('\n=== v2.1.0 流式状态 ===')
    print('  握手成功次数      : %d' % len(ws_handshake))
    print('  中间结果(partial) : %d' % len(ws_partial))
    print('  稳态句末(final)   : %d' % len(ws_final))
    print('  重连次数          : %d' % len(ws_reconn))
    print('  错误码            : %s' % (ws_err[-3:] if ws_err else '无'))
    print('  旧 HTTP 分片日志  : %d' % len(old_http))

    if not ws_handshake:
        print('\n⚠️ 没有 `asr: ws handshake ok` —— tweak 仍在旧进程里。')
        print('   请【完全退出 YouTube 再重开】，播放 1~2 分钟有声视频后重跑本脚本。')
        return 1

    print('\n=== 译文来源（翻译到位的关键指标）===')
    from collections import Counter
    dist = Counter(p for _, p in won)
    total = sum(dist.values()) or 1
    for p, n in dist.most_common():
        print('  %-12s %3d 句  %5.1f%%' % (p, n, n * 100.0 / total))
    agnes_rate = dist.get('agnes', 0) * 100.0 / total
    print('  agnes 主力占比    : %.1f%%  (目标 >80%%，v2.0.2 基线接近 0%%)' % agnes_rate)

    print('\n=== 端到端（稳态句 -> 中文上屏，秒级）===')
    gaps = []
    for f in ws_final:
        nxt = [t for t in show_pair if t >= f]
        if nxt:
            gaps.append(nxt[0] - f)
    if gaps:
        print('  样本 %d 句, min=%ds p50=%ds max=%ds'
              % (len(gaps), min(gaps), statistics.median(gaps), max(gaps)))
        print('  v2.0.2 基线约 4.4s（攒音1.3 + ASR2.0 + 翻译1.2）')
    else:
        print('  暂无可配对的样本（可能还没播放有声视频）')

    ok = (len(ws_final) > 0 and agnes_rate >= 60 and not
          any('4002' in s or '4004' in s for _, s in ws_err))
    print('\n结论: %s' % ('✅ 流式生效且 agnes 为主力' if ok else
                       '⚠️ 需继续排查（见上方指标）'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
