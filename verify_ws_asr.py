#!/usr/bin/env python3
"""verify_ws_asr.py - 腾讯云「实时语音识别 WebSocket」本地可行性验证

目的：动 CI 之前，先在 Windows 上把下面 6 件事一次测完：
  ① 现有 TC3 的 SecretId/SecretKey 能否直接用于实时 ASR（同属 CAM 密钥）
  ② APPID 是否正确
  ③ 实时语音识别服务是否已开通（错误码 4003）
  ④ 16k_multi_lang 大模型引擎在实时接口是否可用 / 是否需单独计费（4004）
  ⑤ 16k/16bit/mono PCM 能否直接被接受（voice_format=1）
  ⑥ 真实首字延迟、slice_type 序列、稳态文本

不落任何密钥到磁盘。密钥来源优先级：
  1) 环境变量 TC3_SECRET_ID / TC3_SECRET_KEY
  2) 设备 /var/mobile/Library/Preferences/com.sykes.livecap.plist（SSH 读回内存，仅打印长度）

用法:
  py -3.11 verify_ws_asr.py <APPID> [16k_mono_s16.wav]
  py -3.11 verify_ws_asr.py 1258344699 test_ws_asr.wav

参考: https://cloud.tencent.com/document/product/1093/35799
签名: Base64( HMAC-SHA1( "asr.cloud.tencent.com/asr/v2/<appid>?<字典序query>", SecretKey ) )
"""
import base64
import hashlib
import hmac
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import wave

import websocket

HOST = 'asr.cloud.tencent.com'
SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
SSH_HOST = 'root@10.10.201.107'
PLIST = '/var/mobile/Library/Preferences/com.sykes.livecap.plist'
FRAME_BYTES = 6400          # 16kHz * 2 bytes * 200ms
FRAME_SEC = 0.2

ERR = {
    4000: '音频发送过快（超过 1:1 实时率）',
    4001: '参数不合法',
    4002: '鉴权失败 —— APPID / SecretId / SecretKey 或签名不对',
    4003: 'AppID 服务未开通 —— 需在控制台开通实时语音识别',
    4004: '资源包耗尽 / 未开通后付费（大模型引擎分级计费）',
    4005: '账户欠费',
    4006: '并发超限',
    4007: '音频解码失败 —— 检查 voice_format 与 PCM 规格',
    4008: '超过 15 秒未发音频',
    4010: '上传了未知文本消息',
    6001: '境外调用，国内站用户请关闭代理',
}


def load_credentials():
    sid = os.environ.get('TC3_SECRET_ID', '')
    skey = os.environ.get('TC3_SECRET_KEY', '')
    if sid and skey:
        print('密钥来源: 环境变量')
        return sid, skey
    cmd = ['ssh', '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
           '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=20',
           SSH_HOST, 'base64 -i ' + PLIST]
    p = subprocess.run(cmd, capture_output=True, timeout=60)
    if p.returncode != 0:
        raise RuntimeError('读取设备 plist 失败: ' + p.stderr.decode('utf-8', 'replace')[:200])
    d = plistlib.loads(base64.b64decode(re.sub(rb'\s+', b'', p.stdout)))
    sid, skey = d.get('tencentSecretId', ''), d.get('tencentSecretKey', '')
    if not sid or not skey:
        raise RuntimeError('设备 plist 里没有腾讯云密钥')
    print('密钥来源: 设备 plist (SecretId len=%d, SecretKey len=%d)' % (len(sid), len(skey)))
    return sid, skey


def build_ws_url(appid, sid, skey, engine='16k_multi_lang'):
    """按官方规范生成签名 URL（签名用原始值拼串，最终 URL 对值做 urlencode）"""
    ts = int(time.time())
    params = {
        'secretid': sid,
        'timestamp': str(ts),
        'expired': str(ts + 3600),
        'nonce': str(ts % 10000000000),
        'engine_model_type': engine,
        'voice_format': '1',          # pcm
        'needvad': '1',               # 开启 VAD，服务端按语义断句
        'vad_silence_time': '800',
        'max_speak_time': '15000',    # 长句强制断句，避免一直不稳态
        'filter_empty_result': '1',
        'word_info': '0',
        'voice_id': str(uuid.uuid4()),
    }
    # 1) 字典序拼签名原文（不含协议头，不含 signature）
    query_plain = '&'.join('%s=%s' % (k, params[k]) for k in sorted(params))
    sign_src = '%s/asr/v2/%s?%s' % (HOST, appid, query_plain)
    # 2) HMAC-SHA1 + base64
    sig = base64.b64encode(
        hmac.new(skey.encode(), sign_src.encode(), hashlib.sha1).digest()).decode()
    # 3) 最终 URL：参数值与签名都要 URL 编码（+、/、= 必须编码）
    q = '&'.join('%s=%s' % (k, urllib.parse.quote(params[k], safe=''))
                 for k in sorted(params))
    q += '&signature=' + urllib.parse.quote(sig, safe='')
    return 'wss://%s/asr/v2/%s?%s' % (HOST, appid, q), params['voice_id'], engine


