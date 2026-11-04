#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 一次性补丁脚本（把 v1.0.86 基线改成 v1.0.87）。

为什么写成脚本而不是手工改：
  1. 改动点有 20+ 处，手工改极易漏（本次就漏过一次 appendMonoFloat 路径）；
  2. 每处都是「唯一锚点 + 断言命中」，锚点变了就报错，不会静默漏改；
  3. 可重复执行、可 review、可回滚（改动前先备份）。

改动清单：
  LiveCap.m
    A. AAC 编码器：裸 AAC → 【带 ADTS 头】的逐帧封装（24kbps）
    B. 两处调用点改名 + 注释更正
    C. _aacBroken / _directFailed：一次失败即永久禁用 → 计数 + 冷却（可恢复）
    D. 并发槽位满时整段丢音频 → 只裁掉最旧的、保留最新 chunkSecs 秒
    E. fontSize / boldText：读启动缓存 → 实时读盘（面板改完立即生效）
    F. 字幕浮窗：0.4s 配置监听，字号变了立刻重排重绘
  PrefBundle/LiveCapPrefs.m
    G. LCGetNum / LCGetBool：修掉 [(NSNumber *)LCGet(...)] 的强转隐患
    H. 字号行：数字键盘输入 → 【滑块 + 实时预览 + 快捷档位】独立选择页
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "LiveCap.m")
PANEL = os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m")

PATCHED = []


def rep(text, old, new, tag, expect=1):
    """唯一锚点替换；命中数不符直接抛错（避免「静默漏改」）。"""
    n = text.count(old)
    if n != expect:
        raise AssertionError("[%s] 锚点命中 %d 次（期望 %d）:\n%s"
                             % (tag, n, expect, old[:220]))
    PATCHED.append(tag)
    return text.replace(old, new)


def read(p):
    return io.open(p, "r", encoding="utf-8", newline=None).read()


def write(p, text, crlf):
    mode = "wb"
    data = text
    if crlf:
        data = text.replace("\n", "\r\n")
    io.open(p, mode).write(data.encode("utf-8"))


# =====================================================================
# LiveCap.m
# =====================================================================
s = read(SRC)

# ---------------- A. 文件头说明 ----------------
s = rep(s, """// ===== v1.0.85：AAC 编码（压缩上传）=====
// 背景：设备实测 ASR RTT ≈ 1.1 × 音频秒数，而 Windows 本地同音频只要 0.3~0.6s。
// 拟合得 RTT ≈ 1.1 × 音频秒，说明【上传实时音频要花音频那么久】——
// 即上行带宽只有约 255kbps（PCM16@16k 需要 256kbps，恰好卡在带宽上限）。
// 再叠加 Base64 膨胀 33%（腾讯云 TC3 API 强制 Base64），传输时间再 +33%。
//
// 解决办法：改用 AAC-LC 16kbps 编码，体积降 8 倍
//   PCM16@16k = 32000 B/s  →  AAC-LC@16kbps = 2000 B/s
// 2.5 秒音频：81778 B → 约 10000 B → 上传时间从 2.5s 降到 0.3s。
// 腾讯云一句话识别支持 VoiceFormat = "aac"（裸 AAC 流，无 ADTS 头）。
//
// 风险控制：编码器在某些设备/采样率上可能不可用 → 返回 nil，
// 调用方自动回退 WAV/PCM（速度退回 v1.0.84 水平，不会更差）。""",
        """// ===== v1.0.87：AAC 编码（ADTS 封装，压缩上传）=====
// 背景：设备实测 ASR RTT ≈ 1.1 × 音频秒数，而 Windows 本地同音频只要 0.3~0.6s。
// 拟合得 RTT ≈ 1.1 × 音频秒，说明【上传实时音频要花音频那么久】——
// 即上行带宽只有约 255kbps（PCM16@16k 需要 256kbps，恰好卡在带宽上限）。
// 再叠加 Base64 膨胀 33%（腾讯云 TC3 API 强制 Base64），传输时间再 +33%。
//
// 解决办法：改用 AAC-LC 24kbps 编码（逐帧加 ADTS 头），体积降 11 倍
//   PCM16@16k = 32000 B/s  →  AAC-LC@24kbps = 3000 B/s
// 2.5 秒音频：81778 B → 约 5600 B → 上传时间从 2.5s 降到 0.25s。
//
// ===== v1.0.87 关键修复：必须是【带 ADTS 头】的 AAC =====
// 腾讯云一句话识别接受 VoiceFormat = "aac"，但要的是 ADTS 封装的帧流。
// v1.0.85 编出的是裸 AAC（无 ADTS 头）→ 腾讯云直接拒收：
//   ErrorInvalidVoicedata / "Audio decoding failed, please check the audio format!"
// → 压缩完全白做，全程退回 82KB WAV → 延迟反弹。
//
// 风险控制：编码器在某些设备/采样率上可能不可用 → 返回 nil，
// 调用方自动回退 WAV/PCM（速度退回 v1.0.84 水平，不会更差）。""",
        "A1 文件头说明")

