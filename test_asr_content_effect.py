#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真实语音 vs 合成音：腾讯云 ASR RTT 对照实验

目的：解释「本地 RTT 0.4s vs 设备 4-7s」的 10 倍差异。
可能原因：
  A) 引擎/内容差异（合成音 vs 真语音，大模型引擎处理真语音更慢）
  B) 网络/设备差异（设备走移动网络或 DNS 慢）
用同一台机器、同一凭据、同一引擎，只变音频内容 → 隔离出 A。
"""
import base64
import io
import json
import os
import struct
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_asr_rtt import request_asr, make_wav, ENGINE  # noqa: E402


def load_wav_8k_to_16k_mono(path):
    """读 8kHz PCM WAV → 重采样到 16kHz 单声道 16bit"""
    with wave.open(path, "rb") as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        sr = w.getframerate()
        frames = w.readframes(w.getnframes())
    if sw != 2:
        raise SystemExit("expect 16bit, got %d" % sw)
    # 解交织为单声道
    src = struct.unpack("<%dh" % (len(frames) // 2), frames)
    mono = [sum(src[i * nch:(i + 1) * nch]) / nch for i in range(len(src) // nch)]
    # 线性重采样 8k -> 16k
    out = []
    for i in range(len(mono) * 2):
        pos = i / 2.0
        i0 = int(pos)
        i1 = min(i0 + 1, len(mono) - 1)
        f = pos - i0
        out.append(mono[i0] * (1 - f) + mono[i1] * f)
    pcm = b"".join(struct.pack("<h", max(-32767, min(32767, int(v)))) for v in out)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
    hdr += struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
    hdr += b"data" + struct.pack("<I", len(pcm))
    return bytes(hdr) + pcm


def slice_wav(wav, seconds, offset=0.0):
    """从 wav 中截取指定秒数（wav 为 16kHz 单声道 16bit）"""
    data = wav[44:]
    start = int(offset * 16000) * 2
    end = start + int(seconds * 16000) * 2
    end = min(end, len(data))
    seg = data[start:end]
    hdr = b"RIFF" + struct.pack("<I", 36 + len(seg)) + b"WAVEfmt "
    hdr += struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
    hdr += b"data" + struct.pack("<I", len(seg))
    return bytes(hdr) + seg


def main():
    real_path = "audio_test/OSR_us_000_0010_8k.wav"
    print("=" * 76)
    print("对照实验：真实语音 vs 合成音，同机器同凭据同引擎")
    print("=" * 76)

    if not os.path.exists(real_path):
        print("缺少真实语音样本:", real_path)
        return 1

    real = load_wav_8k_to_16k_mono(real_path)
    print("真实语音 WAV: %d bytes (%.2f 秒)" % (len(real), (len(real) - 44) / 32000.0))

    print()
    print("--- 真实语音切片（不同长度）---")
    print("%-10s %-10s %-8s %s" % ("音频时长", "RTT(s)", "倍率", "识别结果"))
    real_rtt = {}
    for secs in [1.0, 2.0, 3.0, 5.0]:
        wav = slice_wav(real, secs)
        rtt, status, txt = request_asr(wav)
        real_rtt[secs] = rtt
        show = (txt[:45] + "...") if txt else ""
        print("%-10.1f %-10.2f %-8.2f %s %s" % (secs, rtt, rtt / secs, status, show))

    print()
    print("--- 合成音（同一长度对照）---")
    print("%-10s %-10s %-8s" % ("音频时长", "RTT(s)", "倍率"))
    syn_rtt = {}
    for secs in [1.0, 2.0, 3.0, 5.0]:
        wav = make_wav(secs)
        rtt, status, txt = request_asr(wav)
        syn_rtt[secs] = rtt
        print("%-10.1f %-10.2f %-8.2f %s" % (secs, rtt, rtt / secs, status))

    print()
    print("=" * 76)
    print("结论")
    print("=" * 76)
    print("音频时长   真实语音RTT   合成音RTT   差异")
    for secs in sorted(real_rtt):
        d = real_rtt[secs] - syn_rtt[secs]
        print("  %-8.1f %-12.2f %-11.2f %+.2f" % (secs, real_rtt[secs], syn_rtt[secs], d))

    print()
    if all(real_rtt[s] > syn_rtt[s] * 1.5 for s in real_rtt):
        print("→ 真实语音明显更慢：说明 16k_multi_lang 大模型引擎的处理时间与")
        print("  【内容复杂度】强相关（合成音它只需解码能量包络，真语音要做完整声学建模）")
        print("→ 设备上的 4-7s RTT 主要是【引擎处理真语音】耗时，不是网络问题")
        print("→ 结论：缩短分片长度能【按比例】降低延迟（设备实测 RTT ≈ 音频时长 × 1.1）")
    else:
        print("→ 两者接近：内容不是主因，差异更可能来自设备端网络/DNS")
        print("→ 结论：应从设备网络链路方向排查")
    return 0


if __name__ == "__main__":
    sys.exit(main())
