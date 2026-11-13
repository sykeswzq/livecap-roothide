#!/usr/bin/env python3
"""本地离线对比：用用户反馈视频的音轨，逐个试腾讯云 ASR 引擎，看谁把日语听对了。

不依赖设备 SSH：密钥读本地 dev_cfg.xml（此前从设备 plist 拉回的副本）。
用法: py -3.11 probe_asr_local_v2215.py [pcm_path]
"""
import json
import os
import plistlib
import sys
import threading
import time

import websocket

import verify_ws_asr as v

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.path.join(HERE, 'dev_cfg.xml')
PCM = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(HERE), '_v2215_audio.pcm')

ENGINES = ['16k_multi_lang', '16k_ja', '16k_zh', '16k_en', '16k_ko', '16k_zh_en']
FRAME_BYTES = v.FRAME_BYTES
FRAME_SEC = v.FRAME_SEC


def load_cfg():
    with open(CFG, 'rb') as f:
        d = plistlib.load(f)
    appid = str(d.get('asrAppId') or d.get('appId') or '1312073434')
    return appid, d.get('tencentSecretId', ''), d.get('tencentSecretKey', '')


def handshake(engine, appid, sid, skey):
    url, _, _ = v.build_ws_url(appid, sid, skey, engine=engine)
    try:
        ws = websocket.create_connection(url, timeout=10)
        d = json.loads(ws.recv())
        ws.close()
        return d.get('code'), str(d.get('message', ''))[:60]
    except Exception as e:
        return 'EXC', '%s %s' % (type(e).__name__, str(e)[:50])


def recognize(engine, appid, sid, skey, pcm):
    url, _, _ = v.build_ws_url(appid, sid, skey, engine=engine)
    events = []
    stop = threading.Event()
    ws = websocket.create_connection(url, timeout=15, enable_multithread=True)
    t_connect = time.time()

    def receiver():
        while not stop.is_set():
            try:
                msg = ws.recv()
            except Exception:
                break
            if not msg:
                continue
            try:
                d = json.loads(msg)
            except Exception:
                continue
            code = d.get('code')
            if code is not None and code != 0:
                events.append(('ERROR', str(d.get('message'))[:80]))
                stop.set()
                return
            if d.get('final') == 1:
                stop.set()
                return
            r = d.get('result') or {}
            st = r.get('slice_type')
            if st is not None:
                events.append((st, r.get('voice_text_str', '')))

    th = threading.Thread(target=receiver, daemon=True)
    th.start()
    for off in range(0, len(pcm), FRAME_BYTES):
        if stop.is_set():
            break
        ws.send_binary(pcm[off:off + FRAME_BYTES])
        if off + FRAME_BYTES < len(pcm):
            time.sleep(FRAME_SEC)
    if not stop.is_set():
        ws.send(json.dumps({'type': 'end'}))
    deadline = time.time() + 8
    while not stop.is_set() and time.time() < deadline:
        time.sleep(0.05)
    try:
        ws.close()
    except Exception:
        pass
    finals = [t for st, t in events if st == 2 and t.strip()]
    partials = [t for st, t in events if st in (0, 1) and t.strip()]
    errs = [t for st, t in events if st == 'ERROR']
    return finals, partials, errs, time.time() - t_connect


def main():
    appid, sid, skey = load_cfg()
    pcm = open(PCM, 'rb').read()
    print('音频: %s (%.2fs)  APPID=%s  密钥len=%d/%d'
          % (PCM, len(pcm) / 32000.0, appid, len(sid), len(skey)), flush=True)
    print('=' * 78, flush=True)
    ok = []
    for eng in ENGINES:
        code, msg = handshake(eng, appid, sid, skey)
        print('握手 %-18s code=%-5s %s' % (eng, code, msg), flush=True)
        if code == 0:
            ok.append(eng)
        time.sleep(0.2)
    print('可用引擎: %s' % (', '.join(ok) or '无'), flush=True)
    print('=' * 78, flush=True)
    for eng in ok:
        print('\n>>> 识别 %s ...' % eng, flush=True)
        finals, partials, errs, cost = recognize(eng, appid, sid, skey, pcm)
        if errs:
            print('  错误: %s' % errs[0], flush=True)
        print('  稳态句(%d):' % len(finals), flush=True)
        for t in finals:
            print('    [%s]' % t, flush=True)
        if partials:
            print('  中间结果末尾: [%s]' % partials[-1], flush=True)
        print('  耗时 %.1fs' % cost, flush=True)
    print('\n完成', flush=True)


if __name__ == '__main__':
    main()