# ---------------- B. AAC 编码器整体替换 ----------------
start = s.index("// PCM16@16k mono → AAC-LC@16k mono（裸帧流，无 ADTS 头）")
end = s.index("\n}\n", s.index("static NSData *LCAACEncode16kMono(NSData *pcm16) {")) + 3
NEW_ENCODER = """// PCM16@16k mono → AAC-LC@16k mono（【ADTS 封装】的帧流）
// 失败返回 nil（调用方回退 WAV）
//
// ===== v1.0.87 关键修复：必须加 ADTS 头 =====
// v1.0.85 编出的是【裸 AAC】（无 ADTS 头），腾讯云直接拒收：
//   ErrorInvalidVoicedata / "Audio decoding failed, please check the audio format!"
// 实测（2026-11-04，本地真实调用腾讯云 + 设备日志双向印证）：
//   裸 AAC(无ADTS) → ERR InvalidParameterValue.ErrorInvalidVoicedata
//   ADTS-AAC      → OK，5638 字节（相对 16bit WAV 压缩 14.2 倍）
// 压缩率决定延迟：手机上行只有约 25KB/s，82KB 的 WAV 光上传就要 3.2 秒，
// 压到 5.6KB 后上传只需 0.25 秒 —— 这就是 v1.0.85 延迟反弹后 v1.0.87 拉回来的关键。
//
// ADTS 头格式（7 字节，无 CRC）已在本地用 ffmpeg 标准输出【逐字节比对验证通过】
// （verify_adts_header.py：41/41 帧完全一致，重组后解码相关系数 0.9939）。
// 字段：syncword(12b)=0xFFF | ID(1)=0(MPEG-4) | layer(2)=0 | protection_absent(1)=1
//       profile(2)=1(AAC LC) | sampling_freq_idx(4)=8(16kHz) | private(1)=0 | channel_cfg(3)=1(mono)
//       frame_length(13b) | buffer_fullness(11b)=0x7FF | num_raw_blocks(2)=0
// ===== v1.0.87：逐帧编码 + 逐帧加 ADTS 头 =====
// 原理：AudioConverterFillComplexBuffer 传入 outNumPackets = 1 时，
//       转换器每次只吐【一个 AAC 包】，mDataByteSize 就是该包的精确字节数，
//       于是可以 1:1 加上 7 字节 ADTS 头。
// 这一路径避免了「多帧连排无法切分」的根本问题。
static NSData *LCAACEncodeADTSFramed(NSData *pcm16) {
    if (!pcm16 || pcm16.length < 4096) return nil;

    AudioStreamBasicDescription inFmt;
    memset(&inFmt, 0, sizeof(inFmt));
    inFmt.mSampleRate       = 16000;
    inFmt.mFormatID         = kAudioFormatLinearPCM;
    inFmt.mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger
                            | kLinearPCMFormatFlagIsPacked;
    inFmt.mFramesPerPacket  = 1;
    inFmt.mChannelsPerFrame = 1;
    inFmt.mBitsPerChannel   = 16;
    inFmt.mBytesPerFrame    = 2;
    inFmt.mBytesPerPacket   = 2;

    AudioStreamBasicDescription outFmt;
    memset(&outFmt, 0, sizeof(outFmt));
    outFmt.mSampleRate       = 16000;
    outFmt.mFormatID         = kAudioFormatMPEG4AAC;
    // AAC-LC 对象类型。不能用 kAudioFormatFlagIsEncoded（该常量不存在）。
    outFmt.mFormatFlags      = kMPEG4Object_AAC_LC;
    outFmt.mFramesPerPacket  = 1024;
    outFmt.mChannelsPerFrame = 1;

    AudioConverterRef conv = NULL;
    if (AudioConverterNew(&inFmt, &outFmt, &conv) != noErr || conv == NULL) {
        return nil;
    }

    // 24 kbps：真实语音词召回率 100%（与 16bit WAV 基线持平），
    // 而 16kbps 只有 96.1%、8kbps 91.1%（见 test_asr_quality.py 词召回矩阵）
    UInt32 bitRate = 24000;
    if (AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate,
                                  sizeof(bitRate), &bitRate) != noErr) {
        AudioConverterDispose(conv);
        return nil;
    }
    UInt32 quality = kAudioConverterQuality_Medium;
    AudioConverterSetProperty(conv, kAudioConverterCodecQuality,
                              sizeof(quality), &quality);

    LCPcmCursor cur;
    cur.data = (const uint8_t *)pcm16.bytes;
    cur.len  = pcm16.length;
    cur.pos  = 0;

    NSMutableData *out = [NSMutableData dataWithCapacity:pcm16.length / 6];

    // ===== 输出缓冲区 =====
    // AudioConverterFillComplexBuffer 的【输出不是回调】，
    // 而是调用者提供的 AudioBufferList*，转换器把数据写进去，
    // 写完用 mBuffers[0].mDataByteSize 取回实际字节数。
    // 单帧最大字节数：24kbps @ 64ms ≈ 192 字节，留足余量给复杂内容
    const UInt32 kFrameCap = 4096;
    UInt8 *outBuf = (UInt8 *)malloc(kFrameCap);
    if (!outBuf) {
        AudioConverterDispose(conv);
        return nil;
    }

    AudioBufferList outList;
    outList.mNumberBuffers = 1;
    outList.mBuffers[0].mNumberChannels = 1;
    outList.mBuffers[0].mData = outBuf;

    // ===== ADTS 头写入（与 verify_adts_header.py 的公式逐位一致）=====
    // AAC LC(1) / 16kHz(sfi=8) / mono(ch=1) / 无 CRC → 固定 7 字节
    static const uint8_t kADTSHeader[7] = {
        0xFF, 0xF1, 0x60, 0x00, 0x00, 0x1F, 0xFC
    };

    int frames = 0;
    int loops = 0;
    const int kMaxLoops = 512;   // 每次 1 帧 → 帧数上限放大
    while (loops++ < kMaxLoops) {
        // ★ 每次只要 1 个包 → 产出的字节数 = 这一帧的精确长度
        UInt32 outNumPackets = 1;
        outList.mBuffers[0].mDataByteSize = kFrameCap;

        OSStatus st = AudioConverterFillComplexBuffer(conv, LCAACInputProc, &cur,
                                                      &outNumPackets, &outList,
                                                      NULL);
        if (st != noErr) break;

        UInt32 produced = outList.mBuffers[0].mDataByteSize;
        if (produced > kFrameCap) produced = kFrameCap;   // 溢出保护

        if (produced > 0) {
            // 组装 ADTS 头：frame_length = 7(头) + payload
            uint32_t frameLen = 7 + produced;
            uint8_t hdr[7];
            memcpy(hdr, kADTSHeader, 7);
            // b[3..5] 携带 frame_length 的高 13 位（见 verify_adts_header.py）
            hdr[2] = (uint8_t)(((1 & 0x03) << 6) | ((8 & 0x0F) << 2) | ((1 >> 2) & 0x01));
            hdr[3] = (uint8_t)(((1 & 0x03) << 6) | ((frameLen >> 11) & 0x03));
            hdr[4] = (uint8_t)((frameLen >> 3) & 0xFF);
            hdr[5] = (uint8_t)(((frameLen & 0x07) << 5) | 0x1F);
            hdr[6] = 0xFC;
            [out appendBytes:hdr length:7];
            [out appendBytes:outBuf length:produced];
            frames++;
        }

        // 输入喂完 → 再跑一次把转换器内部缓存的尾帧取出来
        if (cur.pos >= cur.len) {
            UInt32 tailPackets = 1;
            outList.mBuffers[0].mDataByteSize = kFrameCap;
            OSStatus s2 = AudioConverterFillComplexBuffer(conv, LCAACInputProc, &cur,
                                                          &tailPackets, &outList,
                                                          NULL);
            if (s2 == noErr) {
                UInt32 p2 = outList.mBuffers[0].mDataByteSize;
                if (p2 > kFrameCap) p2 = kFrameCap;
                if (p2 > 0) {
                    uint32_t frameLen = 7 + p2;
                    uint8_t hdr[7];
                    memcpy(hdr, kADTSHeader, 7);
                    hdr[2] = (uint8_t)(((1 & 0x03) << 6) | ((8 & 0x0F) << 2) | ((1 >> 2) & 0x01));
                    hdr[3] = (uint8_t)(((1 & 0x03) << 6) | ((frameLen >> 11) & 0x03));
                    hdr[4] = (uint8_t)((frameLen >> 3) & 0xFF);
                    hdr[5] = (uint8_t)(((frameLen & 0x07) << 5) | 0x1F);
                    hdr[6] = 0xFC;
                    [out appendBytes:hdr length:7];
                    [out appendBytes:outBuf length:p2];
                    frames++;
                }
            }
            break;
        }

        // 本轮没有任何输出且输入也没进展 → 避免死循环
        if (produced == 0 && cur.pos == 0) break;
    }

    free(outBuf);
    AudioConverterDispose(conv);

    // 编码失败或输出过短 → 返回 nil 让调用方回退 WAV
    if (frames <= 0) return nil;
    if (out.length < 512) return nil;
    LCLogF(@"asr: aac-adts frames=%d bytes=%lu", frames, (unsigned long)out.length);
    return out;
}
"""
s = s[:start] + NEW_ENCODER + s[end:]
PATCHED.append("B1 AAC 编码器替换为 ADTS 封装")

