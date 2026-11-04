#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LiveCap v1.0.81 实机日志实时抓取 —— 验证「字幕轮动 + 中文翻译」"""
import subprocess
import sys
import time
import os

SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST = '10.10.201.107'

REMOTE = r'''
LOG=""
for f in /var/mobile/Containers/Data/Application/*/Documents/livecap.log; do
  [ -f "$f" ] && LOG="$f" && break
done
if [ -z "$LOG" ]; then
  LOG=/var/mobile/Documents/livecap.log
fi
[ -f "$LOG" ] || { echo "NO_LOG_FOUND"; exit 0; }
echo "LOGFILE=$LOG"
echo "SIZE=$(wc -c < "$LOG")"
tail -f "$LOG"
'''


def run(cmd, timeout=60):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def ssh(cmd_str, timeout=60):
    cmd = ['ssh', '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
           '-o', 'UserKnownHostsFile=/dev/null', f'root@{HOST}', cmd_str]
    r = run(cmd, timeout)
    return r.stdout


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'snapshot'
    seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 90

    if mode == 'snapshot':
        # 一次性快照：拉全量日志并分析
        out = ssh(r'''
LOG=""
for f in /var/mobile/Containers/Data/Application/*/Documents/livecap.log(N); do
  [ -f "$f" ] && LOG="$f" && break
done
[ -z "$LOG" ] && LOG=/var/mobile/Documents/livecap.log
[ -f "$LOG" ] || { echo "NO_LOG"; exit 0; }
echo "LOGFILE=$LOG"
echo "SIZE=$(wc -c < "$LOG")"
echo "---BEGIN---"
cat "$LOG"
''', timeout=90)
        if 'NO_LOG' in out:
            print("!! 未找到日志文件 —— tweak 可能尚未注入")
            print("   1. 确认 YouTube 已打开并播放视频")
            print("   2. 确认 Dopamine 注入白名单勾选了 YouTube")
            print("   3. 确认 mediaserverd 已重启加载新 dylib")
            return
        idx = out.find('---BEGIN---')
        if idx < 0:
            print("!! 抓取输出异常:")
            print(out[:800])
            return
        head = out[:idx].strip()
        body = out[idx + len('---BEGIN---'):]
        print("=" * 70)
        print(head)
        print("=" * 70)
        analyze(body)
    else:
        # 实时跟随
        print("实时跟踪中，Ctrl+C 停止...")
        cmd = ['ssh', '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
               '-o', 'UserKnownHostsFile=/dev/null', f'root@{HOST}', REMOTE]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, bufsize=1)
        start = time.time()
        buf = []
        try:
            for line in p.stdout:
                line = line.rstrip('\n')
                if line.startswith('LOGFILE=') or line.startswith('SIZE='):
                    print(line)
                    continue
                if not line:
                    continue
                buf.append(line)
                print(line)
                if time.time() - start > seconds:
                    break
        except KeyboardInterrupt:
            pass
        finally:
            p.kill()
        print("\n" + "=" * 70)
        analyze('\n'.join(buf))


def analyze(log):
    if not log.strip():
        print("(日志为空)")
        return

    lines = log.split('\n')
    print("\n--- 统计 ---")
    print("总行数: %d" % len(lines))

    keys = {
        'ASR 识别到句子':      'asr: text [',
        'ASR16 识别到句子':    'asr16: text [',
        '语音识别句子':        'speech: final',
        '字幕上屏(pending)':   'overlay: pending seq=',
        '字幕配对(showPair)':  'overlay: showPair seq=',
        '翻译失败(showFailed)': 'overlay: showFailed seq=',
        '竞速获胜':            "WON len=",
        '竞速全失败':          'race all failed',
        '厂商不可用':          'unusable',
        'openai 请求':         'translate: openai request',
        'openai 报错':         'openai req err',
        'mymemory 响应':       'mymemory response status',
        '音频 buffer(节流后)': 'asbr: got buffer',
    }
    for name, pat in keys.items():
        n = sum(1 for l in lines if pat in l)
        flag = '  <<<' if n else ''
        print("  %-22s %4d%s" % (name, n, flag))

    # 轮动验证：pending seq 必须递增
    seqs = []
    for l in lines:
        if 'overlay: pending seq=' in l:
            try:
                s = int(l.split('overlay: pending seq=')[1].split()[0])
                seqs.append(s)
            except Exception:
                pass
    if seqs:
        print("\n--- 轮动验证 ---")
        print("pending 次数: %d, seq 序列: %s" % (len(seqs), seqs[:20]))
        if len(seqs) > 1:
            mono = all(seqs[i] < seqs[i + 1] for i in range(len(seqs) - 1))
            print("seq 是否严格递增(即字幕确实在轮动): %s" % ("是 ✓" if mono else "否 ✗"))

    # 翻译成功明细
    pairs = [l for l in lines if 'overlay: showPair seq=' in l]
    if pairs:
        print("\n--- 翻译成功样本 (最后 5 条) ---")
        for l in pairs[-5:]:
            print("  " + l[:190])

    # 失败原因
    fails = [l for l in lines if 'failed' in l.lower() and 'translate:' in l]
    if fails:
        print("\n--- 翻译失败原因 (最后 6 条) ---")
        for l in fails[-6:]:
            print("  " + l[:190])

    # 竞速耗时（从 openai request 到 WON）
    req_t = None
    print("\n--- 竞速获胜厂商 ---")
    wins = {}
    for l in lines:
        if "WON len=" in l:
            p = l.split("provider '")
            if len(p) > 1:
                w = p[1].split("'")[0]
                wins[w] = wins.get(w, 0) + 1
    for k, v in wins.items():
        print("  %-12s 胜出 %d 次" % (k, v))
    if not wins:
        print("  (无) —— 说明翻译一次都没成功")


if __name__ == '__main__':
    main()