def make_synth_wav(path):
    """本地无 TTS 时，生成带静音间隔的伪语音 WAV，用于验证握手 / 1:1 推流 / VAD 断句。

    用 100~300Hz 基频 + 谐波 + 缓慢包络模拟人声频谱，让 VAD 判定为有人声。
    不能用来评估识别准确率（准确率请放真实语音 wav，或直接在真机上验）。
    """
    import math
    rate = 16000
    speech_secs = [2.0, 2.5, 2.0]
    gap_sec = 0.8
    samples = []
    for si, sec in enumerate(speech_secs):
        n = int(rate * sec)
        for i in range(n):
            t = i / rate
            f0 = 130 + 40 * math.sin(2 * math.pi * 2.3 * t) + si * 15
            env = 0.55 + 0.45 * math.sin(2 * math.pi * 3.1 * t)
            v = (math.sin(2 * math.pi * f0 * t)
                 + 0.5 * math.sin(2 * math.pi * 2 * f0 * t)
                 + 0.28 * math.sin(2 * math.pi * 3 * f0 * t)
                 + 0.16 * math.sin(2 * math.pi * 5 * f0 * t))
            samples.append(int(max(-1, min(1, v * env * 0.42)) * 12000))
        samples.extend([0] * int(rate * gap_sec))
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack('<%dh' % len(samples), *samples))
    print('已生成合成测试音频 %s（%.1fs，3 段人声 + 静音间隔）'
          % (path, len(samples) / rate))
    return path


def load_wav_16k(path):
    """读取 16k/16bit/mono WAV；若规格不同则做线性重采样并转为单声道"""
    with wave.open(path, 'rb') as w:
        rate, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError('测试音频必须是 16bit，当前 sampwidth=%d' % width)
    n = len(raw) // 2
    samples = struct.unpack('<%dh' % n, raw[:n * 2])
    if ch > 1:
        samples = tuple(
            int(sum(samples[i:i + ch]) / ch) for i in range(0, len(samples), ch))
    if rate != 16000:
        step = rate / 16000.0
        out = []
        for i in range(int(len(samples) / step)):
            j = i * step
            lo = int(j)
            hi = min(lo + 1, len(samples) - 1)
            f = j - lo
            out.append(int(samples[lo] * (1 - f) + samples[hi] * f))
        samples = out
    pcm = struct.pack('<%dh' % len(samples), *samples)
    print('测试音频: %.2fs / %dHz / %dch -> 16kHz mono, %d bytes'
          % (len(samples) / 16000.0, rate, ch, len(pcm)))
    return pcm


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    appid = sys.argv[1].strip()
    if not re.fullmatch(r'\d{8,12}', appid):
        print('APPID 应为 8~12 位数字（腾讯云账号中心可见），收到: %r' % appid)
        sys.exit(2)
    wav = sys.argv[2] if len(sys.argv) > 2 else 'test_ws_asr.wav'
    engine = sys.argv[3] if len(sys.argv) > 3 else '16k_multi_lang'
    if not os.path.exists(wav):
        print('未找到测试音频，自动生成合成音频（仅验链路，不验准确率）')
        make_synth_wav(wav)

    sid, skey = load_credentials()
    pcm = load_wav_16k(wav)
    url, voice_id, engine = build_ws_url(appid, sid, skey, engine)
    print('握手: wss://%s/asr/v2/%s?... (engine=%s, voice_id=%s)'
          % (HOST, appid, engine, voice_id))
    print('-' * 62)

    t_connect = time.time()
    ws = websocket.create_connection(url, timeout=15, enable_multithread=True)
    events = []
    stop = threading.Event()

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
            now = time.time()
            code = d.get('code')
            if code is not None and code != 0:
                print('  [错误] code=%s message=%s -> %s'
                      % (code, d.get('message'), ERR.get(code, '')))
                events.append((now, 'ERROR', d.get('message')))
                stop.set()
                return
            if d.get('final') == 1:
                events.append((now, 'FINAL', ''))
                stop.set()
                return
            r = d.get('result') or {}
            st = r.get('slice_type')
            if st is not None:
                txt = r.get('voice_text_str', '')
                tag = {0: '段开始', 1: '中间结果', 2: '稳态句末'}.get(st, str(st))
                print('  [%6.0fms] slice_type=%s %-8s index=%s [%s]'
                      % ((now - t_connect) * 1000, st, tag, r.get('index'), txt))
                events.append((now, st, txt))
            elif code == 0:
                print('  [%6.0fms] 握手成功 code=0 voice_id=%s'
                      % ((now - t_connect) * 1000, d.get('voice_id')))
                events.append((now, 'HANDSHAKE', ''))

    th = threading.Thread(target=receiver, daemon=True)
    th.start()

    # 按 1:1 实时率发送 200ms 帧
    t0 = time.time()
    sent = 0
    for off in range(0, len(pcm), FRAME_BYTES):
        if stop.is_set():
            break
        frame = pcm[off:off + FRAME_BYTES]
        ws.send_binary(frame)
        sent += len(frame)
        if off + FRAME_BYTES < len(pcm):
            time.sleep(FRAME_SEC)
    t_sent = time.time()
    if not stop.is_set():
        ws.send(json.dumps({'type': 'end'}))
    # 等 final，最多 10 秒
    deadline = time.time() + 10
    while not stop.is_set() and time.time() < deadline:
        time.sleep(0.05)
    try:
        ws.close()
    except Exception:
        pass

    print('-' * 62)
    print('发送: %d bytes / %.2fs（1:1 实时率）' % (sent, t_sent - t0))
    partials = [e for e in events if e[1] == 1]
    finals = [e for e in events if e[1] == 2]
    if partials:
        print('首个中间结果延迟: %.0f ms' % ((partials[0][0] - t_connect) * 1000))
    if finals:
        print('稳态句子数: %d' % len(finals))
        for e in finals:
            print('   稳态: %s' % e[2])
    if any(e[1] == 'FINAL' for e in events):
        print('收到 final=1，连接正常收尾')
    errs = [e for e in events if e[1] == 'ERROR']
    print('结论: %s' % ('失败（见上方错误码）' if errs else '握手/推流/断句全链路可用'))
    sys.exit(1 if errs else 0)


if __name__ == '__main__':
    main()