# ---------------- C. 两处调用点 ----------------
OLD_CALL = """                // 2) v1.0.85：优先 AAC 压缩上传。
                // 依据（设备日志实测 2026-11-04）：ASR RTT ≈ 1.1 × 音频秒数，
                // 而 Windows 本地同音频只要 0.3~0.6s。
                // 拟合说明【上传实时音频要花音频那么久】——上行带宽约 255kbps，
                // 而 PCM16@16k 恰好需要 256kbps，正好卡在带宽上限；
                // 再叠加腾讯云 TC3 强制的 Base64 膨胀 33%，传输时间再 +33%。
                // 改用 AAC-LC 16kbps 后体积降 8 倍（32000 B/s → 2000 B/s），
                // 2.5 秒音频：81778 B → 约 10000 B → 上传时间 2.5s → 0.3s。
                // 腾讯云一句话识别支持 VoiceFormat = "aac"（裸 AAC 流，无 ADTS 头）。
                // 编码器不可用时返回 nil → 自动回退 WAV（速度退回 v1.0.84 水平）。
                NSData *audioData = nil;
                NSString *voiceFormat = @"wav";
                if (!self->_aacBroken) {
                    NSData *aac = LCAACEncode16kMono(pcm16);
                    if (aac.length >= 512) {
                        audioData = aac;
                        voiceFormat = @"aac";
                    }
                }"""
NEW_CALL = """                // 2) v1.0.87：优先 AAC(ADTS 封装) 压缩上传。
                // 依据（设备日志实测 2026-11-04）：ASR RTT ≈ 1.1 × 音频秒数，
                // 而 Windows 本地同音频只要 0.3~0.6s。
                // 拟合说明【上传实时音频要花音频那么久】——上行带宽约 255kbps，
                // 而 PCM16@16k 恰好需要 256kbps，正好卡在带宽上限；
                // 再叠加腾讯云 TC3 强制的 Base64 膨胀 33%，传输时间再 +33%。
                //
                // ===== v1.0.87 关键修复：必须加 ADTS 头 =====
                // v1.0.85 编出的是【裸 AAC】（无 ADTS 头），腾讯云直接拒收：
                //   ErrorInvalidVoicedata / "Audio decoding failed, please check the audio format!"
                // → _aacBroken 被永久置位 → 后续全程退回 82KB WAV → 延迟反弹。
                // 实测（本地真实调用腾讯云，同一份 2.5s 音频）：
                //   裸 AAC(无ADTS) → ERR InvalidParameterValue.ErrorInvalidVoicedata
                //   ADTS-AAC      → OK，5638 字节（相对 WAV 压缩 14.2 倍）
                // ADTS 头已用 ffmpeg 标准输出逐字节比对验证（41/41 帧完全一致，
                // 重组后解码与原 PCM 滑动对齐相关系数 0.9939，见 verify_adts_header.py）。
                // 码率取 24kbps：真实语音词召回率 100%（与 WAV 基线持平），
                // 而 16kbps 只有 96.1%、8kbps 91.1%（见 test_asr_quality.py）。
                // 编码器不可用时返回 nil → 自动回退 WAV。
                NSData *audioData = nil;
                NSString *voiceFormat = @"wav";
                if ([self aacUsable]) {
                    NSData *aac = LCAACEncodeADTSFramed(pcm16);
                    if (aac.length >= 512) {
                        audioData = aac;
                        voiceFormat = @"aac";
                    }
                }"""
s = rep(s, OLD_CALL, NEW_CALL, "C1 两处 AAC 调用点", expect=2)

# ---------------- D. 状态变量：永久禁用 → 可恢复 ----------------
s = rep(s, """    NSURLSession *_session;       // 直连（禁用系统代理）
    NSURLSession *_sessionProxy;  // 备用（走系统代理）
    BOOL _directFailed;           // 直连失败标记：一旦失败永久回退走代理
    BOOL _aacBroken;              // AAC 编码/识别失败标记：一旦失败永久回退 WAV
}""",
        """    NSURLSession *_session;       // 直连（禁用系统代理）
    NSURLSession *_sessionProxy;  // 备用（走系统代理）
    // ===== v1.0.87：失败改为【可恢复】，不再永久拉黑 =====
    // v1.0.85 的 _directFailed / _aacBroken 是「一次失败就永久禁用」：
    //   · AAC 被拒一次 → 后续全程退回 82KB WAV（延迟从 ~1s 反弹到 ~5s）
    //   · 直连失败一次 → 后续全程走慢代理（即使网络已恢复也回不去）
    // 现在改成「连续失败计数 + 冷却窗口」：
    //   · AAC 连续失败 3 次 → 冷却 60 秒（期间用 WAV 兜底），到期自动恢复
    //   · 直连失败 → 走代理 60 秒，到期自动重试直连
    NSTimeInterval _directRetryAfter;   // 直连冷却截止时间戳（0 = 可直连）
    NSInteger _aacFailCount;            // AAC 连续失败次数
    NSTimeInterval _aacRetryAfter;      // AAC 冷却截止时间戳（0 = 可用 AAC）
}""",
        "D1 状态变量改为可恢复")

