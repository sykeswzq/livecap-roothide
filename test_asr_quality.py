#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 质量验证：用【真实语音】比较 WAV vs 各码率 ADTS-AAC 的腾讯云识别质量。

背景：
  v1.0.85 把音频压成 AAC 想减延迟，但腾讯云拒收裸 AAC → 压缩白做。
  v1.0.87 改用 ADTS 封装后压缩才真正生效（14.2 倍）。
  但码率选多少？太小会伤识别准确率（字幕错字），太大又白压缩。
  本脚本用 Windows TTS 合成【真实语音】（不是正弦波），
  把同一句话分别用 WAV / AAC-8k / 16k / 24k / 32k / 48k 送腾讯云，
  用词级匹配率衡量识别质量 —— 全部用真实接口，不靠猜。

依赖：PowerShell 的 System.Speech 合成 wav（Windows 内置，无需联网）。
"""
import base64
import hashlib
import hmac
import io
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import wave

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

# 用来合成的真实句子（ASR 应该能识别出这些词）
SENTENCES = [
    "The weather is really nice today and I want to go for a walk in the park.",
    "Please make sure that the emergency exit is not blocked by any boxes.",
    "Our team finished the project two days ahead of the schedule.",
]


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


def tts_to_wav(text, path):
    """用 Windows 内置 TTS 合成真实语音 wav"""
    ps = (
        "Add-Type -AssemblyName System.Speech; "
        "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
        "$s.Rate = 0; "
        "$s.SetOutputToWaveFile('%s'); "
        "$s.Speak('%s'); "
        "$s.Dispose()" % (path, text.replace("'", "''"))
    )
    p = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                       capture_output=True)
    return p.returncode == 0 and os.path.exists(path) and os.path.getsize(path) > 1000


def run(args, stdin_bytes=None):
    p = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + args,
                       input=stdin_bytes, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", "replace")[:400])
    return p.stdout


def request_asr(audio_bytes, voice_format, engine="16k_multi_lang", timeout=30):
    ts = str(int(time.time()))
    date = time.strftime("%Y-%m-%d", time.gmtime())
    body = {
        "ProjectId": 0, "SubServiceType": 2, "EngSerViceType": engine,
        "SourceType": 1, "VoiceFormat": voice_format,
        "UsrAudioKey": "livecap-q-%d" % int(time.time() * 1000),
        "Data": base64.b64encode(audio_bytes).decode(),
        "DataLen": len(audio_bytes),
        "FilterDirty": 0, "FilterModal": 0, "FilterPunc": 1,
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
            return rtt, "ERR:%s" % err.get("Code"), ""
        return rtt, "OK", j.get("Response", {}).get("Result", "")
    except Exception as e:
        return time.time() - t0, "EXC", str(e)


def norm_words(s):
    return re.findall(r"[a-z']+", (s or "").lower())


def word_match(ref, hyp):
    """词级召回率（识别质量指标）"""
    r = norm_words(ref)
    h = set(norm_words(hyp))
    if not r:
        return 0.0
    hit = sum(1 for w in r if w in h)
    return hit / float(len(r))


def main():
    tmpdir = tempfile.mkdtemp()
    print("=" * 96)
    print("真实语音质量验证：WAV vs 各码率 ADTS-AAC（腾讯云一句话识别，引擎 16k_multi_lang）")
    print("=" * 96)

    # 1) 合成真实语音
    wavs = []
    for i, s in enumerate(SENTENCES):
        p = os.path.join(tmpdir, "s%d.wav" % i)
        if not tts_to_wav(s, p):
            print("[warn] TTS 合成失败，跳过（无 SAPI）")
            return 2
        wavs.append((s, p))
    print("已合成 %d 句真实语音" % len(wavs))

    # 2) 统一转成 16k 单声道 WAV（模拟设备抓到的音频）
    pcm16 = []
    for i, (_, p) in enumerate(wavs):
        out = os.path.join(tmpdir, "n%d.wav" % i)
        run(["-i", p, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out])
        with open(out, "rb") as f:
            pcm16.append(f.read())
        with wave.open(out, "rb") as w:
            dur = w.getnframes() / float(w.getframerate())
        print("  句 %d: %.2fs, 16k WAV = %d 字节" % (i, dur, len(pcm16[-1])))

    # 3) 各码率 ADTS-AAC
    variants = [("WAV-16k(基线)", pcm16, "wav", 0)]
    for br in (8000, 16000, 24000, 32000, 48000):
        blobs = []
        for i, data in enumerate(pcm16):
            adts = run(["-f", "wav", "-i", "pipe:0", "-c:a", "aac", "-b:a", "%dk" % (br // 1000),
                        "-ac", "1", "-ar", "16000", "-f", "adts", "pipe:1"], data)
            blobs.append(adts)
        variants.append(("AAC-%dk" % (br // 1000), blobs, "aac", 0))

    # 4) 逐变体打分
    print("-" * 96)
    print("%-16s %-10s %-9s %-9s %s" %
          ("变体", "字节/句", "RTT(s)", "词召回", "备注"))
    print("-" * 96)
    results = []
    for label, blobs, fmt, _ in variants:
        total = sum(len(b) for b in blobs)
        rtt_sum = 0
        score_sum = 0
        errs = []
        for (ref, _), blob in zip(wavs, blobs):
            rtt, status, text = request_asr(blob, fmt)
            rtt_sum += rtt
            if status != "OK":
                errs.append(status)
                continue
            score_sum += word_match(ref, text)
        n = len(blobs)
        avg_rtt = rtt_sum / n
        avg_score = score_sum / n
        note = ("错误: " + ",".join(errs)) if errs else ""
        print("%-16s %-10d %-9.2f %-9.1f%% %s" %
              (label, total // n, avg_rtt, avg_score * 100, note))
        results.append((label, total // n, avg_rtt, avg_score))

    print("-" * 96)
    print("结论（码率取舍）：")
    base = results[0]
    for label, size, rtt, score in results[1:]:
        print("  %-14s 体积 %5dB (%.1fx 压缩)  RTT %.2fs  识别质量 %s" % (
            label, size, base[1] / float(size), rtt,
            "与基线持平 ✓" if score >= base[3] * 0.95 else
            ("轻微下降 (基线 %.0f%%)" % (base[3] * 100))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
