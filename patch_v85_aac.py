#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.85 补丁：AAC 压缩上传 + 直连 session + 错误回退。

两条音频路径（processChunk: / processChunk16:）必须一致改造，
否则会出现「一条路径生效、另一条没生效」的隐性 bug（v1.0.84 就踩过）。
"""
import re
import sys

PATH = "LiveCap.m"

with open(PATH, "r", encoding="utf-8") as f:
    src = f.read()

orig_len = len(src)


def must(cond, msg):
    if not cond:
        print("FATAL: " + msg)
        sys.exit(1)
    print("  OK  " + msg)


# ------------------------------------------------------------------
# 1) WAV 构造 → 「先试 AAC，失败再 WAV」
#    用正则匹配，从 NSMutableData *wav 到 [wav appendData:pcm16]
# ------------------------------------------------------------------
WAV_RE = re.compile(
    r"(?P<ind>[ ]*)(?:// 2\) WAV 头（16bit mono 16k）\n)?"   # 主路径的注释行（可选）
    r"[ ]*NSMutableData \*wav = .*?\n"
    r".*?"
    r"[ ]*\[wav appendData:pcm16\];\n",
    re.DOTALL)

AAC_TMPL = """{ind}// 2) v1.0.85：优先 AAC 压缩上传。
{ind}// 依据（设备日志实测 2026-11-04）：ASR RTT ≈ 1.1 × 音频秒数，
{ind}// 而 Windows 本地同音频只要 0.3~0.6s。
{ind}// 拟合说明【上传实时音频要花音频那么久】——上行带宽约 255kbps，
{ind}// 而 PCM16@16k 恰好需要 256kbps，正好卡在带宽上限；
{ind}// 再叠加腾讯云 TC3 强制的 Base64 膨胀 33%，传输时间再 +33%。
{ind}// 改用 AAC-LC 16kbps 后体积降 8 倍（32000 B/s → 2000 B/s），
{ind}// 2.5 秒音频：81778 B → 约 10000 B → 上传时间 2.5s → 0.3s。
{ind}// 腾讯云一句话识别支持 VoiceFormat = "aac"（裸 AAC 流，无 ADTS 头）。
{ind}// 编码器不可用时返回 nil → 自动回退 WAV（速度退回 v1.0.84 水平）。
{ind}NSData *audioData = nil;
{ind}NSString *voiceFormat = @"wav";
{ind}if (!self->_aacBroken) {{
{ind}    NSData *aac = LCAACEncode16kMono(pcm16);
{ind}    if (aac.length >= 512) {{
{ind}        audioData = aac;
{ind}        voiceFormat = @"aac";
{ind}    }}
{ind}}}
{ind}if (!audioData) {{
{ind}    NSMutableData *wav = [NSMutableData dataWithCapacity:pcm16.length + 44];
{ind}    const char *riff = "RIFF";
{ind}    [wav appendBytes:riff length:4];
{ind}    uint32_t riffSize = (uint32_t)(36 + pcm16.length);
{ind}    [wav appendBytes:&riffSize length:4];
{ind}    const char *wave = "WAVE";
{ind}    [wav appendBytes:wave length:4];
{ind}    const char *fmt = "fmt ";
{ind}    [wav appendBytes:fmt length:4];
{ind}    uint32_t fmtSize = 16;
{ind}    [wav appendBytes:&fmtSize length:4];
{ind}    uint16_t audioFmt = 1;
{ind}    [wav appendBytes:&audioFmt length:2];
{ind}    uint16_t chn = 1;
{ind}    [wav appendBytes:&chn length:2];
{ind}    uint32_t rate = 16000;
{ind}    [wav appendBytes:&rate length:4];
{ind}    uint32_t byteRate = 16000 * 2;
{ind}    [wav appendBytes:&byteRate length:4];
{ind}    uint16_t blockAlign = 2;
{ind}    [wav appendBytes:&blockAlign length:2];
{ind}    uint16_t bits = 16;
{ind}    [wav appendBytes:&bits length:2];
{ind}    const char *data = "data";
{ind}    [wav appendBytes:data length:4];
{ind}    uint32_t dataSize = (uint32_t)pcm16.length;
{ind}    [wav appendBytes:&dataSize length:4];
{ind}    [wav appendData:pcm16];
{ind}    audioData = wav;
{ind}}}
"""


def wav_repl(m):
    ind = m.group("ind")[:16]
    return AAC_TMPL.format(ind=ind)


src, n = WAV_RE.subn(wav_repl, src)
must(n == 2, "WAV→AAC 改造 %d 处（期望 2）" % n)

# ------------------------------------------------------------------
# 2) base64 源切换
# ------------------------------------------------------------------
OLD = "NSString *b64 = [wav base64EncodedStringWithOptions:0];"
NEW = "NSString *b64 = [audioData base64EncodedStringWithOptions:0];"
n = src.count(OLD)
must(n == 2, "base64 源切换 %d 处（期望 2）" % n)
src = src.replace(OLD, NEW)

# ------------------------------------------------------------------
# 3) body 里的 VoiceFormat / DataLen 动态化
# ------------------------------------------------------------------
OLD = """                    @"VoiceFormat": @"wav",
                    @"UsrAudioKey": [NSString stringWithFormat:@"livecap-%@", [[NSUUID UUID] UUIDString]],
                    @"Data": b64,
                    @"DataLen": @(wav.length),"""
NEW = """                    @"VoiceFormat": voiceFormat,
                    @"UsrAudioKey": [NSString stringWithFormat:@"livecap-%@", [[NSUUID UUID] UUIDString]],
                    @"Data": b64,
                    @"DataLen": @(audioData.length),"""
n = src.count(OLD)
must(n == 2, "body VoiceFormat/DataLen 动态化 %d 处（期望 2）" % n)
src = src.replace(OLD, NEW)

# ------------------------------------------------------------------
# 4) sending 日志 + RTT 打点（两条路径都加毫秒级打点）
# ------------------------------------------------------------------
OLD_MAIN = """                LCLogF(@"asr: sending %lu bytes (%@)", (unsigned long)wav.length, eng);
                // v1.0.84：毫秒级打点。
                // 设备日志只有秒级精度，无法区分「RTT 4s」是网络还是服务端，
                // 这次加上毫秒计时，下次实测直接读数字。
                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;"""
NEW_MAIN = """                LCLogF(@"asr: sending %lu bytes (%@ fmt=%@)", (unsigned long)audioData.length,
                       eng, voiceFormat);
                // v1.0.84：毫秒级打点。
                // 设备日志只有秒级精度，无法区分「RTT 4s」是网络还是服务端，
                // 这次加上毫秒计时，下次实测直接读数字。
                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;"""
n = src.count(OLD_MAIN)
must(n == 1, "主路径 sending 日志 %d 处（期望 1）" % n)
src = src.replace(OLD_MAIN, NEW_MAIN)

OLD_RTT = """                    LCLogF(@"asr: rtt=%.0fms audio=%.2fs bytes=%lu",
                           rttMs, (double)wav.length / 32000.0, (unsigned long)wav.length);"""
NEW_RTT = """                    LCLogF(@"asr: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",
                           rttMs, (double)pcm16.length / 32000.0,
                           (unsigned long)audioData.length, voiceFormat);"""
n = src.count(OLD_RTT)
must(n == 1, "主路径 RTT 日志 %d 处（期望 1）" % n)
src = src.replace(OLD_RTT, NEW_RTT)

# 备用路径（asr16:）—— 补上毫秒级打点
OLD_16 = """                LCLogF(@"asr16: sending %lu bytes (%@)", (unsigned long)wav.length, eng);
                NSURLSessionDataTask *task = [_session dataTaskWithRequest:req"""
NEW_16 = """                LCLogF(@"asr16: sending %lu bytes (%@ fmt=%@)", (unsigned long)audioData.length,
                       eng, voiceFormat);
                // v1.0.85：备用路径也补上毫秒级打点（原来只有秒级日志）
                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
                NSURLSession *useSession = self->_directFailed ? self->_sessionProxy : self->_session;
                NSURLSessionDataTask *task = [useSession dataTaskWithRequest:req"""
n = src.count(OLD_16)
must(n == 1, "备用路径 sending 日志 %d 处（期望 1）" % n)
src = src.replace(OLD_16, NEW_16)

OLD_16_RTT = """                    LC_ASR_DONE();
                    if (err) { LCLogF(@"asr16: req err %@", err); return; }"""
NEW_16_RTT = """                    LC_ASR_DONE();
                    NSTimeInterval rttMs = ([NSDate date].timeIntervalSince1970 - t0) * 1000.0;
                    LCLogF(@"asr16: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",
                           rttMs, (double)pcm16.length / 32000.0,
                           (unsigned long)audioData.length, voiceFormat);
                    if (err) { LCLogF(@"asr16: req err %@", err); return; }"""
n = src.count(OLD_16_RTT)
must(n == 1, "备用路径 RTT 插入点 %d 处（期望 1）" % n)
src = src.replace(OLD_16_RTT, NEW_16_RTT)

# ------------------------------------------------------------------
# 5) 直连失败 → 永久回退走代理（主路径）
# ------------------------------------------------------------------
OLD_ERR = """                    if (err) {
                        LCLogF(@"asr: req err %@", err);
                        return;
                    }"""
NEW_ERR = """                    if (err) {
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
                    }"""
n = src.count(OLD_ERR)
must(n == 1, "主路径 err 处理 %d 处（期望 1）" % n)
src = src.replace(OLD_ERR, NEW_ERR)

# 备用路径
OLD_ERR16 = """                    if (err) { LCLogF(@"asr16: req err %@", err); return; }"""
NEW_ERR16 = """                    if (err) {
                        if (!self->_directFailed) {
                            self->_directFailed = YES;
                            self->_session = self->_sessionProxy;
                            LCLogF(@"asr16: direct failed (%@), fallback to proxy", err);
                        } else {
                            LCLogF(@"asr16: req err %@", err);
                        }
                        return;
                    }"""
n = src.count(OLD_ERR16)
must(n == 1, "备用路径 err 处理 %d 处（期望 1）" % n)
src = src.replace(OLD_ERR16, NEW_ERR16)

# ------------------------------------------------------------------
# 6) AAC 被腾讯云拒绝 → 永久回退 WAV
# ------------------------------------------------------------------
OLD_EMPTY = """                    NSDictionary *respD = json[@"Response"];
                    NSString *text = respD[@"Result"];
                    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
                        LCLogF(@"asr: empty result (%@)", json);
                        return;
                    }"""
NEW_EMPTY = """                    NSDictionary *respD = json[@"Response"];
                    if (respD[@"Error"]) {
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
                    }
                    NSString *text = respD[@"Result"];
                    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
                        LCLogF(@"asr: empty result (%@)", json);
                        return;
                    }"""
n = src.count(OLD_EMPTY)
must(n == 1, "主路径 empty result %d 处（期望 1）" % n)
src = src.replace(OLD_EMPTY, NEW_EMPTY)

OLD_EMPTY16 = """                    NSDictionary *respD = json[@"Response"];
                    NSString *text = respD[@"Result"];
                    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
                        LCLogF(@"asr16: empty result (%@)", json);
                        return;
                    }"""
NEW_EMPTY16 = """                    NSDictionary *respD = json[@"Response"];
                    if (respD[@"Error"]) {
                        if ([voiceFormat isEqualToString:@"aac"]) {
                            self->_aacBroken = YES;
                            LCLogF(@"asr16: aac rejected by tencent (%@), fallback to wav",
                                   respD[@"Error"]);
                        } else {
                            LCLogF(@"asr16: tencent error %@", respD[@"Error"]);
                        }
                        return;
                    }
                    NSString *text = respD[@"Result"];
                    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
                        LCLogF(@"asr16: empty result (%@)", json);
                        return;
                    }"""
n = src.count(OLD_EMPTY16)
must(n == 1, "备用路径 empty result %d 处（期望 1）" % n)
src = src.replace(OLD_EMPTY16, NEW_EMPTY16)

# ------------------------------------------------------------------
# 7) 主路径 session 选择
# ------------------------------------------------------------------
OLD_TASK = """                NSURLSessionDataTask *task = [_session dataTaskWithRequest:req"""
NEW_TASK = """                NSURLSession *useSession = self->_directFailed ? self->_sessionProxy : self->_session;
                NSURLSessionDataTask *task = [useSession dataTaskWithRequest:req"""
n = src.count(OLD_TASK)
must(n == 1, "主路径 task 创建 %d 处（期望 1，备用路径已单独处理）" % n)
src = src.replace(OLD_TASK, NEW_TASK)

with open(PATH, "w", encoding="utf-8") as f:
    f.write(src)

print("\nOK: LiveCap.m 已更新 (%d -> %d bytes)" % (orig_len, len(src)))