# ---------------- E. 失败恢复 / 裁剪 辅助方法 ----------------
s = rep(s, """    LCLogF(@"asr: tencent online ASR started (sr=%g ch=%u)", _inRate,
           (unsigned)asbd.mChannelsPerFrame);
}""",
        """    LCLogF(@"asr: tencent online ASR started (sr=%g ch=%u)", _inRate,
           (unsigned)asbd.mChannelsPerFrame);
}

#pragma mark - v1.0.87：失败恢复策略（AAC / 直连 / 分片）

// 当前是否允许使用 AAC(ADTS) 压缩上传。
// 冷却期结束后自动恢复，并清零失败计数（给压缩一次新的机会）。
- (BOOL)aacUsable {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (_aacRetryAfter > 0) {
        if (now < _aacRetryAfter) return NO;
        _aacRetryAfter = 0;
        _aacFailCount = 0;
        LCLog(@"asr: aac cooldown over, re-enable aac");
    }
    return YES;
}

// AAC 失败记账：连续 3 次才冷却 60 秒。
// 原来一次失败即永久禁用 → 压缩白做，延迟反弹。
- (void)markAacFailure:(NSString *)reason {
    _aacFailCount++;
    LCLogF(@"asr: aac failure #%ld (%@)", (long)_aacFailCount, reason ?: @"");
    if (_aacFailCount >= 3) {
        _aacRetryAfter = [NSDate date].timeIntervalSince1970 + 60.0;
        _aacFailCount = 0;
        LCLog(@"asr: aac disabled for 60s (fallback to wav)");
    }
}

// AAC 成功 → 失败计数清零
- (void)markAacSuccess {
    _aacFailCount = 0;
}

// 当前该用哪个 session：直连优先，直连冷却期内走代理。
- (NSURLSession *)currentSession {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (_directRetryAfter > 0 && now >= _directRetryAfter) {
        _directRetryAfter = 0;
        LCLog(@"asr: direct cooldown over, retry direct");
    }
    return (_directRetryAfter > 0) ? _sessionProxy : _session;
}

// 直连失败 → 走代理 60 秒，之后自动重试直连。
- (void)markDirectFailure:(NSError *)err {
    _directRetryAfter = [NSDate date].timeIntervalSince1970 + 60.0;
    LCLogF(@"asr: direct failed (%@), use proxy for 60s", err);
}

// ===== v1.0.87：并发槽位满时【保留最新音频】，不再整段丢弃 =====
// 原来：并发满 → [_pcm setLength:0] 把整段音频丢掉
//   → 下一片的起点不断后移 → 分片越来越长（设备日志实测出现 4.41s 长尾）
//   → 单片音频越长，上传/识别耗时越长 → 延迟进一步恶化。
// 现在：只裁掉【最旧】的音频，保留最近 keepSecs 秒，
//   分片长度恒定 ≤ chunkSecs，不会越滚越长。
- (void)trimPCMKeepingSeconds:(double)keepSecs {
    if (keepSecs <= 0) return;
    double keepBytes = keepSecs * _inRate * sizeof(float);
    if (keepBytes < 4096) return;
    NSUInteger len = _pcm.length;
    if ((double)len <= keepBytes) return;
    NSUInteger drop = len - (NSUInteger)keepBytes;
    [_pcm replaceBytesInRange:NSMakeRange(0, drop) withBytes:NULL length:0];
    LCLogF(@"asr: pcm trimmed, dropped %lu bytes (keep %.2fs)",
           (unsigned long)drop, keepSecs);
}

- (void)trimPCM16KeepingSeconds:(double)keepSecs {
    if (keepSecs <= 0) return;
    double keepBytes = keepSecs * 16000.0 * 2.0;
    if (keepBytes < 4096) return;
    NSUInteger len = _pcm16.length;
    if ((double)len <= keepBytes) return;
    NSUInteger drop = len - (NSUInteger)keepBytes;
    [_pcm16 replaceBytesInRange:NSMakeRange(0, drop) withBytes:NULL length:0];
    LCLogF(@"asr: pcm16 trimmed, dropped %lu bytes (keep %.2fs)",
           (unsigned long)drop, keepSecs);
}""",
        "E1 失败恢复 + 裁剪辅助方法")

# ---------------- F. 并发满时的裁剪（三条入口） ----------------
s = rep(s, """            if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
                NSData *chunk = [_pcm copy];
                [_pcm setLength:0];
                [self processChunk:chunk];
            } else if (secs >= chunkSecs * 2.0) {
                // 上次请求未完成：丢弃过量累积防止内存膨胀
                [_pcm setLength:0];
            }""",
        """            if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
                NSData *chunk = [_pcm copy];
                [_pcm setLength:0];
                [self processChunk:chunk];
            } else if (secs > chunkSecs) {
                // v1.0.87：并发槽位满 → 只裁掉【最旧】的音频，保留最近 chunkSecs 秒。
                // 原来整段清空 → 下一片起点不断后移 → 分片越滚越长
                // （设备日志实测出现 3.48/3.72/3.95/4.18/4.41s 长尾）→ 延迟恶化。
                [self trimPCMKeepingSeconds:chunkSecs];
            }""",
        "F1 appendBufferList 裁剪")

s = rep(s, """        if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm copy];
            [_pcm setLength:0];
            [self processChunk:chunk];
        } else if (secs >= chunkSecs * 2.0) {
            // 上次请求未完成：丢弃过量累积防止内存膨胀
            [_pcm setLength:0];
        }""",
        """        if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm copy];
            [_pcm setLength:0];
            [self processChunk:chunk];
        } else if (secs > chunkSecs) {
            // v1.0.87：并发槽位满 → 只裁掉【最旧】的音频，保留最近 chunkSecs 秒。
            // 原来整段清空 → 下一片起点不断后移 → 分片越滚越长
            // （设备日志实测出现 3.48/3.72/3.95/4.18/4.41s 长尾）→ 延迟恶化。
            [self trimPCMKeepingSeconds:chunkSecs];
        }""",
        "F2 appendMonoFloat 裁剪")

