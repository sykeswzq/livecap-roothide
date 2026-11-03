#!/usr/bin/env python3
"""verify_asr_params.py - 校验腾讯云 ASR（一句话识别）请求参数是否正确

背景（本项目踩过的坑）：
  一句话识别（SentenceRecognition）接口用 TC3 签名，密钥走 HTTP header，
  **body 里不能带 AppId / SecretId / VoiceId / Timestamp** —— 带了会返回
    UnknownParameter: The parameter `XXX` is not recognized.

  引擎可用性（实测 2026-11-03，本账号）：
    可用:   16k_zh, 16k_en, 16k_multi_lang, 16k_ja, 16k_ko
    不可用: 16k_zh_en, 16k_zh_large, 16k_en_large, bigmodel
    （大模型引擎只在「实时语音识别 WebSocket」接口提供）

用法: python3 verify_asr_params.py [SecretId] [SecretKey]
环境变量: TC3_SECRET_ID / TC3_SECRET_KEY（推荐，不落仓库）
"""
import base64
import hashlib
import hmac
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request

DEFAULT_SID = os.environ.get('TC3_SECRET_ID', '')
DEFAULT_SK = os.environ.get('TC3_SECRET_KEY', '')

HOST = 'asr.tencentcloudapi.com'
REGION = 'ap-guangzhou'
ACTION = 'SentenceRecognition'
VERSION = '2019-06-14'

SUPPORTED_ENGINES = ['16k_zh', '16k_en', '16k_multi_lang', '16k_ja', '16k_ko']
BANNED_BODY_FIELDS = ['AppId', 'SecretId', 'VoiceId', 'Timestamp', 'Token']


def tc_auth(secret_id, secret_key, service, action, host, region, payload, version):
    """TC3-HMAC-SHA256 签名（scope 三段：Date/service/tc3_request）"""
    ts = str(int(time.time()))
    date = time.strftime('%Y-%m-%d', time.gmtime())
    body = json.dumps(payload).encode()
    canonical_headers = 'content-type:application/json\nhost:%s\n' % host
    signed_headers = 'content-type;host'
    canonical_request = 'POST\n/\n\n%s\n%s\n%s' % (
        canonical_headers, signed_headers, hashlib.sha256(body).hexdigest())
    scope = '%s/%s/tc3_request' % (date, service)
    string_to_sign = 'TC3-HMAC-SHA256\n%s\n%s\n%s' % (
        ts, scope, hashlib.sha256(canonical_request.encode()).hexdigest())

    def h(key, msg):
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    k = h(('TC3' + secret_key).encode(), date)
    k = h(k, service)
    k = h(k, 'tc3_request')
    sig = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()
    auth = ('TC3-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s'
            % (secret_id, scope, signed_headers, sig))

    req = urllib.request.Request('https://%s' % host, data=body, method='POST')
    for k, v in [
        ('Content-Type', 'application/json'),
        ('Host', host),
        ('X-TC-Action', action),
        ('X-TC-Version', version),
        ('X-TC-Timestamp', ts),
        ('X-TC-Region', region),
        ('Authorization', auth),
    ]:
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        try:
            return e.read().decode()
        except Exception:
            return 'HTTP %d' % e.code
    except Exception as e:
        return 'EXC %s: %s' % (type(e).__name__, e)


def make_silence_wav(seconds=1, rate=16000):
    n = rate * seconds
    pcm = b'\x00\x00' * n
    hdr = (b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt ' +
           struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16) +
           b'data' + struct.pack('<I', len(pcm)))
    return hdr + pcm


def build_body(engine, wav, b64):
    """完全模拟 LiveCap.m 的请求体"""
    return {
        'ProjectId': 0,
        'SubServiceType': 2,
        'EngSerViceType': engine,
        'SourceType': 1,
        'VoiceFormat': 'wav',
        'UsrAudioKey': 'livecap-verify-%d' % int(time.time()),
        'Data': b64,
        'DataLen': len(wav),
        'FilterDirty': 0,
        'FilterModal': 0,
        'FilterPunc': 1,
    }


def check(secret_id, secret_key, body, label):
    r = tc_auth(secret_id, secret_key, 'asr', ACTION, HOST, REGION, body, VERSION)
    try:
        resp = json.loads(r)['Response']
    except Exception:
        print('  [FAIL] %s: 响应无法解析 -> %s' % (label, r[:140]))
        return False
    if 'Error' in resp:
        code = resp['Error'].get('Code', '?')
        msg = resp['Error'].get('Message', '')[:70]
        print('  [FAIL] %s: %s: %s' % (label, code, msg))
        return False
    if 'Result' in resp:
        print('  [OK]   %s: 参数被接受 (AudioDuration=%s)' % (label, resp.get('AudioDuration')))
        return True
    print('  [WARN] %s: 响应无 Result 字段 -> %s' % (label, r[:120]))
    return False


def main():
    sid = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SID
    sk = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_SK

    if not sid or not sk:
        print('=== ASR 参数自检（未提供密钥，跳过线上对拍）===')
        print('  一句话识别支持的引擎: %s' % ', '.join(SUPPORTED_ENGINES))
        print('  不支持的引擎（仅 WebSocket 实时识别可用）:')
        print('    16k_zh_en, 16k_zh_large, 16k_en_large, bigmodel')
        print('  body 中禁止出现的字段: %s' % ', '.join(BANNED_BODY_FIELDS))
        print('  body 必需字段: ProjectId, SubServiceType, EngSerViceType, SourceType,')
        print('                VoiceFormat, UsrAudioKey, Data, DataLen, FilterDirty, FilterModal, FilterPunc')
        return 0

    wav = make_silence_wav(1)
    b64 = base64.b64encode(wav).decode()

    print('=== 1. 引擎可用性（一句话识别）===')
    rc = 0
    for eng in SUPPORTED_ENGINES:
        if not check(sid, sk, build_body(eng, wav, b64), eng):
            rc = 1

    print()
    print('=== 2. 被禁引擎应被明确拒绝（防止误用）===')
    for eng in ['16k_zh_en', '16k_zh_large', 'bigmodel']:
        r = tc_auth(sid, sk, 'asr', ACTION, HOST, REGION,
                    build_body(eng, wav, b64), VERSION)
        if 'Not support' in r:
            print('  [OK]   %s: 如预期被拒 (一句话识别不支持，需用 WebSocket)' % eng)
        else:
            print('  [WARN] %s: 未被拒绝 -> %s' % (eng, r[:110]))
            rc = 1

    print()
    print('=== 3. body 禁止字段（带上会被 UnknownParameter 拒绝）===')
    base = build_body('16k_zh_en', wav, b64)
    base['EngSerViceType'] = '16k_zh'
    for bad in BANNED_BODY_FIELDS:
        body = dict(base)
        body[bad] = '12345' if bad != 'Timestamp' else int(time.time())
        r = tc_auth(sid, sk, 'asr', ACTION, HOST, REGION, body, VERSION)
        if 'UnknownParameter' in r:
            print('  [OK]   %s: 如预期被拒 (body 不应带此字段)' % bad)
        else:
            print('  [WARN] %s: 未被拒绝 -> %s' % (bad, r[:100]))

    print()
    if rc == 0:
        print('ASR 参数校验通过')
    return rc


if __name__ == '__main__':
    sys.exit(main())
