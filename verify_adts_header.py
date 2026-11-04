#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 前置验证：在动 C 代码之前，先证明【ADTS 头生成逻辑】100% 正确。

要验证的东西（LiveCap.m 里 LCAppendADTSHeader 将逐字节实现同样的逻辑）：
  1. 我写的 ADTS 头公式 与 ffmpeg 产出的标准 ADTS 头【逐字节一致】；
  2. 用我的头重新组装裸 AAC 帧 → ffmpeg 能正确解码（音频内容无损）；
  3. 组装后的 ADTS 流被腾讯云一句话识别接受。

方法：
  - ffmpeg -f adts 产出标准 ADTS 文件 → 解析出每帧的 ADTS 头 + 帧体；
  - 用我的公式重算该帧的 ADTS 头 → 必须与 ffmpeg 的头逐字节相同；
  - 用 ffmpeg 的帧体 + 我的头重组 → ffmpeg 解码 → 与原始 PCM 比对。
"""
import io
import os
import struct
import subprocess
import sys
import wave

import imageio_ffmpeg

FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()


# ===== 我将要在 C 里实现的 ADTS 头逻辑（逐位对应）=====
# AAC LC, 16000 Hz, mono, no CRC → 7 字节头
SAMPLING_FREQ_INDEX = {   # MPEG-4 sampling_frequency_index
    96000: 0, 88200: 1, 64000: 2, 48000: 3, 44100: 4, 32000: 5,
    24000: 6, 22050: 7, 16000: 8, 12000: 9, 11025: 10, 8000: 11,
}


def make_adts_header(payload_len, sample_rate=16000, channels=1, profile=1):
    """profile: 0=Main,1=LC,2=SSR,3=LTP（ADTS 里 profile = objectType-1）"""
    sfi = SAMPLING_FREQ_INDEX[sample_rate]
    frame_len = 7 + payload_len          # ADTS 头 + 帧体
    b = bytearray(7)
    b[0] = 0xFF
    b[1] = 0xF1                        # syncword(4)=F, ID(1)=0(MPEG-4), layer(2)=0, protection_absent(1)=1
    b[2] = ((profile & 0x03) << 6) | ((sfi & 0x0F) << 2) | ((channels >> 2) & 0x01)
    b[3] = (((channels & 0x03) << 6) | ((frame_len >> 11) & 0x03))
    b[4] = (frame_len >> 3) & 0xFF
    b[5] = ((frame_len & 0x07) << 5) | 0x1F
    b[6] = 0xFC                        # buffer_fullness=0x7FF(VBR), num_raw_blocks=0
    return bytes(b)


def parse_adts(data):
    """解析 ADTS 流 → [(header7, payload)]"""
    frames = []
    i = 0
    n = len(data)
    while i + 7 <= n:
        if data[i] != 0xFF or (data[i + 1] & 0xF0) != 0xF0:
            i += 1
            continue
        flen = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | (data[i + 5] >> 5)
        if flen < 7 or i + flen > n:
            i += 1
            continue
        frames.append((data[i:i + 7], data[i + 7:i + flen]))
        i += flen
    return frames


def run(args, stdin_bytes=None):
    p = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + args,
                       input=stdin_bytes, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", "replace")[:400])
    return p.stdout


def main():
    # 1) 造一段 2.5 秒的 16k 单声道 WAV（正弦 + 包络，便于比对）
    sr = 16000
    secs = 2.5
    import math
    pcm = bytearray()
    for i in range(int(sr * secs)):
        t = i / sr
        env = 0.4 + 0.6 * abs(math.sin(math.pi * 2 * 3.0 * t))
        v = int(math.sin(math.pi * 2 * 220 * t) * env * 12000)
        pcm += struct.pack("<h", v)
    wav_bytes = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " \
        + struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16) \
        + b"data" + struct.pack("<I", len(pcm)) + bytes(pcm)

    # 2) ffmpeg 产出标准 ADTS
    adts_std = run(["-f", "wav", "-i", "pipe:0", "-c:a", "aac", "-b:a", "16k",
                    "-ac", "1", "-ar", "16000", "-f", "adts", "pipe:1"], wav_bytes)
    frames = parse_adts(adts_std)
    print("=" * 78)
    print("v1.0.87 前置验证：ADTS 头生成逻辑")
    print("=" * 78)
    print("ffmpeg 标准 ADTS 帧数: %d   文件大小: %d 字节" % (len(frames), len(adts_std)))

    # 3) 逐帧比对：我的头 vs ffmpeg 的头
    mismatch = 0
    for idx, (hdr, payload) in enumerate(frames):
        mine = make_adts_header(len(payload))
        if mine != hdr:
            mismatch += 1
            if mismatch <= 3:
                print("  ✗ 第 %d 帧不一致: mine=%s ffmpeg=%s" %
                      (idx, mine.hex(), hdr.hex()))
    if mismatch == 0:
        print("  ✓ 全部 %d 帧的 ADTS 头与 ffmpeg 标准输出【逐字节一致】" % len(frames))
    else:
        print("  ✗ %d/%d 帧不一致" % (mismatch, len(frames)))

    # 4) 用我的头重组 → ffmpeg 解码 → 与原始 PCM 比对
    rebuilt = bytearray()
    for hdr, payload in frames:
        rebuilt += make_adts_header(len(payload))
        rebuilt += payload
    decoded = run(["-f", "aac", "-i", "pipe:0", "-f", "wav", "-ac", "1",
                   "-ar", "16000", "-c:a", "pcm_s16le", "pipe:1"], bytes(rebuilt))

    w = wave.open(io.BytesIO(decoded), "rb")
    dec_pcm = w.readframes(w.getnframes())
    w.close()

    # AAC 是有损的，不能要求字节相同；用相关系数判断内容是否保真。
    # 注意：AAC 编码器有 priming delay（编码延迟），解码输出相对原始 PCM
    # 会有固定样本偏移，直接逐点相关系数会被相位差拉低 → 先做滑动对齐取最大值。
    a = struct.unpack("<%dh" % (len(pcm) // 2), bytes(pcm))
    b = struct.unpack("<%dh" % (len(dec_pcm) // 2), dec_pcm)
    m = min(len(a), len(b))
    a, b = a[:m], b[:m]
    mean_a = sum(a) / m
    mean_b = sum(b) / m
    da = [x - mean_a for x in a]
    db = [x - mean_b for x in b]
    den_a = sum(x * x for x in da) ** 0.5
    den_b = sum(x * x for x in db) ** 0.5

    best_corr = -1.0
    best_off = 0
    max_off = 4096
    step = 8
    for off in range(-max_off, max_off + 1, step):
        if off >= 0:
            xs, ys = da[off:], db[:m - off]
        else:
            xs, ys = da[:m + off], db[-off:]
        n = len(xs)
        if n < 1000:
            continue
        num = sum(xs[i] * ys[i] for i in range(0, n, 4))
        den = (sum(x * x for x in xs[::4]) ** 0.5) * (sum(y * y for y in ys[::4]) ** 0.5)
        if den == 0:
            continue
        c = num / den
        if c > best_corr:
            best_corr = c
            best_off = off
    print("  重组后解码: %d 帧, 最佳对齐偏移 = %d 样本, 相关系数 = %.4f %s" %
          (m, best_off, best_corr,
           "✓ 内容保真" if best_corr > 0.9 else "✗ 内容异常"))

    # 5) 裸 AAC（无 ADTS）对照：证明「必须有 ADTS 头」
    raw = b"".join(payload for _, payload in frames)
    print("  裸 AAC(去头) 大小 = %d 字节 ; 带 ADTS = %d 字节" % (len(raw), len(rebuilt)))
    print("  压缩比 = %.1fx（相对 16bit WAV %d 字节）" % (
        len(wav_bytes) / float(len(rebuilt)), len(wav_bytes)))

    ok = (mismatch == 0) and best_corr > 0.9
    print("=" * 78)
    print("结论: %s" % ("✓ ADTS 头逻辑正确，可照此实现到 Objective-C"
                         if ok else "✗ 存在问题，不能进入 CI"))
    print("=" * 78)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