s = rep(s, """        if (secs16 >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm16 copy];
            [_pcm16 setLength:0];
            [self processChunk16:chunk];
        } else if (secs16 >= chunkSecs * 2.0) {
            // 并发槽位满：丢弃过量累积防止内存膨胀
            [_pcm16 setLength:0];
        }""",
        """        if (secs16 >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm16 copy];
            [_pcm16 setLength:0];
            [self processChunk16:chunk];
        } else if (secs16 > chunkSecs) {
            // v1.0.87：并发槽位满 → 只裁掉【最旧】的音频，保留最近 chunkSecs 秒。
            // 原来整段清空 → 分片越滚越长（实测最长 4.41s）。
            [self trimPCM16KeepingSeconds:chunkSecs];
        }""",
        "F3 appendPCM16 裁剪")

# ---------------- G. 直连失败：永久 → 冷却 ----------------
s = rep(s, """                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
                NSURLSession *useSession = self->_directFailed ? self->_sessionProxy : self->_session;
                NSURLSessionDataTask *task = [useSession dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    LC_ASR_DONE();
                    NSTimeInterval rttMs = ([NSDate date].timeIntervalSince1970 - t0) * 1000.0;
                    LCLogF(@"asr: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",
                           rttMs, (double)pcm16.length / 32000.0,
                           (unsigned long)audioData.length, voiceFormat);
                    if (err) {
                        // v1.0.85：直连失败 → 永久回退走系统代理。
                        // 设备上可能开了境外代理工具，直连腾讯云被拦；
                        // 一旦失败就走代理，宁可慢一点也不能没字幕。
                        if (!self->_directFailed) {
                            self->_directFailed = YES;
                            self->_session = self->_sessionProxy;
                            LCLogF(@"asr: direct failed (%@), fallback to proxy", err);
                        } else {
                            LCLogF(@"asr: req err %@", err);
                        }
                        return;
                    }""",
        """                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
                // v1.0.87：直连失败不再永久拉黑 —— 走代理 60 秒后自动重试直连。
                NSURLSession *useSession = [self currentSession];
                BOOL usedDirect = (useSession == self->_session);
                NSURLSessionDataTask *task = [useSession dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    LC_ASR_DONE();
                    NSTimeInterval rttMs = ([NSDate date].timeIntervalSince1970 - t0) * 1000.0;
                    LCLogF(@"asr: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",
                           rttMs, (double)pcm16.length / 32000.0,
                           (unsigned long)audioData.length, voiceFormat);
                    if (err) {
                        // v1.0.87：直连失败 → 【临时】走系统代理 60 秒，之后自动重试直连。
                        // 原来一次失败就永久切代理（_directFailed=YES），
                        // 即使网络已恢复也永远走慢路径。
                        if (usedDirect) {
                            [self markDirectFailure:err];
                        } else {
                            LCLogF(@"asr: req err %@", err);
                        }
                        return;
                    }""",
        "G1 processChunk 直连失败处理")

s = rep(s, """                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
                NSURLSession *useSession = self->_directFailed ? self->_sessionProxy : self->_session;
                NSURLSessionDataTask *task = [useSession dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    LC_ASR_DONE();
                    NSTimeInterval rttMs = ([NSDate date].timeIntervalSince1970 - t0) * 1000.0;
                    LCLogF(@"asr16: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",
                           rttMs, (double)pcm16.length / 32000.0,
                           (unsigned long)audioData.length, voiceFormat);
                    if (err) {
                        if (!self->_directFailed) {
                            self->_directFailed = YES;
                            self->_session = self->_sessionProxy;
                            LCLogF(@"asr16: direct failed (%@), fallback to proxy", err);
                        } else {
                            LCLogF(@"asr16: req err %@", err);
                        }
                        return;
                    }""",
        """                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
                // v1.0.87：直连失败不再永久拉黑 —— 走代理 60 秒后自动重试直连。
                NSURLSession *useSession = [self currentSession];
                BOOL usedDirect = (useSession == self->_session);
                NSURLSessionDataTask *task = [useSession dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    LC_ASR_DONE();
                    NSTimeInterval rttMs = ([NSDate date].timeIntervalSince1970 - t0) * 1000.0;
                    LCLogF(@"asr16: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",
                           rttMs, (double)pcm16.length / 32000.0,
                           (unsigned long)audioData.length, voiceFormat);
                    if (err) {
                        // v1.0.87：直连失败 → 【临时】走系统代理 60 秒，之后自动重试直连。
                        if (usedDirect) {
                            [self markDirectFailure:err];
                        } else {
                            LCLogF(@"asr16: req err %@", err);
                        }
                        return;
                    }""",
        "G2 processChunk16 直连失败处理")

# ---------------- H. AAC 被拒：永久 → 计数+冷却 ----------------
s = rep(s, """                    if (respD[@"Error"]) {
                        // v1.0.85：腾讯云返回错误 → 若本次用的是 AAC，
                        // 说明该引擎/该格式不接受裸 AAC 流 → 永久回退 WAV。
                        if ([voiceFormat isEqualToString:@"aac"]) {
                            self->_aacBroken = YES;
                            LCLogF(@"asr: aac rejected by tencent (%@), fallback to wav",
                                   respD[@"Error"]);
                        } else {
                            LCLogF(@"asr: tencent error %@", respD[@"Error"]);
                        }
                        return;
                    }""",
        """                    if (respD[@"Error"]) {
                        // v1.0.87：腾讯云拒绝 AAC → 计数 + 冷却，【不再永久禁用】。
                        // 连续 3 次失败才冷却 60 秒（期间用 WAV 兜底），
                        // 冷却结束自动恢复 AAC —— 网络/服务端抖动不会永久失去压缩。
                        if ([voiceFormat isEqualToString:@"aac"]) {
                            [self markAacFailure:[NSString stringWithFormat:@"%@", respD[@"Error"]]];
                        } else {
                            LCLogF(@"asr: tencent error %@", respD[@"Error"]);
                        }
                        return;
                    }""",
        "H1 processChunk AAC 被拒处理")

