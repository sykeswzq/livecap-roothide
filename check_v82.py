#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LiveCap v1.0.82 实机日志分析 —— 验证「只显示中文一行 + 字幕轮动」

v1.0.82 的验证要点：
  1. 英文行必须【完全不画】→ 日志里 originLabel 的 hidden=1 / frame 高度=0
  2. 中文行必须有内容 → tLbl text=[中文...]
  3. 字幕仍要轮动 → pending seq 严格递增
  4. 翻译链路仍要通 → WON / showPair 出现
  5. 只中文模式下 showPending 不应清空译文 → 不该出现反复的「翻译中…」
"""
import subprocess
import sys
import time
import re

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
        out = ssh(r'''
LOG=""
for f in /var/mobile/Containers/Data/Application/*/Documents/livecap.log; do
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


def has_cjk(s):
    for ch in s:
        if '\u4e00' <= ch <= '\u9fff':
            return True
    return False


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
        '只中文模式标记':      'zh-only',
        '竞速获胜':            "WON len=",
        '竞速全失败':          'race all failed',
        '厂商不可用':          'unusable',
        '队列溢出丢弃':        'queue overflow',
        'mymemory 响应':       'mymemory response status',
        '音频 buffer(节流后)': 'asbr: got buffer',
    }
    for name, pat in keys.items():
        n = sum(1 for l in lines if pat in l)
        flag = '  <<<' if n else ''
        print("  %-22s %4d%s" % (name, n, flag))

    # ===== v1.0.82 专项：英文行是否真的没画 =====
    print("\n" + "=" * 70)
    print("v1.0.82 专项验证：只显示中文一行")
    print("=" * 70)

    layout = [l for l in lines if 'overlay: layout' in l]
    if layout:
        # oLbl=(x,y,h=...) 里的 h 就是英文行高度
        ohs = []
        for l in layout:
            m = re.search(r'oLbl=\([^)]*h=([\d.]+)\)', l)
            if m:
                try:
                    ohs.append(float(m.group(1)))
                except ValueError:
                    pass
        if ohs:
            nonzero = [h for h in ohs if h > 0.5]
            print("\n[1] 英文行高度（oLbl h=）:")
            print("    采样 %d 次, 非零 %d 次" % (len(ohs), len(nonzero)))
            if nonzero:
                print("    ✗ 英文行仍在显示（高度非零，最大 %.1f）" % max(nonzero))
                print("      => showEnglish 可能被设成了 YES，或配置未生效")
            else:
                print("    ✓ 英文行高度全为 0 —— 英文原文已彻底不显示")
    else:
        print("\n[1] 英文行高度: 无 layout 日志（可能还没出字幕）")

    # tLbl 文本必须是中文
    tlbl = [l for l in lines if 'overlay: tLbl text=' in l]
    if tlbl:
        print("\n[2] 中文字幕内容（最后 6 条）:")
        cjk_ok = 0
        for l in tlbl[-6:]:
            m = re.search(r'overlay: tLbl text=\[(.*?)\] hidden=(\d)', l)
            txt = m.group(1) if m else ''
            hid = m.group(2) if m else '?'
            ok = has_cjk(txt)
            if ok and hid == '0':
                cjk_ok += 1
            print("    %s hidden=%s  %s" % ("✓" if (ok and hid == '0') else "✗", hid, txt[:70]))
        print("    含中文且可见: %d/%d" % (cjk_ok, min(6, len(tlbl))))

    # 只中文模式下不该反复出现「翻译中…」
    ph = sum(1 for l in tlbl if '翻译中' in l)
    pf = sum(1 for l in tlbl if '翻译失败' in l)
    print("\n[3] 占位文字出现次数:")
    print("    「翻译中…」: %d 次" % ph)
    print("    「翻译失败」: %d 次" % pf)
    if ph > len(tlbl) * 0.5 and len(tlbl) > 3:
        print("    ✗ 占位文字占比过高 —— 译文可能没回来，或被反复清空")
    elif ph == 0:
        print("    ✓ 没有出现「翻译中…」（说明保留了上一句中文，行为符合预期）")

    # 轮动验证
    seqs = []
    for l in lines:
        if 'overlay: pending seq=' in l:
            m = re.search(r'overlay: pending seq=(\d+)', l)
            if m:
                seqs.append(int(m.group(1)))
    if seqs:
        print("\n[4] 轮动验证:")
        print("    pending 次数: %d, seq: %s" % (len(seqs), seqs[:20]))
        if len(seqs) > 1:
            mono = all(seqs[i] < seqs[i + 1] for i in range(len(seqs) - 1))
            print("    seq 严格递增（字幕在轮动）: %s" % ("是 ✓" if mono else "否 ✗"))

    # showPair 的译文必须是中文
    pairs = [l for l in lines if 'overlay: showPair seq=' in l]
    if pairs:
        print("\n[5] 翻译成功样本（最后 5 条）:")
        for l in pairs[-5:]:
            m = re.search(r'trans=\[(.*?)\] transLen=(\d+)', l)
            if m:
                txt = m.group(1)
                print("    %s %s" % ("✓" if has_cjk(txt) else "✗ 非中文", txt[:80]))

    # 竞速胜出厂商
    print("\n[6] 竞速胜出厂商:")
    wins = {}
    for l in lines:
        if "WON len=" in l:
            p = l.split("provider '")
            if len(p) > 1:
                w = p[1].split("'")[0]
                wins[w] = wins.get(w, 0) + 1
    for k, v in wins.items():
        print("    %-12s 胜出 %d 次" % (k, v))
    if not wins:
        print("    (无) —— 翻译一次都没成功")

    # 失败原因
    fails = [l for l in lines if 'failed' in l.lower() and ('translate:' in l or 'overlay:' in l)]
    if fails:
        print("\n[7] 失败原因（最后 6 条）:")
        for l in fails[-6:]:
            print("    " + l[:180])


if __name__ == '__main__':
    main()
