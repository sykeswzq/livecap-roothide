#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""离线验证 LiveCap.m 里 ADTS 封装头的位运算是否正确（与 FFmpeg 官方实现对拍）。

背景：
  v1.0.85 腾讯云拒收裸 AAC（ErrorInvalidVoicedata: Audio decoding failed），
  v1.0.87 改成「ADTS 封装 AAC」后，如果 7 字节头的位运算写错，接口依然会拒收。
  本机没有 iOS SDK 编不了 dylib，所以先把头单独离线验死，再上真机。

验证方法（三方交叉）：
  A. FFmpeg 官方 ADTS muxer 生成的帧头        —— 权威参考
  B. 逐字复刻 LiveCap.m 的 C 位运算生成的头    —— 待验证对象
  C. 按 ISO/IEC 13818-7 规范独立解析/生成的头 —— 第三方交叉核对
  三者必须完全一致；再把 B 封装出的完整流喂回 FFmpeg 解复用器，
  要求能报出 sample_rate=16000 / channels=1 / 帧数一致。

用法: py -3.11 verify_adts.py
"""
import io
import math
import os
import struct
import sys

try:
    import av
except ImportError:
    print("需要 PyAV: py -3.11 -m pip install av")
    sys.exit(2)

SF_RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
            16000, 12000, 11025, 8000, 7350]


# ============================ A. 复刻 LiveCap.m 的 C 端头构造 ============================
def c_adts_header(produced: int) -> bytes:
    """逐字复刻 LiveCap.m: LCAACEncodeADTSFramed() 里的头构造。

    对应源码：
        static const uint8_t kADTSHeader[7] = { 0xFF, 0xF1, 0x60, 0x00, 0x00, 0x1F, 0xFC };
        uint32_t frameLen = 7 + produced;
        uint8_t hdr[7]; memcpy(hdr, kADTSHeader, 7);
        hdr[2] = (uint8_t)(((1 & 0x03) << 6) | ((8 & 0x0F) << 2) | ((1 >> 2) & 0x01));
        hdr[3] = (uint8_t)(((1 & 0x03) << 6) | ((frameLen >> 11) & 0x03));
        hdr[4] = (uint8_t)((frameLen >> 3) & 0xFF);
        hdr[5] = (uint8_t)(((frameLen & 0x07) << 5) | 0x1F);
        hdr[6] = 0xFC;
    """
    kADTSHeader = [0xFF, 0xF1, 0x60, 0x00, 0x00, 0x1F, 0xFC]
    frameLen = 7 + produced
    hdr = list(kADTSHeader)
    hdr[2] = ((1 & 0x03) << 6) | ((8 & 0x0F) << 2) | ((1 >> 2) & 0x01)
    hdr[3] = ((1 & 0x03) << 6) | ((frameLen >> 11) & 0x03)
    hdr[4] = (frameLen >> 3) & 0xFF
    hdr[5] = (((frameLen & 0x07) << 5) | 0x1F) & 0xFF
    hdr[6] = 0xFC
    return bytes(hdr)


# ============================ C. ISO/IEC 13818-7 独立实现 ============================
def iso_parse(hdr: bytes):
    d = {}
    d["syncword"] = (hdr[0] << 4) | (hdr[1] >> 4)
    d["id"] = (hdr[1] >> 3) & 0x01
    d["layer"] = (hdr[1] >> 1) & 0x03
    d["protection_absent"] = hdr[1] & 0x01
    d["profile"] = (hdr[2] >> 6) & 0x03
    d["sampling_index"] = (hdr[2] >> 2) & 0x0F
    d["private_bit"] = (hdr[2] >> 1) & 0x01
    d["channel_config"] = ((hdr[2] & 0x01) << 2) | ((hdr[3] >> 6) & 0x03)
    d["original_copy"] = (hdr[3] >> 5) & 0x01
    d["home"] = (hdr[3] >> 4) & 0x01
    d["copyright_id_bit"] = (hdr[3] >> 3) & 0x01
    d["copyright_id_start"] = (hdr[3] >> 2) & 0x01
    d["aac_frame_len"] = ((hdr[3] & 0x03) << 11) | (hdr[4] << 3) | (hdr[5] >> 5)
    d["adts_buffer_fullness"] = ((hdr[5] & 0x1F) << 6) | (hdr[6] >> 2)
    d["num_raw_blocks"] = hdr[6] & 0x03
    d["sample_rate"] = SF_RATES[d["sampling_index"]] if d["sampling_index"] < len(SF_RATES) else None
    return d


def iso_expected_header(produced: int) -> bytes:
    """按 ISO/IEC 13818-7 独立生成一份正确的 ADTS 头（不复刻 C 代码）。"""
    frame_len = 7 + produced
    b = bytearray(7)
    b[0] = 0xFF
    b[1] = 0xF0 | (0 << 3) | (0 << 2) | 1     # MPEG-4, layer0, no CRC
    b[2] = (1 << 6) | (8 << 2) | (0 << 1) | 0  # profile=1(AAC-LC), sf_idx=8(16k), priv=0, chan hi=0
    b[3] = (1 << 6) | ((frame_len >> 11) & 0x03)
    b[4] = (frame_len >> 3) & 0xFF
    b[5] = ((frame_len & 0x07) << 5) | 0x1F
    b[6] = 0xFC
    return bytes(b)


# ============================ A. 用 FFmpeg 官方 muxer 生成参考 ADTS ============================
def make_reference_adts(seconds=2.5, rate=16000):
    """用 PyAV/FFmpeg 的 adts muxer 编出标准 ADTS 流，返回 (原始字节, [(hdr7, payload)])。"""
    out = io.BytesIO()
    container = av.open(out, mode="w", format="adts")
    stream = container.add_stream("aac", rate=rate)
    stream.layout = "mono"
    stream.bit_rate = 24000          # 与 LiveCap.m 的 24kbps 一致

    n = int(seconds * rate)
    samples = bytearray()
    for i in range(n):
        t = i / rate
        env = 0.5 * (1 + math.sin(2 * math.pi * 3.0 * t))
        samples += struct.pack("<h", int(12000 * env * math.sin(2 * math.pi * 440.0 * t)))
    frame = av.AudioFrame(format="s16", layout="mono", samples=n)
    frame.sample_rate = rate
    frame.pts = 0
    frame.planes[0].update(bytes(samples))

    for packet in stream.encode(frame):
        container.mux(packet)
    for packet in stream.encode(None):
        container.mux(packet)
    container.close()

    data = out.getvalue()
    return data, split_adts(data)


def split_adts(data: bytes):
    """把 ADTS 流按帧切开 → [(header7, payload), ...]。跳过 muxer 开头的 skip box。"""
    frames = []
    i = 0
    # FFmpeg 的 adts muxer 会在流首写一个 skip box，先跳到第一个 syncword
    while i + 7 <= len(data):
        if data[i] == 0xFF and (data[i + 1] & 0xF0) == 0xF0:
            break
        i += 1
    while i + 7 <= len(data):
        flen = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | (data[i + 5] >> 5)
        if flen < 7 or i + flen > len(data):
            break
        frames.append((data[i:i + 7], data[i + 7: i + flen]))
        i += flen
    return frames


def main():
    print("=" * 74)
    print("ADTS 封装头离线验证（对拍 FFmpeg 官方实现）")
    print("=" * 74)

    raw, frames = make_reference_adts()
    print("\n[1] FFmpeg 参考 ADTS: %d 字节 / %d 帧" % (len(raw), len(frames)))
    if not frames:
        print("❌ 没能解析出参考帧")
        return 1

    # ---------- 对拍 ----------
    same_c = same_iso = 0
    diff_c, diff_iso = [], []
    for idx, (fh, payload) in enumerate(frames):
        a = c_adts_header(len(payload))       # B: 复刻 C 代码
        b = iso_expected_header(len(payload))  # C: 按规范独立生成
        if a == fh:
            same_c += 1
        else:
            diff_c.append((idx, fh.hex(), a.hex()))
        if b == fh:
            same_iso += 1
        else:
            diff_iso.append((idx, fh.hex(), b.hex()))

    print("[2] 与 FFmpeg 官方帧头对拍")
    print("    B. 复刻 C 代码  : 一致 %d/%d 帧" % (same_c, len(frames)))
    for i, f, a in diff_c[:3]:
        print("        ❌ 帧%d 官方=%s 复刻=%s" % (i, f, a))
    print("    C. ISO 独立生成 : 一致 %d/%d 帧" % (same_iso, len(frames)))
    for i, f, b in diff_iso[:3]:
        print("        ❌ 帧%d 官方=%s ISO=%s" % (i, f, b))

    # ---------- 官方帧头样例 ----------
    fh0, p0 = frames[0]
    print("\n[3] 官方帧头样例: %s   (payload %d 字节)" % (fh0.hex(' '), len(p0)))
    f = iso_parse(fh0)
    print("    syncword=0x%03X  ID=%d(MPEG-4)  profile=%d(AAC-LC)  sf_idx=%d(%sHz)  chan=%d(mono)"
          % (f["syncword"], f["id"], f["profile"], f["sampling_index"],
             f["sample_rate"], f["channel_config"]))
    print("    frame_len=%d (=%d+7)  buffer_fullness=0x%03X  raw_blocks=%d"
          % (f["aac_frame_len"], len(p0), f["adts_buffer_fullness"], f["num_raw_blocks"]))

    # ---------- 把 B 封装出的流喂回 FFmpeg 解复用器 ----------
    rebuilt = b"".join(c_adts_header(len(p)) + p for _, p in frames)
    inp = av.open(io.BytesIO(rebuilt))
    st = inp.streams.audio[0]
    cc = st.codec_context
    decoded = 0
    samples = 0
    for fr in inp.decode(st):
        decoded += 1
        samples += fr.samples
    inp.close()

    print("\n[4] 用复刻头封装后，回灌 FFmpeg 解复用器")
    print("    sample_rate = %s   channels = %s   codec = %s"
          % (cc.sample_rate, cc.channels, cc.name))
    print("    解出 %d 帧 / %d 采样点（封装 %d 帧）" % (decoded, samples, len(frames)))

    # ---------- 结论 ----------
    checks = [
        ("复刻 C 代码与 FFmpeg 官方头逐字节一致", same_c == len(frames)),
        ("ISO 独立生成与 FFmpeg 官方头逐字节一致", same_iso == len(frames)),
        ("解复用器读出采样率 = 16000", cc.sample_rate == 16000),
        ("解复用器读出声道数 = 1 (mono)", cc.channels == 1),
        ("解码帧数与封装帧数一致", decoded == len(frames)),
        ("解出采样点 ≈ 2.5s * 16000", abs(samples - 40000) < 3000),
    ]
    print("\n[5] 判定")
    all_ok = True
    for name, good in checks:
        all_ok = all_ok and good
        print("    %s %s" % ("✅" if good else "❌", name))

    print("\n" + "=" * 74)
    print("结论: %s" % ("✅ ADTS 头完全正确，腾讯云应能正常解码"
                        if all_ok else "❌ ADTS 头有问题，接口会被拒收"))
    print("=" * 74)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