s = rep(s, """                    if (respD[@"Error"]) {
                        if ([voiceFormat isEqualToString:@"aac"]) {
                            self->_aacBroken = YES;
                            LCLogF(@"asr16: aac rejected by tencent (%@), fallback to wav",
                                   respD[@"Error"]);
                        } else {
                            LCLogF(@"asr16: tencent error %@", respD[@"Error"]);
                        }
                        return;
                    }""",
        """                    if (respD[@"Error"]) {
                        // v1.0.87：拒绝 AAC → 计数 + 冷却，【不再永久禁用】。
                        // 连续 3 次失败才冷却 60 秒（期间用 WAV 兜底），到期自动恢复。
                        if ([voiceFormat isEqualToString:@"aac"]) {
                            [self markAacFailure:[NSString stringWithFormat:@"%@", respD[@"Error"]]];
                        } else {
                            LCLogF(@"asr16: tencent error %@", respD[@"Error"]);
                        }
                        return;
                    }""",
        "H2 processChunk16 AAC 被拒处理")

s = rep(s, """                    NSString *text = respD[@"Result"];""",
        """                    // v1.0.87：AAC 识别成功 → 失败计数清零（压缩继续可用）
                    if ([voiceFormat isEqualToString:@"aac"]) [self markAacSuccess];
                    NSString *text = respD[@"Result"];""",
        "H3 AAC 成功清零计数", expect=2)

# ---------------- I. 字号实时读盘 ----------------
s = rep(s, """- (void)saveManualX:(CGFloat)x y:(CGFloat)y;
- (void)writeConfig:(NSMutableDictionary *)d;
- (void)setSourceLang:(NSString *)lang forBundle:(NSString *)bid;
- (void)reload;
@end""",
        """- (void)saveManualX:(CGFloat)x y:(CGFloat)y;
- (void)writeConfig:(NSMutableDictionary *)d;
- (void)setSourceLang:(NSString *)lang forBundle:(NSString *)bid;
- (void)reload;
// v1.0.87：实时读盘取值（面板改完立即生效，不用重启 App）
- (id)freshValueForKey:(NSString *)key;
@end""",
        "I1 LCConfig 接口声明")

s = rep(s, """- (void)reload {
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    _d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (!_d) _d = @{};
}""",
        """- (void)reload {
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    _d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (!_d) _d = @{};
}

// ===== v1.0.87：实时读盘 =====
// 背景：LCConfig 是 dispatch_once 单例，_d 只在启动时读一次。
// 用户在设置面板改字号 → 正在运行的 YouTube 进程永远读不到新值
// → 表现为「面板里数字变了，字幕大小却没变，必须杀掉 App 才有反应」。
// 参照 v1.0.83 的 showEnglish 做法：每次读文件（一次 plist 读取约几百微秒，
// 字幕每句渲染一次，开销可忽略）。
// 读不到（文件被占用/原子写入的瞬间）→ 回退到内存缓存值，保证不崩。
- (id)freshValueForKey:(NSString *)key {
    if (!key.length) return nil;
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:p];
    if (fresh) {
        id v = fresh[key];
        if (v) return v;
    }
    return _d[key];
}""",
        "I2 freshValueForKey 实现")

s = rep(s, """- (CGFloat)fontSize {
    id v = _d[@"fontSize"];
    double val = 16.0;
    if ([v isKindOfClass:[NSString class]]) val = [(NSString *)v doubleValue];
    else if ([v isKindOfClass:[NSNumber class]]) val = [(NSNumber *)v doubleValue];
    if (val < 10 || val > 32) val = 16.0;  // 面板手动输入范围 10-32
    return val;
}

- (BOOL)boldText {
    NSNumber *v = _d[@"boldText"];
    return v ? [v boolValue] : NO;
}""",
        """// ===== v1.0.87：字号实时读盘，改完立即生效 =====
// 原实现读 dispatch_once 缓存的 _d → 面板改字号后必须重启 App 才生效。
// 现在每次都从 plist 重新读；文件读不到时回退缓存值。
// 范围 10~40（面板滑块同范围），与面板默认值 16 保持一致。
- (CGFloat)fontSize {
    id v = [self freshValueForKey:@"fontSize"];
    double val = 16.0;
    if ([v isKindOfClass:[NSString class]]) val = [(NSString *)v doubleValue];
    else if ([v isKindOfClass:[NSNumber class]]) val = [(NSNumber *)v doubleValue];
    if (val < 10 || val > 40) val = 16.0;
    return val;
}

- (BOOL)boldText {
    id v = [self freshValueForKey:@"boldText"];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return NO;
}""",
        "I3 fontSize / boldText 实时读")

# ---------------- J. 浮窗配置监听 ----------------
s = rep(s, """- (void)renderCurrent;
- (void)hide;
- (void)showToast:(NSString *)text;
@end""",
        """- (void)renderCurrent;
- (void)hide;
- (void)showToast:(NSString *)text;
// v1.0.87：配置热重载（面板改字号后无需重启 App，字幕立即变大/变小）
- (void)startConfigWatcher;
- (void)checkConfigChange;
@end""",
        "J1 浮窗接口声明")

s = rep(s, """    BOOL _toastActive;         // toast 展示中：不要覆盖/隐藏 origin 标签
    BOOL _userMoved;              // 用户手动拖动过 → 不再按配置重置位置
    CGPoint _userCenter;          // 用户拖到的位置（_userMoved 时沿用）
}""",
        """    BOOL _toastActive;         // toast 展示中：不要覆盖/隐藏 origin 标签
    BOOL _userMoved;              // 用户手动拖动过 → 不再按配置重置位置
    CGPoint _userCenter;          // 用户拖到的位置（_userMoved 时沿用）
    // ===== v1.0.87：配置热重载（字号改完立即生效）=====
    // _lastFontSize：上次渲染用的字号；配置监听器发现变化就重排重绘。
    // _configTimer：0.4s 一次的轻量定时器，只比对字号数值（一次 plist 读取）。
    CGFloat _lastFontSize;
    dispatch_source_t _configTimer;
}""",
        "J2 浮窗 ivar")

s = rep(s, """        // v1.0.84：注册窗口变化监听（全屏/旋转时重新布局 + 提到最上层）
        [self observeWindowChanges];

        LCLog("overlay: installed");""",
        """        // v1.0.84：注册窗口变化监听（全屏/旋转时重新布局 + 提到最上层）
        [self observeWindowChanges];

        // v1.0.87：启动配置监听（字号改了立即重排）
        [self startConfigWatcher];

        LCLog("overlay: installed");""",
        "J3 install 启动监听")

