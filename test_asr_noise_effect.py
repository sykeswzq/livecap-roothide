#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""决定性实验：为什么设备 RTT 4-7s，本地只有 0.4s？

假设：设备送的是【YouTube 视频音轨】= 人声 + 背景音乐 + AAC 有损失真，
      而本地测试是【干净朗读】→ 16k_multi_lang 大模型引擎处理难度不同。

验证：把真实语音 + 背景音乐混合 + 最近邻重采样失真，模拟设备音频，
      测 RTT；同时测干净版对照。

结论用途：为 v1.0.84 决定「分片长度」参数。
"""
import base64
import io
import json
import math
import os
import random
import struct
import sys
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_asr_rtt import request_asr  # noqa: E402

random.seed(42)


def load_wav_8k_to_16k_mono(path):
    with wave.open(path, "rb") as w:
        nch, sw, sr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        frames = w.readframes(w.getnframes())
    src = struct.unpack("<%dh" % (len(frames) // 2), frames)
    mono = [sum(src[i * nch:(i + 1) * nch]) / nch for i in range(len(src) // nch)]
    out = []
    for i in range(len(mono) * 2):
        pos = i / 2.0
        i0 = int(pos)
        i1 = min(i0 + 1, len(mono) - 1)
        f = pos - i0
        out.append(mono[i0] * (1 - f) + mono[i1] * f)
    return out


def wrap_wav(samples, sr=16000):
    pcm = b"".join(struct.pack("<h", max(-32767, min(32767, int(v)))) for v in samples)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
    hdr += struct.pack("<IHHIIHH", 16, 1, 1, sr, 32000, 2, 16)
    hdr += b"data" + struct.pack("<I", len(pcm))
    return bytes(hdr) + pcm


def add_music(speech, level=0.45):
    """叠加背景音乐（和弦 + 鼓点 + 白噪），模拟 YouTube 视频音轨"""
    n = len(speech)
    out = list(speech)
    for i in range(n):
        t = i / 16000.0
        # 简单和弦：C-G-Am-F 循环，200BPM 八分音符
        chord = [261.6, 392.0, 440.0, 349.2][int(t / 2.0) % 4]
        music = (math.sin(math.pi * 2 * chord * t) * 0.5
                 + math.sin(math.pi * 2 * chord * 1.5 * t) * 0.25
                 + math.sin(math.pi * 2 * chord * 2.0 * t) * 0.15)
        # 鼓点
        beat = (t * 3.333) % 1.0
        if beat < 0.06:
            music += random.uniform(-0.6, 0.6) * (1 - beat / 0.06)
        out[i] = out[i] + music * level * 22000
    return out


def apply_lossy(samples, sr_in=44100):
    """模拟设备侧的失真：44.1k→16k 最近邻降采样（无抗混叠滤波）→ 再补回 16k"""
    ratio = sr_in / 16000.0
    n = len(samples)
    out = []
    for i in range(int(n / ratio)):
        idx = int(i * ratio)
        if idx >= n:
            break
        out.append(samples[idx])
    return out


def measure(name, wav, runs=2):
    rtts = []
    txt = None
    status = ""
    for _ in range(runs):
        rtt, status, t = request_asr(wav)
        rtts.append(rtt)
        if t:
            txt = t
    rtt = sorted(rtts)[len(rtts) // 2]
    show = (txt[:38] + "...") if txt else ""
    print("%-34s %-8.2f %-6.2f %-10s %s" %
          (name, rtt, rtt / (len(wav) / 32000.0), status, show))
    return rtt, txt


def main():
    real_path = "audio_test/OSR_us_000_0010_8k.wav"
    if not os.path.exists(real_path):
        print("缺少样本")
        return 1
    speech = load_wav_8k_to_16k_mono(real_path)
    noisy = add_music(speech)

    print("=" * 78)
    print("决定性实验：干净朗读 vs 视频音轨（人声+音乐+降采样失真）")
    print("=" * 78)
    print("%-34s %-8s %-6s %-10s %s" % ("音频类型", "RTT(s)", "倍率", "状态", "识别结果"))
    print("-" * 78)

    for secs in [2.5, 5.0]:
        # 干净
        clean = speech[:int(secs * 16000)]
        measure("干净朗读 %.1fs" % secs, wrap_wav(clean))
        # 加音乐
        measure("人声+背景音乐 %.1fs" % secs, wrap_wav(noisy[:int(secs * 16000)]))
        # 加音乐 + 44.1k 降采样失真（模拟设备）
        lossy = apply_lossy(noisy[:int(secs * 16000)])
        measure("视频音轨(加音乐+失真) %.1fs" % secs, wrap_wav(lossy))

    print()
    print("=" * 78)
    print("附加：16k_multi_lang vs 16k_en vs 16k_zh 对比（视频音轨 5s）")
    print("=" * 78)
    lossy = apply_lossy(noisy[:int(5.0 * 16000)])
    wav5 = wrap_wav(lossy)
    for eng in ["16k_multi_lang", "16k_en", "16k_zh"]:
        rtt, status, txt = request_asr(wav5, engine=eng)
        show = (txt[:40] + "...") if txt else ""
        print("  %-18s RTT=%-7.2f %-8s %s" % (eng, rtt, status, show))
    return 0


if __name__ == "__main__":
    sys.exit(main())
