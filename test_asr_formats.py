#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 决定性实验：用真实腾讯云接口验证【哪种音频封装被接受】+【体积对 RTT 的影响】。

背景（设备日志实证 2026-11-04）：
  - 手机上 2.55s 音频（81778 B WAV）RTT 高达 2.5~10s，且大量 10003ms 硬超时；
  - 同一份 80KB WAV 在 Windows 上 RTT 仅 0.43s
    → 说明瓶颈是【上行链路】，不是服务端算力 → 减体积是唯一有效手段；
  - v1.0.85 编的裸 AAC（无 ADTS 头）被腾讯云拒收：
    ErrorInvalidVoicedata / "Audio decoding failed, please check the audio format!"
    且代码把 AAC【永久禁用】→ 全程退回 82KB WAV → 延迟反弹。

本脚本要回答（全部用真实接口，禁止猜测）：
  Q1. 裸 AAC / ADTS-AAC / WAV / Opus(ogg) 哪种被腾讯云接受？
  Q2. 同样 2.5s 音频，体积从 80KB 压到 ~6KB 后 RTT 降多少？
  Q3. 16k_multi_lang（多语言大模型）vs 16k_en：延迟与识别质量差多少？

前置：pip install imageio-ffmpeg（提供 ffmpeg 二进制）
用法：set TC3_SECRET_ID / TC3_SECRET_KEY 后运行
"""
import base64
import hashlib
import hmac
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

import imageio_ffmpeg

FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()

SECRET_ID = os.environ.get("TC3_SECRET_ID", "")
SECRET_KEY = os.environ.get("TC3_SECRET_KEY", "")
if not SECRET_ID or not SECRET_KEY:
    raise SystemExit("请先设置环境变量 TC3_SECRET_ID / TC3_SECRET_KEY")

HOST = "asr.tencentcloudapi.com"
SERVICE = "asr"
ACTION = "SentenceRecognition"
REGION = "ap-guangzhou"


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
    n = int(sr * seconds)
    pcm = bytearray()
    for i in range(n):
        t = i / sr
        env = 0.35 + 0.65 * abs(math.sin(math.pi * 2 * 4.5 * t))
        if (t % 1.8) > 1.55:
            env = 0.02
        f0 = 120 + 30 * math.sin(math.pi * 2 * 1.2 * t)
        s = math.sin(math.pi * 2 * f0 * t) * 0.6
        s += math.sin(math.pi * 2 * f0 * 2 * t) * 0.25
        s += math.sin(math.pi * 2 * f0 * 3 * t) * 0.15
        v = int(max(-1.0, min(1.0, s * env * 0.7)) * 32767)
        pcm += struct.pack("<h", v)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
    hdr += struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16)
    hdr += b"data" + struct.pack("<I", len(pcm))
    return bytes(hdr) + bytes(pcm)


def ff(args):
    """跑 ffmpeg，返回 stdout bytes"""
    p = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + args,
                       capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg failed: %s" % p.stderr.decode("utf-8", "replace")[:300])
    return p.stdout


def encode_variants(wav_bytes, seconds):
    """用 ffmpeg 编出多种封装，返回 [(名称, 数据, VoiceFormat)]"""
    out = []
    tmpdir = tempfile.mkdtemp()
    src = os.path.join(tmpdir, "in.wav")
    with open(src, "wb") as f:
        f.write(wav_bytes)

    # 1) 裸 AAC（无 ADTS）：ffmpeg -f adts 但去掉 ADTS 头很难，
    #    这里用 mp4 容器解出裸 AAC elementary stream
    mp4 = os.path.join(tmpdir, "out.m4a")
    ff(["-i", src, "-c:a", "aac", "-b:a", "16k", "-ac", "1", "-ar", "16000", mp4])
    with open(mp4, "rb") as f:
        m4a = f.read()
    out.append(("m4a容器", m4a, "m4a"))

    # 2) ADTS 封装的 AAC（裸流 + 7 字节 ADTS 头/帧）
    adts = os.path.join(tmpdir, "out.aac")
    ff(["-i", src, "-c:a", "aac", "-b:a", "16k", "-ac", "1", "-ar", "16000",
        "-f", "adts", adts])
    with open(adts, "rb") as f:
        adts_bytes = f.read()
    out.append(("ADTS-AAC", adts_bytes, "aac"))

    # 3) 从 ADTS 里剥掉 ADTS 头 → 裸 AAC elementary stream
    raw = strip_adts(adts_bytes)
    out.append(("裸AAC(无ADTS)", raw, "aac"))

    # 4) Opus（腾讯云支持 ogg_opus? 先测 opus 格式名）
    opus = os.path.join(tmpdir, "out.opus")
    try:
        ff(["-i", src, "-c:a", "libopus", "-b:a", "16k", "-ac", "1", "-ar", "16000", opus])
        with open(opus, "rb") as f:
            out.append(("OGG-OPUS", f.read(), "ogg_opus"))
    except Exception as e:
        print("[warn] opus 编码失败: %s" % e)

    # 5) 8k 采样率 WAV（体积减半）
    wav8 = os.path.join(tmpdir, "out8.wav")
    ff(["-i", src, "-ar", "8000", "-ac", "1", "-c:a", "pcm_s16le", wav8])
    with open(wav8, "rb") as f:
        out.append(("WAV-8k", f.read(), "wav"))

    # 6) ADTS-AAC 64kbps（更高音质、更大体积）
    adts64 = os.path.join(tmpdir, "out64.aac")
    ff(["-i", src, "-c:a", "aac", "-b:a", "64k", "-ac", "1", "-ar", "16000",
        "-f", "adts", adts64])
    with open(adts64, "rb") as f:
        out.append(("ADTS-AAC-64k", f.read(), "aac"))

    return out


def strip_adts(data):
    """剥离 ADTS 头，返回裸 AAC elementary stream"""
    i = 0
    out = bytearray()
    n = len(data)
    while i + 7 <= n:
        if not (data[i] == 0xFF and (data[i + 1] & 0xF0) == 0xF0):
            i += 1
            continue
        protection_absent = data[i + 1] & 0x01
        header_len = 7 if protection_absent else 9
        frame_len = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | (data[i + 5] >> 5)
        if frame_len <= header_len or i + frame_len > n:
            i += 1
            continue
        out += data[i + header_len:i + frame_len]
        i += frame_len
    return bytes(out)


def request_asr(audio_bytes, voice_format, engine="16k_multi_lang", timeout=30):
    ts = str(int(time.time()))
    date = time.strftime("%Y-%m-%d", time.gmtime())
    body = {
        "ProjectId": 0,
        "SubServiceType": 2,
        "EngSerViceType": engine,
        "SourceType": 1,
        "VoiceFormat": voice_format,
        "UsrAudioKey": "livecap-fmt-%d" % int(time.time() * 1000),
        "Data": base64.b64encode(audio_bytes).decode(),
        "DataLen": len(audio_bytes),
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
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
        rtt = time.time() - t0
        j = json.loads(raw)
        err = j.get("Response", {}).get("Error")
        if err:
            return rtt, "ERR:%s" % err.get("Code"), err.get("Message", ""), None
        txt = j.get("Response", {}).get("Result", "")
        return rtt, "OK", "", txt
    except Exception as e:
        return time.time() - t0, "EXC", str(e), None


def main():
    seconds = 2.5
    wav = make_wav(seconds)
    variants = encode_variants(wav, seconds)

    print("=" * 104)
    print("腾讯云 SentenceRecognition 实测 | 音频 %.1fs | 编码器接受度 + RTT" % seconds)
    print("=" * 104)
    print("%-18s %-12s %-12s %-9s %-7s %s" %
          ("封装", "字节", "压缩比", "RTT(s)", "结果", "备注"))
    print("-" * 104)

    base = len(wav)
    accepted = []
    for label, data, fmt in variants:
        rtt, status, msg, txt = request_asr(data, fmt, "16k_multi_lang")
        ratio = base / float(len(data)) if data else 0
        note = msg[:52] if msg else (("text=%s" % (txt[:36])) if txt else "")
        print("%-18s %-12d %-12.1fx %-9.2f %-7s %s" %
              (label, len(data), ratio, rtt, status, note))
        if status == "OK":
            accepted.append((label, data, fmt, rtt, ratio))

    print("-" * 104)
    print("被接受的封装：%s" % (", ".join(a[0] for a in accepted) or "（无）"))

    # 若 ADTS-AAC 可用 → 用它测「体积 vs RTT」与「引擎差异」
    best = None
    for a in accepted:
        if "ADTS" in a[0] and "64k" not in a[0]:
            best = a
            break
    if best:
        label, data, fmt, rtt, ratio = best
        print("\n【用 %s 测引擎差异】" % label)
        for eng in ("16k_multi_lang", "16k_en"):
            r, s, m, t = request_asr(data, fmt, eng)
            print("  引擎 %-16s RTT=%.2fs %s %s" %
                  (eng, r, s, (m[:40] if m else (t[:40] if t else ""))))

    print("\n【结论】")
    print("  · 压缩比最高的【被接受】封装 = 减延迟的关键（手机上行才是瓶颈）")
    print("  · 腾讯云拒收的封装（如裸 AAC）必须彻底放弃，不能留兜底逻辑")
    print("  · 引擎选择影响延迟与质量，可作为面板上的可选项")
    return 0


if __name__ == "__main__":
    sys.exit(main())