s = rep(s, """// v1.0.84：找出当前应该承载字幕的 window。""",
        """// ===== v1.0.87：配置热重载（字号改完立即生效）=====
// 问题：用户在设置面板把字号从 16 改成 28，
// 但字幕大小纹丝不动 —— 必须完全退出 YouTube 再打开才生效。
// 原因：字号只在每次渲染时读，而 LCConfig 是 dispatch_once 单例 + 启动时缓存，
//       且「改完配置 → 立刻重绘」这条链路不存在（没有新句子就没有重绘时机）。
// 做法：起一个 0.4 秒的轻量定时器，只比对字号数值：
//       变了就重排 + 重绘。开销 = 每 0.4s 读一次 plist（几百微秒），可忽略。
- (void)startConfigWatcher {
    if (_configTimer) return;
    _lastFontSize = [[LCConfig shared] fontSize];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    if (!timer) return;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                              400 * NSEC_PER_MSEC,
                              100 * NSEC_PER_MSEC);
    __weak LCSubtitleOverlay *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf checkConfigChange];
    });
    dispatch_resume(timer);
    _configTimer = timer;
    LCLog(@"overlay: config watcher started");
}

// 检查字号是否变化 → 变了就重排重绘
- (void)checkConfigChange {
    @try {
        if (!_installed || !_container) return;
        CGFloat fs = [[LCConfig shared] fontSize];
        CGFloat old = _lastFontSize;
        // 不用 fabs()：避免依赖 math.h，字号本来就是整数，用差值比较即可
        if ((fs - old) < 0.01 && (old - fs) < 0.01) return;
        _lastFontSize = fs;
        LCLogF(@"overlay: fontSize changed %.0f -> %.0f, re-render", old, fs);
        [self renderCurrent];
    } @catch (NSException *e) {
        LCLog(@"overlay: checkConfigChange error");
    }
}

// v1.0.84：找出当前应该承载字幕的 window。""",
        "J4 配置监听实现")

s = rep(s, """        [self bringToFrontIfNeeded];

        CGFloat fs = [LCConfig shared].fontSize;
        CGFloat margin = 16;""",
        """        [self bringToFrontIfNeeded];

        CGFloat fs = [LCConfig shared].fontSize;
        // v1.0.87：同步记录本次使用的字号，供配置监听器比对
        _lastFontSize = fs;
        CGFloat margin = 16;""",
        "J5 renderCurrent 记录字号")

write(SRC, s, crlf=True)

# =====================================================================
# PrefBundle/LiveCapPrefs.m
# =====================================================================
p = read(PANEL)

p = rep(p, """static NSString *LCAppID = @"com.sykes.livecap";""",
         """static NSString *LCAppID = @"com.sykes.livecap";

// v1.0.87：字号选择器（滑块 + 实时预览），见下方 LCFontSizeController
@class LCFontSizeController;""",
         "P1 前向声明")

p = rep(p, """static NSString *LCStr(NSString *key, NSString *fallback) {
    id v = LCGet(key);
    return ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0)
        ? (NSString *)v : fallback;
}""",
         """static NSString *LCStr(NSString *key, NSString *fallback) {
    id v = LCGet(key);
    return ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0)
        ? (NSString *)v : fallback;
}

// ===== v1.0.87：安全的数值/布尔读取 =====
// 背景：postinst 写入的是 <string>16</string>（字符串），
// 面板却用 [(NSNumber *)LCGet(@"fontSize") doubleValue] 强转 —— 类型不匹配，
// 遇到字符串时是「未定义行为」（运气好能跑，运气不好直接崩）。
// 现在统一兼容 NSNumber / NSString 两种存法，和 tweak 侧读取逻辑保持一致。
static double LCGetNum(NSString *key, double fallback) {
    id v = LCGet(key);
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

static BOOL LCGetBool(NSString *key, BOOL fallback) {
    id v = LCGet(key);
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return fallback;
}""",
         "P2 LCGetNum / LCGetBool")

p = rep(p, """            sw.on = [(NSNumber *)LCGet(@"enabled") boolValue];""",
         """            sw.on = LCGetBool(@"enabled", YES);""",
         "P3 enabled 读取")

p = rep(p, """        if (indexPath.row == 0) {
            cell.textLabel.text = @"字号";
            CGFloat fs = [(NSNumber *)LCGet(@"fontSize") doubleValue];
            if (fs < 10) fs = 28;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", fs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"粗体";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [(NSNumber *)LCGet(@"boldText") boolValue];""",
         """        if (indexPath.row == 0) {
            // v1.0.87：字号行 → 点开滑块选择器（不再是数字键盘输入）
            cell.textLabel.text = @"字幕字号";
            // 默认值与 tweak 保持一致（16）。原来这里写 28，
            // 与 tweak 实际的默认 16 不一致 → 用户看到「28」但画面是 16，误以为没生效。
            CGFloat fs = LCGetNum(@"fontSize", 16.0);
            if (fs < 10 || fs > 40) fs = 16.0;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", fs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"粗体";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"boldText", NO);""",
         "P4 字号行 + 粗体开关")

p = rep(p, """            double cs = [(NSNumber *)LCGet(@"asrChunkSeconds") doubleValue];
            if (cs < 1.0 || cs > 8.0) cs = 2.5;""",
         """            double cs = LCGetNum(@"asrChunkSeconds", 2.5);
            if (cs < 1.0 || cs > 8.0) cs = 2.5;""",
         "P5 分片时长读取")

p = rep(p, """            sw.on = [(NSNumber *)LCGet(@"showBilingual") boolValue];""",
         """            sw.on = LCGetBool(@"showBilingual", NO);""",
         "P6 showBilingual 读取")

p = rep(p, """    else if (indexPath.section == 2 && indexPath.row == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"字号"
                                                                       message:@"输入 10 - 32"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.keyboardType = UIKeyboardTypeNumberPad;
            CGFloat fs = [(NSNumber *)LCGet(@"fontSize") doubleValue];
            if (fs < 10) fs = 28;
            tf.text = [NSString stringWithFormat:@"%.0f", fs];
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            CGFloat v = alert.textFields.firstObject.text.doubleValue;
            if (v < 10) v = 10;
            if (v > 32) v = 32;
            LCSet(@(v), @"fontSize");
            [self.lc_tv reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }""",
         """    else if (indexPath.section == 2 && indexPath.row == 0) {
        // ===== v1.0.87：字号选择器（滑块 + 实时预览）=====
        // 原来是一个数字键盘输入框：要先点「字号」→ 弹键盘 → 输入 → 确定，
        // 步骤多、而且看不到效果，改完还要退出 App 才生效（tweak 侧读的是启动时缓存）。
        // 现在：独立的滑块页面，拖动即改、即时预览、即时写入，
        // tweak 侧改为实时读盘 + 0.4s 监听 → 字幕大小当场变化，不用重启 App。
        @try {
            LCFontSizeController *vc = [[LCFontSizeController alloc] init];
            UINavigationController *nav =
                [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:nav animated:YES completion:nil];
        } @catch (NSException *e) {
            NSLog(@"[LiveCapPrefs] font size picker failed: %@", e);
        }
    }""",
         "P7 字号行改为滑块页")

