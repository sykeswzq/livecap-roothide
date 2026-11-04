#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""实测腾讯云 SentenceRecognition HTTP 接口：音频长度 vs RTT

目的：为 LiveCap v1.0.84 的「降低翻译延迟」提供真实数据依据。
方法：用设备上的真实凭据 + 合成语音（音调包络模拟语音能量），
     截取不同长度的 WAV，分别请求腾讯云一句话识别，测量 RTT。

注意：合成音频不是真语音，腾讯云可能返回空 Result，
      但 RTT（服务端处理耗时）依然有效 —— 这正是我们要测的量。
"""
import base64
import hashlib
import hmac
import io
import json
import math
import struct
import sys
import time
import urllib.request

# 密钥从环境变量读取，禁止硬编码进仓库
# （GitHub Push Protection 会拦截含真实 SecretID 的提交）
import os
SECRET_ID = os.environ.get("TC3_SECRET_ID", "")
SECRET_KEY = os.environ.get("TC3_SECRET_KEY", "")
if not SECRET_ID or not SECRET_KEY:
    raise SystemExit("请先设置环境变量 TC3_SECRET_ID / TC3_SECRET_KEY")
HOST = "asr.tencentcloudapi.com"
SERVICE = "asr"
ACTION = "SentenceRecognition"
REGION = "ap-guangzhou"
ENGINE = "16k_multi_lang"


def sha256_hex(b):
    return hashlib.sha256(b).hexdigest()


def hmac_sha256(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def tc3_auth(payload, timestamp, date):
    canonical_headers = "content-type:application/json\nhost:%s\n" % HOST
    signed_headers = "content-type;host"
    canonical_request = "POST\n/\n\n%s\n%s\n%s" % (
        canonical_headers, signed_headers, sha256_hex(payload))
    credential_scope = "%s/%s/tc3_request" % (date, SERVICE)
    string_to_sign = "TC3-HMAC-SHA256\n%s\n%s\n%s" % (
        timestamp, credential_scope, sha256_hex(canonical_request.encode()))
    k_date = hmac_sha256(("TC3" + SECRET_KEY).encode(), date)
    k_service = hmac_sha256(k_date, SERVICE)
    k_signing = hmac_sha256(k_service, "tc3_request")
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()
    return ("TC3-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
            % (SECRET_ID, credential_scope, signed_headers, signature))


def make_wav(seconds, sr=16000):
    """生成带语音能量包络的单声道 16bit PCM WAV（模拟有声语音的 RMS 分布）"""
    n = int(sr * seconds)
    pcm = bytearray()
    for i in range(n):
        t = i / sr
        # 音节包络：4.5 Hz 的强弱起伏 + 停顿
        env = 0.35 + 0.65 * abs(math.sin(math.pi * 2 * 4.5 * t))
        # 每 1.8 秒插入 0.25 秒静音（模拟句间停顿）
        phase = t % 1.8
        if phase > 1.55:
            env = 0.02
        # 基频 + 共振峰近似
        f0 = 120 + 30 * math.sin(math.pi * 2 * 1.2 * t)
        s = math.sin(math.pi * 2 * f0 * t) * 0.6
        s += math.sin(math.pi * 2 * f0 * 2 * t) * 0.25
        s += math.sin(math.pi * 2 * f0 * 3 * t) * 0.15
        v = int(max(-1.0, min(1.0, s * env * 0.7)) * 32767)
        pcm += struct.pack("<h", v)

    hdr = b"RIFF"
    data_size = len(pcm)
    hdr += struct.pack("<I", 36 + data_size) + b"WAVEfmt "
    hdr += struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16)
    hdr += b"data" + struct.pack("<I", data_size)
    return bytes(hdr) + bytes(pcm)


def request_asr(wav, engine=ENGINE):
    ts = str(int(time.time()))
    date = time.strftime("%Y-%m-%d", time.gmtime())
    body = {
        "ProjectId": 0,
        "SubServiceType": 2,
        "EngSerViceType": engine,
        "SourceType": 1,
        "VoiceFormat": "wav",
        "UsrAudioKey": "livecap-test-%d" % int(time.time() * 1000),
        "Data": base64.b64encode(wav).decode(),
        "DataLen": len(wav),
        "FilterDirty": 0,
        "FilterModal": 0,
        "FilterPunc": 1,
    }
    payload = json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request("https://%s" % HOST, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Host", HOST)
    req.add_header("X-TC-Action", ACTION)
    req.add_header("X-TC-Version", "2019-06-14")
    req.add_header("X-TC-Timestamp", ts)
    req.add_header("X-TC-Region", REGION)
    req.add_header("Authorization", tc3_auth(payload, ts, date))

    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
        rtt = time.time() - t0
        j = json.loads(raw)
        err = j.get("Response", {}).get("Error")
        if err:
            return rtt, "ERR: %s" % err.get("Code"), None
        txt = j.get("Response", {}).get("Result", "")
        return rtt, "OK", txt
    except Exception as e:
        return time.time() - t0, "EXC: %s" % e, None


def main():
    print("=" * 74)
    print("腾讯云 SentenceRecognition 实测：音频长度 vs RTT")
    print("=" * 74)
    print("%-10s %-12s %-10s %-8s %s" %
          ("音频时长", "WAV字节", "RTT(s)", "倍率", "结果"))
    print("-" * 74)

    results = []
    for secs in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0]:
        wav = make_wav(secs)
        # 每档跑 2 次取中位数，减少偶发抖动
        rtts = []
        status = ""
        txt = None
        for _ in range(2):
            rtt, status, t = request_asr(wav)
            rtts.append(rtt)
            if t:
                txt = t
        rtt = sorted(rtts)[len(rtts) // 2]
        results.append((secs, rtt))
        ratio = rtt / secs if secs else 0
        show = (txt[:40] + "...") if txt else ""
        print("%-10.1f %-12d %-10.2f %-8.2f %s %s" %
              (secs, len(wav), rtt, ratio, status, show))

    print("-" * 74)
    print("结论（用于 v1.0.84 分片参数决策）：")
    for secs, rtt in results:
        print("  音频 %.0fs → RTT %.2fs （RTT/音频 = %.2f）" % (secs, rtt, rtt / secs))
    if len(results) >= 2:
        # 线性拟合 RTT = a * secs + b
        xs = [r[0] for r in results]
        ys = [r[1] for r in results]
        n = len(xs)
        mx = sum(xs) / n
        my = sum(ys) / n
        num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        den = sum((x - mx) ** 2 for x in xs)
        a = num / den if den else 0
        b = my - a * mx
        print()
        print("  线性拟合: RTT ≈ %.2f * 音频秒数 + %.2f" % (a, b))
        print("  → 若分片从 5s 降到 2s，RTT 约 %.2fs（省 %.2fs）" %
              (a * 2 + b, (a * 5 + b) - (a * 2 + b)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
