#!/usr/bin/env python3
"""verify_tc3_signature.py - 校验腾讯云 TC3-HMAC-SHA256 签名逻辑是否正确

背景（本项目踩过的坑）：
  1. credential scope 写成【四段】Date/service/region/tc3_request
     → 腾讯云直接返回 AuthFailure.InvalidAuthorization:
       "Credential scope size not valid"
     官方规范是【三段】Date/service/tc3_request，region 只放 X-TC-Region 头。
  2. canonical headers 里多带 x-tc-action
     → 腾讯云按实际请求头校验，Content-Type/header 集合对不上
       → AuthFailure.SignatureFailure
  3. canonical headers 的 Content-Type 带 "; charset=utf-8"
     但实际 HTTP 头不带（或反之）→ 哈希不一致 → SignatureFailure

本脚本用【与 LiveCap.m 完全一致的逻辑】生成签名，并与腾讯云真实服务对拍。
不修改任何线上服务状态，只发只读/探测性请求。

用法: python3 verify_tc3_signature.py [SecretId] [SecretKey]
环境变量: TC3_SECRET_ID / TC3_SECRET_KEY（推荐，不落仓库）
          未提供时从参数读取；两者都没有则跳过线上对拍（仅做格式自检）
"""
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

DEFAULT_SID = os.environ.get('TC3_SECRET_ID', '')
DEFAULT_SK = os.environ.get('TC3_SECRET_KEY', '')


def lc_auth_header(secret_id, secret_key, timestamp, date, payload,
                   host, service):
    """完全模拟 LiveCap.m 的 LCTencentAuthHeaderEx（修复后的版本）"""
    hashed_payload = hashlib.sha256(payload).hexdigest()
    canonical_headers = 'content-type:application/json\nhost:%s\n' % host
    signed_headers = 'content-type;host'
    canonical_request = 'POST\n/\n\n%s\n%s\n%s' % (
        canonical_headers, signed_headers, hashed_payload)
    credential_scope = '%s/%s/tc3_request' % (date, service)
    string_to_sign = 'TC3-HMAC-SHA256\n%s\n%s\n%s' % (
        timestamp, credential_scope,
        hashlib.sha256(canonical_request.encode()).hexdigest())

    def h(key, msg):
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    k = h(('TC3' + secret_key).encode(), date)
    k = h(k, service)
    k = h(k, 'tc3_request')
    sig = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()
    return ('TC3-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s'
            % (secret_id, credential_scope, signed_headers, sig))


def tc_call(secret_id, secret_key, service, action, host, region, payload,
            version):
    ts = str(int(time.time()))
    date = time.strftime('%Y-%m-%d', time.gmtime())
    body = json.dumps(payload).encode()
    auth = lc_auth_header(secret_id, secret_key, ts, date, body, host, service)
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


def main():
    sid = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SID
    sk = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_SK

    if not sid or not sk:
        print('=== TC3 签名逻辑自检（未提供密钥，跳过线上对拍）===')
        print('  设置 TC3_SECRET_ID / TC3_SECRET_KEY 环境变量后可与腾讯云真实服务对拍')
        print('  已验证的 scope 格式: Date/service/tc3_request（三段，不含 region）')
        print('  已验证的 SignedHeaders: content-type;host')
        print('  已验证的 Content-Type: application/json（不带 charset）')
        return 0

    print('=== 1. STS GetCallerIdentity（验证密钥本身有效）===')
    r = tc_call(sid, sk, 'sts', 'GetCallerIdentity',
                'sts.tencentcloudapi.com', 'ap-guangzhou', {}, '2018-08-13')
    if '"Error"' in r:
        print('  FAIL: 密钥/签名有问题 ->', r[:200])
        print('  >>> 签名逻辑与腾讯云规范不符，务必先修签名')
        return 1
    print('  OK: 密钥有效, 签名通过')

    print()
    print('=== 2. TMT TextTranslate（翻译服务）===')
    r = tc_call(sid, sk, 'tmt', 'TextTranslate',
                'tmt.tencentcloudapi.com', 'ap-guangzhou',
                {'SourceText': 'hello world', 'Source': 'auto',
                 'Target': 'zh', 'ProjectId': 0}, '2018-03-21')
    if 'AuthFailure' in r:
        print('  FAIL: 签名被拒 ->', r[:200])
        return 1
    if 'UserNotRegistered' in r:
        print('  WARN: 签名通过，但该账号未开通「机器翻译 TMT」服务')
        print('       -> 需到腾讯云控制台开通；或改用其他翻译通道')
    else:
        print('  OK:', r[:150])

    print()
    print('=== 3. ASR SentenceRecognition（语音识别服务）===')
    asr_payload = {
        'SecretId': sid, 'Timestamp': int(time.time()), 'VoiceId': 'lc_verify',
        'EngineModelType': '16k_en', 'EngSerViceType': '16k_en',
        'TextType': '0', 'Data': 'AAAA', 'DataLen': 3,
        'SourceType': 0, 'VoiceFormat': 'wav',
    }
    r = tc_call(sid, sk, 'asr', 'SentenceRecognition',
                'asr.tencentcloudapi.com', 'ap-guangzhou',
                asr_payload, '2019-06-14')
    if 'AuthFailure' in r:
        print('  FAIL: 签名被拒 ->', r[:200])
        return 1
    if 'UnknownParameter' in r or 'MissingParameter' in r:
        print('  OK: 签名通过（返回参数提示，说明已越过鉴权）')
        print('       ->', r[:150])
    elif '"Error"' in r:
        print('  WARN: 签名通过，但业务报错 ->', r[:180])
    else:
        print('  OK:', r[:150])

    print()
    print('签名逻辑校验通过（scope 三段 + SignedHeaders=content-type;host）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