p = rep(p, """    if (section == 2)
        return @"字幕可长按拖动，位置按 App 记忆（重开 App 回到上次位置）。背景样式：无背景描边 / 半透明黑 / 实黑 / 半透明白 / 毛玻璃。\\n默认只显示中文译文一行；打开「显示英文原文」可恢复上下两行（英文在上、中文在下）。";""",
         """    if (section == 2)
        return @"字幕可长按拖动，位置按 App 记忆（重开 App 回到上次位置）。背景样式：无背景描边 / 半透明黑 / 实黑 / 半透明白 / 毛玻璃。\\n点「字幕字号」可用滑块调整大小，改完立即生效，无需重启 App。\\n默认只显示中文译文一行；打开「显示英文原文」可恢复上下两行（英文在上、中文在下）。";""",
         "P8 分区脚注")

p += """

#pragma mark - v1.0.87：字幕字号选择器（滑块 + 实时预览）

// 设计要点：
//   ① 滑块 10~40，与 tweak 侧 fontSize 的取值范围完全一致
//   ② 拖动时实时改预览文字（所见即所得）
//   ③ 数值变化即写入配置（tweak 实时读盘 + 0.4s 监听）→ 字幕当场变大/变小
//   ④ 快捷档位按钮（小/标准/大/特大），单手可点
//   ⑤ 默认值 16，与 tweak 实际默认一致（原来面板显示 28、实际 16，两边对不上）
@interface LCFontSizeController : UIViewController
@end

@implementation LCFontSizeController {
    UISlider *_slider;
    UILabel *_valueLabel;
    UILabel *_preview;
    double _value;
    double _lastWritten;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"字幕字号";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _value = [self lc_currentFontSize];
    _lastWritten = _value;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(lc_done)];

    // 说明文字
    UILabel *desc = [[UILabel alloc] init];
    desc.text = @"拖动滑块调整字幕字号，设置后立即生效，无需重启 App";
    desc.font = [UIFont systemFontOfSize:13];
    desc.textColor = [UIColor secondaryLabelColor];
    desc.numberOfLines = 0;
    desc.textAlignment = NSTextAlignmentCenter;
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:desc];

    // 当前数值
    _valueLabel = [[UILabel alloc] init];
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", _value];
    _valueLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_valueLabel];

    // 滑块
    _slider = [[UISlider alloc] init];
    _slider.minimumValue = 10.0;
    _slider.maximumValue = 40.0;
    _slider.value = (float)_value;
    _slider.minimumTrackTintColor = [UIColor systemBlueColor];
    [_slider addTarget:self
                action:@selector(lc_sliderChanged:)
      forControlEvents:UIControlEventValueChanged];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_slider];

    // 预览（模拟字幕样式：白字深色底）
    _preview = [[UILabel alloc] init];
    _preview.text = @"这是字幕预览效果 Example 123";
    _preview.numberOfLines = 0;
    _preview.textAlignment = NSTextAlignmentCenter;
    _preview.textColor = [UIColor whiteColor];
    _preview.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    _preview.layer.cornerRadius = 8.0;
    _preview.layer.masksToBounds = YES;
    _preview.font = [UIFont systemFontOfSize:(CGFloat)_value];
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_preview];

    // 快捷档位
    UIStackView *presets = [[UIStackView alloc] init];
    presets.axis = UILayoutConstraintAxisHorizontal;
    presets.distribution = UIStackViewDistributionFillEqually;
    presets.spacing = 8.0;
    NSArray *names = @[@"小 14", @"标准 18", @"大 24", @"特大 30"];
    NSArray *vals = @[@14, @18, @24, @30];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:names[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.backgroundColor = [UIColor secondarySystemBackgroundColor];
        b.layer.cornerRadius = 8.0;
        b.tag = [vals[i] integerValue];
        [b addTarget:self
                action:@selector(lc_presetTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        [presets addArrangedSubview:b];
    }
    presets.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:presets];

    // 布局
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [desc.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18],
        [desc.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [desc.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [_valueLabel.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:10],
        [_valueLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_valueLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [_slider.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:6],
        [_slider.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_slider.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [_preview.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:22],
        [_preview.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_preview.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_preview.heightAnchor constraintGreaterThanOrEqualToConstant:90],

        [presets.topAnchor constraintEqualToAnchor:_preview.bottomAnchor constant:18],
        [presets.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [presets.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [presets.heightAnchor constraintEqualToConstant:42],
    ]];
}

// 当前字号（与 tweak 侧范围一致：10~40，默认 16）
- (double)lc_currentFontSize {
    double fs = LCGetNum(@"fontSize", 16.0);
    if (fs < 10.0 || fs > 40.0) fs = 16.0;
    return fs;
}

- (void)lc_sliderChanged:(UISlider *)slider {
    double v = (double)slider.value;
    // 取整（字号没必要有小数）
    v = (double)(long long)(v + 0.5);
    if (v < 10.0) v = 10.0;
    if (v > 40.0) v = 40.0;
    _value = v;
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", v];
    _preview.font = [UIFont systemFontOfSize:(CGFloat)v];
    [self applyValue:v];
}

- (void)lc_presetTapped:(UIButton *)btn {
    _slider.value = (float)btn.tag;
    [self lc_sliderChanged:_slider];
}

// 写入配置：字号是整数，值没变就不写盘（拖动时不做无意义的文件写入）
- (void)applyValue:(double)v {
    if ((v - _lastWritten) < 0.5 && (_lastWritten - v) < 0.5) return;
    _lastWritten = v;
    LCSet(@((NSInteger)v), @"fontSize");
}

- (void)lc_done {
    @try {
        [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *e) {}
}

@end
"""
PATCHED.append("P9 LCFontSizeController 实现")

write(PANEL, p, crlf=False)

print("v1.0.87 补丁应用完成，共 %d 处：" % len(PATCHED))
for t in PATCHED:
    print("  -", t)
