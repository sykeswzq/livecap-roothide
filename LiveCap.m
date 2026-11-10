// LiveCap.m — roothide 实时视频字幕翻译 tweak (iOS 15-16, arm64e) v1.0.59
// 原理：swizzle AVPlayer 拿到 AVPlayerItem，挂 MTAudioProcessingTap 抓 PCM
//      → SFSpeech 实时转写（有授权时）；无授权自动切腾讯云一句话识别（在线 ASR）
//      → 原文经 OpenAI 兼容接口翻译（agnes）
//      → 悬浮双语字幕显示在 keyWindow.rootViewController.view（不新建 UIWindow）
// 依赖：AVFoundation / Speech / MediaToolbox / AudioToolbox / CommonCrypto
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Speech/Speech.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaToolbox/MTAudioProcessingTap.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CFNetwork/CFNetwork.h>
#import "fishhook.h"

// TC3 签名函数前置声明（定义在腾讯云 ASR 区，翻译区先调用）
static NSString *LCTencentAuthHeaderEx(NSString *secretId, NSString *secretKey,
                                       NSString *timestamp, NSString *date,
                                       NSData *payload, NSString *host,
                                       NSString *service, NSString *action,
                                       NSString *region);
static NSString *LCTencentAuthHeader(NSString *secretId, NSString *secretKey,
                                     NSString *timestamp, NSString *date,
                                     NSData *payload, NSString *host);

// ===== v1.0.85：ASR 并发上限 =====
// 背景：v1.0.84 之前 ASR 是完全串行的（_inFlight 布尔锁）。
// 设备实测（2026-11-04）ASR RTT ≈ 1.1 × 音频秒数，
// 串行时吞吐 = 音频时长 / RTT ≈ 1/1.1 = 0.91 实时率 →
// 字幕永远追不上语音，表现为「越播越滞后」。
// 改成 2 路并发后吞吐翻倍，可以跟上实时。
// v2.2.0：回落链路改回串行。2 路并发时两个 POST 的 RTT 不同，
// 后发的分片可能先返回，showPending 直接上屏会让字幕【顺序颠倒】
// （用户反馈「字幕和语音对不上」的来源之一）。回落只是兜底，稳定优先。
static const NSInteger LC_ASR_MAX_CONCURRENCY = 1;

// 请求结束时释放一个并发槽位（防止计数变负）
#define LC_ASR_DONE() do { \
    if (_inFlightCount > 0) _inFlightCount--; \
} while (0)

// ===== v1.0.87：AAC 编码（ADTS 封装，压缩上传）=====
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
// 调用方自动回退 WAV/PCM（速度退回 v1.0.84 水平，不会更差）。

typedef struct {
    const uint8_t *data;
    size_t len;
    size_t pos;
} LCPcmCursor;

// ===== AudioConverter 输入回调（按 SDK 真实签名）=====
// AudioConverter.h 权威原型：
//   typedef OSStatus (*AudioConverterComplexInputDataProc)(
//       AudioConverterRef               inAudioConverter,
//       UInt32 *                        ioNumberDataPackets,
//       AudioBufferList *               ioData,
//       AudioStreamPacketDescription ** outDataPacketDescription,
//       void *                          inUserData);
//
// 注意：第 3 参是 AudioBufferList*（不是 void**），
// 而且整个回调是 5 个参数、返回 OSStatus。
// 写成 3 参数版本会连着两轮 CI 报
// "incompatible function pointer types passing
//  'OSStatus (void *, UInt32 *, void **)'"。
static OSStatus LCAACInputProc(AudioConverterRef inConverter,
                               UInt32 *ioNumberDataPackets,
                               AudioBufferList *ioData,
                               AudioStreamPacketDescription **outDataPacketDescription,
                               void *inUserData) {
    LCPcmCursor *cur = (LCPcmCursor *)inUserData;
    size_t remain = cur->len - cur->pos;
    if (remain == 0) { *ioNumberDataPackets = 0; return noErr; }

    // ioNumberDataPackets 是「需要的最小包数」，16bit mono 每包 2 字节
    size_t want = (size_t)(*ioNumberDataPackets) * 2;
    size_t give = (remain < want) ? remain : want;

    // 必须把 ioData 的成员指向我们提供的 PCM 数据
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mDataByteSize = (UInt32)give;
    ioData->mBuffers[0].mData = (void *)(cur->data + cur->pos);

    cur->pos += give;
    *ioNumberDataPackets = (UInt32)(give / 2);
    // 输入是线性 PCM，没有包描述
    if (outDataPacketDescription) *outDataPacketDescription = NULL;
    return noErr;
}

// PCM16@16k mono → AAC-LC@16k mono（【ADTS 封装】的帧流）
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
    // 注意：这里【不能】打日志 —— LCLogF 的定义在本函数之后（文件里更靠后），
    // 在此处调用会报 "call to undeclared function 'LCLogF'"（CI 实证）。
    // 调用方（processChunk: / processChunk16:）会打 "asr: sending N bytes"，信息足够。
    (void)frames;
    return out;
}

// ===== v1.0.85：Session 工厂（ASR 直连 / 走代理）=====
// 背景：设备实测 ASR RTT ≈ 1.1 × 音频秒数 + 约 1.5s 固定开销，
// 而翻译（走 Cloudflare 边缘）只要 0.82s。
// 多出来的固定开销来自【系统 HTTP 代理】：请求先到境外代理节点再转发到腾讯云，
// 多出 2 个跨洋 RTT（腾讯云错误码 6001 也是这么提示的：
// 「国内站用户请检查是否使用境外代理，如果使用请关闭」）。
// 做法：ASR 请求禁用系统代理直连；若直连失败则永久回退到走代理。
static NSURLSession *LCSessionDirect(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSMutableDictionary *proxy = [NSMutableDictionary dictionary];
    // iOS 上只有 kCFNetworkProxiesHTTPEnable 可用，
    // kCFNetworkProxiesHTTPSEnable / kCFNetworkProxiesSOCKSEnable 标记为
    // "unavailable: not available on iOS"，直接用会导致 CI 编译失败。
    // 只关 HTTP 代理即可覆盖绝大多数境外代理工具的接管行为。
    [proxy setObject:@NO forKey:(__bridge NSString *)kCFNetworkProxiesHTTPEnable];
    [proxy setObject:@NO forKey:@"HTTPSEnable"];
    [proxy setObject:@NO forKey:@"SOCKSEnable"];
    cfg.connectionProxyDictionary = proxy;
    cfg.timeoutIntervalForRequest = 12.0;
    return [NSURLSession sessionWithConfiguration:cfg];
}

static NSURLSession *LCSessionDefault(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 12.0;
    return [NSURLSession sessionWithConfiguration:cfg];
}

#pragma mark - 日志

// ===== 高频日志节流 =====
// 背景：音频回调每秒触发数十次，直接写盘会把 livecap.log 刷到 10MB 级。
// 后果有两点：① 每次写盘都要 seek+write+close，拖慢 App；
//            ② 设备日志被刷屏，排查问题时根本看不到关键行。
// 做法：同一 key 在 minInterval 秒内只打印一次。
static NSMutableDictionary *gLogThrottle = nil;
static dispatch_once_t gLogThrottleOnce;

static BOOL LCLogThrottled(NSString *key, NSTimeInterval minInterval) {
    dispatch_once(&gLogThrottleOnce, ^{
        gLogThrottle = [NSMutableDictionary dictionary];
    });
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (gLogThrottle) {
        NSNumber *last = gLogThrottle[key];
        if (last && (now - [last doubleValue]) < minInterval) return NO;
        gLogThrottle[key] = @(now);
        return YES;
    }
}

// 日志轮转：超过 4MB 就归档为 .old，避免无限膨胀
static void LCRotateLogIfNeeded(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (!attrs) return;
    unsigned long long sz = [attrs fileSize];
    if (sz < 4ull * 1024ull * 1024ull) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *old = [path stringByAppendingString:@".old"];
    [fm removeItemAtPath:old error:NULL];
    [fm moveItemAtPath:path toPath:old error:NULL];
}

// 追加写一行到文件（不存在则创建）
static void LCAppendLine(NSString *path, NSData *data) {
    @try {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        } else {
            [data writeToFile:path atomically:YES];
        }
    } @catch (NSException *e) {}
}

static void LCLog(const char *msg) {
    NSLog(@"[LiveCap] %s", msg);
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"[%lld] %s\n",
                          (long long)[[NSDate date] timeIntervalSince1970], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        // 主写 App 沙盒容器 Documents（App Store App 一定可写；Filza 搜 livecap.log 可见）
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count) {
            NSString *p = [paths[0] stringByAppendingPathComponent:@"livecap.log"];
            LCRotateLogIfNeeded(p);
            LCAppendLine(p, data);
        }
        // 尽力写全局路径（App Store 沙盒可能拒绝，失败静默）
        // 注意：必须是【追加】，用 writeToFile:atomically: 会整文件覆盖，
        // 结果只留下最后一行，还每次都做一次完整文件写入。
        NSString *gp = @"/var/mobile/Documents/livecap.log";
        LCRotateLogIfNeeded(gp);
        LCAppendLine(gp, data);
    }
}

static void LCLogF(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LCLog([s UTF8String]);
}

#pragma mark - 配置（/var/mobile/Library/Preferences/com.sykes.livecap.plist，面板与 tweak 共用）

static NSString *LCJBRootPath(NSString *path) {
    // roothide 下 PreferenceBundle(SpringBoard) 与目标 App 进程路径不同，必须经 jbroot 解析
    void *sym = dlsym(RTLD_DEFAULT, "jbroot");
    if (sym) {
        typedef const char *(*fn_t)(const char *);
        fn_t fn = (fn_t)sym;
        @try {
            const char *real = fn([path UTF8String]);
            if (real) return [NSString stringWithUTF8String:real];
        } @catch (NSException *e) {}
    }
    return path;
}

@interface LCConfig : NSObject
+ (instancetype)shared;
@property (readonly) BOOL enabled;
@property (readonly) NSString *apiBase;
@property (readonly) NSString *apiKey;
@property (readonly) NSString *model;
@property (readonly) CGFloat fontSize;
@property (readonly) BOOL boldText;
@property (readonly) UIColor *textColor;
@property (readonly) NSString *backgroundStyle;
@property (readonly) BOOL showEnglish;   // 是否同时显示英文原文（默认 NO：只显示中文一行）
@property (readonly) BOOL strictSubtitleSync;  // v2.2.0：整句才送译（默认 YES，可回退）
@property (readonly) CGFloat manualX;
@property (readonly) CGFloat manualY;
- (void)saveManualX:(CGFloat)x y:(CGFloat)y;
- (void)writeConfig:(NSMutableDictionary *)d;
- (void)reload;
// v1.0.87：实时读盘取值（面板改完立即生效，不用重启 App）
- (id)freshValueForKey:(NSString *)key;
@end

@implementation LCConfig {
    NSDictionary *_d;
}

+ (instancetype)shared {
    static LCConfig *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LCConfig alloc] init]; [s reload]; });
    return s;
}

- (void)reload {
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
}

- (BOOL)enabled {
    NSNumber *v = _d[@"enabled"];
    return v ? [v boolValue] : YES;
}

- (NSString *)apiBase {
    NSString *s = _d[@"apiBase"];
    return (s && s.length) ? s : @"https://apihub.agnes-ai.cn/v1";
}

- (NSString *)apiKey {
    NSString *s = _d[@"apiKey"];
    return (s && s.length) ? s : @"";
}

- (NSString *)model {
    NSString *s = _d[@"model"];
    // v2.1.0 默认 agnes-3.0-flash（免费、非推理模型）。
    // 实测（2026-11-10，设备同款 payload 各 5 次）：
    //   2.5-flash：p50 1.09s / max 7.8s，带 reasoning_content，
    //     思维链吃光 256 token 时 content 返回空 → showFailed（日志里 15 次），
    //     碎片句还会回显英文。
    //   3.0-flash：p50 1.38s / max 17.4s，reasoning=0、不回显英文、译文更自然。
    // 3.0 有极端长尾，靠 3.5s 超时 + MyMemory 延迟兜底窗口兜住。
    return (s && s.length) ? s : @"agnes-3.0-flash";
}

- (NSString *)tencentSecretId {
    NSString *s = _d[@"tencentSecretId"];
    return (s && s.length) ? s : @"";
}

- (NSString *)tencentSecretKey {
    NSString *s = _d[@"tencentSecretKey"];
    return (s && s.length) ? s : @"";
}

// ===== v2.1.0：流式 ASR 配置 =====
// 注意「升级不覆盖已有 plist」这个坑：设备 plist 里可能没有这些新键，
// 所以每个都必须有代码默认值，不能只靠 postinst 预写。
- (NSString *)asrAppId {
    NSString *s = _d[@"asrAppId"];
    if (s.length) return s;
    // 账号 APPID（非密钥）。可用 cam:GetUserAppId 查；也可用 plist 覆盖。
    return @"1312073434";
}

- (NSString *)asrEngine {
    NSString *s = _d[@"asrEngine"];
    if (s.length) return s;
    // 16k_en 是账号已开通的通用引擎（实测 code=0）。
    // 大模型引擎 16k_multi_lang / 16k_zh_en / Hy-ASR-3.0-preview 属独立计费项，
    // 未开通后付费时会返回 4004；开通后把 asrEngine 改成对应值即可，无需重新编译。
    return @"16k_en";
}

- (BOOL)streamASREnabled {
    id v = _d[@"streamASR"];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return YES;   // 默认开：流式是 v2.1.0 的主路径，关掉则回到旧 HTTP 分片
}

// v2.2.0：严格同步（整句才送译）。关掉则回到 v2.1.1 的「中间结果定时兜底」，
// 便于真机对照，确认断句重构是否有效。
- (BOOL)strictSubtitleSync {
    id v = [self freshValueForKey:@"strictSubtitleSync"];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return YES;
}

// ===== v1.0.87：字号实时读盘，改完立即生效 =====
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
}

- (UIColor *)textColor {
    // 自定义任意颜色（hex：#RRGGBB / #RRGGBBAA，参考 XL 下拉时间取色器）
    NSString *hex = _d[@"textColorHex"];
    if (!hex || hex.length < 7) return [UIColor whiteColor];
    NSScanner *sc = [NSScanner scannerWithString:hex];
    [sc setScanLocation:1];
    unsigned rgb = 0;
    if (![sc scanHexInt:&rgb]) return [UIColor whiteColor];
    CGFloat a = 1.0;
    if (hex.length >= 9) {
        a = ((rgb & 0xFF) / 255.0);
        rgb = (rgb >> 8);
    }
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF)/255.0
                           green:((rgb >> 8) & 0xFF)/255.0
                            blue:(rgb & 0xFF)/255.0 alpha:a];
}

- (NSString *)backgroundStyle {
    NSString *s = _d[@"backgroundStyle"];
    return (s && s.length) ? s : @"frost";  // 默认毛玻璃
}

// v1.0.82：字幕只显示中文一行。
// 用户实测反馈「有时候是两行 一行英文 一行中文，我只要一行中文就行了」。
// 默认 NO（只中文）；用户可在设置面板切回「同时显示英文原文」。
//
// 【实时读盘】面板拨动开关后无需重启 App 立即生效：
// LCConfig 启动时把 plist 读进 _d 缓存，若继续读缓存则要重启才变。
// 这里每次直接读文件（renderCurrent 每句调用一次，开销可忽略）。
// 文件读不到时回退到缓存值。
- (BOOL)showEnglish {
    // v1.0.83：语义反转为 showBilingual（默认 NO = 只显示中文一行）。
    // 老版本用的 showEnglish 键语义相反（true=显示英文），且实测会被
    // 面板/tweak 竞争写覆写 → 曾经出现「明明写了 false 却变成 true」。
    // 现在只认 showBilingual，showEnglish 一律忽略，
    // 彻底消除「英文行莫名其妙出现」的可能。
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:p];
    if (fresh) {
        NSNumber *v = fresh[@"showBilingual"];
        return v ? [v boolValue] : NO;
    }
    NSNumber *v = _d[@"showBilingual"];
    return v ? [v boolValue] : NO;
}

- (NSDictionary *)manualPositions {
    NSDictionary *d = _d[@"manualPositions"];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

- (NSString *)bundleId {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"";
}

- (CGFloat)manualX {
    NSDictionary *mp = [self manualPositions];
    id p = mp[self.bundleId];
    if ([p isKindOfClass:[NSDictionary class]]) {
        NSNumber *v = p[@"x"];
        if (v && [v doubleValue] >= 0 && [v doubleValue] <= 1) return [v doubleValue];
    }
    return 0.5;
}

- (CGFloat)manualY {
    NSDictionary *mp = [self manualPositions];
    id p = mp[self.bundleId];
    if ([p isKindOfClass:[NSDictionary class]]) {
        NSNumber *v = p[@"y"];
        if (v && [v doubleValue] >= 0 && [v doubleValue] <= 1) return [v doubleValue];
    }
    return 0.35;
}

// v2.0.2：分片时长可在设置面板调节（键 asrChunkSeconds），默认 1.5 秒。
// 依据（2026-11-10 设备实测，v2.0.1，29 句样本）：
//   端到端 4.4s = 攒音 1.3s + 腾讯云 ASR 2.0s(p90 4.8s) + 翻译 1.2s。
//   v2.0.1 已修好串行队列，翻译不再是瓶颈；缩短分片可同时减少
//   「攒音等待」和「ASR 按音频时长计费的处理耗时」，是双重收益。
// 真实取值由 LCHttpASR 的 -lc_chunkSeconds 提供（带 2 秒缓存，避免音频回调高频读盘）。
#define LC_ASR_CHUNK_DEFAULT 1.5

// v1.0.83：统一的配置写回通道。
// 背景：面板用 CFPreferences 写、tweak 用文件直写，两套机制竞争同一个
// plist → 互相覆盖（实测 showEnglish 写好的 false 被覆写成 true）。
// 现在 tweak 侧统一走这个方法：
//   1. 每次都【重新读文件】拿最新快照（不���用可能过期的 _d）
//   2. 改完写回
//   3. 通知 cfprefsd 同步，保证 CFPreferences 视图与文件一致
- (void)writeConfig:(NSMutableDictionary *)d {
    @try {
        NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
        [d writeToFile:p atomically:YES];
        // 让 cfprefsd 重新加载磁盘内容，避免它用内存里的旧值覆盖回去
        CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.sykes.livecap");
    } @catch (NSException *e) {
        LCLog(@"config: write failed");
    }
}

- (void)saveManualX:(CGFloat)x y:(CGFloat)y {
    NSString *path = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    NSMutableDictionary *pos = [NSMutableDictionary dictionaryWithDictionary:
        [d[@"manualPositions"] isKindOfClass:[NSDictionary class]] ? d[@"manualPositions"] : @{}];
    pos[self.bundleId] = @{@"x": @(x), @"y": @(y)};
    d[@"manualPositions"] = pos;
    BOOL ok = [d writeToFile:path atomically:YES];
    if (ok) {
        // 与面板的 CFPreferences 视图保持一致，防止两边互相覆盖
        CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.sykes.livecap");
    }
    if (!ok) {
        // App 沙盒可能无法写全局 Preferences（roothide 路径映射 + 沙盒权限），
        // 退而求其次写自己的沙盒 Documents（至少本次会话内位置能保留）
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count) {
            NSString *fallback = [paths[0] stringByAppendingPathComponent:@"livecap_positions.plist"];
            NSMutableDictionary *fd = [NSMutableDictionary dictionaryWithContentsOfFile:fallback];
            if (!fd) fd = [NSMutableDictionary dictionary];
            NSMutableDictionary *fpos = [NSMutableDictionary dictionaryWithDictionary:
                [fd[@"manualPositions"] isKindOfClass:[NSDictionary class]] ? fd[@"manualPositions"] : @{}];
            fpos[self.bundleId] = @{@"x": @(x), @"y": @(y)};
            fd[@"manualPositions"] = fpos;
            [fd writeToFile:fallback atomically:YES];
            LCLogF(@"pos: global write failed, saved to sandbox %@", fallback);
        }
    }
    _d = d;  // 内存同步，下一次 show 直接生效
    LCLogF(@"pos: saved for %@ x=%.2f y=%.2f ok=%d", self.bundleId, x, y, ok);
}

@end

#pragma mark - 翻译（OpenAI 兼容 chat/completions）

@interface LCTranslator : NSObject
+ (instancetype)shared;
- (void)translate:(NSString *)text completion:(void (^)(NSString *result))completion;
// 串行翻译队列：同一时刻只有一条请求在飞，新文本覆盖排队中的旧文本
- (void)pumpQueue;
// 带重试的 OpenAI 兼容翻译（网络超时自动重试，最多 3 次）
- (void)openaiTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               apiKey:(NSString *)apiKey apiBase:(NSString *)apiBase
                  model:(NSString *)model attempt:(NSInteger)attempt
          maxAttempts:(NSInteger)maxAttempts
             completion:(void (^)(NSString *result))completion;
@end

@implementation LCTranslator {
    NSURLSession *_session;
    dispatch_queue_t _queue;
    NSMutableDictionary *_cache;
    NSMutableDictionary *_lastSentText;
    NSMutableDictionary *_lastSentTime;
    // ===== 串行化翻译请求 =====
    // 实测：并发 3 条请求时单条延迟从 2s 恶化到 10s（互相抢带宽），
    // 而 ASR 每 4~5s 就换一句 → 译文永远追不上，表现为「字幕框一直是英文」。
    // 现在同一时刻只允许一条在飞，新文本覆盖排队中的旧文本。
    // v1.0.82：单槽「只保留最新」会丢 completion
    //   —— 双语模式无感（画面靠 showPending 刷英文），
    //   —— 但中文单行模式下 completion 丢失 = 那句话的中文整句不显示。
    // 改为 FIFO 队列（有限长，超长时丢【最旧】的，因为它已经过时）。
    NSMutableArray *_pendingItems;   // 每项 = @{@"text": NSString, @"comp": block}
    BOOL _inflight;
    BOOL _tencentDisabled;   // 腾讯云机器翻译服务未开通时，本次会话内跳过
    // v2.0.2：agnes 免费额度限流后的暂停截止时间戳（0 = 正常参赛）
    NSTimeInterval _agnesPausedUntil;
}

+ (instancetype)shared {
    static LCTranslator *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[LCTranslator alloc] init];
        s->_session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
        s->_queue = dispatch_queue_create("com.sykes.livecap.translate", DISPATCH_QUEUE_SERIAL);
        s->_cache = [NSMutableDictionary dictionary];
        s->_lastSentText = [NSMutableDictionary dictionary];
        s->_lastSentTime = [NSMutableDictionary dictionary];
        s->_pendingItems = [NSMutableArray array];
    });
    return s;
}

- (void)translate:(NSString *)text completion:(void (^)(NSString *))completion {
    if (!text || text.length == 0) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;

    // v2.0.0：目标语言硬编码为中文，cacheKey 不再拼入语言参数
    NSString *cacheKey = [NSString stringWithFormat:@"|%@", trimmed];
    NSString *cached = nil;
    @synchronized(self) { cached = _cache[cacheKey]; }
    // 注意：必须同时判 length，否则空串（模型对乱码输入常返回空）会被当成有效缓存，
    // 导致这一句之后永远翻译不出来
    if (cached.length > 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    // 相同文本 1.0s 内不重复请求（partial 节流）
    NSNumber *nowN = @([[NSDate date] timeIntervalSince1970]);
    NSString *lastText = _lastSentText[cacheKey];
    NSNumber *lastTime = _lastSentTime[cacheKey];
    if (lastText && [lastText isEqualToString:trimmed] && lastTime &&
        ([nowN doubleValue] - [lastTime doubleValue]) < 1.0) {
        // 1 秒内的重复句：命中缓存就回缓存，否则回调 nil（保持状态一致，
        // 不能静默 return —— 否则这句的 completion 永远不执行，中文会整句丢失）
        NSString *dupCached = nil;
        @synchronized(self) { dupCached = _cache[cacheKey]; }
        if (dupCached.length > 0) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(dupCached); });
        } else if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        }
        return;
    }
    _lastSentText[cacheKey] = trimmed;
    _lastSentTime[cacheKey] = nowN;

    // ===== 入队（串行化 FIFO）=====
    // 翻译是异步的，比 ASR 慢。若允许多条请求并发：
    //   ① 互相抢带宽，单条延迟从 <1s 恶化到 10s，译文永远追不上字幕；
    //   ② 回调乱序，英文与中文错配。
    // 因此同一时刻只允许一条在飞，其余排队。
    //
    // v1.0.82 修正：原来排队是「单槽 + 新文本覆盖旧文本」，
    // 被覆盖那条的 completion 永远不会执行 →
    // 双语模式看不出（画面已由 showPending 刷了英文），
    // 中文单行模式下那句话的中文会整句消失。
    // 现在改为 FIFO 队列，每句都保证有回调；队列过长时丢【最旧】的
    // （它已经落后于语音太多，显示出来反而是错的）。
    dispatch_async(_queue, ^{
        // 注意：completion 是 block 类型，不能写成 completion ?: [NSNull null]
        //   —— ?: 运算符要求两侧类型一致，block 与 NSNull* 混用会编译报错
        //      (incompatible operand types: 'void (^)(NSString *)' and 'NSNull *')
        // 这里统一用 id 承载，取出时再显式 cast 回 block。
        id compBox = completion ? (id)completion : (id)[NSNull null];
        [self->_pendingItems addObject:@{@"text": trimmed, @"comp": compBox}];
        // v2.2.0：kMaxQueue=1 时每来一句就丢掉排队中的上一句，配合 3~5s 的
        // 翻译 RTT 会让大量句子【整句不显示】，表现为字幕跳句、和语音对不上。
        // 放宽到 3；真正过时的译文由 showPair 按最新句 seq 丢弃，不会错配上屏。
        const NSUInteger kMaxQueue = 3;
        while (self->_pendingItems.count > kMaxQueue) {
            NSDictionary *dropped = self->_pendingItems.firstObject;
            [self->_pendingItems removeObjectAtIndex:0];
            id dc = dropped[@"comp"];
            LCLogF(@"translate: queue overflow, drop oldest text=[%@]", dropped[@"text"]);
            if (dc && dc != [NSNull null]) {
                void (^dcomp)(NSString *) = (void (^)(NSString *))dc;
                dispatch_async(dispatch_get_main_queue(), ^{ dcomp(nil); });
            }
        }
        [self pumpQueue];
    });
}

// 串行翻译队列：同一时刻只允许一条请求在飞。
// 保证回调顺序与 ASR 顺序一致，字幕框里英文/中文永远成对。
- (void)pumpQueue {
    if (_inflight) return;
    if (_pendingItems.count == 0) return;
    NSDictionary *item = _pendingItems.firstObject;
    [_pendingItems removeObjectAtIndex:0];
    NSString *text = item[@"text"];
    if (!text.length) { [self pumpQueue]; return; }
    id rawComp = item[@"comp"];
    void (^comp)(NSString *) = nil;
    if (rawComp && rawComp != [NSNull null]) {
        comp = (void (^)(NSString *))rawComp;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"|%@", text];
    NSString *cached = nil;
    @synchronized(self) { cached = _cache[cacheKey]; }
    if (cached.length > 0) {
        if (comp) dispatch_async(dispatch_get_main_queue(), ^{ comp(cached); });
        [self pumpQueue];
        return;
    }

    _inflight = YES;

    // v2.0.0：目标语言硬编码为中文
    // ===== prompt 精简（v1.0.81）=====
    // 实测（设备 → apihub.agnes-ai.cn 网关）：
    //   agnes-3.0-flash + 1401 字节长 prompt → 29~40s（必然超时）
    //   agnes-2.5-flash +  232 字节中 prompt → 0.96~7.6s（可用）
    // 长 prompt 不只是慢，还会显著抬高网关排队时间。
    // 这里保留最关键的三条约束（只输出译文 / 输入可能是脏片段要照翻 / 绝不回显英文），
    // 去掉示例和冗长规则，压到 ~230 字节。
    // v2.0.0：目标语言硬编码为中文，直接写死在 sysPrompt 里
    // v2.2.0：改回「忠实直译」。
    // v2.1.0 让模型顺手纠错、补全截断词，实测会把碎片脑补成另一句完整话，
    // 译文和 YouTube 原版字幕对不上（用户反馈）。字幕翻译必须逐字忠实，
    // 宁可译出半句，也不要替观众猜内容。
    NSString *sysPrompt = @"You are a subtitle translator. Translate the given speech-to-text "
        @"fragment faithfully into natural Simplified Chinese. Keep the original meaning and word "
        @"order; do NOT add, infer, complete, summarize or correct anything absent from the input. "
        @"If the input is an incomplete fragment, translate only that fragment and leave it "
        @"incomplete. Output ONLY the Chinese translation: no quotes, no explanation, no English. "
        @"NEVER echo the input.";

    __weak typeof(self) weakSelf = self;
    NSDate *t0 = [NSDate date];
    [self raceTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
             completion:^(NSString *result) {
        LCLogF(@"translate: inflight rtt=%lldms len=%lu",
               (long long)([[NSDate date] timeIntervalSinceDate:t0] * 1000),
               (unsigned long)result.length);
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf->_queue, ^{
            strongSelf->_inflight = NO;
            if (comp) dispatch_async(dispatch_get_main_queue(), ^{ comp(result); });
            [strongSelf pumpQueue];
        });
    }];
}

// v2.0.0：目标语言固定为中文，译文校验只需检查是否含中文字符
- (BOOL)isUsableTranslation:(NSString *)res forText:(NSString *)text {
    if (!res.length) return NO;
    NSString *norm = [res stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!norm.length) return NO;
    NSString *orig = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([norm isEqualToString:orig]) return NO;
    BOOL hasCJK = NO;
    for (NSUInteger i = 0; i < norm.length; i++) {
        unichar ch = [norm characterAtIndex:i];
        if (ch >= 0x4E00 && ch <= 0x9FFF) { hasCJK = YES; break; }
    }
    if (!hasCJK) return NO;
    return YES;
}

// ===== 并行竞速翻译（v1.0.81）=====
// 背景：串行 fallback 的致命问题是「等最慢的那家」。
//   旧顺序 agnes → mymemory → tencent，而 agnes 单次实测 29~40s，
//   串起来一句要 45s+，字幕永远追不上语音（实测画面停在第一句 51 秒）。
// 改成并行发出，谁先返回【有效译文】谁获胜，其余结果直接丢弃：
//   实测 agnes-2.5-flash 0.87~3.4s、MyMemory 1.25~2.4s，
//   竞速后整体延迟 = min(两者) ≈ 1s。
// 竞速天然提供了冗余：一家失败另一家顶上，不再需要靠重试放大延迟。
- (void)raceTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
             completion:(void (^)(NSString *result))completion {
    NSString *apiKey = [[LCConfig shared] apiKey];
    NSString *apiBase = [[LCConfig shared] apiBase];
    NSString *model = [[LCConfig shared] model];

    // 参赛厂商
    // v2.0.2：agnes 免费额度报「速率限制」后暂停 90 秒，不再发无效请求。
    // 设备实测 22 次 provider 失败几乎全是这个错误：白跑一个 HTTPS 请求，
    // 还会和 ASR 抢上行带宽（ASR p90 高达 4.8s）。MyMemory 始终是兜底。
    NSMutableArray *providers = [NSMutableArray array];
    BOOL tencentDisabled = NO;
    BOOL agnesPaused = NO;
    @synchronized(self) {
        tencentDisabled = _tencentDisabled;
        agnesPaused = (_agnesPausedUntil > 0 &&
                       [NSDate timeIntervalSinceReferenceDate] < _agnesPausedUntil);
    }
    if (apiKey.length && apiBase.length && !agnesPaused) [providers addObject:@"agnes"];
    [providers addObject:@"mymemory"];               // 永远保留的免费兜底
    NSString *secretId = [[LCConfig shared] tencentSecretId];
    NSString *secretKey = [[LCConfig shared] tencentSecretKey];
    if (!tencentDisabled && secretId.length && secretKey.length) [providers addObject:@"tencent"];

    // 竞速状态：pending=未结束请求数，won=是否已有赢家
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"pending"] = @(providers.count);
    state[@"won"] = @NO;

    // 单个厂商的回调
    void (^onResult)(NSString *, NSString *) = ^(NSString *provider, NSString *res) {
        BOOL accept = NO;
        BOOL allFailed = NO;
        @synchronized (state) {
            BOOL won = [state[@"won"] boolValue];
            if (!won && res.length && [self isUsableTranslation:res forText:text]) {
                state[@"won"] = @YES;
                accept = YES;
            } else {
                if (res.length) {
                    LCLogF(@"translate: provider '%@' unusable (原文回显或无中文)", provider);
                } else {
                    LCLogF(@"translate: provider '%@' failed", provider);
                }
                NSInteger p = [state[@"pending"] integerValue] - 1;
                state[@"pending"] = @(p);
                // 所有厂商都失败 → 整句翻译失败
                if (p <= 0 && !won) allFailed = YES;
            }
        }
        if (accept) {
            @synchronized(self) {
                _cache[cacheKey] = res;
                if (_cache.count > 300) [_cache removeAllObjects];
            }
            LCLogF(@"translate: provider '%@' WON len=%lu", provider, (unsigned long)res.length);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(res); });
        } else if (allFailed) {
            LCLogF(@"translate: race all failed text=[%@]", text);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        }
    };

    // v2.1.0 给 agnes 2.5 秒优先窗口，v2.2.0 压到 1.0 秒。
    // 纯竞速下 MyMemory 0.6~1.1s 恒快于 agnes 1.4s → 会系统性选到质量差的
    // 兜底译文（还会回显上一句）。但 2.5s 窗口 + agnes 3.5s 超时会让失败路径
    // 拖到 3.7~4.9s，比 ASR 产句还慢，队列必然积压 → 字幕越播越滞后。
    // 1.0s 既让 agnes 先跑，又保证兜底能在 2.5s 内上屏。
    BOOL preferAgnes = [providers containsObject:@"agnes"];

    // 并行发出全部请求
    for (NSString *provider in providers) {
        NSString *p = [provider copy];
        if ([p isEqualToString:@"tencent"]) {
            LCLogF(@"translate: race -> tencent");
            [self tencentTranslate:text systemPrompt:sysPrompt cacheKey:cacheKey
                          secretId:secretId secretKey:secretKey
                       completion:^(NSString *r) { onResult(p, r); }];
        } else if ([p isEqualToString:@"agnes"]) {
            LCLogF(@"translate: race -> agnes model=%@", model);
            [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                          apiKey:apiKey apiBase:apiBase model:model maxAttempts:1
                       completion:^(NSString *r) { onResult(p, r); }];
        } else {
            LCLogF(@"translate: race -> mymemory%@", preferAgnes ? @" (delayed 1.0s)" : @"");
            void (^fireMyMemory)(void) = ^{
                BOOL alreadyWon = NO;
                @synchronized (state) { alreadyWon = [state[@"won"] boolValue]; }
                if (alreadyWon) return;   // agnes 已赢，别再发无效请求抢上行带宽
                [self mymemoryTranslate:text
                             completion:^(NSString *r) { onResult(p, r); }];
            };
            if (preferAgnes) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), fireMyMemory);
            } else {
                fireMyMemory();
            }
        }
    }
}

// MyMemory 会把 ' " & < > 转成 HTML 实体，直接上屏会显示成 &#39; 这种乱码。
// 这里做一次还原（只处理常见的几种，避免引入 NSAttributedString 的额外依赖开销）。
static NSString *LCDecodeHTMLEntities(NSString *s) {
    if (!s.length) return s;
    if ([s rangeOfString:@"&"].location == NSNotFound) return s;
    NSMutableString *m = [s mutableCopy];
    NSDictionary *map = @{
        @"&#39;": @"'", @"&apos;": @"'", @"&quot;": @"\"",
        @"&amp;":  @"&",  @"&lt;":   @"<", @"&gt;":   @">",
        @"&#34;": @"\"", @"&nbsp;": @" ",
    };
    for (NSString *k in map) {
        [m replaceOccurrencesOfString:k withString:map[k]
                               options:NSLiteralSearch range:NSMakeRange(0, m.length)];
    }
    return [m copy];
}

// 语言代码：BCP-47 -> MyMemory 格式（zh 用 zh-CN，其余取前缀）
static NSString *LCShortLang(NSString *lc) {
    if ([lc hasPrefix:@"zh"]) return @"zh-CN";
    if ([lc hasPrefix:@"ja"]) return @"ja";
    if ([lc hasPrefix:@"ko"]) return @"ko";
    if ([lc hasPrefix:@"fr"]) return @"fr";
    if ([lc hasPrefix:@"de"]) return @"de";
    if ([lc hasPrefix:@"es"]) return @"es";
    if ([lc hasPrefix:@"ru"]) return @"ru";
    if ([lc hasPrefix:@"ar"]) return @"ar";
    return @"en";
}

// v2.0.0：目标语言固定为中文；MyMemory 免费翻译（GET api.mymemory.translated.net，无需密钥）
- (void)mymemoryTranslate:(NSString *)text completion:(void (^)(NSString *result))completion {
    // v2.0.0 修复：MyMemory 不接受 langpair 里的 "auto"（设备实测 403
    // "'AUTO' IS AN INVALID SOURCE LANGUAGE"），此前免费兜底 100% 失败。
    // 目标语言固定 zh-CN；源语言按英文处理（非英文源由 agnes 竞速兜住）。
    NSString *src = @"en";
    NSString *dst = @"zh-CN";
    // 关键：langpair 的分隔符 | 属于 URL 保留字符，必须百分号编码，
    // 否则 NSURL 报 -1002 (unsupported URL)，MyMemory 永远失败
    NSString *langPair = [NSString stringWithFormat:@"%@%%7C%@", src, dst];
    NSString *urlStr = [NSString stringWithFormat:
        @"https://api.mymemory.translated.net/get?q=%@&langpair=%@",
        [text stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]],
        langPair];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:@"LiveCap/1.0" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 6.0;
    LCLogF(@"translate: mymemory request url=%@", urlStr);
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskErr) {
        if (taskErr) {
            LCLogF(@"translate: mymemory req err %@ url=%@", taskErr, urlStr);
            if (completion) completion(nil);
            return;
        }
        NSError *__autoreleasing pe = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
        if (pe || !json) {
            LCLogF(@"translate: mymemory parse err %@ data len=%lu", pe, (unsigned long)data.length);
            if (completion) completion(nil);
            return;
        }
        NSDictionary *rd = json[@"responseData"];
        NSString *content = rd[@"translatedText"];
        LCLogF(@"translate: mymemory response status=%@ content=[%@]", json[@"responseStatus"], content);
        if (![content isKindOfClass:[NSString class]] || content.length == 0) { if (completion) completion(nil); return; }
        // 空查询/警告时不当作结果
        if ([content hasPrefix:@"NO QUERY SPECIFIED"] || [content hasPrefix:@"MY MEMORY WARNING"]) { if (completion) completion(nil); return; }
        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // MyMemory 会把引号等转成 HTML 实体（&#39; &quot; &amp;），必须还原
        result = LCDecodeHTMLEntities(result);
        // 注意：这里【不】写缓存。
        // 竞速模式下 provider 内部写缓存会出问题：
        //   ① 慢的那家回来后会把胜出的译文覆盖掉；
        //   ② 更糟的是返回「英文回显」的结果被写进缓存，
        //      之后同一句再翻译会直接命中这个坏缓存，永远显示英文。
        // 缓存统一由 raceTranslate 的胜出方写入。
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    }];
    [task resume];
}

// 腾讯云机器翻译 TextTranslate（TC3 签名，2018-03-21；免费每月 500 万字符）
// 语言代码映射：LCConfig 的 BCP-47 (en-US/ja-JP/…) -> ISO 639-1 (en/ja/…)
static NSString *LCTmtLang(NSString *lcLang) {
    if ([lcLang hasPrefix:@"zh"]) return @"zh";
    if ([lcLang hasPrefix:@"ja"]) return @"ja";
    if ([lcLang hasPrefix:@"ko"]) return @"ko";
    if ([lcLang hasPrefix:@"fr"]) return @"fr";
    if ([lcLang hasPrefix:@"de"]) return @"de";
    if ([lcLang hasPrefix:@"es"]) return @"es";
    if ([lcLang hasPrefix:@"ru"]) return @"ru";
    if ([lcLang hasPrefix:@"ar"]) return @"ar";
    return @"en";
}

- (void)tencentTranslate:(NSString *)text systemPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               secretId:(NSString *)secretId secretKey:(NSString *)secretKey
             completion:(void (^)(NSString *result))completion {
    if (text.length > 1800) text = [text substringToIndex:1800];  // TextTranslate 单次上限
    NSString *src = LCTmtLang(@"auto-detected");
    NSString *dst = LCTmtLang(@"zh-CN");
    NSDictionary *body = @{
        @"SourceText": text,
        @"Source": src,
        @"Target": dst,
        @"ProjectId": @0
    };
    NSError *__autoreleasing err = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err || !payload) { LCLogF(@"translate: tencent json err %@", err); if (completion) completion(nil); return; }

    long long ts = (long long)[[NSDate date] timeIntervalSince1970];
    NSString *tsStr = [NSString stringWithFormat:@"%lld", ts];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd"];
    [df setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
    NSString *dateStr = [df stringFromDate:[NSDate date]];

    NSString *host = @"tmt.tencentcloudapi.com";
    NSString *auth = LCTencentAuthHeaderEx(secretId, secretKey, tsStr, dateStr, payload, host,
                                           @"tmt", @"texttranslate", @"ap-guangzhou");

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://tmt.tencentcloudapi.com"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:host forHTTPHeaderField:@"Host"];
    [req setValue:@"TextTranslate" forHTTPHeaderField:@"X-TC-Action"];
    [req setValue:@"2018-03-21" forHTTPHeaderField:@"X-TC-Version"];
    [req setValue:tsStr forHTTPHeaderField:@"X-TC-Timestamp"];
    [req setValue:@"ap-guangzhou" forHTTPHeaderField:@"X-TC-Region"];
    [req setValue:auth forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = payload;
    req.timeoutInterval = 6.0;

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskErr) {
        if (taskErr) {
            LCLogF(@"translate: tencent req err %@", taskErr);
            if (completion) completion(nil);
            return;
        }
        NSError *__autoreleasing parseErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr || !json) { LCLogF(@"translate: tencent parse err %@", parseErr); if (completion) completion(nil); return; }
        NSDictionary *respD = json[@"Response"];
        if (respD[@"Error"]) {
            LCLogF(@"translate: tencent api err %@", respD[@"Error"]);
            // 「服务未开通」是账号级永久错误，重试无意义。
            // 一旦遇到，本次会话内直接把腾讯云翻译拉黑，
            // 避免每一句都先白跑一次注定失败的往返（实测拖慢约 1s/句）。
            NSString *code = respD[@"Error"][@"Code"];
            NSString *msg = respD[@"Error"][@"Message"];
            if ([code isEqualToString:@"FailedOperation.UserNotRegistered"] ||
                [msg containsString:@"has not been opened"]) {
                @synchronized(self) { self->_tencentDisabled = YES; }
                LCLogF(@"translate: tencent disabled for this session (service not opened)");
            }
            if (completion) completion(nil);
            return;
        }
        NSString *content = respD[@"TargetText"];
        if (![content isKindOfClass:[NSString class]] || content.length == 0) {
            LCLogF(@"translate: tencent empty target (%@)", json);
            if (completion) completion(nil);
            return;
        }
        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // 同样不在 provider 内部写缓存，统一由竞速层负责
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    }];
    [task resume];
}

// OpenAI 兼容翻译（agnes AI / 任何兼容的 chat/completions 接口）
- (void)openaiTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               apiKey:(NSString *)apiKey apiBase:(NSString *)apiBase
                  model:(NSString *)model maxAttempts:(NSInteger)maxAttempts
             completion:(void (^)(NSString *result))completion {
    [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                   apiKey:apiKey apiBase:apiBase model:model
                  attempt:0 maxAttempts:maxAttempts completion:completion];
}

// 带重试的内部实现：agnes 网关存在间歇性超时（实测约 3 成请求 -1001），
// 单次失败直接顺延到下一个 provider 会导致「一直显示英文」，
// 因此对网络类错误（超时/连接失败）在同一 provider 上重试。
- (void)openaiTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               apiKey:(NSString *)apiKey apiBase:(NSString *)apiBase
                  model:(NSString *)model attempt:(NSInteger)attempt maxAttempts:(NSInteger)maxAttempts
             completion:(void (^)(NSString *result))completion {
    if (text.length > 1800) text = [text substringToIndex:1800];
    NSString *trimmedModel = model.length ? model : @"agnes-3.0-flash";
    // 动态 max_tokens：每行最多 96 token，最少 256，最多 2048
    NSUInteger lineCount = [text componentsSeparatedByString:@"\n"].count;
    NSInteger maxTokens = (NSInteger)(lineCount * 96);
    if (maxTokens < 256) maxTokens = 256;
    if (maxTokens > 2048) maxTokens = 2048;
    NSDictionary *body = @{
        @"model": trimmedModel,
        @"messages": @[
            @{@"role": @"system", @"content": sysPrompt},
            @{@"role": @"user",   @"content": text}
        ],
        @"temperature": @0.3,
        @"top_p": @0.6,
        @"max_tokens": @(maxTokens)
    };
    NSError *__autoreleasing err = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err || !payload) { LCLogF(@"translate: openai json err %@", err); if (completion) completion(nil); return; }

    // 诊断：打印实际发出的报文（前 500 字节）
    // 只有拿到设备端真实 payload 才能判断是「请求被改」还是「响应被改」
    {
        NSString *raw = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] ?: @"(非UTF8)";
        NSString *head = raw.length > 500 ? [raw substringToIndex:500] : raw;
        if (LCLogThrottled(@"payload", 15.0)) {
            LCLogF(@"translate: PAYLOAD len=%lu head=[%@]", (unsigned long)payload.length, head);
        }
    }

    // 拼接 API URL（可能以 / 结尾）
    NSString *chatUrl = [apiBase hasSuffix:@"/"] ? [apiBase stringByAppendingString:@"chat/completions"]
                                                 : [apiBase stringByAppendingString:@"/chat/completions"];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:chatUrl]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    // 必须显式设置 User-Agent：
    // NSURLSession 默认发 "LiveCap/1.0.68 CFNetwork/xxx Darwin/xxx"，
    // 实测该 UA 会让部分 AI 网关的模型退化（直接回显英文原文，不翻译）。
    // 换成普通客户端标识后翻译恢复正常。
    [req setValue:@"LiveCap/1.0" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = payload;
    // v2.0.0 修复：竞速【全部失败】时 _inflight 要等最慢的一路超时才释放，
    // 30s 会把串行翻译队列堵死（设备日志实测中文滞后 5~8s、大量 showFailed）。
    // v2.1.0：agnes-3.0-flash p50 1.38s，但实测有 17.4s 级长尾（历史注释
    // 里甚至出现过 29~40s）。压到 3.5s：正常请求都能回，长尾直接放弃，
    // 交给延迟窗口里发出的 MyMemory 兜底，不让串行翻译队列被卡住。
    req.timeoutInterval = 3.5;

    LCLogF(@"translate: openai request url=%@ model=%@ attempt=%ld", chatUrl, trimmedModel, (long)attempt);
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskErr) {
        // v2.0.2：网关限流识别。agnes 免费额度限流返回的是 HTTP 200 +
        // {"error":{"message":"...速率限制..."}}，不是 429，所以状态码和响应体都要判。
        // 命中后暂停 90 秒参赛，到期自动恢复；只针对 agnes 域名，不误伤自建 API。
        BOOL isAgnes = ([apiBase rangeOfString:@"agnes"
                                      options:NSCaseInsensitiveSearch].location != NSNotFound);
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        if (isAgnes && (status == 429 || status == 403)) {
            @synchronized(self) {
                _agnesPausedUntil = [NSDate timeIntervalSinceReferenceDate] + 90.0;
            }
            LCLogF(@"translate: agnes http %ld -> pause 90s", (long)status);
        }
        if (taskErr) {
            LCLogF(@"translate: openai req err %@ url=%@ attempt=%ld", taskErr, chatUrl, (long)attempt);
            // 网络类错误（超时/连接中断）→ 退避后重试同一 provider
            BOOL retryable = ([taskErr.domain isEqualToString:NSURLErrorDomain] &&
                              (taskErr.code == NSURLErrorTimedOut ||
                               taskErr.code == NSURLErrorNetworkConnectionLost ||
                               taskErr.code == NSURLErrorCannotConnectToHost ||
                               taskErr.code == NSURLErrorCannotFindHost ||
                               taskErr.code == NSURLErrorDNSLookupFailed));
            // 重试次数由调用方指定：竞速模式下 maxAttempts=1（即不重试），
            // 因为另一家厂商已经在并行跑了，重试只会白白放大延迟。
            if (retryable && attempt < maxAttempts) {
                NSTimeInterval delay = 0.8 * (attempt + 1);
                LCLogF(@"translate: openai retry in %.1fs (attempt %ld -> %ld)", delay, (long)attempt, (long)(attempt + 1));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                                   apiKey:apiKey apiBase:apiBase model:model
                                  attempt:attempt + 1 maxAttempts:maxAttempts completion:completion];
                });
                return;
            }
            if (completion) completion(nil);
            return;
        }
        NSError *__autoreleasing pe = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
        if (pe || !json) {
            LCLogF(@"translate: openai parse err %@ data len=%lu", pe, (unsigned long)data.length);
            if (completion) completion(nil);
            return;
        }
        // 解析响应
        // 诊断：先打印原始响应前 600 字节 —— 确认服务端到底返回了什么
        {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!raw) raw = [NSString stringWithFormat:@"(binary %lu bytes)",
                             (unsigned long)data.length];
            NSString *head = raw.length > 600 ? [raw substringToIndex:600] : raw;
            if (LCLogThrottled(@"raw", 15.0)) {
                LCLogF(@"translate: RAW len=%lu head=[%@]", (unsigned long)data.length, head);
            }
            // 额外：打印 content 字段的字节数和中文字符数
            NSDictionary *j = json;
            NSArray *chs = j[@"choices"];
            if ([chs count] > 0) {
                NSDictionary *msg = chs[0][@"message"];
                NSString *c = msg[@"content"];
                if ([c isKindOfClass:[NSString class]]) {
                    LCLogF(@"translate: content len=%lu bytes=[%.*s]", (unsigned long)c.length, (int)MIN(100, c.length), [c UTF8String]);
                }
            }
        }
        // v2.0.2：HTTP 200 但响应体是 {"error":{...}} 的限流场景
        NSDictionary *gwErr = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
        NSString *gwMsg = [gwErr isKindOfClass:[NSDictionary class]] ? gwErr[@"message"] : nil;
        if (isAgnes && [gwMsg isKindOfClass:[NSString class]] &&
            ([gwMsg rangeOfString:@"速率限制"].location != NSNotFound ||
             [gwMsg rangeOfString:@"Token Plan"].location != NSNotFound ||
             [gwMsg rangeOfString:@"rate" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            @synchronized(self) {
                _agnesPausedUntil = [NSDate timeIntervalSinceReferenceDate] + 90.0;
            }
            LCLogF(@"translate: agnes rate-limited -> pause 90s");
        }
        NSArray *choices = json[@"choices"];
        if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) {
            LCLogF(@"translate: openai no choices (%@)", json);
            if (completion) completion(nil);
            return;
        }
        NSDictionary *firstChoice = choices[0];
        NSDictionary *msg = firstChoice[@"message"];
        NSString *content = msg[@"content"];
        if (![content isKindOfClass:[NSString class]] || content.length == 0) {
            LCLogF(@"translate: openai empty content (%@)", json);
            if (completion) completion(nil);
            return;
        }
        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        LCLogF(@"translate: openai response len=%lu text=[%@]", (unsigned long)result.length, result);
        // 不在这里写缓存 —— 竞速模式下会覆盖胜出方的结果（见 raceTranslate 注释）
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    }];
    [task resume];
}

@end

#pragma mark - 腾讯云一句话识别（在线 ASR，绕开 SFSpeech 授权）

// TC3-HMAC-SHA256 签名工具
static NSString *LCDataToHex(NSData *d) {
    const unsigned char *p = d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

static NSData *LCHMACSHA256(NSData *key, NSData *data) {
    NSMutableData *out = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, out.mutableBytes);
    return out;
}

static NSData *LCSHA256(NSData *d) {
    NSMutableData *out = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, out.mutableBytes);
    return out;
}

static NSData *LCBytes(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

static NSString *LCTencentAuthHeaderEx(NSString *secretId, NSString *secretKey,
                                       NSString *timestamp, NSString *date,
                                       NSData *payload, NSString *host,
                                       NSString *service, NSString *action,
                                       NSString *region) {
    // CanonicalRequest
    // Content-Type 必须与实际请求头完全一致（不能带 charset，腾讯云按原样参与哈希）
    // SignedHeaders 只用 content-type;host（腾讯云官方示例格式；
    // 多带 x-tc-action 会导致 Content-Type 与签名串不一致 → SignatureFailure）
    NSString *hashedPayload = LCDataToHex(LCSHA256(payload));
    NSString *canonicalHeaders = [NSString stringWithFormat:
        @"content-type:application/json\nhost:%@\n", host];
    NSString *signedHeaders = @"content-type;host";
    NSString *canonicalRequest = [NSString stringWithFormat:
        @"POST\n/\n\n%@\n%@\n%@",
        canonicalHeaders, signedHeaders, hashedPayload];

    // TC3 credential scope 必须是【三段】Date/service/tc3_request，不含 region！
    // 写成四段（含 region）腾讯云直接返回
    //   AuthFailure.InvalidAuthorization: "Credential scope size not valid"
    // region 只放在 X-TC-Region 请求头里，不参与签名 scope。
    (void)region;  // 保留参数仅为兼容调用方；scope 不含 region
    NSString *credentialScope = [NSString stringWithFormat:@"%@/%@/tc3_request", date, service];
    NSString *stringToSign = [NSString stringWithFormat:
        @"TC3-HMAC-SHA256\n%@\n%@\n%@",
        timestamp, credentialScope, LCDataToHex(LCSHA256(LCBytes(canonicalRequest)))];

    // 密钥派生（TC3+SecretKey 是二进制 HMAC 键）
    NSMutableData *tc3Key = [NSMutableData data];
    [tc3Key appendBytes:"TC3" length:3];
    [tc3Key appendData:LCBytes(secretKey)];

    NSData *secretDate = LCHMACSHA256(tc3Key, LCBytes(date));
    NSData *secretService = LCHMACSHA256(secretDate, LCBytes(service));
    NSData *secretSigning = LCHMACSHA256(secretService, LCBytes(@"tc3_request"));
    NSData *signature = LCHMACSHA256(secretSigning, LCBytes(stringToSign));

    return [NSString stringWithFormat:
        @"TC3-HMAC-SHA256 Credential=%@/%@, SignedHeaders=%@, Signature=%@",
        secretId, credentialScope, signedHeaders, LCDataToHex(signature)];
}

static NSString *LCTencentAuthHeader(NSString *secretId, NSString *secretKey,
                                     NSString *timestamp, NSString *date,
                                     NSData *payload, NSString *host) {
    return LCTencentAuthHeaderEx(secretId, secretKey, timestamp, date, payload, host,
                                 @"asr", @"sentencerecognition", @"ap-guangzhou");
}

// tap 输入格式（LCTapPrepare 记录，供 PCM 转换 / SFSpeech 缓冲）
static AudioStreamBasicDescription gProcessingFormat;
static BOOL gProcessingFormatValid = NO;

@interface LCSubtitleOverlay : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)install;
// ===== v1.0.81 显示策略 =====
// 旧策略（原子配对）：英文先到只登记，译文回来才整对刷屏。
//   后果：只要翻译慢/失败，画面就永远停在第一句 —— 用户反馈「不轮动」。
// 新策略（seq 配对）：ASR 每出一句 final 就【立即】把英文刷上屏，
//   字幕框随语音轮动；译文回来后补上中文；迟到的旧译文按 seq 丢弃，不会串句。
- (NSUInteger)showPending:(NSString *)origin;   // 返回本次 seq
- (void)showPartial:(NSString *)origin;          // partial 只登记，不刷屏
- (void)showPair:(NSString *)origin translation:(NSString *)translation seq:(NSUInteger)seq;
- (void)showFailed:(NSString *)origin seq:(NSUInteger)seq;
- (void)renderCurrent;
- (void)hide;
- (void)showToast:(NSString *)text;
// v1.0.87：配置热重载（面板改字号后无需重启 App，字幕立即变大/变小）
- (void)startConfigWatcher;
- (void)checkConfigChange;
@end

#pragma mark - 腾讯云实时语音识别 WebSocket（v2.1.0：不攒音频，边说边推）

// 实测依据（2026-11-10，见 verify_ws_asr.py / probe_ws_engines.py）：
//   · 签名 Base64(HMAC-SHA1("asr.cloud.tencent.com/asr/v2/<appid>?<字典序query>", SecretKey))
//     —— 与 TC3 完全不同的算法，但复用同一对 CAM 密钥。
//   · voice_format=1（16k/16bit/mono PCM），每 200ms 发 6400 字节，严格 1:1 实时率。
//   · needvad=1 让服务端按语义断句，slice_type=2 才是稳态句末，只有它送翻译。
//   · 音频回调本身是实时的，「缓冲满 6400 字节就切一帧」天然满足 1:1，不需要攒分片。
//   · 发送必须串行（上一帧 completion 后再发下一帧），否则会被服务端判 4000。
//   · 引擎默认 16k_en（通用引擎，账号已开通）；开通大模型 ASR 后付费后
//     把 asrEngine 改成 16k_multi_lang 即可，无需重新编译。

static NSString *LCPercentEncodeAll(NSString *s) {
    // RFC 3986 unreserved = A-Z a-z 0-9 - _ . ~
    // v2.1.0 只用 alphanumericCharacterSet，会把 engine_model_type=16k_en 的 '_'、
    // voice_id(UUID) 的 '-' 也编码成 %5F / %2D；本地 verify_ws_asr.py 用
    // urllib.parse.quote(v, safe='') 是保留这两个字符的。为消除设备端与本地实测
    // 验签结果不一致的隐患，这里统一为同一套规则。+、/、= 仍会被编码。
    NSMutableCharacterSet *allow = [NSMutableCharacterSet alphanumericCharacterSet];
    [allow addCharactersInString:@"-_.~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allow] ?: s;
}

static NSString *LCWsHmacSha1B64(NSString *src, NSString *key) {
    const char *k = [key UTF8String];
    const char *d = [src UTF8String];
    if (!k || !d) return nil;
    unsigned char mac[CC_SHA1_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA1, k, strlen(k), d, strlen(d), mac);
    return [[NSData dataWithBytes:mac length:sizeof(mac)] base64EncodedStringWithOptions:0];
}

@interface LCStreamASR : NSObject <NSURLSessionWebSocketDelegate>
+ (instancetype)shared;
- (BOOL)isActive;
- (void)start;
- (void)appendPCM16:(NSData *)pcm16;
- (void)appendMonoFloat:(const float *)mono frames:(UInt32)frames rate:(double)rate;
- (void)stop;
@end

@implementation LCStreamASR {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    NSMutableData *_buf;                  // 不足一帧的残余 PCM
    NSMutableArray<NSData *> *_frames;    // 待发送帧（串行）
    BOOL _sending;
    BOOL _ready;                          // 收到 code=0 握手确认
    BOOL _active;
    NSTimeInterval _lastAudioAt;
    NSTimeInterval _lastFrameAt;
    dispatch_source_t _keepalive;
    NSInteger _retryCount;
    // v2.1.1：流式断句兜底与看门狗
    NSTimeInterval _startedAt;          // start 时刻
    NSTimeInterval _lastSentenceAt;     // 最近一次真正送翻译的时刻
    NSString *_lastPartialText;         // 最近一次中间结果
    NSTimeInterval _lastPartialAt;      // 中间结果文本发生变化的时刻
    NSString *_lastTranslatedText;      // 最近一次送翻译的文本（去重用）
    // v2.2.0：客户端语义断句（partial 只累积，成句才送译）
    NSMutableString *_sentence;         // 当前累积句
    NSString *_lastRawPartial;          // 上一次原始 partial（前缀归一化用）
    NSTimeInterval _lastChangeAt;       // 累积文本最后变化时刻
    NSTimeInterval _sentenceStartAt;    // 本句起始时刻（0 = 尚未开始）
}

+ (instancetype)shared {
    static LCStreamASR *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[LCStreamASR alloc] init];
        s->_buf = [NSMutableData data];
        s->_frames = [NSMutableArray array];
    });
    return s;
}

- (BOOL)isActive { return _active; }

- (NSURL *)lc_buildURL {
    LCConfig *cfg = [LCConfig shared];
    NSString *appid = [cfg asrAppId];
    NSString *sid = [cfg tencentSecretId];
    NSString *skey = [cfg tencentSecretKey];
    if (appid.length == 0 || sid.length == 0 || skey.length == 0) {
        LCLog("asr: ws missing appid/keys -> keep HTTP fallback");
        return nil;
    }
    long long ts = (long long)[[NSDate date] timeIntervalSince1970];
    NSString *engine = [cfg asrEngine];
    NSDictionary *p = @{
        @"secretid": sid,
        @"timestamp": [NSString stringWithFormat:@"%lld", ts],
        @"expired": [NSString stringWithFormat:@"%lld", ts + 3600],
        @"nonce": [NSString stringWithFormat:@"%lld", ts % 10000000000LL],
        @"engine_model_type": engine,
        @"voice_format": @"1",
        @"needvad": @"1",
        @"vad_silence_time": @"800",
        @"max_speak_time": @"15000",
        @"filter_empty_result": @"1",
        @"voice_id": [[NSUUID UUID] UUIDString],
    };
    NSArray *keys = [[p allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *plain = [NSMutableString stringWithFormat:@"asr.cloud.tencent.com/asr/v2/%@?", appid];
    NSMutableString *query = [NSMutableString string];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *k = keys[i];
        NSString *v = p[k];
        if (i) { [plain appendString:@"&"]; [query appendString:@"&"]; }
        [plain appendFormat:@"%@=%@", k, v];          // 签名原文用未编码值
        [query appendFormat:@"%@=%@", k, LCPercentEncodeAll(v)];
    }
    NSString *sig = LCWsHmacSha1B64(plain, skey);
    if (!sig) return nil;
    NSString *url = [NSString stringWithFormat:
        @"wss://asr.cloud.tencent.com/asr/v2/%@?%@&signature=%@",
        appid, query, LCPercentEncodeAll(sig)];
    LCLogF(@"asr: ws connecting engine=%@ appid=%@", engine, appid);
    return [NSURL URLWithString:url];
}

- (void)start {
    if (_active) return;
    if (![[LCConfig shared] streamASREnabled]) {
        LCLog("asr: ws disabled by config -> HTTP fallback");
        return;
    }
    NSURL *url = [self lc_buildURL];
    if (!url) return;
    _active = YES;
    _ready = NO;
    _retryCount = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    _lastAudioAt = now;
    _startedAt = now;
    _lastSentenceAt = now;          // 看门狗从 start 起算，避免刚连上就误判
    _lastPartialAt = now;
    _lastPartialText = nil;
    _lastTranslatedText = nil;
    if (!_sentence) _sentence = [NSMutableString string];
    [_sentence setString:@""];
    _lastRawPartial = nil;
    _lastChangeAt = now;
    _sentenceStartAt = 0;
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
    c.connectionProxyDictionary = @{};   // 禁系统代理，直连（同 LCSessionDirect）
    _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    _task = [_session webSocketTaskWithURL:url];
    [_task resume];
    [self lc_pumpReceive];
    [self lc_startKeepalive];
}

- (void)stop {
    _active = NO;
    _ready = NO;
    if (_keepalive) { dispatch_source_cancel(_keepalive); _keepalive = nil; }
    @synchronized(self) { [_frames removeAllObjects]; }
    if (_task) {
        NSURLSessionWebSocketTask *old = _task;
        _task = nil;                       // 先置空，让旧 task 的关闭回调被忽略
        // 注意：关闭方法是 cancelWithCloseCode:reason:（委托回调才是 didCloseWithCode:）
        [old cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    }
    [_session invalidateAndCancel];
    _session = nil;
}

- (void)lc_pumpReceive {
    NSURLSessionWebSocketTask *task = _task;
    if (!task || !_active) return;
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self->_active) return;
        if (task != self->_task) return;   // 已被重连替换的旧 task，回调直接丢弃
        if (err) {
            LCLogF(@"asr: ws recv err %@", err);
            [self lc_reconnect];
            return;
        }
        if (msg.type == NSURLSessionWebSocketMessageTypeString && msg.string.length) {
            [self lc_onText:msg.string];
        }
        [self lc_pumpReceive];
    }];
}

- (void)lc_onText:(NSString *)s {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![j isKindOfClass:[NSDictionary class]]) return;
    id codeObj = j[@"code"];
    if (codeObj) {
        NSInteger code = [codeObj integerValue];
        if (code != 0) {
            LCLogF(@"asr: ws code=%ld msg=%@", (long)code, j[@"message"]);
            // 4002 签名/密钥、4003 服务未开通、4004 大模型计费未开：不要无限重连
            if (code == 4002 || code == 4003 || code == 4004) {
                LCLog("asr: ws fatal -> stop, HTTP fallback takes over");
                [self stop];
                return;
            }
            [self lc_reconnect];
            return;
        }
        if (!_ready) {
            _ready = YES;
            _retryCount = 0;
            LCLogF(@"asr: ws handshake ok voice_id=%@", j[@"voice_id"]);
            [self lc_drain];
        }
    }
    if ([j[@"final"] integerValue] == 1) {
        LCLog("asr: ws final=1");
    }
    NSDictionary *r = j[@"result"];
    if (![r isKindOfClass:[NSDictionary class]]) return;
    NSInteger st = [r[@"slice_type"] integerValue];
    NSString *txt = r[@"voice_text_str"];
    if (txt.length == 0) return;
    if (![[LCConfig shared] strictSubtitleSync]) {
        // 可回退路径：完全沿用 v2.1.1 的「中间结果定时兜底」，便于真机 A/B 对照
        if (st == 1) {
            [[LCSubtitleOverlay shared] showPartial:txt];
            [self lc_maybeTranslatePartial:txt];
        } else if (st == 2) {
            [self lc_translateFinal:txt];
        }
        return;
    }

    if (st == 2) {
        // 服务端明确判句末：合并累积文本后收句，一句只翻一次
        NSString *merged = [self lc_mergePartial:txt];
        LCLogF(@"asr: ws final sentence [%@]", merged);
        [self lc_commitSentence:merged reason:@"slice2"];
        return;
    }
    if (st == 1) {
        // v2.2.0：中间结果【只登记、只累积，绝不单独送翻译】。
        // v2.1.1 每 3 秒把半句当整句送译，是本轮「字幕对不上」的首因。
        [[LCSubtitleOverlay shared] showPartial:txt];
        NSString *merged = [self lc_mergePartial:txt];
        [self lc_updateSentence:merged];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if ([self lc_shouldCommit:merged now:now]) {
            [self lc_commitSentence:merged reason:@"auto"];
        }
    }
}

// ===== v2.2.0 客户端语义断句 =====
// 腾讯云 slice_type=1 的 voice_text_str 有两种形态：
//   (a) 同一句的累积前缀："hello" → "hello world" → "hello world today"
//   (b) 每片独立文本：    "hello" → "world" → "today"
// 统一归一化成一条累积句，避免把半句当整句反复送翻、也避免重复拼接。
- (NSString *)lc_mergePartial:(NSString *)raw {
    NSString *cur = _sentence ?: @"";
    NSString *last = _lastRawPartial ?: @"";
    _lastRawPartial = [raw copy];
    if (cur.length && [raw hasPrefix:cur]) return raw;                    // (a) 累积
    if (raw.length && cur.length && [cur hasPrefix:raw]) return cur;       // 服务端回退
    if ([raw isEqualToString:last]) return cur;                            // 重复推送
    if (raw.length && cur.length && [cur rangeOfString:raw].location != NSNotFound) return cur;
    return cur.length ? [NSString stringWithFormat:@"%@ %@", cur, raw] : raw;   // (b) 追加
}

- (void)lc_updateSentence:(NSString *)merged {
    if (!_sentence) _sentence = [NSMutableString string];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (![merged isEqualToString:_sentence]) {
        [_sentence setString:merged];
        _lastChangeAt = now;
        if (_sentenceStartAt <= 0) _sentenceStartAt = now;
    }
    if (LCLogThrottled(@"ws-partial", 1.0)) LCLogF(@"asr: ws partial [%@]", merged);
}

- (BOOL)lc_shouldCommit:(NSString *)s now:(NSTimeInterval)now {
    if (s.length < 2) return NO;
    unichar last = [s characterAtIndex:s.length - 1];
    if (last == '.' || last == '?' || last == '!' ||
        last == 0x3002 || last == 0xFF1F || last == 0xFF01) return YES;   // 句末标点
    if (now - _lastChangeAt >= 1.0 && s.length >= 8) return YES;          // 静音断句
    if (s.length >= 100) return YES;                                       // 长度上限
    if (_sentenceStartAt > 0 && now - _sentenceStartAt >= 8.0) return YES; // 硬上限
    return NO;
}

// 静音时服务端不再推 partial，靠 keepalive 定时器收句
- (void)lc_flushIfSettled {
    if (![[LCConfig shared] strictSubtitleSync]) return;
    NSString *s = [_sentence copy];
    if (s.length < 2) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastChangeAt >= 1.0 && s.length >= 8)
        [self lc_commitSentence:s reason:@"silence"];
    else if (_sentenceStartAt > 0 && now - _sentenceStartAt >= 8.0)
        [self lc_commitSentence:s reason:@"timeout"];
}

- (void)lc_commitSentence:(NSString *)text reason:(NSString *)why {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *s = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 无论是否送译都先清空累积状态，避免下一句粘上上一句
    if (!_sentence) _sentence = [NSMutableString string];
    [_sentence setString:@""];
    _lastRawPartial = nil;
    _lastChangeAt = now;
    _sentenceStartAt = 0;
    if (s.length < 2) return;
    if ([s isEqualToString:_lastTranslatedText]) {
        LCLog("asr: ws skip duplicate sentence");
        return;
    }
    LCLogF(@"asr: ws commit (%@) [%@]", why, s);
    [self lc_translateFinal:s];
}

// 旧兜底（strictSubtitleSync=NO 时使用）：保留 v2.1.1 行为供真机对照。
// 文本稳定 1.0s 或距上次送译 ≥3.0s 且文本变化后，把当前中间结果当一句送翻译。
- (void)lc_maybeTranslatePartial:(NSString *)text {
    if (!_active || text.length < 4) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL changed = ![text isEqualToString:_lastPartialText];
    if (changed) {
        _lastPartialText = [text copy];
        _lastPartialAt = now;
    }
    BOOL settled = !changed && (now - _lastPartialAt >= 1.0);
    // 不依赖「文本是否变长」：服务端给的 voice_text_str 可能是每片独立文本而非累积，
    // 那种情况下长度比较永远不成立，会重新变回零字幕。
    BOOL periodic = (now - _lastSentenceAt >= 3.0) &&
                    ![text isEqualToString:_lastTranslatedText];
    if (!settled && !periodic) return;
    if ([text isEqualToString:_lastTranslatedText]) return;   // 同一句不重复翻
    LCLogF(@"asr: ws partial fallback translate [%@]", text);
    [self lc_translateFinal:text];
}

- (void)lc_translateFinal:(NSString *)text {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 稳态句与 partial 兜底可能间隔很近且文本相同，跳过重复翻译避免字幕抖两下
    if ([text isEqualToString:_lastTranslatedText] && (now - _lastSentenceAt < 1.5)) {
        LCLog("asr: ws skip duplicate sentence");
        return;
    }
    _lastTranslatedText = [text copy];
    _lastSentenceAt = now;
    NSUInteger seq = [[LCSubtitleOverlay shared] showPending:text];
    [[LCTranslator shared] translate:text completion:^(NSString *tr) {
        if (tr.length) [[LCSubtitleOverlay shared] showPair:text translation:tr seq:seq];
        else [[LCSubtitleOverlay shared] showFailed:text seq:seq];
    }];
}

- (void)appendPCM16:(NSData *)pcm16 {
    if (!_active || !pcm16.length) return;
    _lastAudioAt = [[NSDate date] timeIntervalSince1970];
    @synchronized(self) {
        [_buf appendData:pcm16];
        while (_buf.length >= 6400) {
            NSData *frame = [_buf subdataWithRange:NSMakeRange(0, 6400)];
            [_buf replaceBytesInRange:NSMakeRange(0, 6400) withBytes:NULL length:0];
            if (_frames.count > 12) [_frames removeObjectAtIndex:0];  // 网络慢时丢最旧
            [_frames addObject:frame];
        }
    }
    [self lc_drain];
}

- (void)appendMonoFloat:(const float *)mono frames:(UInt32)frames rate:(double)rate {
    // float 管线（非 YouTube 主路径）：增量最近邻重采样到 16k + 量化 SInt16，
    // 再走同一条 PCM16 流式通道，保证不会同时跑 HTTP 产生双份字幕。
    if (!_active || !mono || frames == 0) return;
    double ratio = (rate > 0) ? rate / 16000.0 : 1.0;
    if (ratio <= 0) ratio = 1.0;
    UInt32 outN = (UInt32)(frames / ratio);
    if (outN == 0) return;
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)outN * sizeof(SInt16)];
    SInt16 *dst = (SInt16 *)[out mutableBytes];
    for (UInt32 i = 0; i < outN; i++) {
        UInt32 src = (UInt32)(i * ratio);
        if (src >= frames) src = frames - 1;
        float v = mono[src];
        if (v > 1.0f) v = 1.0f;
        else if (v < -1.0f) v = -1.0f;
        dst[i] = (SInt16)(v * 32767.0f);
    }
    [self appendPCM16:out];
}

- (void)lc_drain {
    NSData *frame = nil;
    @synchronized(self) {
        if (_sending || !_ready || !_active || _frames.count == 0) return;
        _sending = YES;
        frame = _frames[0];
        [_frames removeObjectAtIndex:0];
    }
    NSURLSessionWebSocketTask *task = _task;
    if (!task) { @synchronized(self) { _sending = NO; } return; }
    __weak typeof(self) weakSelf = self;
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithData:frame];
    [task sendMessage:msg completionHandler:^(NSError *err) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        @synchronized(self) { self->_sending = NO; }
        if (err) { LCLogF(@"asr: ws send err %@", err); [self lc_reconnect]; return; }
        self->_lastFrameAt = [[NSDate date] timeIntervalSince1970];
        [self lc_drain];
    }];
}

- (void)lc_startKeepalive {
    if (_keepalive) dispatch_source_cancel(_keepalive);
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    _keepalive = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_keepalive, dispatch_walltime(NULL, 0), 200 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_keepalive, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self->_active) return;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        // v2.1.1 看门狗：流式层一旦 _active=YES 就会吞掉三条音频入口，
        // 如果它半死不活（握手不上 / 识别全空），旧的 HTTP 分片链路永远没机会跑，
        // 表现为「右上只有一个拖动圆点、字幕框完全不出现」。
        // 这里在两种异常下主动 stop，让音频入口自动回落 HTTP，保证字幕一定出来。
        if (!self->_ready && (now - self->_startedAt > 6.0)) {
            LCLog("asr: ws handshake timeout 6s -> HTTP fallback");
            [self stop];
            return;
        }
        if (self->_ready && (now - self->_lastAudioAt < 2.0) &&
            (now - self->_lastSentenceAt > 10.0)) {
            LCLog("asr: ws no sentence in 10s -> HTTP fallback");
            [self stop];
            return;
        }
        if (!self->_ready) return;
        // v2.2.0：静音时服务端不再推 partial，由定时器按「文本稳定」收句
        [self lc_flushIfSettled];
        if (now - self->_lastAudioAt < 1.0) return;           // 有真实音频时不插静音
        if (now - self->_lastAudioAt > 30.0) {                // 长时间无音频，主动断开省计费
            LCLog("asr: ws idle 30s -> disconnect");
            [self stop];
            return;
        }
        NSMutableData *silence = [NSMutableData dataWithLength:6400];  // 全 0 静音帧
        @synchronized(self) {
            if (self->_frames.count > 12) [self->_frames removeObjectAtIndex:0];
            [self->_frames addObject:silence];
        }
        [self lc_drain];
    });
    dispatch_resume(_keepalive);
}

- (void)lc_reconnect {
    if (!_active) return;
    _retryCount++;
    if (_retryCount > 5) {
        LCLog("asr: ws retry exhausted -> stop, HTTP fallback takes over");
        [self stop];
        return;
    }
    LCLogF(@"asr: ws reconnect #%ld", (long)_retryCount);
    _ready = NO;
    // 重连必须重置两个看门狗基准：否则 _startedAt 仍是本次会话 start 的时刻，
    // 握手看门狗会在重连后 200ms 内误判「握手超时」把流式杀掉；
    // _lastSentenceAt 同理，重连期间不应算作「零产出」。
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    _startedAt = now;
    _lastSentenceAt = now;
    // 重连是全新的 voice_id / 音频流，旧半句不能带过去
    if (!_sentence) _sentence = [NSMutableString string];
    [_sentence setString:@""];
    _lastRawPartial = nil;
    _lastChangeAt = now;
    _sentenceStartAt = 0;
    @synchronized(self) { [_frames removeAllObjects]; }
    if (_task) {
        NSURLSessionWebSocketTask *old = _task;
        _task = nil;
        // 注意：关闭方法是 cancelWithCloseCode:reason:（委托回调才是 didCloseWithCode:）
        [old cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    }
    NSURL *url = [self lc_buildURL];   // 必须换新的 voice_id / timestamp
    if (!url) { [self stop]; return; }
    _task = [_session webSocketTaskWithURL:url];
    [_task resume];
    [self lc_pumpReceive];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didOpenWithProtocol:(NSString *)protocol {
    LCLogF(@"asr: ws opened protocol=%@", protocol ?: @"(none)");
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    LCLogF(@"asr: ws closed code=%ld", (long)code);
    // 只处理当前 task：重连时 cancel 掉的旧 task 也会触发本回调，
    // 不忽略会形成「cancel → didClose → reconnect → cancel」死循环。
    if (_active && task == _task) [self lc_reconnect];
}

@end

#pragma mark - LCHttpASR

@interface LCHttpASR : NSObject
+ (instancetype)shared;
- (BOOL)isRunning;
- (void)startWithFormat:(AudioStreamBasicDescription)asbd;
- (void)appendBufferList:(AudioBufferList *)list frames:(UInt32)frames;
- (void)appendMonoFloat:(const float *)mono frames:(UInt32)frames;  // AVSampleBuffer 管线：单声道 float32
- (void)appendPCM16:(NSData *)pcm16;   // AVSampleBuffer 管线（YouTube 自研播放器）：16k/16bit/mono PCM
- (void)stop;
@end

@implementation LCHttpASR {
    NSMutableData *_pcm;          // float32 单声道样本累积
    NSMutableData *_pcm16;        // 16bit 单声道 PCM 累积（AVSampleBuffer 管线）
    double _inRate;               // 输入采样率
    BOOL _running;
    // v1.0.85：BOOL _inFlight → NSInteger _inFlightCount
    // 允许最多 LC_ASR_MAX_CONCURRENCY 个请求同时在飞，消除串行排队导致的持续滞后。
    NSInteger _inFlightCount;
    NSURLSession *_session;       // 直连（禁用系统代理）
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
    // v2.0.2：分片时长可在面板实时修改，这里缓存 2 秒，避免每次音频回调读盘
    double _chunkSecs;
    NSTimeInterval _chunkCheckAt;
}

// v2.0.2：读取 asrChunkSeconds，钳制到 [1.0, 3.0]，默认 1.5 秒。
// 面板用 LCSet 写盘 + CFPreferencesAppSynchronize，这里直接读文件，
// 两边不打架；读不到文件（沙盒/roothide 路径异常）时用默认值兜底。
- (double)lc_chunkSeconds {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    @synchronized(self) {
        if (_chunkSecs > 0 && (now - _chunkCheckAt) < 2.0) return _chunkSecs;
        _chunkCheckAt = now;
        double v = LC_ASR_CHUNK_DEFAULT;
        NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        id raw = d[@"asrChunkSeconds"];
        if ([raw isKindOfClass:[NSNumber class]]) v = [(NSNumber *)raw doubleValue];
        else if ([raw isKindOfClass:[NSString class]]) v = [(NSString *)raw doubleValue];
        if (v < 1.0 || v > 3.0) v = LC_ASR_CHUNK_DEFAULT;
        _chunkSecs = v;
        return v;
    }
}

+ (instancetype)shared {
    static LCHttpASR *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[LCHttpASR alloc] init];
        s->_pcm = [NSMutableData data];
        s->_pcm16 = [NSMutableData data];
        // v1.0.85：ASR 用直连 session（禁用系统代理）
        s->_session = LCSessionDirect();
        s->_sessionProxy = LCSessionDefault();
    });
    return s;
}

- (BOOL)isRunning { return _running; }

- (void)startWithFormat:(AudioStreamBasicDescription)asbd {
    if (_running) return;
    if (asbd.mSampleRate <= 0) {
        LCLog("asr: waiting for audio format (tap prepare will call again)");
        return;
    }
    _inRate = asbd.mSampleRate;
    [_pcm setLength:0];
    [_pcm16 setLength:0];
    _inFlightCount = 0;
    _running = YES;
    LCLogF(@"asr: tencent online ASR started (sr=%g ch=%u)", _inRate,
           (unsigned)asbd.mChannelsPerFrame);
    // v2.1.0：启动流式 WebSocket。失败时 LCStreamASR 会自行 stop，
    // 三条音频入口检测到 !isActive 会自动回落旧的 HTTP 分片链路。
    [[LCStreamASR shared] start];
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
}

- (void)appendBufferList:(AudioBufferList *)list frames:(UInt32)frames {
    if (!_running) return;
    if (![[LCConfig shared] enabled]) return;
    if (_inRate <= 0) return;
    if (!list || frames == 0) return;
    @autoreleasepool {
        @try {
            // 转单声道 float32：interleaved 按帧平均，non-interleaved 多 buffer 平均
            unsigned ch = (gProcessingFormatValid && gProcessingFormat.mChannelsPerFrame > 0)
                ? (unsigned)gProcessingFormat.mChannelsPerFrame : 2;
            BOOL interleaved = !(gProcessingFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
            float *tmp = (float *)malloc(frames * sizeof(float));
            if (!tmp) return;
            for (UInt32 i = 0; i < frames; i++) {
                float acc = 0;
                if (interleaved && list->mNumberBuffers > 0) {
                    const float *b = (const float *)list->mBuffers[0].mData;
                    for (unsigned c = 0; c < ch; c++) acc += b[i * ch + c];
                    acc /= ch;
                } else {
                    unsigned n = 0;
                    for (unsigned c = 0; c < list->mNumberBuffers; c++) {
                        if (list->mBuffers[c].mData) {
                            acc += ((const float *)list->mBuffers[c].mData)[i];
                            n++;
                        }
                    }
                    if (n) acc /= n;
                }
                tmp[i] = acc;
            }
            // v2.1.0：流式模式下直接推 WebSocket，不再攒分片，也不发 HTTP，
            // 避免两条链路同时识别造成双份字幕。
            if ([[LCStreamASR shared] isActive]) {
                [[LCStreamASR shared] appendMonoFloat:tmp frames:frames rate:_inRate];
                free(tmp);
                return;
            }
            [_pcm appendBytes:tmp length:frames * sizeof(float)];
            free(tmp);

            // v1.0.84：分片时长从固定 5 秒改为可配置，默认 1.5 秒（v2.0.2，设置面板可调）。
            // 依据（设备日志实证）：ASR RTT ≈ 音频时长 × 1.1
            //   5.11s 音频 → RTT 5.6s；7.20s 音频 → RTT 10s
            // 分片减半 → RTT 近似减半 → 字幕延迟从 ~6s 降到 ~3s。
            // 代价：句子被切碎的概率上升。为补偿，保留 overlap 重叠区
            // （下一段开头复用上一段末尾的音频），避免词被切断。
            double chunkSecs = [self lc_chunkSeconds];
            double secs = (double)_pcm.length / sizeof(float) / _inRate;
            if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
                NSData *chunk = [_pcm copy];
                [_pcm setLength:0];
                [self processChunk:chunk];
            } else if (secs > chunkSecs) {
                // v1.0.87：并发槽位满 → 只裁掉【最旧】的音频，保留最近 chunkSecs 秒。
                // 原来整段清空 → 下一片起点不断后移 → 分片越滚越长
                // （设备日志实测出现 3.48/3.72/3.95/4.18/4.41s 长尾）→ 延迟恶化。
                [self trimPCMKeepingSeconds:chunkSecs];
            }
        } @catch (NSException *e) {
            LCLogF(@"asr: append err %@", e);
        }
    }
}

- (void)processChunk:(NSData *)floatMono {
    // v2.0.2：分片缩到 1.5s 后，并发槽满 trim 出的残片可能很短，
    // 送上去只会得到半截词（设备日志已出现 "your per" 这种），直接丢弃。
    if (!floatMono || floatMono.length < sizeof(float) * 8000) return;  // <0.5s @16k 丢弃
    _inFlightCount++;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
                // 1) 重采样到 16k（最近邻） + 量化 SInt16
                NSUInteger inCount = floatMono.length / sizeof(float);
                const float *in = (const float *)floatMono.bytes;
                double ratio = _inRate / 16000.0;
                NSUInteger outCount = (NSUInteger)(inCount / ratio);
                if (outCount < 160) { LC_ASR_DONE(); return; }  // 太短
                NSMutableData *pcm16 = [NSMutableData dataWithCapacity:outCount * 2];
                SInt16 *out = (SInt16 *)malloc(outCount * 2);
                if (!out) { LC_ASR_DONE(); return; }
                for (NSUInteger n = 0; n < outCount; n++) {
                    NSUInteger idx = (NSUInteger)(n * ratio);
                    if (idx >= inCount) idx = inCount - 1;
                    float f = in[idx];
                    if (f > 1.0f) f = 1.0f;
                    if (f < -1.0f) f = -1.0f;
                    out[n] = (SInt16)(f * 32767.0f);
                }
                [pcm16 appendBytes:out length:outCount * 2];
                free(out);

                // 2) v1.0.87：优先 AAC(ADTS 封装) 压缩上传。
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
                }
                if (!audioData) {
                    NSMutableData *wav = [NSMutableData dataWithCapacity:pcm16.length + 44];
                    const char *riff = "RIFF";
                    [wav appendBytes:riff length:4];
                    uint32_t riffSize = (uint32_t)(36 + pcm16.length);
                    [wav appendBytes:&riffSize length:4];
                    const char *wave = "WAVE";
                    [wav appendBytes:wave length:4];
                    const char *fmt = "fmt ";
                    [wav appendBytes:fmt length:4];
                    uint32_t fmtSize = 16;
                    [wav appendBytes:&fmtSize length:4];
                    uint16_t audioFmt = 1;
                    [wav appendBytes:&audioFmt length:2];
                    uint16_t chn = 1;
                    [wav appendBytes:&chn length:2];
                    uint32_t rate = 16000;
                    [wav appendBytes:&rate length:4];
                    uint32_t byteRate = 16000 * 2;
                    [wav appendBytes:&byteRate length:4];
                    uint16_t blockAlign = 2;
                    [wav appendBytes:&blockAlign length:2];
                    uint16_t bits = 16;
                    [wav appendBytes:&bits length:2];
                    const char *data = "data";
                    [wav appendBytes:data length:4];
                    uint32_t dataSize = (uint32_t)pcm16.length;
                    [wav appendBytes:&dataSize length:4];
                    [wav appendData:pcm16];
                    audioData = wav;
                }

                // 3) base64 + 请求
                NSString *b64 = [audioData base64EncodedStringWithOptions:0];
                NSString *secretId = [[LCConfig shared] tencentSecretId];
                NSString *secretKey = [[LCConfig shared] tencentSecretKey];
                if (secretId.length == 0 || secretKey.length == 0) {
                    LCLog("asr: tencent keys missing");
                    LC_ASR_DONE();
                    return;
                }
                // 识别语言映射
                // 实测（腾讯云一句话识别接口）：
                //   支持: 16k_zh / 16k_en / 16k_multi_lang / 16k_ja / 16k_ko
                //   不支持: 16k_zh_en / 16k_zh_large / 16k_en_large / bigmodel
                //   （大模型引擎只在「实时语音识别 WebSocket」接口提供，
                //     一句话识别 HTTP 接口不支持 —— 实测会返回
                //      InvalidParameter: Not support [EngineModelType: xxx]）
                // 16k_multi_lang 是大模型引擎：参数量极大、语言模型性能增强，
                // 对「噪声大/回音大/人声小/人声远」等低质量音频识别准确率极大提升，
                // 且支持 15 语种自动识别（句子/段落级）。
                // 我们抓的是视频音轨（背景音乐 + 对白），正属于低质量音频场景，
                // 用普通引擎 16k_en 会被识别成碎片。
                // v2.0.0：源语言自动检测，统一用多语言大模型引擎
                NSString *eng = @"16k_multi_lang";   // 多语言大模型引擎（支持 15 语种自动识别）

                NSDictionary *body = @{
                    @"ProjectId": @0,
                    @"SubServiceType": @2,
                    @"EngSerViceType": eng,
                    @"SourceType": @1,
                    @"VoiceFormat": voiceFormat,
                    @"UsrAudioKey": [NSString stringWithFormat:@"livecap-%@", [[NSUUID UUID] UUIDString]],
                    @"Data": b64,
                    @"DataLen": @(audioData.length),
                    @"FilterDirty": @0,
                    @"FilterModal": @0,
                    @"FilterPunc": @1
                };
                NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
                if (!payload) { LC_ASR_DONE(); return; }

                long long ts = (long long)[[NSDate date] timeIntervalSince1970];
                NSString *tsStr = [NSString stringWithFormat:@"%lld", ts];
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                [df setDateFormat:@"yyyy-MM-dd"];
                [df setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
                NSString *dateStr = [df stringFromDate:[NSDate date]];

                NSString *host = @"asr.tencentcloudapi.com";
                NSString *auth = LCTencentAuthHeader(secretId, secretKey, tsStr, dateStr, payload, host);

                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                    [NSURL URLWithString:@"https://asr.tencentcloudapi.com"]];
                req.HTTPMethod = @"POST";
                [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                [req setValue:host forHTTPHeaderField:@"Host"];
                [req setValue:@"SentenceRecognition" forHTTPHeaderField:@"X-TC-Action"];
                [req setValue:@"2019-06-14" forHTTPHeaderField:@"X-TC-Version"];
                [req setValue:tsStr forHTTPHeaderField:@"X-TC-Timestamp"];
                [req setValue:@"ap-guangzhou" forHTTPHeaderField:@"X-TC-Region"];
                [req setValue:auth forHTTPHeaderField:@"Authorization"];
                req.HTTPBody = payload;
                req.timeoutInterval = 10.0;

                LCLogF(@"asr: sending %lu bytes (%@ fmt=%@)", (unsigned long)audioData.length,
                       eng, voiceFormat);
                // v1.0.84：毫秒级打点。
                // 设备日志只有秒级精度，无法区分「RTT 4s」是网络还是服务端，
                // 这次加上毫秒计时，下次实测直接读数字。
                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
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
                    }
                    NSError *__autoreleasing pe = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
                    if (pe || !json) { LCLogF(@"asr: parse err %@", pe); return; }
                    NSDictionary *respD = json[@"Response"];
                    if (respD[@"Error"]) {
                        // v1.0.87：腾讯云拒绝 AAC → 计数 + 冷却，【不再永久禁用】。
                        // 连续 3 次失败才冷却 60 秒（期间用 WAV 兜底），
                        // 冷却结束自动恢复 AAC —— 网络/服务端抖动不会永久失去压缩。
                        if ([voiceFormat isEqualToString:@"aac"]) {
                            [self markAacFailure:[NSString stringWithFormat:@"%@", respD[@"Error"]]];
                        } else {
                            LCLogF(@"asr: tencent error %@", respD[@"Error"]);
                        }
                        return;
                    }
                    // v1.0.87：AAC 识别成功 → 失败计数清零（压缩继续可用）
                    if ([voiceFormat isEqualToString:@"aac"]) [self markAacSuccess];
                    NSString *text = respD[@"Result"];
                    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
                        LCLogF(@"asr: empty result (%@)", json);
                        return;
                    }
                    text = [text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (text.length == 0) return;
                    LCLogF(@"asr: text [%@]", text);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // seq 配对：英文先上屏（字幕框轮动），译文回来按 seq 回填
                        NSUInteger seq = [[LCSubtitleOverlay shared] showPending:text];
                        [[LCTranslator shared] translate:text
                            completion:^(NSString *tr) {
                                if (tr.length) [[LCSubtitleOverlay shared] showPair:text translation:tr seq:seq];
                                else [[LCSubtitleOverlay shared] showFailed:text seq:seq];
                            }];
                    });
                }];
                [task resume];
            } @catch (NSException *e) {
                LC_ASR_DONE();
                LCLogF(@"asr: process err %@", e);
            }
        }
    });
}

- (void)stop {
    _running = NO;
    LC_ASR_DONE();
    [_pcm setLength:0];
    [_pcm16 setLength:0];
    [[LCStreamASR shared] stop];
}

// ===== AVSampleBuffer 管线（YouTube 自研播放器）输入 =====

// 单声道 float32 输入（appendCMSampleBuffer 转换后）：与现有 float32 累积/重采样/POST 完全复用
- (void)appendMonoFloat:(const float *)mono frames:(UInt32)frames {
    if (!_running) return;
    if (![[LCConfig shared] enabled]) return;
    if (!mono || frames == 0) return;
    if ([[LCStreamASR shared] isActive]) {
        [[LCStreamASR shared] appendMonoFloat:mono frames:frames rate:_inRate];
        return;
    }
    @autoreleasepool {
        [_pcm appendBytes:mono length:frames * sizeof(float)];
        // v1.0.84：分片时长与 appendBufferList: 保持一致（可配置，默认 1.5 秒（v2.0.2，设置面板可调））。
        // 依据（设备日志实证）：ASR RTT ≈ 音频时长 × 1.1，
        // 分片越长延迟越大；5 秒分片 → RTT 5.6s，2.5 秒分片 → RTT 约 2.8s。
        double chunkSecs = [self lc_chunkSeconds];
        double secs = (double)_pcm.length / sizeof(float) / _inRate;
        if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm copy];
            [_pcm setLength:0];
            [self processChunk:chunk];
        } else if (secs > chunkSecs) {
            // v1.0.87：并发槽位满 → 只裁掉【最旧】的音频，保留最近 chunkSecs 秒。
            // 原来整段清空 → 下一片起点不断后移 → 分片越滚越长
            // （设备日志实测出现 3.48/3.72/3.95/4.18/4.41s 长尾）→ 延迟恶化。
            [self trimPCMKeepingSeconds:chunkSecs];
        }
    }
}

- (void)appendPCM16:(NSData *)pcm16 {
    if (!_running) return;
    if (![[LCConfig shared] enabled]) return;
    if (!pcm16 || pcm16.length == 0) return;
    // v2.1.0 主路径：YouTube 自研播放器给的已经是 16k/16bit/mono PCM，
    // 直接切成 200ms 帧推流，零重采样、零编码、零 Base64。
    if ([[LCStreamASR shared] isActive]) {
        [[LCStreamASR shared] appendPCM16:pcm16];
        return;
    }
    @autoreleasepool {
        [_pcm16 appendData:pcm16];
        // v1.0.85：修掉写死的 5 秒分片（v1.0.84 只改了 float 路径，漏了这里）。
        // 统一使用 asrChunkSeconds 配置，默认 1.5 秒（v2.0.2，设置面板可调）。
        double chunkSecs = [self lc_chunkSeconds];
        double secs16 = (double)_pcm16.length / 2.0 / 16000.0;
        if (secs16 >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm16 copy];
            [_pcm16 setLength:0];
            [self processChunk16:chunk];
        } else if (secs16 > chunkSecs) {
            // v1.0.87：并发槽位满 → 只裁掉【最旧】的音频，保留最近 chunkSecs 秒。
            // 原来整段清空 → 分片越滚越长（实测最长 4.41s）。
            [self trimPCM16KeepingSeconds:chunkSecs];
        }
    }
}

- (void)processChunk16:(NSData *)pcm16 {
    // v2.0.2：16k/16bit/mono = 32000 B/s，正常 1.5s 分片 = 48000 B。
    // 不足 0.7s（22400 B）的残片识别出来多半是半截词，丢弃不发 ASR。
    if (!pcm16 || pcm16.length < 22400) {
        LCLogF(@"asr: skip short chunk len=%lu", (unsigned long)pcm16.length);
        return;
    }
    _inFlightCount++;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
                // 2) v1.0.87：优先 AAC(ADTS 封装) 压缩上传。
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
                }
                if (!audioData) {
                    NSMutableData *wav = [NSMutableData dataWithCapacity:pcm16.length + 44];
                    const char *riff = "RIFF";
                    [wav appendBytes:riff length:4];
                    uint32_t riffSize = (uint32_t)(36 + pcm16.length);
                    [wav appendBytes:&riffSize length:4];
                    const char *wave = "WAVE";
                    [wav appendBytes:wave length:4];
                    const char *fmt = "fmt ";
                    [wav appendBytes:fmt length:4];
                    uint32_t fmtSize = 16;
                    [wav appendBytes:&fmtSize length:4];
                    uint16_t audioFmt = 1;
                    [wav appendBytes:&audioFmt length:2];
                    uint16_t chn = 1;
                    [wav appendBytes:&chn length:2];
                    uint32_t rate = 16000;
                    [wav appendBytes:&rate length:4];
                    uint32_t byteRate = 16000 * 2;
                    [wav appendBytes:&byteRate length:4];
                    uint16_t blockAlign = 2;
                    [wav appendBytes:&blockAlign length:2];
                    uint16_t bits = 16;
                    [wav appendBytes:&bits length:2];
                    const char *data = "data";
                    [wav appendBytes:data length:4];
                    uint32_t dataSize = (uint32_t)pcm16.length;
                    [wav appendBytes:&dataSize length:4];
                    [wav appendData:pcm16];
                    audioData = wav;
                }

                NSString *b64 = [audioData base64EncodedStringWithOptions:0];
                NSString *secretId = [[LCConfig shared] tencentSecretId];
                NSString *secretKey = [[LCConfig shared] tencentSecretKey];
                if (secretId.length == 0 || secretKey.length == 0) {
                    LCLog("asr16: tencent keys missing");
                    LC_ASR_DONE();
                    return;
                }
                // v2.0.0：源语言自动检测，统一用中文引擎（默认已覆盖主要场景）
                NSString *eng = @"16k_zh";

                NSDictionary *body = @{
                    @"ProjectId": @0,
                    @"SubServiceType": @2,
                    @"EngSerViceType": eng,
                    @"SourceType": @1,
                    @"VoiceFormat": voiceFormat,
                    @"UsrAudioKey": [NSString stringWithFormat:@"livecap-%@", [[NSUUID UUID] UUIDString]],
                    @"Data": b64,
                    @"DataLen": @(audioData.length),
                    @"FilterDirty": @0,
                    @"FilterModal": @0,
                    @"FilterPunc": @1
                };
                NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
                if (!payload) { LC_ASR_DONE(); return; }

                long long ts = (long long)[[NSDate date] timeIntervalSince1970];
                NSString *tsStr = [NSString stringWithFormat:@"%lld", ts];
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                [df setDateFormat:@"yyyy-MM-dd"];
                [df setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
                NSString *dateStr = [df stringFromDate:[NSDate date]];

                NSString *host = @"asr.tencentcloudapi.com";
                NSString *auth = LCTencentAuthHeader(secretId, secretKey, tsStr, dateStr, payload, host);

                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                    [NSURL URLWithString:@"https://asr.tencentcloudapi.com"]];
                req.HTTPMethod = @"POST";
                [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                [req setValue:host forHTTPHeaderField:@"Host"];
                [req setValue:@"SentenceRecognition" forHTTPHeaderField:@"X-TC-Action"];
                [req setValue:@"2019-06-14" forHTTPHeaderField:@"X-TC-Version"];
                [req setValue:tsStr forHTTPHeaderField:@"X-TC-Timestamp"];
                [req setValue:@"ap-guangzhou" forHTTPHeaderField:@"X-TC-Region"];
                [req setValue:auth forHTTPHeaderField:@"Authorization"];
                req.HTTPBody = payload;
                req.timeoutInterval = 10.0;

                LCLogF(@"asr16: sending %lu bytes (%@ fmt=%@)", (unsigned long)audioData.length,
                       eng, voiceFormat);
                // v1.0.85：备用路径也补上毫秒级打点（原来只有秒级日志）
                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
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
                    }
                    NSError *__autoreleasing pe = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
                    if (pe || !json) { LCLogF(@"asr16: parse err %@", pe); return; }
                    NSDictionary *respD = json[@"Response"];
                    if (respD[@"Error"]) {
                        // v1.0.87：拒绝 AAC → 计数 + 冷却，【不再永久禁用】。
                        // 连续 3 次失败才冷却 60 秒（期间用 WAV 兜底），到期自动恢复。
                        if ([voiceFormat isEqualToString:@"aac"]) {
                            [self markAacFailure:[NSString stringWithFormat:@"%@", respD[@"Error"]]];
                        } else {
                            LCLogF(@"asr16: tencent error %@", respD[@"Error"]);
                        }
                        return;
                    }
                    // v1.0.87：AAC 识别成功 → 失败计数清零（压缩继续可用）
                    if ([voiceFormat isEqualToString:@"aac"]) [self markAacSuccess];
                    NSString *text = respD[@"Result"];
                    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
                        LCLogF(@"asr16: empty result (%@)", json);
                        return;
                    }
                    text = [text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (text.length == 0) return;
                    LCLogF(@"asr16: text [%@]", text);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // seq 配对：英文先上屏（字幕框轮动），译文回来按 seq 回填
                        NSUInteger seq = [[LCSubtitleOverlay shared] showPending:text];
                        [[LCTranslator shared] translate:text
                            completion:^(NSString *tr) {
                                if (tr.length) [[LCSubtitleOverlay shared] showPair:text translation:tr seq:seq];
                                else [[LCSubtitleOverlay shared] showFailed:text seq:seq];
                            }];
                    });
                }];
                [task resume];
            } @catch (NSException *e) {
                LC_ASR_DONE();
                LCLogF(@"asr16: process err %@", e);
            }
        }
    });
}

@end

#pragma mark - 悬浮字幕

@implementation LCSubtitleOverlay {
    UIView *_container;
    UIVisualEffectView *_blurView;
    UILabel *_originLabel;
    UILabel *_transLabel;
    UIView *_dragHandle;          // 拖动把手（只有按住它才能拖动字幕框）
    BOOL _installed;
    BOOL _dragging;
    CGPoint _dragStartCenter;
    // ===== v1.0.81 seq 配对状态 =====
    // _displayedOrigin / _displayedTranslation 是当前【同时显示】的一对内容。
    // _displayedSeq 记录当前画面属于第几句（seq 由 showPending 分配）。
    // 译文回来时用 seq 对账：seq < _displayedSeq 说明这句已经过时，直接丢弃，
    // 避免出现「画面是新英文、下面挂着旧译文」的错配。
    NSString *_displayedOrigin;
    NSString *_displayedTranslation;
    NSString *_pendingOrigin;      // 最新一句英文，翻译还在路上
    NSUInteger _seqCounter;        // 单调递增的句子序号分配器
    NSUInteger _displayedSeq;      // 双语模式：当前画面对应的 seq
    NSUInteger _pendingSeq;        // 最新一句待翻译的 seq
    // ===== v1.0.82：只显示中文一行 =====
    // _transSeq  = 当前显示的译文对应的 seq（只中文模式的对账基准）
    // _placeholder = 尚无可显示译文时的占位文字（翻译中… / 翻译失败）
    NSUInteger _transSeq;
    NSString *_placeholder;
    BOOL _toastActive;         // toast 展示中：不要覆盖/隐藏 origin 标签
    BOOL _userMoved;              // 用户手动拖动过 → 不再按配置重置位置
    CGPoint _userCenter;          // 用户拖到的位置（_userMoved 时沿用）
    // ===== v1.0.87：配置热重载（字号改完立即生效）=====
    // _lastFontSize：上次渲染用的字号；配置监听器发现变化就重排重绘。
    // _configTimer：0.4s 一次的轻量定时器，只比对字号数值（一次 plist 读取）。
    CGFloat _lastFontSize;
    dispatch_source_t _configTimer;
}

+ (instancetype)shared {
    static LCSubtitleOverlay *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LCSubtitleOverlay alloc] init]; });
    return s;
}

- (void)install {
    if (_installed) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *keyWindow = nil;

        // iOS 13+ 必须用 connectedScenes 获取窗口（YouTube 多场景 App keyWindow 可能为 nil）
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (!windowScene) continue;
            // 优先找 keyWindow
            for (UIWindow *w in windowScene.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
            if (keyWindow) break;
            // Fallback: 找第一个有 rootViewController.view 的窗口
            for (UIWindow *w in windowScene.windows) {
                if (w.rootViewController && w.rootViewController.view) {
                    keyWindow = w;
                    LCLog("overlay: using foreground scene window");
                    break;
                }
            }
            if (keyWindow) break;
        }

        // 最后兜底：遍历 app.windows
        if (!keyWindow) {
            for (UIWindow *w in app.windows) {
                if (w.rootViewController && w.rootViewController.view) {
                    keyWindow = w;
                    LCLog("overlay: using fallback all-windows");
                    break;
                }
            }
        }

        if (!keyWindow) { LCLog("overlay: no keyWindow found"); return; }
        // 挂到 keyWindow 本身（而不是 rootViewController.view）：
        // 1) 层级最高，不会被 App 内部的全屏播放层/手势层盖住导致拖不动
        // 2) 不受 App 视图树变化影响
        UIView *parent = keyWindow;
        if (!parent) { LCLog("overlay: no rootVC view"); return; }

        CGFloat fs = [LCConfig shared].fontSize;
        BOOL bold = [[LCConfig shared] boldText];
        UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
        container.backgroundColor = [UIColor clearColor];

        UILabel *ol = [[UILabel alloc] initWithFrame:CGRectZero];
        ol.font = [UIFont systemFontOfSize:fs weight:(bold ? UIFontWeightBold : UIFontWeightMedium)];
        ol.textColor = [UIColor whiteColor];
        ol.numberOfLines = 0;  // 不限行数：文本多长框多高（show 时仍带屏幕上限保护）
        ol.lineBreakMode = NSLineBreakByWordWrapping;
        ol.userInteractionEnabled = NO;
        [container addSubview:ol];
        _originLabel = ol;

        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectZero];
        tl.font = [UIFont systemFontOfSize:fs - 1 weight:(bold ? UIFontWeightSemibold : UIFontWeightRegular)];
        tl.textColor = [UIColor colorWithRed:0.62 green:0.92 blue:1.0 alpha:1.0];
        tl.numberOfLines = 0;
        tl.lineBreakMode = NSLineBreakByWordWrapping;
        tl.userInteractionEnabled = NO;
        [container addSubview:tl];
        _transLabel = tl;

        // 字幕位置默认手动：容器始终可拖动，每个 App 分别记忆最后位置
        // 拖动方式：在字幕框左上角放一个专用的「拖动把手」，
        // 只有按住把手才能拖动字幕框。
        // 不用 pan/长按：YouTube 全屏播放时 video view 上有自己的
        // 滑动(进度条)/长按(2倍速)/双击(暂停)手势，
        // 我们的手势挂在同一个 window 上会被它们 cancel 掉（表现为怎么拖都拖不动），
        // 用独立把手则完全避开竞争。
        container.userInteractionEnabled = YES;

        // 拖动把手：半透明白色圆点 + 深色双向箭头，直观且不遮挡字幕
        UIView *handle = [[UIView alloc] initWithFrame:CGRectZero];
        handle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        handle.layer.cornerRadius = 13.0;
        handle.layer.borderWidth = 2.0;
        handle.layer.borderColor = [UIColor colorWithWhite:0.1 alpha:0.9].CGColor;
        handle.userInteractionEnabled = YES;
        handle.accessibilityIdentifier = @"LiveCapDragHandle";
        // 关键：必须立刻给出可见尺寸。
        // 若等到 showOriginal 才定位，而 ASR 还没出结果（showOriginal 未被调用），
        // 把手会一直是 CGRectZero —— 表现为「右上角没有白点」。
        handle.frame = CGRectMake(2, 2, 26, 26);
        [container addSubview:handle];
        _dragHandle = handle;

        // 把手用 UIPanGestureRecognizer：它是独立的小 view，
        // YouTube 的手势不会覆盖它（YouTube 手势在 video view 上）
        UIPanGestureRecognizer *hp = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleHandlePan:)];
        hp.cancelsTouchesInView = NO;
        hp.delegate = self;   // 关键：允许与 YouTube 的手势同时识别
        [handle addGestureRecognizer:hp];

        [parent addSubview:container];
        _container = container;
        _installed = YES;

        // 关键：立即给 container 一个可见的尺寸和位置。
        // 否则在 ASR 首次出结果之前，字幕框是 CGRectZero（不可见），
        // 把手也跟着不可见 —— 表现为「字幕框没有、右上角没有白点」。
        [self layoutInitialFrame];

        // v1.0.84：注册窗口变化监听（全屏/旋转时重新布局 + 提到最上层）
        [self observeWindowChanges];

        // v1.0.87：启动配置监听（字号改了立即重排）
        [self startConfigWatcher];

        LCLog("overlay: installed");
    } @catch (NSException *e) {
        LCLog("overlay: install error");
        _container = nil;
        _installed = NO;
    }
}

// ===== v1.0.87：配置热重载（字号改完立即生效）=====
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

// v1.0.84：找出当前应该承载字幕的 window。
// 优先用 key window：YouTube 全屏若新建 window，那个新 window 会成为 key，
// 我们必须跟着搬过去，否则字幕留在旧 window 里被完全盖住。
// 注意：键盘 window 的 windowLevel 很高但不是 key，且不是我们的目标 ——
//       所以只用 key window 判定，不按 windowLevel 挑。
- (UIWindow *)bestHostWindow {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *key = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && !w.hidden && w.alpha > 0.01) { key = w; break; }
        }
        if (key) break;
    }
    if (key) return key;
    // 兜底：遍历 app.windows 找 key
    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow && !w.hidden) return w;
    }
    // 再兜底：第一个有 rootViewController 的可见 window
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.rootViewController && w.rootViewController.view) return w;
        }
    }
    return nil;
}

// v1.0.84：确保 container 挂在正确的 window 上。
// 全屏新建 window 时把 container 搬过去（保留相对位置比例）。
- (void)ensureInBestWindow {
    if (!_container) return;
    UIWindow *host = [self bestHostWindow];
    if (!host) return;
    if (_container.superview == host) return;
    UIWindow *old = _container.window;
    // 记录迁移前的相对位置比例，迁移后按新窗口尺寸还原
    CGFloat oldW = old ? old.bounds.size.width : 0;
    CGFloat oldH = old ? old.bounds.size.height : 0;
    CGFloat relX = 0.5, relY = 0.5;
    if (oldW > 0 && oldH > 0) {
        relX = _container.center.x / oldW;
        relY = _container.center.y / oldH;
    }
    @try {
        [_container removeFromSuperview];
        [host addSubview:_container];
        // 按新窗口尺寸还原相对位置
        CGPoint c = CGPointMake(relX * host.bounds.size.width,
                                relY * host.bounds.size.height);
        _container.center = c;
        _userCenter = c;
        LCLogF(@"overlay: re-homed to new window (old=%@ new=%@ size=%@)",
               NSStringFromClass([old class]), NSStringFromClass([host class]),
               NSStringFromCGRect(host.bounds));
    } @catch (NSException *e) {
        LCLog(@"overlay: re-home error");
    }
}

// v1.0.84：把字幕 container 提到所在 window 的最顶层。
// 解决「YouTube 全屏时字幕被全屏 VC 的 view 盖住」的问题。
- (void)bringToFrontIfNeeded {
    // 先确保挂在正确的 window 上（全屏新建 window 的情况）
    [self ensureInBestWindow];
    UIView *parent = _container.superview;
    if (!parent) return;
    // 已经是最后一个 subview 就没必要再动（避免每次渲染都触发重排）
    if (parent.subviews.lastObject == _container) return;
    @try {
        [parent bringSubviewToFront:_container];
        LCLogF(@"overlay: brought to front (parent=%@ subviews=%lu)",
               NSStringFromClass([parent class]), (unsigned long)parent.subviews.count);
    } @catch (NSException *e) {
        LCLog(@"overlay: bringToFront error");
    }
}

// v1.0.84：窗口尺寸/可见性变化监听。
// 全屏播放时 window bounds 会从竖屏 393x852 变成横屏 852x393，
// 若不重新布局，字幕会按旧的竖屏尺寸排版（宽度过大、位置偏移）。
- (void)observeWindowChanges {
    static BOOL registered = NO;
    if (registered) return;
    registered = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // UIWindowDidBecomeVisible：全屏 VC 出现后把我们提到最上层
    [nc addObserverForName:UIWindowDidBecomeVisibleNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self bringToFrontIfNeeded];
            [self renderCurrent];
            LCLogF(@"overlay: window became visible, re-layout (super=%@)",
                   NSStringFromCGRect(_container.superview.bounds));
        });
    }];
    // 尺寸变化：旋转 / 全屏切换都会触发。
    // 注意：UIKit 没有「window frame 变化」这种通知
    //（UIKit 根本没有「window frame 变化」通知，CI 编译会报 undeclared identifier）。
    // 旋转用下面这两个通知覆盖：
    //   UIDeviceOrientationDidChangeNotification —— 设备物理旋转
    //   UIApplicationDidChangeStatusBarOrientationNotification —— 状态栏方向变化
    [nc addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];
    [nc addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];
    // v1.0.84：key window 变化 = 全屏新建了 window → 必须把字幕搬过去
    [nc addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensureInBestWindow];
            [self renderCurrent];
            LCLogF(@"overlay: key window changed -> re-homed (super=%@)",
                   NSStringFromCGRect(_container.superview.bounds));
        });
    }];
}

// 初始化字幕框位置/尺寸（ASR 尚未出结果时也保证可见）
- (void)layoutInitialFrame {
    if (!_container) return;
    CGFloat fs = [[LCConfig shared] fontSize];
    CGFloat pad = 10;
    CGRect hostBounds = _container.superview ? _container.superview.bounds
                                             : [UIScreen mainScreen].bounds;
    CGFloat hostW = hostBounds.size.width;
    CGFloat hostH = hostBounds.size.height;
    CGFloat w = hostW - 32 + pad * 2;
    CGFloat h = fs + pad * 2;
    if (w < 80) w = 80;
    CGFloat mx = [[LCConfig shared] manualX];
    CGFloat my = [[LCConfig shared] manualY];
    CGFloat spanX = MAX(hostW - w, 1);
    CGFloat spanY = MAX(hostH - h, 1);
    CGFloat x = mx * spanX;
    CGFloat y = my * spanY;
    _container.frame = CGRectMake(x, y, w, h);
    _container.hidden = NO;
    // 把手定位到右上角内侧
    if (_dragHandle) {
        CGFloat hs = 26.0;
        _dragHandle.frame = CGRectMake(w - hs - 4, 4, hs, hs);
    }
    LCLogF(@"overlay: initial frame c=(%.0f,%.0f,%.0f,%.0f)",
           x, y, w, h);
}

#pragma mark - 手势同时识别
// 核心修复：YouTube 在 video view / window 上装了滑动、长按、双击等手势。
// 默认情况下同一次触摸只允许一个手势识别，另一个会被 cancel —— 表现为「怎么拖都拖不动」。
// 实现本 delegate 后，我们的拖动把手手势可以和 App 的手势同时识别，互不干扰。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

// 我们的手势已经识别时，不要求其他手势先失败
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

- (void)handleHandlePan:(UIPanGestureRecognizer *)g {
    if (!_container) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        _dragStartCenter = _container.center;
        LCLogF(@"drag: begin center=(%.1f,%.1f)", _dragStartCenter.x, _dragStartCenter.y);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (!_dragging) return;
        CGPoint t = [g translationInView:_container.superview];
        _container.center = CGPointMake(_dragStartCenter.x + t.x, _dragStartCenter.y + t.y);
        _userCenter = _container.center;
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        if (!_dragging) return;
        _dragging = NO;
        // 用户拖过之后就沿用当前位置，不再被 showOriginal 重置
        _userMoved = YES;
        _userCenter = _container.center;
        LCLogF(@"drag: end center=(%.1f,%.1f)", _userCenter.x, _userCenter.y);
        // 归一化当前位置并按 App 记录（0-1 百分比），下次打开/切回该 App 自动恢复
        CGRect r = _container.frame;
        CGRect p = _container.superview.bounds;
        CGFloat spanX = MAX(p.size.width - r.size.width, 1);
        CGFloat spanY = MAX(p.size.height - r.size.height, 1);
        CGFloat mx = MIN(MAX(r.origin.x / spanX, 0), 1);
        CGFloat my = MIN(MAX(r.origin.y / spanY, 0), 1);
        [[LCConfig shared] saveManualX:mx y:my];
    }
}

// 白字黑描边 + 彩色描边：任何背景都清晰（Metal/视频画面读不到，直接硬描边）
static NSMutableAttributedString *LCStrokedText(NSString *text, UIColor *color, UIFont *font) {
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:text ?: @""];
    if (as.length == 0) return as;
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    CGFloat lum = 0.299*r + 0.587*g + 0.114*b;
    UIColor *stroke = (lum > 0.5) ? [UIColor blackColor] : [UIColor whiteColor];
    NSDictionary *attrs = @{
        NSForegroundColorAttributeName: color,
        NSStrokeColorAttributeName: stroke,
        NSStrokeWidthAttributeName: @(-font.pointSize * 0.18),
        NSFontAttributeName: font,
    };
    [as addAttributes:attrs range:NSMakeRange(0, as.length)];
    return as;
}

// ===== 原子配对显示 =====
// 背景：翻译是异步的（网络往返 0.5~2s），而 ASR 每 4~5s 就换一句。
// v1.0.80 的「原子配对」实现有致命缺陷：showPending 只在「从未显示过任何内容」时
// 才刷新画面。于是第一句之后，后续每一句 pending 都只更新 _pendingOrigin 而
// 【不碰画面】，画面被永久冻结在第一句 —— 实测日志里 9 条 pending 只对应 1 次
// showFailed，字幕框表现为「不轮动」。
//
// v1.0.81 改为 seq 配对：
//   showPending  → 分配 seq，立刻把英文刷上屏（字幕框随语音轮动）
//   showPair     → 译文回来，seq 对账通过才回填中文；seq 过时直接丢弃
//   showFailed   → 翻译失败，seq 对账通过才确认（此时画面已是该句英文，无需重刷）
- (NSUInteger)showPending:(NSString *)origin {
    if (!_container || !_installed) {
        LCLogF(@"overlay: show skipped (container=%d installed=%d)", _container != nil, _installed);
        return 0;
    }
    @try {
        if (origin.length == 0) return 0;
        NSUInteger seq = ++_seqCounter;
        _pendingOrigin = origin;
        _pendingSeq = seq;

        if (![[LCConfig shared] showEnglish]) {
            // ===== 只显示中文一行 =====
            // 【不】清空当前译文、也不重刷画面：保留上一句中文直到新译文到达。
            // 这是标准字幕行为（Netflix / YouTube 都是上一句保持到下一句出现），
            // 若在这里清空，翻译的 1~2s 延迟会让字幕框反复闪「翻译中…」非常刺眼。
            if (_displayedTranslation.length == 0) {
                _placeholder = @"翻译中…";
                [self renderCurrent];
            }
            LCLogF(@"overlay: pending seq=%lu origin=[%@] (zh-only, keeping last)", (unsigned long)seq, origin);
            return seq;
        }

        // ===== 双语模式 =====
        // 立即刷新画面：新英文立刻上屏，字幕框随语音轮动。
        // 译文暂时清空，等 showPair 回来再补上 —— 宁可短暂缺中文，也不能卡住不动。
        _displayedOrigin = origin;
        _displayedTranslation = nil;
        _displayedSeq = seq;
        [self renderCurrent];
        LCLogF(@"overlay: pending seq=%lu origin=[%@]", (unsigned long)seq, origin);
        return seq;
    } @catch (NSException *e) {
        LCLog(@"overlay: pending error");
        return 0;
    }
}

// partial（半句）只登记，不刷屏 —— 避免半句话反复顶掉完整句子
- (void)showPartial:(NSString *)origin {
    @try {
        if (origin.length == 0) return;
        _pendingOrigin = origin;
    } @catch (NSException *e) {}
}

// 翻译成功：回填中文。seq 过期说明这句已经滚过去了，丢弃以免错配。
- (void)showPair:(NSString *)origin translation:(NSString *)translation seq:(NSUInteger)seq {
    if (!_container || !_installed) {
        LCLogF(@"overlay: show skipped (container=%d installed=%d)", _container != nil, _installed);
        return;
    }
    @try {
        if (origin.length == 0) return;
        if (translation.length == 0) { [self showFailed:origin seq:seq]; return; }
        if (![[LCConfig shared] showEnglish]) {
            // 只中文模式：对账基准是 _transSeq（当前显示的译文）
            if (seq != 0 && seq < _transSeq) {
                LCLogF(@"overlay: drop stale pair seq=%lu (transSeq=%lu) origin=[%@]",
                       (unsigned long)seq, (unsigned long)_transSeq, origin);
                return;
            }
            // v2.2.0：_transSeq 只能挡「比当前画面更旧」的译文。
            // 语音已走到第 N 句、第 N-3 句的译文才回来时 seq >= _transSeq 仍会被
            // 接受 → 讲的 A 却显示 B。以最新登记句 _pendingSeq 为基准，
            // 落后 ≥2 句直接丢弃（允许落后 1 句，避免翻译稍慢就完全没字幕）。
            if (seq != 0 && _pendingSeq > seq + 1) {
                LCLogF(@"overlay: drop lagging pair seq=%lu (latest=%lu) origin=[%@]",
                       (unsigned long)seq, (unsigned long)_pendingSeq, origin);
                return;
            }
            _displayedTranslation = translation;
            _displayedOrigin = origin;
            _transSeq = seq ? seq : _transSeq;
            _placeholder = nil;
            if (seq && seq == _pendingSeq) _pendingOrigin = nil;
            LCLogF(@"overlay: showPair seq=%lu origin=[%@] trans=[%@] transLen=%lu (zh-only)",
                   (unsigned long)seq, origin, translation, (unsigned long)translation.length);
            [self renderCurrent];
            return;
        }
        if (seq != 0 && seq < _displayedSeq) {
            LCLogF(@"overlay: drop stale pair seq=%lu (displayed=%lu) origin=[%@]",
                   (unsigned long)seq, (unsigned long)_displayedSeq, origin);
            return;
        }
        _displayedOrigin = origin;
        _displayedTranslation = translation;
        _displayedSeq = seq ? seq : _displayedSeq;
        if (seq && seq == _pendingSeq) _pendingOrigin = nil;
        LCLogF(@"overlay: showPair seq=%lu origin=[%@] trans=[%@] transLen=%lu",
               (unsigned long)seq, origin, translation, (unsigned long)translation.length);
        [self renderCurrent];
    } @catch (NSException *e) {
        LCLog(@"overlay: showPair error");
    }
}

// 翻译彻底失败：画面已经是这句英文（showPending 已刷过），无需重刷，只做记账。
- (void)showFailed:(NSString *)origin seq:(NSUInteger)seq {
    if (!_container || !_installed) return;
    @try {
        if (origin.length == 0) return;
        if (![[LCConfig shared] showEnglish]) {
            // 只中文模式：翻译失败时【保留】上一句中文（不要清空字幕框）。
            // 若从来没成功译过一句，则显示「翻译失败」占位，而不是留一个空框。
            if (_displayedTranslation.length == 0) {
                _placeholder = @"翻译失败";
                [self renderCurrent];
            }
            if (seq && seq == _pendingSeq) _pendingOrigin = nil;
            LCLogF(@"overlay: showFailed seq=%lu origin=[%@] (zh-only)", (unsigned long)seq, origin);
            return;
        }
        if (seq != 0 && seq < _displayedSeq) {
            LCLogF(@"overlay: drop stale fail seq=%lu (displayed=%lu)",
                   (unsigned long)seq, (unsigned long)_displayedSeq);
            return;
        }
        _displayedOrigin = origin;
        _displayedTranslation = nil;
        _displayedSeq = seq ? seq : _displayedSeq;
        if (seq && seq == _pendingSeq) _pendingOrigin = nil;
        LCLogF(@"overlay: showFailed seq=%lu origin=[%@]", (unsigned long)seq, origin);
    } @catch (NSException *e) {
        LCLog(@"overlay: showFailed error");
    }
}

// 渲染当前成对内容（_displayedOrigin + _displayedTranslation）
//
// v1.0.82：字幕只显示中文一行。
// 用户实测反馈「有时候是两行 一行英文 一行中文，我只要一行中文就行了」。
// showEnglish = NO（默认）：
//   - 英文行完全不画（标签 hidden，frame 归零，不参与高度计算）
//   - 中文独占整行，字号升到与英文同级（fs 而非 fs-1），颜色跟随用户设置
//   - 还没有任何译文时显示「翻译中…」，避免出现一个空框
// showEnglish = YES（用户在设置面板切回）：
//   - 保持 v1.0.81 的双语布局
- (void)renderCurrent {
    @try {
        // toast 展示期间不重排画面：toast 自己管布局，
        // 否则容器的居中位置会被字幕位置覆盖、且字幕文字会叠在 toast 上。
        // toast 结束后会再调一次 renderCurrent 恢复正常字幕。
        if (_toastActive) return;

        BOOL showEn = [[LCConfig shared] showEnglish];
        NSString *origin = showEn ? (_displayedOrigin ?: @"") : @"";
        NSString *translation = _displayedTranslation ?: @"";
        UIColor *tc = [[LCConfig shared] textColor];

        // 只显示中文时，中文升为「主字幕」：用主字号 + 用户设定颜色
        // 双语模式时维持原样：英文主字号(tc)，中文次字号(浅蓝)
        if (showEn) {
            _transLabel.font = [UIFont systemFontOfSize:[[LCConfig shared] fontSize] - 1
                                                  weight:([[LCConfig shared] boldText] ? UIFontWeightSemibold : UIFontWeightRegular)];
            _transLabel.textColor = [UIColor colorWithRed:0.62 green:0.92 blue:1.0 alpha:1.0];
        } else {
            _transLabel.font = [UIFont systemFontOfSize:[[LCConfig shared] fontSize]
                                                  weight:([[LCConfig shared] boldText] ? UIFontWeightBold : UIFontWeightMedium)];
            _transLabel.textColor = tc;
        }

        // 只显示中文且还没有任何译文 → 显示占位提示，不要空框
        if (!showEn && translation.length == 0) {
            translation = _placeholder ?: @"";
        }

        if (!_toastActive) {
            _originLabel.attributedText = LCStrokedText(origin, tc, _originLabel.font);
            _transLabel.attributedText = LCStrokedText(translation, tc, _transLabel.font);
        }

        // ===== v1.0.84：全屏字幕不显示 =====
        // 根因：YouTube 全屏播放时会 present 一个全屏 VC，
        //       该 VC 的 view 被加到 window 的 subviews【末尾】= 最上层，
        //       把我们挂在 window 上的字幕 container 直接盖住。
        // 现象：竖屏能显示，一进全屏字幕就消失。
        // 修复：每次渲染前把 container 提到 window 最顶层。
        // 代价：可忽略（一次 bringSubviewToFront）。
        [self bringToFrontIfNeeded];

        CGFloat fs = [LCConfig shared].fontSize;
        // v1.0.87：同步记录本次使用的字号，供配置监听器比对
        _lastFontSize = fs;
        CGFloat margin = 16;
        // 尺寸基于 superview（现在是 keyWindow），
        // 横屏时 window.bounds 的宽高与屏幕相反，不能用 mainScreen
        CGRect hostBounds = _container.superview ? _container.superview.bounds : [UIScreen mainScreen].bounds;
        CGFloat hostW = hostBounds.size.width;
        CGFloat hostH = hostBounds.size.height;
        // v1.0.85：字幕框宽度上限。
        // 问题：全屏横屏时 hostW=852 → maxW=820 → 容器宽 840，几乎占满整屏，
        //       用户反馈「全屏的时候字幕框太宽了」。
        // 做法：① 绝对上限 460pt（横屏不再随屏幕拉满）
        //       ② 下方再按译文实际宽度收窄（短句就不占大片背景）
        CGFloat maxW = MIN(hostW - margin * 2, 460.0);

        CGFloat pad = 10;
        // 完整测量两段文本高度（不截断，文本多长框多高）
        // 测量宽度与实际 label 宽度一致（要避开右上角的拖动把手）
        CGFloat handleSpace = _dragHandle ? 26.0 : 0.0;
        // v1.0.85：内容自适应宽度。
        // 按译文单行实际宽度收窄容器，短句时背景不再铺满整行。
        // 宽度下限 200pt（太窄会导致中文频繁换行、框变高）。
        if (translation.length && _transLabel.font) {
            CGFloat tw = [translation sizeWithAttributes:
                @{NSFontAttributeName: _transLabel.font}].width;
            CGFloat desired = tw + handleSpace + pad * 2 + 10.0;
            CGFloat lo = MIN(200.0, hostW - margin * 2);
            maxW = MAX(MIN(desired, maxW), lo);
        }
        // v1.0.83：测量宽度必须【扣掉左右内边距】。
        // 旧实现 measureW = maxW - handleSpace，但 label 实际放在 x=pad 处、宽 textW，
        // 文字真正能用的宽度 = textW - 2*pad 的量级；
        // 测量宽度算多了 → 换行数比实际少 → th 偏小 → 标签高度不够 → 末行被裁。
        CGFloat measureW = maxW - handleSpace - pad * 2;
        CGFloat oh = 0, th = 0;
        if (origin.length) {
            oh = [origin boundingRectWithSize:CGSizeMake(measureW, CGFLOAT_MAX)
                options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{NSFontAttributeName:_originLabel.font} context:nil].size.height;
        }
        if (translation.length) {
            th = [translation boundingRectWithSize:CGSizeMake(measureW, CGFLOAT_MAX)
                options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{NSFontAttributeName:_transLabel.font} context:nil].size.height;
        }

        CGFloat w = maxW + pad * 2;
        CGFloat h = pad * 2 + oh + th + (origin.length && translation.length ? 4 : 0);
        if (h < fs + pad * 2) h = fs + pad * 2;

        CGFloat sw = hostW;
        CGFloat sh = hostH;
        // 安全上限：极端长文本时最多占 45% 屏高，防止霸屏
        h = MIN(h, sh * 0.45);
        [self applyBackgroundStyle:CGSizeMake(w, h)];

        // 按当前 App 记忆的位置（0-1 百分比）定位
        // 注意：用户手动拖动过之后，必须沿用用户位置，
        // 否则 showOriginal 每 5 秒（每轮 ASR）都会把位置重算回配置值，
        // 表现为「怎么拖都弹回原处」。
        CGFloat mx = [[LCConfig shared] manualX];
        CGFloat my = [[LCConfig shared] manualY];
        CGFloat spanX = MAX(sw - w, 1);
        CGFloat spanY = MAX(sh - h, 1);
        if (_userMoved) {
            // v1.0.83 修复：用户拖动过之后【必须仍然更新容器尺寸】。
            // 旧实现只改 center 不改 size → 容器高度被永久冻结在拖动那一刻的高度
            // （实测 58pt），而中文字幕被排到 y=71（高 36），底边 107 超出容器 58，
            // 被 masksToBounds=YES 直接裁掉 → 用户看到「中文没显示全」。
            // 正确做法：保留用户拖到的中心点，但尺寸照常按当前文本高度重算。
            CGRect f = _container.frame;
            f.size = CGSizeMake(w, h);
            // 保持中心点不变（用户拖到的位置），只改尺寸
            f.origin = CGPointMake(_userCenter.x - w / 2.0, _userCenter.y - h / 2.0);
            // v1.0.84：把 container 钳制在宿主 bounds 内。
            // 竖屏 (393x852) 拖到 (189,320)，转横屏 (852x393) 后
            // 320 + 高度/2 可能超出底边 → 字幕被推出屏幕（全屏时看不见）。
            CGFloat minX = w / 2.0;
            CGFloat maxX = MAX(sw - w / 2.0, minX);
            CGFloat minY = h / 2.0;
            CGFloat maxY = MAX(sh - h / 2.0, minY);
            f.origin.x = MIN(MAX(f.origin.x, minX - w / 2.0), maxX - w / 2.0);
            f.origin.y = MIN(MAX(f.origin.y, minY - h / 2.0), maxY - h / 2.0);
            _container.frame = f;
            _userCenter = _container.center;
        } else {
            CGFloat x = mx * spanX;
            CGFloat y = my * spanY;
            _container.frame = CGRectMake(x, y, w, h);
        }
        CGFloat ly = pad;
        // 文字区域避开右上角的拖动把手
        CGFloat textW = maxW - handleSpace;
        if (origin.length) {
            _originLabel.frame = CGRectMake(pad, ly, textW, oh);
            _originLabel.hidden = NO;
            ly += oh + 4;
        } else if (!_toastActive) {
            // v1.0.83：只中文模式下英文标签必须彻底收起。
            // 除了 frame 归零，还要清空 attributedText —— 否则 label 仍持有上一句英文，
            // 若后续任何分支漏了 hidden=YES，英文会再次闪现。
            // 只显示中文时英文行必须彻底收起（frame 归零 + hidden），
            // 否则会残留上一句英文，表现为「两行：上面英文下面中文」
            _originLabel.frame = CGRectZero;
            _originLabel.hidden = YES;
            // 清空文本，彻底杜绝英文残留（只中文模式下的最后一道保险）
            _originLabel.attributedText = nil;
        }
        if (translation.length) {
            _transLabel.frame = CGRectMake(pad, ly, textW, th);
            _transLabel.hidden = NO;
        } else {
            // 没有译文时必须把中文标签收起，否则会残留上一句的中文
            // （表现为「新英文 + 旧中文」的半英半中）
            _transLabel.frame = CGRectZero;
            _transLabel.hidden = YES;
        }
        // 拖动把手：字幕框右上角内侧
        if (_dragHandle) {
            CGFloat hs = 26.0;
            _dragHandle.frame = CGRectMake(w - hs - 4, 4, hs, hs);
            _dragHandle.hidden = NO;
        }
        // 没有任何文字时隐藏容器，避免出现一个只有背景的空框
        BOOL hasContent = (origin.length > 0) || (translation.length > 0);
        _container.hidden = !hasContent;
        LCLogF(@"overlay: layout c=(%.0f,%.0f,%.0f,%.0f) oLbl=(%.0f,%.0f,h=%.0f) tLbl=(%.0f,%.0f,h=%.0f) oh=%.1f th=%.1f super=%@",
              _container.frame.origin.x, _container.frame.origin.y, _container.frame.size.width, _container.frame.size.height,
              _originLabel.frame.origin.x, _originLabel.frame.origin.y, _originLabel.frame.size.height,
              _transLabel.frame.origin.x, _transLabel.frame.origin.y, _transLabel.frame.size.height,
              oh, th, NSStringFromCGRect(_container.superview.bounds));
        LCLogF(@"overlay: tLbl text=[%@] hidden=%d alpha=%.2f superHidden=%d",
              _transLabel.text, _transLabel.hidden, _transLabel.alpha, _transLabel.superview.hidden);
        if (_dragHandle) {
            LCLogF(@"overlay: handle frame=%@ hidden=%d superHidden=%d clips=%d containerClips=%d",
                  NSStringFromCGRect(_dragHandle.frame), _dragHandle.hidden,
                  _dragHandle.superview.hidden, _dragHandle.clipsToBounds,
                  _container.clipsToBounds);
        }
    } @catch (NSException *e) {
        LCLog("overlay: show error");
    }
}

// 字幕背景样式：1 无背景（描边）/ 2 半透明黑 / 3 实黑 / 4 半透明白 / 5 毛玻璃
- (void)applyBackgroundStyle:(CGSize)size {
    NSString *style = [[LCConfig shared] backgroundStyle];
    _container.layer.cornerRadius = 0;
    _container.layer.masksToBounds = NO;
    _container.backgroundColor = [UIColor clearColor];
    if (_blurView) _blurView.hidden = YES;
    if ([style isEqualToString:@"none"]) return;

    _container.layer.cornerRadius = 10;
    _container.layer.masksToBounds = YES;
    if ([style isEqualToString:@"darktrans"]) {
        _container.backgroundColor = [UIColor colorWithWhite:0 alpha:0.66];
    } else if ([style isEqualToString:@"darksolid"]) {
        _container.backgroundColor = [UIColor blackColor];
    } else if ([style isEqualToString:@"lighttrans"]) {
        _container.backgroundColor = [UIColor colorWithWhite:1 alpha:0.75];
    } else {  // frost 毛玻璃
        if (!_blurView) {
            UIVisualEffectView *bv = [[UIVisualEffectView alloc]
                initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
            bv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            bv.userInteractionEnabled = NO;
            [_container addSubview:bv];
            [_container sendSubviewToBack:bv];
            _blurView = bv;
        }
        _blurView.hidden = NO;
        _blurView.frame = (CGRect){CGPointZero, size};
        _container.backgroundColor = [UIColor clearColor];
        // 毛玻璃必须留在最底层，否则会盖住字幕文字和拖动把手
        [_container sendSubviewToBack:_blurView];
    }
}

- (void)hide {
    _container.hidden = YES;
    _pendingOrigin = nil;
    _displayedOrigin = nil;
    _displayedTranslation = nil;
    _placeholder = nil;
    // _transSeq 【不】重置：保持单调递增，这样 hide 之前发出的译文回来时
    // 会因 seq < _transSeq 被丢弃，不会把已隐藏的字幕又画回来。
    // seq 计数器【不】重置：保持单调递增，这样 hide 之前发出的译文回来时
    // 会因 seq < _displayedSeq 被丢弃，不会把已隐藏的字幕又画回来。
}

// 快速开关提示（复用字幕条，2 秒后自动消失）
- (void)showToast:(NSString *)text {
    if (!_container || !_installed) return;
    @try {
        _originLabel.attributedText = LCStrokedText(text, [[LCConfig shared] textColor], _originLabel.font);
        _transLabel.attributedText = nil;
        CGFloat fs = [LCConfig shared].fontSize;
        CGFloat margin = 24;
        CGRect toastBounds = _container.superview ? _container.superview.bounds : [UIScreen mainScreen].bounds;
        CGFloat maxW = toastBounds.size.width - margin * 2;
        CGFloat oh = [text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin
            attributes:@{NSFontAttributeName:_originLabel.font} context:nil].size.height;
        CGFloat pad = 10;
        CGFloat w = maxW + pad * 2;
        CGFloat h = pad * 2 + oh;
        [self applyBackgroundStyle:CGSizeMake(w, h)];
        CGFloat sw = toastBounds.size.width;
        CGFloat sh = toastBounds.size.height;
        UIEdgeInsets insets = UIEdgeInsetsZero;
        if (@available(iOS 11.0, *)) {
            insets = [UIApplication sharedApplication].keyWindow.safeAreaInsets;
        }
        _container.frame = CGRectMake((sw - w) / 2, sh - insets.bottom - h - 120, w, h);
        _originLabel.frame = CGRectMake(pad, pad, maxW, oh);
        // toast 用英文标签承载（内容是中文提示语，字号/描边逻辑一致）
        _originLabel.hidden = NO;
        _transLabel.hidden = YES;
        _transLabel.frame = CGRectZero;
        _container.hidden = NO;
        _toastActive = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 不能直接清空 attributedText：那会把 toast 期间新到字幕的文字也抹掉。
            // 正确做法是重新渲染当前成对内容。
            _toastActive = NO;
            _originLabel.attributedText = nil;
            _transLabel.attributedText = nil;
            _originLabel.hidden = YES;
            [self renderCurrent];
        });
    } @catch (NSException *e) {}
}

@end

#pragma mark - 语音识别（SFSpeech + 腾讯云在线 fallback）

// 语音识别（SFSpeech + 腾讯云在线 fallback）

@interface LCSpeech : NSObject
+ (instancetype)shared;
- (void)startWithFormat:(AudioStreamBasicDescription)asbd;
- (void)appendBufferList:(AudioBufferList *)list frames:(UInt32)frames;
- (void)appendCMSampleBuffer:(CMSampleBufferRef)sbuf;   // AVSampleBuffer 管线音频
- (void)decodeAndAppendCMSampleBuffer:(CMSampleBufferRef)sbuf fmt:(const AudioStreamBasicDescription *)asbd;  // AAC 解码
- (void)stop;
@end

@implementation LCSpeech {
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_request;
    BOOL _recording;
    BOOL _authorized;
    NSString *_pendingFinal;
    NSMutableString *_accum;
    CFAbsoluteTime _lastPartialAt;
    CFAbsoluteTime _lastAppendAt;
}

+ (instancetype)shared {
    static LCSpeech *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LCSpeech alloc] init]; s->_accum = [NSMutableString string]; });
    return s;
}

- (void)startWithFormat:(AudioStreamBasicDescription)asbd {
    if (_recording) return;
    // 授权检查：目标 App 往往没有语音识别 usage description，主动 requestAuthorization
    // 在无描述时可能触发系统级终止（注入进程被杀）。改为只查状态、不主动请求；
    // 授权是系统全局的（设置→隐私→语音识别），用户在其他有语音功能的 App 里授权一次即可。
    // 1.0.12：无授权时自动切换腾讯云在线识别（不需要任何 iOS 授权）。
    SFSpeechRecognizerAuthorizationStatus st = [SFSpeechRecognizer authorizationStatus];
    if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        LCLogF(@"speech: auth status=%ld -> fallback 腾讯云在线识别", (long)st);
        _recording = NO;
        if (asbd.mSampleRate > 0) {
            gProcessingFormat = asbd;
            gProcessingFormatValid = YES;
        }
        [[LCHttpASR shared] startWithFormat:gProcessingFormat];
        return;
    }
    if (asbd.mSampleRate > 0) {
        gProcessingFormat = asbd;
        gProcessingFormatValid = YES;
    }
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"auto-detected"];
    SFSpeechRecognizer *rec = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!rec || !rec.isAvailable) {
        // 该 locale 不可用则退回 en-US
        rec = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
        if (!rec || !rec.isAvailable) {
            LCLog("speech: recognizer unavailable -> fallback 腾讯云在线识别");
            [[LCHttpASR shared] startWithFormat:gProcessingFormat];
            return;
        }
    }
    _recognizer = rec;

    SFSpeechAudioBufferRecognitionRequest *req = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    req.shouldReportPartialResults = YES;
    req.taskHint = SFSpeechRecognitionTaskHintDictation;
    _request = req;
    _authorized = NO;
    _recording = YES;
    _pendingFinal = nil;
    [_accum setString:@""];
    _lastPartialAt = 0;

    __weak typeof(self) weakSelf = self;
    [rec recognitionTaskWithRequest:req resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            LCLogF(@"speech: task error %@ -> fallback 腾讯云在线识别", error);
            self->_recording = NO;
            [[LCHttpASR shared] startWithFormat:gProcessingFormat];
            return;
        }
        if (!result) return;
        NSString *text = result.bestTranscription.formattedString;
        if (result.isFinal) {
            [self->_accum appendString:text];
            if ([self->_accum length] > 0) {
                self->_pendingFinal = [self->_accum copy];
                [self->_accum setString:@""];
                NSString *captureText = self->_pendingFinal;  // 捕获当前文本，防止被下一句覆盖
                LCLogF(@"speech: final [%@] -> sending for translation", captureText);
                NSUInteger seq = [[LCSubtitleOverlay shared] showPending:captureText];
                // 合并开关：翻译跟随总开关
                [[LCTranslator shared] translate:captureText
                    completion:^(NSString *tr) {
                        LCLogF(@"speech: translation result len=%lu text=[%@]", (unsigned long)tr.length, tr);
                        if (tr.length) [[LCSubtitleOverlay shared] showPair:captureText translation:tr seq:seq];
                        else [[LCSubtitleOverlay shared] showFailed:captureText seq:seq];
                    }];
            }
        } else {
            if (text.length == 0) return;
            // partial 节流：1.0s 内不重复刷
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - self->_lastPartialAt < 1.0) return;
            self->_lastPartialAt = now;
            // partial 只是「正在说的半句」，会不断被更长的内容取代。
            // 若也去请求翻译，会同时产生两个问题：
            //   ① 浪费请求（每 1s 一条），把串行队列塞满，真正的 final 排不上
            //   ② partial 的译文回来时，画面上的英文已经是另一段 → 错配
            // 所以 partial 只登记不翻译，等 final 到了再整段翻译。
            // 也不能刷屏：partial 是半句话，顶掉画面上的完整句子会闪烁。
            [[LCSubtitleOverlay shared] showPartial:text];
        }
    }];
}

- (void)appendBufferList:(AudioBufferList *)list frames:(UInt32)frames {
    if (![[LCConfig shared] enabled]) return;  // 合并开关关闭时忽略音频
    // 在线识别模式：转发给腾讯云 ASR
    if ([[LCHttpASR shared] isRunning]) {
        [[LCHttpASR shared] appendBufferList:list frames:frames];
        return;
    }
    if (!_recording || !_request || frames == 0) return;
    // 音频渲染线程：节流到 ~80ms 一次，降低高频对象分配压力
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastAppendAt < 0.08) return;
    _lastAppendAt = now;
    @autoreleasepool {
        @try {
            AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithStreamDescription:&gProcessingFormat];
            if (!fmt) return;
            AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
            if (!pcm) return;
            pcm.frameLength = frames;
            BOOL interleaved = !(gProcessingFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
            if (interleaved) {
                if (list->mBuffers[0].mData && list->mBuffers[0].mDataByteSize > 0)
                    memcpy(pcm.floatChannelData[0], list->mBuffers[0].mData, list->mBuffers[0].mDataByteSize);
            } else {
                UInt32 nch = MIN(list->mNumberBuffers, fmt.channelCount);
                for (UInt32 i = 0; i < nch; i++) {
                    if (list->mBuffers[i].mData && list->mBuffers[i].mDataByteSize > 0)
                        memcpy(pcm.floatChannelData[i], list->mBuffers[i].mData, list->mBuffers[i].mDataByteSize);
                }
            }
            [_request appendAudioPCMBuffer:pcm];
        } @catch (NSException *e) {
            LCLogF(@"speech: append err %@", e);
        }
    }
}

// AAC 解码输入回调（AudioConverterFillComplexBuffer，带 packet 描述）
typedef struct {
    uint8_t *data;
    size_t len;
    size_t dataLen;          // buffer 实际字节数（越界校验用）
    AudioStreamPacketDescription *descs;
    UInt32 descCount;
    UInt32 idx;
} LCConvInput;
static OSStatus LCInputProc(AudioConverterRef conv, UInt32 *numPackets,
                            AudioBufferList *ioData, AudioStreamPacketDescription **outPacketDesc,
                            void *inUserData) {
    LCConvInput *in = (LCConvInput *)inUserData;
    if (!in || !numPackets || in->idx >= in->descCount) {
        if (numPackets) *numPackets = 0;
        return noErr;
    }
    UInt32 n = *numPackets;
    if (in->descCount - in->idx < n) n = in->descCount - in->idx;
    // 关键：转换器的 packet description 里 mStartOffset 是【相对于 mData 指针】的偏移。
    // 我们手上这份描述的 mStartOffset 是【相对于整个 buffer 起点】的绝对偏移，
    // 直接交出去会被再加一次 mData 基址 -> 偏移翻倍 -> 读到垃圾 -> 解码失败(-50)。
    //
    // 解法：每次只交【1 个包】，并把它的 mStartOffset 归零
    //       （mData 指向该包真实起点，偏移 0 即正确）。
    // AAC 每包 1024 帧，多交几次不影响吞吐。
    if (n > 1) n = 1;
    ioData->mNumberBuffers = 1;

    // 该包在 buffer 内的绝对偏移
    UInt32 absOff = in->descs[in->idx].mStartOffset;
    UInt32 absLen = in->descs[in->idx].mDataByteSize;
    if ((UInt64)absOff + absLen > (UInt64)in->dataLen) {
        // 越界保护：包超出 buffer，停止喂数据
        *numPackets = 0;
        return noErr;
    }

    // mData 指向该包真实起点，描述里的偏移归零 —— 两者基准一致
    static AudioStreamPacketDescription sOne;
    sOne.mStartOffset = 0;
    sOne.mDataByteSize = absLen;
    sOne.mVariableFramesInPacket = in->descs[in->idx].mVariableFramesInPacket;
    ioData->mBuffers[0].mData = in->data + absOff;
    ioData->mBuffers[0].mDataByteSize = absLen;
    if (outPacketDesc) *outPacketDesc = &sOne;
    *numPackets = 1;
    in->idx += 1;
    return noErr;
}

// AVSampleBuffer 管线音频（YouTube 自研播放器不走 AVPlayer，走 AVSampleBufferAudioRenderer）
// enqueueSampleBuffer: 是音频样本必经入口 → 取 LPCM → float32 单声道 → 腾讯云 ASR
- (void)appendCMSampleBuffer:(CMSampleBufferRef)sbuf {
    if (!sbuf) return;
    if (![[LCConfig shared] enabled]) return;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
    if (!fmt) return;
    const AudioStreamBasicDescription *asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (!asbdP) return;
    AudioStreamBasicDescription asbd = *asbdP;
    // 高频路径：每个音频 buffer 都会进来，必须节流，否则日志每秒数千行
    if (LCLogThrottled(@"asbr", 3.0)) {
        LCLogF(@"asbr: got buffer sr=%u ch=%u fmt=0x%x (%s) frames=%lld",
               (unsigned)asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
               (unsigned)asbd.mFormatID,
               asbd.mFormatID == kAudioFormatLinearPCM ? "LPCM" :
               asbd.mFormatID == 'aac ' ? "AAC" :
               asbd.mFormatID == 'mp4a' ? "MP4A" : "other",
               (long long)CMSampleBufferGetNumSamples(sbuf));
    }
    if (asbd.mSampleRate <= 0) return;
    if (![[LCHttpASR shared] isRunning]) {
        gProcessingFormat = asbd;
        gProcessingFormatValid = YES;
        [[LCHttpASR shared] startWithFormat:asbd];
    }
    CMItemCount frames = CMSampleBufferGetNumSamples(sbuf);
    if (frames <= 0 || frames > 262144) return;
    @autoreleasepool {
        @try {
            // 压缩格式（AAC 等）：调用 decodeAndAppendCMSampleBuffer: 解码
            if (asbd.mFormatID != kAudioFormatLinearPCM) {
                [self decodeAndAppendCMSampleBuffer:sbuf fmt:&asbd];
                return;
            }
            AudioBufferList abl;
            memset(&abl, 0, sizeof(abl));
            CMBlockBufferRef bb = NULL;
            OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sbuf, NULL, &abl, sizeof(abl), NULL, NULL,
                kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &bb);
            if (st != noErr) {
                if (bb) CFRelease(bb);
                return;
            }
            UInt32 frames32 = (UInt32)frames;
            float *mono = (float *)malloc(frames32 * sizeof(float));
            if (!mono) {
                if (bb) CFRelease(bb);
                return;
            }
            BOOL interleaved = !(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
            unsigned ch = (asbd.mChannelsPerFrame > 0) ? (unsigned)asbd.mChannelsPerFrame : 2;
            if (interleaved && abl.mNumberBuffers > 0) {
                AudioBuffer *buf = &abl.mBuffers[0];
                if (asbd.mBitsPerChannel == 32 && (asbd.mFormatFlags & kAudioFormatFlagIsFloat)) {
                    const float *b = (const float *)buf->mData;
                    for (UInt32 i = 0; i < frames32; i++) {
                        float acc = 0;
                        for (unsigned c = 0; c < ch; c++) acc += b[i * ch + c];
                        mono[i] = acc / ch;
                    }
                } else if (asbd.mBitsPerChannel == 16) {
                    const SInt16 *b = (const SInt16 *)buf->mData;
                    for (UInt32 i = 0; i < frames32; i++) {
                        float acc = 0;
                        for (unsigned c = 0; c < ch; c++) acc += (float)b[i * ch + c] / 32768.0f;
                        mono[i] = acc / ch;
                    }
                } else if (asbd.mBitsPerChannel == 24) {
                    const uint8_t *b = (const uint8_t *)buf->mData;
                    for (UInt32 i = 0; i < frames32; i++) {
                        float acc = 0;
                        for (unsigned c = 0; c < ch; c++) {
                            size_t o = ((size_t)i * ch + c) * 3;
                            int32_t v = (b[o] << 8) | (b[o + 1] << 16) | (b[o + 2] << 24);
                            acc += (float)v / 8388608.0f;
                        }
                        mono[i] = acc / ch;
                    }
                } else {
                    free(mono);
                    if (bb) CFRelease(bb);
                    return;
                }
            } else {
                unsigned n = 0;
                for (UInt32 c = 0; c < abl.mNumberBuffers; c++) {
                    AudioBuffer *buf = &abl.mBuffers[c];
                    if (!buf->mData) continue;
                    if (asbd.mBitsPerChannel == 32 && (asbd.mFormatFlags & kAudioFormatFlagIsFloat)) {
                        const float *b = (const float *)buf->mData;
                        for (UInt32 i = 0; i < frames32; i++) mono[i] = (n == 0) ? b[i] : (mono[i] + b[i]);
                    } else if (asbd.mBitsPerChannel == 16) {
                        const SInt16 *b = (const SInt16 *)buf->mData;
                        for (UInt32 i = 0; i < frames32; i++) {
                            float v = (float)b[i] / 32768.0f;
                            mono[i] = (n == 0) ? v : (mono[i] + v);
                        }
                    } else {
                        free(mono);
                        if (bb) CFRelease(bb);
                        return;
                    }
                    n++;
                }
                if (n > 1) {
                    for (UInt32 i = 0; i < frames32; i++) mono[i] /= n;
                }
                if (n == 0) {
                    free(mono);
                    if (bb) CFRelease(bb);
                    return;
                }
            }
            if (bb) CFRelease(bb);
            [[LCHttpASR shared] appendMonoFloat:mono frames:frames32];
            free(mono);
        } @catch (NSException *e) {
            LCLogF(@"audio: appendCM err %@", e);
        }
    }
}

// 压缩音频（AAC）→ AudioConverter + packet 描述 解码 → float32 mono → 腾讯云 ASR
- (void)decodeAndAppendCMSampleBuffer:(CMSampleBufferRef)sbuf
                                  fmt:(const AudioStreamBasicDescription *)inASBD {
    if (!sbuf || !inASBD || inASBD->mSampleRate <= 0) return;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
    if (!bb) return;
    size_t dataLen = 0;
    const char *dataPtr = NULL;
    OSStatus st = CMBlockBufferGetDataPointer(bb, 0, NULL, &dataLen, (void**)&dataPtr);
    if (st != noErr || !dataPtr || dataLen == 0 || dataLen > 2 * 1024 * 1024) return;

    // 'aac '（0x61616320）是 YouTube 自定义 AAC 标识，转换为标准 mp4a
    AudioStreamBasicDescription inASBD2 = *inASBD;
    if (inASBD2.mFormatID == 0x61616320) {
        inASBD2.mFormatID = kAudioFormatMPEG4AAC;
        inASBD2.mFormatFlags = 0;
        LCLogF(@"audio: dec normalize aac->mp4a");
    }

    // 确保 mFramesPerPacket 正确设置（YouTube 通常每包 1024 帧）
    if (inASBD2.mFramesPerPacket == 0) {
        inASBD2.mFramesPerPacket = 1024;
        LCLogF(@"audio: dec set default fpp=1024");
    }

    if (LCLogThrottled(@"decin", 3.0)) {
        LCLogF(@"audio: dec in sr=%.0f fmt=0x%08x ch=%u fpp=%u len=%zu",
               inASBD2.mSampleRate, (unsigned)inASBD2.mFormatID,
               (unsigned)inASBD2.mChannelsPerFrame, (unsigned)inASBD2.mFramesPerPacket, dataLen);
    }

    // 打印数据头部，判断封装格式（节流：hex 字符串构建本身也有开销）
    if (LCLogThrottled(@"dechex", 10.0)) {
        NSMutableString *hex = [NSMutableString string];
        size_t nHex = MIN(dataLen, 16);
        for (size_t i = 0; i < nHex; i++) [hex appendFormat:@"%02x ", (uint8_t)dataPtr[i]];
        LCLogF(@"audio: dec head[%zu]: %@", nHex, hex);
    }

    // 输出格式：float32 PCM
    AudioStreamBasicDescription outASBD = {0};
    outASBD.mSampleRate = inASBD2.mSampleRate;
    outASBD.mFormatID = kAudioFormatLinearPCM;
    outASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    outASBD.mFramesPerPacket = 1;
    outASBD.mChannelsPerFrame = (inASBD2.mChannelsPerFrame > 0) ? inASBD2.mChannelsPerFrame : 2;
    outASBD.mBitsPerChannel = 32;
    outASBD.mBytesPerFrame = 4 * outASBD.mChannelsPerFrame;
    outASBD.mBytesPerPacket = outASBD.mBytesPerFrame;

    // 创建 AudioConverter
    AudioConverterRef conv = NULL;
    st = AudioConverterNew(&inASBD2, &outASBD, &conv);
    if (st != noErr || !conv) {
        LCLogF(@"audio: decode conv new err %d (0x%08x)", (int)st, (unsigned)st);
        return;
    }

        // 修复：尝试获取 magic cookie；缺失时按 AAC-LC 依据 ASBD 合成 AudioSpecificConfig
    CMFormatDescriptionRef fmtD = CMSampleBufferGetFormatDescription(sbuf);
    if (fmtD) {
        CFTypeRef cookieRef = CMFormatDescriptionGetExtension(fmtD, CFSTR("MagicCookie"));
        BOOL setCookie = NO;
        if (cookieRef && CFGetTypeID(cookieRef) == CFDataGetTypeID()) {
            CFDataRef cookieData = (CFDataRef)cookieRef;
            if (CFDataGetLength(cookieData) > 0) {
                AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                          (UInt32)CFDataGetLength(cookieData),
                                          CFDataGetBytePtr(cookieData));
                LCLogF(@"audio: dec cookie %ldB", (long)CFDataGetLength(cookieData));
                setCookie = YES;
            }
        }
        // YouTube 的 AAC format description 常不带 MagicCookie；AAC-LC 可由 ASBD 推断并合成
        if (!setCookie && inASBD2.mFormatID == kAudioFormatMPEG4AAC) {
            UInt32 sr = (UInt32)inASBD2.mSampleRate;
            int srIdx = 4;
            if      (sr == 96000) srIdx = 0;
            else if (sr == 88200) srIdx = 1;
            else if (sr == 64000) srIdx = 2;
            else if (sr == 48000) srIdx = 3;
            else if (sr == 44100) srIdx = 4;
            else if (sr == 32000) srIdx = 5;
            else if (sr == 24000) srIdx = 6;
            else if (sr == 22050) srIdx = 7;
            else if (sr == 16000) srIdx = 8;
            else if (sr == 12000) srIdx = 9;
            else if (sr == 11025) srIdx = 10;
            else if (sr == 8000)  srIdx = 11;
            UInt8 chn = (inASBD2.mChannelsPerFrame > 0) ? (UInt8)inASBD2.mChannelsPerFrame : 2;
            if (chn < 1 || chn > 7) chn = 2;
            UInt8 ac[2];
            ac[0] = (UInt8)((2 /*AAC-LC*/ << 3) | (srIdx >> 1));
            ac[1] = (UInt8)(((srIdx & 1) << 7) | (chn << 3));
            AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, 2, ac);
            LCLogF(@"audio: dec cookie synthesized sr=%u srIdx=%d ch=%u", (unsigned)sr, srIdx, chn);
        }
    }

    // 构建 packet 描述
    //
    // 关键（实测踩坑）：压缩格式(AAC)下
    //   CMSampleBufferGetAudioStreamPacketDescriptions 返回的是【整个码流】的包描述数组
    //   （实测 160 个），而不是当前 buffer 内的包（实测 10 个）。
    //   直接用会导致：
    //     1) 偏移/长度指向 buffer 之外的数据 -> 解码器只解出前 2 个包
    //     2) 输出缓冲按 descCount 之外的样本数计算 -> 严重截断
    //   最终只拿到 20% 的音频 -> 腾讯云 ASR 识别成乱码
    //        ("Can of ts five five butatingasc zero")
    //
    // 正确做法：用 CMSampleBufferGetSampleSizeArray 拿到【当前 buffer 内】每个包的真实字节数，
    // 自行重建描述；并按 descCount × 每包帧数 计算输出容量。
    AudioStreamPacketDescription *descs = NULL;
    UInt32 descCount = 0;
    CMItemCount dCnt = 0;
    st = CMSampleBufferGetAudioStreamPacketDescriptions(sbuf, 0, NULL, &dCnt);
    if (st == noErr && dCnt > 0 && dCnt <= 8192) {
        AudioStreamPacketDescription *tmp =
            (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * (size_t)dCnt);
        if (tmp) {
            st = CMSampleBufferGetAudioStreamPacketDescriptions(sbuf, dCnt, tmp, &dCnt);
            // 校验：官方描述必须完全落在当前 buffer 内，否则是码流级描述，不能用。
            // 实测 YouTube 的 AAC buffer：官方恒返回 frames×16 个包（码流级），
            // 其中只有前 ~2 个落在本 buffer 内，其余指向 buffer 之外 —— 直接用会越界读。
            BOOL valid = (st == noErr && dCnt > 0);
            if (valid) {
                for (CMItemCount i = 0; i < dCnt; i++) {
                    SInt64 end = (SInt64)tmp[i].mStartOffset + (SInt64)tmp[i].mDataByteSize;
                    if (tmp[i].mDataByteSize == 0 || end > (SInt64)dataLen) { valid = NO; break; }
                }
            }
            if (valid) {
                descs = tmp;
                descCount = (UInt32)dCnt;
            } else {
                free(tmp);
            }
        }
    }

    // 用 sample sizes 重建【当前 buffer 内】的包描述。
    //
    // 实测（YouTube AAC buffer）：
    //   frames=10, len=3670 字节 → 官方包描述 160 个（= frames×16，码流级）
    //   frames=1,  len=431  字节 → 官方包描述 16 个
    // 可见官方描述与本 buffer 无关，不能直接用。
    //
    // 正确做法：用 CMSampleBufferGetSampleSizeArray 拿到每个【sample】的字节数，
    // 累加直到填满 dataLen 为止 —— 这样得到的包数与字节数天然自洽，
    // 既不会越界，也不会漏解。
    if (!descs) {
        CMItemCount numSamples = CMSampleBufferGetNumSamples(sbuf);
        if (numSamples > 0 && numSamples <= 8192) {
            size_t *sizes = (size_t *)malloc(sizeof(size_t) * (size_t)numSamples);
            if (sizes) {
                CMItemCount numSizes = 0;
                CMSampleBufferGetSampleSizeArray(sbuf, numSamples, sizes, &numSizes);
                if (numSizes > 0) {
                    // numSizes==1：CoreMedia 只给「统一大小」，展开成 numSamples 个包
                    CMItemCount effN = (numSizes == 1 && numSamples > 1) ? numSamples : numSizes;
                    if (effN > 8192) effN = 8192;
                    descs = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * (size_t)effN);
                    if (descs) {
                        size_t off = 0;
                        for (CMItemCount i = 0; i < effN; i++) {
                            size_t sz = (numSizes == 1) ? sizes[0] : sizes[i];
                            // 越界保护：包不能为空，累计偏移不能超出 buffer
                            if (sz == 0 || off + sz > (size_t)dataLen) break;
                            descs[i].mStartOffset = (UInt32)off;
                            descs[i].mDataByteSize = (UInt32)sz;
                            descs[i].mVariableFramesInPacket = 0;
                            off += sz;
                            descCount++;
                        }
                        if (descCount == 0) { free(descs); descs = NULL; }
                        LCLogF(@"audio: dec built %u pkt descs from %lld sizes (eff=%lld, dataLen=%lld)",
                               (unsigned)descCount, (long long)numSizes, (long long)effN, (long long)dataLen);
                    }
                }
                free(sizes);
            }
        }
    }

// 如果没有 packet 描述，尝试检测 ADTS 帧
    if (!descs && dataLen >= 7 && ((uint8_t)dataPtr[0]) == 0xFF && (((uint8_t)dataPtr[1]) & 0xF6) == 0xF0) {
        UInt32 cap = 64;
        descs = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * cap);
        if (descs) {
            size_t off = 0;
            while (off + 7 <= dataLen && descCount < cap) {
                const uint8_t *p = (const uint8_t *)dataPtr + off;
                if (p[0] != 0xFF || (p[1] & 0xF6) != 0xF0) break;
                UInt32 frameLen = ((p[3] & 0x03) << 11) | (p[4] << 3) | (p[5] >> 5);
                if (frameLen < 7 || off + frameLen > dataLen) break;
                descs[descCount].mStartOffset = (UInt32)off;
                descs[descCount].mDataByteSize = frameLen;
                descs[descCount].mVariableFramesInPacket = 0;
                descCount++;
                off += frameLen;
            }
            if (descCount == 0) { free(descs); descs = NULL; }
        }
        if (descs) LCLogF(@"audio: dec ADTS %u frames", (unsigned)descCount);
    }

    // 兜底：将整个 buffer 作为单个 packet
    if (!descs) {
        descCount = 1;
        descs = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription));
        if (descs) {
            descs[0].mStartOffset = 0;
            descs[0].mDataByteSize = (UInt32)dataLen;
            descs[0].mVariableFramesInPacket = 0;
        }
    }
    if (!descs) {
        AudioConverterDispose(conv);
        return;
    }
    // 兜底 2：整段当单包解码通常会失败(-50)。
    // 若可用字节数足够，按 AAC 典型包长(~384 字节)切分成多个等长包，
    // 这样 AudioConverter 至少能解出大部分音频，而不是整段丢弃。
    if (descCount == 1 && descs[0].mDataByteSize > 800) {
        UInt32 approx = (UInt32)(dataLen / 384);
        if (approx >= 2 && approx <= 512) {
            AudioStreamPacketDescription *nd =
                (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * approx);
            if (nd) {
                UInt32 each = (UInt32)dataLen / approx;
                UInt32 used = 0;
                for (UInt32 i = 0; i < approx; i++) {
                    UInt32 sz = (i == approx - 1) ? ((UInt32)dataLen - used) : each;
                    nd[i].mStartOffset = used;
                    nd[i].mDataByteSize = sz;
                    nd[i].mVariableFramesInPacket = 0;
                    used += sz;
                }
                free(descs);
                descs = nd;
                descCount = approx;
                LCLogF(@"audio: dec fallback split into %u pkts (%u bytes each)", (unsigned)descCount, (unsigned)each);
            }
        }
    }
    if (LCLogThrottled(@"decpkts", 3.0)) {
        LCLogF(@"audio: dec pkts=%u", (unsigned)descCount);
    }

    // 计算输出缓冲大小
    // 关键：压缩格式(AAC)下 CMSampleBufferGetNumSamples 返回的是【包数】，
    // 不是 PCM 帧数。直接用它算容量会严重偏小 -> 输出被截断（实测只解出 20% 音频）。
    // 正确算法：输出帧数 ≈ 包数 × 每包帧数(AAC-LC = 1024)。
    CMItemCount numPkts = (CMItemCount)descCount;
    CMItemCount framesPerPacket = (CMItemCount)(inASBD2.mFramesPerPacket > 0 ? inASBD2.mFramesPerPacket : 1024);
    // 防御：每包帧数异常时按 1024 算（AAC-LC 标准值），避免乘法溢出
    if (framesPerPacket <= 0 || framesPerPacket > 4096) framesPerPacket = 1024;
    CMItemCount totalSamples = numPkts * framesPerPacket;
    if (totalSamples <= 0) totalSamples = (CMItemCount)CMSampleBufferGetNumSamples(sbuf);
    if (totalSamples <= 0) totalSamples = 1024;
    // 上限保护：单次解码最多约 30 秒音频，防止超大分配
    if (totalSamples > 16000 * 30) totalSamples = 16000 * 30;
    // 输出缓冲：按【实际可解出的帧数】算，不要多留余量。
    // 多留的部分会让转换器以为还能再解出几千帧，于是再次回调输入；
    // 而输入早已耗尽（返回 0 包）-> AudioConverter 判定输入不完整 -> -50。
    UInt32 outCapacity = (UInt32)(totalSamples * outASBD.mBytesPerFrame);
    if (outCapacity > 4 * 1024 * 1024) outCapacity = 4 * 1024 * 1024;
    if (outCapacity < 16384) outCapacity = 16384;

    UInt8 *outData = (UInt8 *)malloc(outCapacity);
    if (!outData) {
        free(descs);
        AudioConverterDispose(conv);
        return;
    }
    AudioBufferList outList;
    memset(&outList, 0, sizeof(outList));
    outList.mNumberBuffers = 1;
    outList.mBuffers[0].mNumberChannels = outASBD.mChannelsPerFrame;
    outList.mBuffers[0].mData = outData;
    outList.mBuffers[0].mDataByteSize = outCapacity;

    // 准备输入数据
    LCConvInput in = { (uint8_t *)dataPtr, dataLen, dataLen, descs, descCount, 0 };
    // 请求的输出帧数不能超过【输入实际能解出的帧数】(包数 × 每包帧数)。
    // 超出部分会让转换器再次回调输入，而输入已耗尽 -> -50。
    UInt32 realFrames = (UInt32)totalSamples;
    UInt32 outNumPackets = (UInt32)(outCapacity / outASBD.mBytesPerFrame);
    if (outNumPackets > realFrames) outNumPackets = realFrames;
    if (outNumPackets > 262144) outNumPackets = 262144;
    if (outNumPackets < 1) outNumPackets = 1;
    LCLogF(@"audio: dec req pkts=%u realFrames=%u cap=%u", (unsigned)outNumPackets,
           (unsigned)realFrames, (unsigned)outCapacity);

    st = AudioConverterFillComplexBuffer(conv, LCInputProc, &in, &outNumPackets, &outList, NULL);
    AudioConverterDispose(conv);
    free(descs);

    if (st != noErr) {
        LCLogF(@"audio: decode fill err %d (0x%08x)", (int)st, (unsigned)st);
        free(outData);
        return;
    }

    UInt32 producedFrames = outList.mBuffers[0].mDataByteSize / outASBD.mBytesPerFrame;
    // 安全：转换器写入的字节数绝不能超过我们给的容量
    if (outList.mBuffers[0].mDataByteSize > outCapacity) {
        LCLogF(@"audio: dec overflow guard %lu > %lu",
               (unsigned long)outList.mBuffers[0].mDataByteSize, (unsigned long)outCapacity);
        free(outData);
        return;
    }
    if (producedFrames == 0 || producedFrames > 262144) {
        free(outData);
        return;
    }
    // 诊断：解出的帧数应接近 包数×1024；若明显偏小说明仍有丢包
    if (producedFrames < (UInt32)(descCount * framesPerPacket / 2)) {
        LCLogF(@"audio: dec TRUNCATED pkts=%u expect~%u got=%u",
               (unsigned)descCount,
               (unsigned)(descCount * framesPerPacket), producedFrames);
    }

    unsigned ch = outASBD.mChannelsPerFrame;
    const float *src = (const float *)outList.mBuffers[0].mData;
    float *mono = (float *)malloc(producedFrames * sizeof(float));
    if (!mono) { free(outData); return; }
    for (UInt32 i = 0; i < producedFrames; i++) {
        float acc = 0;
        for (unsigned c = 0; c < ch; c++) acc += src[i * ch + c];
        mono[i] = acc / ch;
    }
    free(outData);
    [[LCHttpASR shared] appendMonoFloat:mono frames:producedFrames];
    free(mono);
    if (LCLogThrottled(@"decframes", 3.0)) {
        LCLogF(@"audio: decoded %u frames", (unsigned)producedFrames);
    }
}

- (void)stop {
    _recording = NO;
    if (_request) {
        [_request endAudio];
        _request = nil;
    }
    _recognizer = nil;
    [[LCHttpASR shared] stop];
}

@end

#pragma mark - MTAudioProcessingTap 回调

static void LCTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    *tapStorageOut = clientInfo;
}

static void LCTapFinalize(MTAudioProcessingTapRef tap) {}

static void LCTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                         const AudioStreamBasicDescription *processingFormat) {
    @try {
        // 记录格式供后续 PCM 转换
        void *client = MTAudioProcessingTapGetStorage(tap);
        if (!client) return;
        if (processingFormat) {
            memcpy(&gProcessingFormat, processingFormat, sizeof(AudioStreamBasicDescription));
            gProcessingFormatValid = YES;
            LCLogF(@"tap: prepare sr=%g ch=%u bits=%u",
                   gProcessingFormat.mSampleRate,
                   (unsigned)gProcessingFormat.mChannelsPerFrame,
                   (unsigned)gProcessingFormat.mBitsPerChannel);
        }
        LCSpeech *speech = (__bridge LCSpeech *)client;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                [speech startWithFormat:gProcessingFormat];
            } @catch (NSException *e) {
                LCLogF(@"tap: prepare start err %@", e);
            }
        });
    } @catch (NSException *e) {
        LCLogF(@"tap: prepare err %@", e);
    }
}

static void LCTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                         MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                         CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    @try {
        OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut,
                                                             NULL, numberFramesOut);
        if (status == noErr) {
            void *client = MTAudioProcessingTapGetStorage(tap);
            LCSpeech *speech = (__bridge LCSpeech *)client;
            if (speech) {
                [speech appendBufferList:bufferListInOut frames:(UInt32)*numberFramesOut];
            }
        }
    } @catch (NSException *e) {
        LCLogF(@"tap: process err %@", e);
    }
}

#pragma mark - AVPlayer hook

// 关联对象键：存该 player/item 关联的 AVMutableAudioMixInputParameters（我们的 tap 参数），
// 供 LCApplyPlayerMuteState 设置 volume 用。
static void *LCTapParamsKey = &LCTapParamsKey;

// 根据 App 自身的 muted/volume 意图，决定 tap 取音频的增益（始终在音量斜坡之前，PreEffects）。
// - App 想正常出声（muted==NO 且 volume>0）→ tap 恢复全幅（volume=1），字幕正常。
// - App 自己静音（muted==YES 或 volume==0）→ tap 也置 0（系统输出静音），但 PreEffects 下
//   ASR 仍拿得到全幅音频（音量斜坡在 tap 之后才生效）→ 字幕不消失。
// default 有声状态 → volume=1.0；mute 状态 → volume=0.0。
static void LCApplyTapMuteState(AVPlayerItem *item, BOOL muted, float volume) {
    // PreEffects tap 已在音量斜坡之前捕获全幅音频，无需动态调整 volume
    // muted=NO → tap 拿到全幅；muted=YES → tap 仍拿到全幅（系统输出静音但 ASR 正常）
}

static void LCAttachTapToItem(AVPlayerItem *item) {
    if (!item) return;
    // 关联对象去重：同一 item 只挂一次（currentItem getter 会被高频调用，不能每次重建 tap）
    static void *LCAttachKey = &LCAttachKey;
    if (objc_getAssociatedObject(item, LCAttachKey)) return;
    objc_setAssociatedObject(item, LCAttachKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        // 不检查 item.audioMix：目标 App（如 YouTube）可能已设自己的 audioMix
        // （音效/均衡），旧代码因此跳过挂载 tap → 音频抓不到。直接强制挂我们的 tap。
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParameters];
        // PreEffects：在 AVAudioMix 音量斜坡之前取音频（Apple QA1783：唯一 effect = 线性音量斜坡，
        // 且 AVPlayer.muted/输出音量=0 的混合发生在下游）。因此 setVolume(0) 让系统输出静音，
        // 但 tap 拿到全幅音频 → ASR 不受影响。这就是"输出静音也能出字幕"的核心。
        MTAudioProcessingTapCallbacks callbacks = {0};
        callbacks.version = 0;
        callbacks.init = LCTapInit;
        callbacks.finalize = LCTapFinalize;
        callbacks.prepare = LCTapPrepare;
        callbacks.process = LCTapProcess;
        callbacks.clientInfo = (__bridge void *)[LCSpeech shared];  // 音频数据经 storage 送识别器
        MTAudioProcessingTapRef tap = NULL;
        OSStatus st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                 kMTAudioProcessingTapCreationFlag_PreEffects, &tap);
        if (st != noErr || !tap) {
            LCLogF(@"tap: create failed st=%d", (int)st);
            return;
        }
        params.audioTapProcessor = tap;
        mix.inputParameters = @[params];
        item.audioMix = mix;
        // 记住 params，供 LCApplyPlayerMuteState 动态调音量（跟随 App 自身音量意图）
        objc_setAssociatedObject(item, LCTapParamsKey, params, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LCLogF(@"tap: attached to item %p (PreEffects)", item);
// 跟随 App 自身音量：若 App 已设 muted/volume=0（App 想静音），我们也静音；
// 若 App 有声（volume>0 且 muted=NO），我们恢复全幅。hook setMuted:/setVolume: 会维护此状态。
// 注意：此处不调 LCApplyPlayerMuteState（因为 item 可能尚未挂到 player），
// 而是由 AVPlayer 的 muted/volume hook + KVO 在合适时机统一维护。
// item 上存储关联对象后，外部 hook 通过 item 拿 params 即可。
    } @catch (NSException *e) {
        LCLogF(@"tap: attach error %@", e);
    }
}

static void (*orig_setCurrentItem)(id, SEL, AVPlayerItem *);
static void LC_setCurrentItem(id self, SEL _cmd, AVPlayerItem *item) {
    orig_setCurrentItem(self, _cmd, item);
    if (item) LCAttachTapToItem(item);
}

static void (*orig_replaceCurrentItem)(id, SEL, AVPlayerItem *);
static void LC_replaceCurrentItem(id self, SEL _cmd, AVPlayerItem *item) {
    orig_replaceCurrentItem(self, _cmd, item);
    if (item) LCAttachTapToItem(item);
}

// 兜底 hook：AVPlayer.currentItem getter —— YouTube 等 App 创建/切换 item 的路径无法枚举，
// 但任何播放器渲染/状态查询都会读 currentItem。读到 item 即挂 tap（关联对象去重，幂等）。
static AVPlayerItem *(*orig_currentItem)(id, SEL);
static AVPlayerItem *LC_currentItem(id self, SEL _cmd) {
    AVPlayerItem *item = orig_currentItem(self, _cmd);
    if (item) {
        @try { LCAttachTapToItem(item); } @catch (NSException *e) {}
    }
    return item;
}

// AVPlayer.muted 和 AVPlayer.volume 直接调——目标 App（YouTube/B站等）经常通过这两个 API 调音量，
// 必须 hook 才能同步到 tap 参数，保证"App 静音时 tap 也静音，App 有声时 tap 全幅"。
static void (*orig_setMuted)(id, SEL, BOOL);
static void LC_setMuted(id self, SEL _cmd, BOOL muted) {
    orig_setMuted(self, _cmd, muted);
    AVPlayer *p = (AVPlayer *)self;
    // 同步到所有已 attach 的 item 的 tap 参数（PreEffects 下 ASR 不受影响）
    id item = p.currentItem;
    @try { LCApplyTapMuteState(item, muted, p.volume); } @catch (NSException *e) {}
}
static void (*orig_setVolume)(id, SEL, float);
static void LC_setVolume(id self, SEL _cmd, float vol) {
    orig_setVolume(self, _cmd, vol);
    AVPlayer *p = (AVPlayer *)self;
    BOOL muted = [p isMuted];
    @try { LCApplyTapMuteState(p.currentItem, muted, vol); } @catch (NSException *e) {}
}

// 探测 hook：确认目标 App 是否真的使用 AVPlayer 家族（YouTube 疑为自研播放器，不走 AVPlayer）。
static id (*orig_avpInit)(id, SEL);
static id LC_avpInit(id self, SEL _cmd) {
    if (orig_avpInit) self = orig_avpInit(self, _cmd);
    LCLogF(@"avp: init %p", self);
    return self;
}
static id (*orig_avpInitPlayerItem)(id, SEL, AVPlayerItem *);
static id LC_avpInitPlayerItem(id self, SEL _cmd, AVPlayerItem *item) {
    if (orig_avpInitPlayerItem) self = orig_avpInitPlayerItem(self, _cmd, item);
    LCLogF(@"avp: initWithPlayerItem %p", self);
    if (self && item) LCAttachTapToItem(item);
    return self;
}
static id (*orig_avpInitURL)(id, SEL, NSURL *);
static id LC_avpInitURL(id self, SEL _cmd, NSURL *url) {
    if (orig_avpInitURL) self = orig_avpInitURL(self, _cmd, url);
    LCLogF(@"avp: initWithURL %p", self);
    return self;
}
static id (*orig_itemInitNoArgs)(id, SEL);
static id LC_itemInitNoArgs(id self, SEL _cmd) {
    if (orig_itemInitNoArgs) self = orig_itemInitNoArgs(self, _cmd);
    LCLogF(@"item: init(noargs) %p", self);
    return self;
}

// AVPlayerItem 创建即挂 tap：YouTube 等 App 不一定走 setCurrentItem/replaceCurrentItem，
// 但任何播放都必须创建 AVPlayerItem，指定初始化器 initWithAsset:automaticallyLoadedAssetKeys:
// 是所有创建路径的汇聚点。
static id (*orig_itemInitAssetKeys)(id, SEL, AVAsset *, NSArray *);
static id LC_itemInitAssetKeys(id self, SEL _cmd, AVAsset *asset, NSArray *keys) {
    if (orig_itemInitAssetKeys) self = orig_itemInitAssetKeys(self, _cmd, asset, keys);
    if (self) {
        LCLogF(@"item: init %p", self);
        LCAttachTapToItem(self);
    }
    return self;
}

// 扩展初始化入口：YouTube 等大型 App 常用 initWithAsset:（单参）/ initWithURL: / initWithAsset:error:
// 这些便捷初始化不一定走 initWithAsset:automaticallyLoadedAssetKeys:，逐个 hook 兜底。
static id (*orig_itemInitAsset)(id, SEL, AVAsset *);
static id LC_itemInitAsset(id self, SEL _cmd, AVAsset *asset) {
    if (orig_itemInitAsset) self = orig_itemInitAsset(self, _cmd, asset);
    if (self) {
        LCLogF(@"item: initAsset %p", self);
        LCAttachTapToItem(self);
    }
    return self;
}

static id (*orig_itemInitURL)(id, SEL, NSURL *);
static id LC_itemInitURL(id self, SEL _cmd, NSURL *url) {
    if (orig_itemInitURL) self = orig_itemInitURL(self, _cmd, url);
    if (self) {
        LCLogF(@"item: initURL %p", self);
        LCAttachTapToItem(self);
    }
    return self;
}

static id (*orig_itemInitURLOptions)(id, SEL, NSURL *, NSDictionary *);
static id LC_itemInitURLOptions(id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    if (orig_itemInitURLOptions) self = orig_itemInitURLOptions(self, _cmd, url, options);
    if (self) {
        LCLogF(@"item: initURLOptions %p", self);
        LCAttachTapToItem(self);
    }
    return self;
}

static id (*orig_itemInitAssetErr)(id, SEL, AVAsset *, NSError **);
static id LC_itemInitAssetErr(id self, SEL _cmd, AVAsset *asset, NSError **err) {
    if (orig_itemInitAssetErr) self = orig_itemInitAssetErr(self, _cmd, asset, err);
    if (self) {
        LCLogF(@"item: initAssetErr %p", self);
        LCAttachTapToItem(self);
    }
    return self;
}

static BOOL gInSetAudioMix = NO;
static void (*orig_setAudioMix)(id, SEL, id);
// 目标 App 播放时可能自己 setAudioMix（覆盖我们的 tap）→ 每次被覆盖后重挂我们的 tap
static void LC_setAudioMix(id self, SEL _cmd, id mix) {
    orig_setAudioMix(self, _cmd, mix);
    if (gInSetAudioMix) return;
    gInSetAudioMix = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { LCAttachTapToItem(self); } @catch (NSException *e) {}
        gInSetAudioMix = NO;
    });
}

static void LCSwizzleAVPlayer(void) {
    @try {
        Method m1 = class_getInstanceMethod([AVPlayer class], @selector(setCurrentItem:));
        if (m1) {
            orig_setCurrentItem = (void *)method_getImplementation(m1);
            method_setImplementation(m1, (IMP)LC_setCurrentItem);
            LCLog("hook: setCurrentItem OK");
        }
        Method m2 = class_getInstanceMethod([AVPlayer class], @selector(replaceCurrentItemWithPlayerItem:));
        if (m2) {
            orig_replaceCurrentItem = (void *)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)LC_replaceCurrentItem);
            LCLog("hook: replaceCurrentItem OK");
        }
        Method mci = class_getInstanceMethod([AVPlayer class], @selector(currentItem));
        if (mci) {
            orig_currentItem = (void *)method_getImplementation(mci);
            method_setImplementation(mci, (IMP)LC_currentItem);
            LCLog("hook: currentItem OK");
        }
        Method avi = class_getInstanceMethod([AVPlayer class], @selector(init));
        if (avi) {
            orig_avpInit = (void *)method_getImplementation(avi);
            method_setImplementation(avi, (IMP)LC_avpInit);
            LCLog("hook: avp init OK");
        }
        Method avip = class_getInstanceMethod([AVPlayer class], @selector(initWithPlayerItem:));
        if (avip) {
            orig_avpInitPlayerItem = (void *)method_getImplementation(avip);
            method_setImplementation(avip, (IMP)LC_avpInitPlayerItem);
            LCLog("hook: avp initWithPlayerItem OK");
        }
        Method aviu = class_getInstanceMethod([AVPlayer class], @selector(initWithURL:));
        if (aviu) {
            orig_avpInitURL = (void *)method_getImplementation(aviu);
            method_setImplementation(aviu, (IMP)LC_avpInitURL);
            LCLog("hook: avp initWithURL OK");
        }
        Method initi = class_getInstanceMethod([AVPlayerItem class], @selector(init));
        if (initi) {
            orig_itemInitNoArgs = (void *)method_getImplementation(initi);
            method_setImplementation(initi, (IMP)LC_itemInitNoArgs);
            LCLog("hook: item init(noargs) OK");
        }
        Method mi = class_getInstanceMethod([AVPlayerItem class],
                                            @selector(initWithAsset:automaticallyLoadedAssetKeys:));
        if (mi) {
            orig_itemInitAssetKeys = (void *)method_getImplementation(mi);
            method_setImplementation(mi, (IMP)LC_itemInitAssetKeys);
            LCLog("hook: item init OK");
        }
        Method mia = class_getInstanceMethod([AVPlayerItem class], @selector(initWithAsset:));
        if (mia) {
            orig_itemInitAsset = (void *)method_getImplementation(mia);
            method_setImplementation(mia, (IMP)LC_itemInitAsset);
            LCLog("hook: item initWithAsset OK");
        }
        Method miu = class_getInstanceMethod([AVPlayerItem class], @selector(initWithURL:));
        if (miu) {
            orig_itemInitURL = (void *)method_getImplementation(miu);
            method_setImplementation(miu, (IMP)LC_itemInitURL);
            LCLog("hook: item initWithURL OK");
        }
        Method miuo = class_getInstanceMethod([AVPlayerItem class], @selector(initWithURL:options:));
        if (miuo) {
            orig_itemInitURLOptions = (void *)method_getImplementation(miuo);
            method_setImplementation(miuo, (IMP)LC_itemInitURLOptions);
            LCLog("hook: item initWithURLOptions OK");
        }
        Method miae = class_getInstanceMethod([AVPlayerItem class], @selector(initWithAsset:error:));
        if (miae) {
            orig_itemInitAssetErr = (void *)method_getImplementation(miae);
            method_setImplementation(miae, (IMP)LC_itemInitAssetErr);
            LCLog("hook: item initWithAssetErr OK");
        }
        Method ma = class_getInstanceMethod([AVPlayerItem class], @selector(setAudioMix:));
        if (ma) {
            orig_setAudioMix = (void *)method_getImplementation(ma);
            method_setImplementation(ma, (IMP)LC_setAudioMix);
            LCLog("hook: setAudioMix OK");
        }
        // AVPlayer.muted/volume hook：App 通过这两个 API 调音量时同步到 tap 参数
        Method ms = class_getInstanceMethod([AVPlayer class], @selector(setMuted:));
        if (ms) {
            orig_setMuted = (void *)method_getImplementation(ms);
            method_setImplementation(ms, (IMP)LC_setMuted);
            LCLog("hook: setMuted OK");
        }
        Method ms2 = class_getInstanceMethod([AVPlayer class], @selector(setVolume:));
        if (ms2) {
            orig_setVolume = (void *)method_getImplementation(ms2);
            method_setImplementation(ms2, (IMP)LC_setVolume);
            LCLog("hook: setVolume OK");
        }
    } @catch (NSException *e) {
        LCLogF(@"hook: error %@", e);
    }
}

#pragma mark - 音频栈探测（YouTube 自研播放器不走 AVPlayer，定位其音频输出 API）
// 探测候选：AVAudioEngine / AVSampleBufferAudioRenderer / AVSampleBufferRenderSynchronizer /
// AVAudioPlayerNode / AVAudioSession（播放必触发 setActive）。命中哪个就锁定音频捕获入口。

static id (*orig_avaeInit)(id, SEL);
static id LC_avaeInit(id self, SEL _cmd) {
    if (orig_avaeInit) self = orig_avaeInit(self, _cmd);
    LCLogF(@"audio: AVAudioEngine init %p", self);
    return self;
}
static id (*orig_asbrInit)(id, SEL);
static id LC_asbrInit(id self, SEL _cmd) {
    if (orig_asbrInit) self = orig_asbrInit(self, _cmd);
    LCLogF(@"audio: AVSampleBufferAudioRenderer init %p", self);
    return self;
}
static id (*orig_avsrsInit)(id, SEL);
static id LC_avsrsInit(id self, SEL _cmd) {
    if (orig_avsrsInit) self = orig_avsrsInit(self, _cmd);
    LCLogF(@"audio: AVSampleBufferRenderSynchronizer init %p", self);
    return self;
}
static id (*orig_avapnInit)(id, SEL);
static id LC_avapnInit(id self, SEL _cmd) {
    if (orig_avapnInit) self = orig_avapnInit(self, _cmd);
    LCLogF(@"audio: AVAudioPlayerNode init %p", self);
    return self;
}
static OSStatus (*orig_avsasSetActive)(id, SEL, BOOL, NSError *__autoreleasing *);
static OSStatus LC_avsasSetActive(id self, SEL _cmd, BOOL active, NSError *__autoreleasing *err) {
    OSStatus st = orig_avsasSetActive(self, _cmd, active, err);
    LCLogF(@"audio: AVAudioSession setActive %d st=%d", active ? 1 : 0, (int)st);
    return st;
}
static OSStatus (*orig_avsasSetCategory)(id, SEL, NSString *, NSError *__autoreleasing *);
static OSStatus LC_avsasSetCategory(id self, SEL _cmd, NSString *cat, NSError *__autoreleasing *err) {
    OSStatus st = orig_avsasSetCategory(self, _cmd, cat, err);
    LCLogF(@"audio: AVAudioSession setCategory %@ st=%d", cat, (int)st);
    return st;
}
static void (*orig_asbrEnqueue)(id, SEL, CMSampleBufferRef);
static void LC_asbrEnqueue(id self, SEL _cmd, CMSampleBufferRef sbuf) {
    LCLogF(@"asbr: enqueue called sbuf=%p self=%@ cmd=%s", sbuf, self, sel_getName(_cmd));
    orig_asbrEnqueue(self, _cmd, sbuf);
    if (sbuf) {
        @try { [[LCSpeech shared] appendCMSampleBuffer:sbuf]; } @catch (NSException *e) { LCLogF(@"asbr: append error %@", e); }
    } else {
        LCLogF(@"asbr: sbuf is NULL — skipping");
    }
}
// ===== 系统音频输出层抓解码后 PCM：包装 YouTube 播放 AU 的 render 回调（TrollRecorder 思路） =====
#define LC_MAX_CB 8
static struct { AudioUnit au; AudioUnitElement el; AURenderCallbackStruct cb; } gLCCbs[LC_MAX_CB];
static int gLCCbN = 0;

static OSStatus LC_RenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                  UInt32 inNumberFrames, AudioBufferList *ioData) {
    AURenderCallbackStruct *orig = (AURenderCallbackStruct *)inRefCon;
    OSStatus st = orig->inputProc(orig->inputProcRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (st == noErr && ioData && ioData->mNumberBuffers > 0 && inNumberFrames > 0 && inNumberFrames <= 262144) {
        @autoreleasepool {
            @try {
                if ([[LCConfig shared] enabled] && gProcessingFormatValid) {
                    if (![[LCHttpASR shared] isRunning]) {
                        [[LCHttpASR shared] startWithFormat:gProcessingFormat];
                    }
                    [[LCHttpASR shared] appendBufferList:ioData frames:inNumberFrames];
                }
            } @catch (NSException *e) {
                LCLogF(@"audio: CB err %@", e);
            }
        }
    }
    return st;
}

static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus LC_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
                                        AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    LCLogF(@"LC_AUSP: called inID=0x%x scope=%u elem=%u dataSize=%u", (unsigned)inID, (unsigned)inScope, (unsigned)inElement, (unsigned)inDataSize);
    OSStatus st = orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
    if (st == noErr && inID == kAudioUnitProperty_SetRenderCallback && inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
        AURenderCallbackStruct cb;
        memcpy(&cb, inData, sizeof(cb));
        if (cb.inputProc && gLCCbN < LC_MAX_CB) {
            int slot = gLCCbN++;
            gLCCbs[slot].au = inUnit;
            gLCCbs[slot].el = inElement;
            gLCCbs[slot].cb = cb;
            AURenderCallbackStruct wrapped = { LC_RenderCallback, &gLCCbs[slot].cb };
            orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
            if (!gProcessingFormatValid) {
                AudioStreamBasicDescription asbd;
                UInt32 sz = sizeof(asbd);
                if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                                         kAudioUnitScope_Output, inElement,
                                         &asbd, &sz) == noErr) {
                    gProcessingFormat = asbd;
                    gProcessingFormatValid = YES;
                    LCLogF(@"audio: AUSP fmt sr=%.0f ch=%u bits=%u fmt=0x%08x noninter=%d",
                           asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
                           (unsigned)asbd.mBitsPerChannel, (unsigned)asbd.mFormatID,
                           (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : 0);
                }
            }
            LCLogF(@"audio: AUSP wrap cb unit=%p elem=%u (slot %d)", inUnit, (unsigned)inElement, slot);
        }
    }
    return st;
}

static void LCHookAudioUnitRender(void) {
    struct rebinding rb = { "AudioUnitSetProperty", (void *)LC_AudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty };
    int r = rebind_symbols(&rb, 1);
    LCLogF(@"hook: AudioUnitSetProperty rebind=%d", r);
}

// ===== mediaserverd 系统音频 tap：包装播放 AU render 回调抓系统混音 PCM（EQE / TrollRecorder 同思路）=====
// 路线 A：注入系统音频守护进程，任何 App 播放都过这里的混音 AU → 拿解码后 PCM，不针对单个 App。
// 本模块运行在 mediaserverd（root daemon）内：无 UIKit，实时音频线程内零分配零锁。
static FILE *gLCMediaLogF = NULL;
static int gLCMediaLogWarned = 0;
static long gLCMediaLogNsLog = 0;
static void LCMediaLog(const char *fmt, ...) {
    if (!gLCMediaLogF) {
        // daemon 沙盒通常禁止 /tmp：依次尝试 /var/log（root daemon 通用日志目录）→ /var/mobile/Documents
        const char *paths[] = { "/var/log/livecap_media.log", "/var/mobile/Documents/livecap_media.log", NULL };
        for (int i = 0; paths[i] && !gLCMediaLogF; i++) {
            gLCMediaLogF = fopen(paths[i], "a");
            if (gLCMediaLogF) {
                fprintf(gLCMediaLogF, "=== LiveCap mediaserverd tap session (path=%s) ===\n", paths[i]);
            }
        }
        if (!gLCMediaLogF && !gLCMediaLogWarned) {
            gLCMediaLogWarned = 1;
            NSLog(@"[LiveCap] media: fopen ALL log paths FAILED errno=%d", errno);
        }
    }
    if (!gLCMediaLogF) {
        // 全路径不可写时回退系统日志，但限频（音频回调每秒触发，不能每秒刷 os_log）
        long now = time(NULL);
        if (now != gLCMediaLogNsLog) {
            gLCMediaLogNsLog = now;
            va_list ap2;
            va_start(ap2, fmt);
            NSString *msg = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:fmt] arguments:ap2];
            va_end(ap2);
            NSLog(@"[LiveCap] media: %@", msg);
        }
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    time_t t = time(NULL);
    fprintf(gLCMediaLogF, "[%lld] ", (long long)t);
    vfprintf(gLCMediaLogF, fmt, ap);
    fprintf(gLCMediaLogF, "\n");
    va_end(ap);
    fflush(gLCMediaLogF);
}

#define LC_MEDIA_MAX_CB 16
static struct { AudioUnit au; AudioUnitElement el; AURenderCallbackStruct cb; } gMediaCbs[LC_MEDIA_MAX_CB];
static int gMediaCbN = 0;
static long gMediaLastLog = 0;
static int gMediaFmtValid = 0;
static AudioStreamBasicDescription gMediaFmt;

static int LCMediaFindSlot(AudioUnit unit, AudioUnitElement el) {
    for (int i = 0; i < gMediaCbN; i++) {
        if (gMediaCbs[i].au == unit && gMediaCbs[i].el == el) return i;
    }
    if (gMediaCbN < LC_MEDIA_MAX_CB) return gMediaCbN++;
    return -1;
}

// 包装回调：先跑原始回调（向系统输出音频），随后就地复制 ioData PCM（只 memcpy，不分配不锁）
static OSStatus LCMediaRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                      UInt32 inNumberFrames, AudioBufferList *ioData) {
    AURenderCallbackStruct *orig = (AURenderCallbackStruct *)inRefCon;
    OSStatus st = orig->inputProc(orig->inputProcRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (st == noErr && ioData && ioData->mNumberBuffers > 0 && inNumberFrames > 0 && inNumberFrames <= 262144) {
        long now = time(NULL);
        if (now != gMediaLastLog) {
            gMediaLastLog = now;
            unsigned ch = (unsigned)ioData->mBuffers[0].mNumberChannels;
            if (ch == 0) ch = 2;
            LCMediaLog("media: tap bus=%u frames=%u ch=%u sr=%.0f fmt=0x%08x noninter=%d",
                       (unsigned)inBusNumber, (unsigned)inNumberFrames, ch,
                       gMediaFmtValid ? gMediaFmt.mSampleRate : 0.0,
                       (unsigned)(gMediaFmtValid ? gMediaFmt.mFormatID : 0),
                       (gMediaFmtValid && (gMediaFmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved)) ? 1 : 0);
        }
    }
    return st;
}

static OSStatus (*orig_AUSP_Media)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus LC_AUSP_Media(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
                              AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    OSStatus st = orig_AUSP_Media(inUnit, inID, inScope, inElement, inData, inDataSize);
    if (st == noErr && inID == kAudioUnitProperty_SetRenderCallback && inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
        AURenderCallbackStruct cb;
        memcpy(&cb, inData, sizeof(cb));
        if (cb.inputProc) {
            int slot = LCMediaFindSlot(inUnit, inElement);
            if (slot >= 0) {
                gMediaCbs[slot].au = inUnit;
                gMediaCbs[slot].el = inElement;
                gMediaCbs[slot].cb = cb;
                AURenderCallbackStruct wrapped = { LCMediaRenderCallback, &gMediaCbs[slot].cb };
                orig_AUSP_Media(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
                if (!gMediaFmtValid) {
                    AudioStreamBasicDescription asbd;
                    UInt32 sz = sizeof(asbd);
                    if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                                             kAudioUnitScope_Output, inElement, &asbd, &sz) == noErr) {
                        gMediaFmt = asbd;
                        gMediaFmtValid = 1;
                        LCMediaLog("media: fmt sr=%.0f ch=%u fmt=0x%08x noninter=%d",
                                   asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
                                   (unsigned)asbd.mFormatID,
                                   (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : 0);
                    }
                }
                LCMediaLog("media: wrap cb unit=%p elem=%u (slot %d)", inUnit, (unsigned)inElement, slot);
            }
        }
    }
    return st;
}

// mediaserverd 入口：由构造器延迟 2s 调用（dlopen 早期 rebind 段错误，等 dyld 稳定后再 hook）
static void LCInitMediaServerTap(void) {
    LCMediaLog("media: init");
    struct rebinding rb = { "AudioUnitSetProperty", (void *)LC_AUSP_Media, (void **)&orig_AUSP_Media };
    int r = rebind_symbols(&rb, 1);
    LCMediaLog("media: rebind AudioUnitSetProperty=%d", r);
}

// ===== 音频路径发现：枚举所有相关类的方法，找到YouTube实际使用的 =====
static void LCDiscoverAudioPath(void) {
    @try {
        // 枚举 AVSampleBufferAudioRenderer 的所有实例方法
        Class asbr = NSClassFromString(@"AVSampleBufferAudioRenderer");
        if (asbr) {
            UInt32 methodCount = 0;
            Method *methods = class_copyMethodList(asbr, &methodCount);
            LCLogF(@"discover: AVSampleBufferAudioRenderer has %u methods", (unsigned)methodCount);
            for (UInt32 i = 0; i < methodCount; i++) {
                SEL sel = method_getName(methods[i]);
                const char *name = sel_getName(sel);
                if (name && (strstr(name, "sample") || strstr(name, "buffer") || strstr(name, "render") || strstr(name, "enqueue"))) {
                    LCLogF(@"discover:   - %s", name);
                }
            }
            free(methods);
        }
        
        // 枚举 AVSampleBufferRenderSynchronizer
        Class avsrs = NSClassFromString(@"AVSampleBufferRenderSynchronizer");
        if (avsrs) {
            UInt32 methodCount = 0;
            Method *methods = class_copyMethodList(avsrs, &methodCount);
            LCLogF(@"discover: AVSampleBufferRenderSynchronizer has %u methods", (unsigned)methodCount);
            for (UInt32 i = 0; i < methodCount; i++) {
                SEL sel = method_getName(methods[i]);
                const char *name = sel_getName(sel);
                if (name && (strstr(name, "sync") || strstr(name, "sample") || strstr(name, "buffer"))) {
                    LCLogF(@"discover:   - %s", name);
                }
            }
            free(methods);
        }
        
        // 枚举 AVAudioEngine 的节点
        Class ae = NSClassFromString(@"AVAudioEngine");
        if (ae) {
            LCLog(@"discover: AVAudioEngine found");
            // 检查 inputNode/outputNode 相关属性
            Class apn = NSClassFromString(@"AVAudioPlayerNode");
            if (apn) LCLog(@"discover: AVAudioPlayerNode available");
        }
    } @catch (NSException *e) {
        LCLogF(@"discover: error %@", e);
    }
}

static void LCSwizzleAudioProbe(void) {
    @try {
        // 先发现音频路径
        LCDiscoverAudioPath();
        
        Class ae = NSClassFromString(@"AVAudioEngine");
        if (ae) {
            Method m = class_getInstanceMethod(ae, @selector(init));
            if (m) { orig_avaeInit = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)LC_avaeInit); LCLog("probe: AVAudioEngine.init OK"); }
        }
        Class asbr = NSClassFromString(@"AVSampleBufferAudioRenderer");
        if (asbr) {
            Method m = class_getInstanceMethod(asbr, @selector(init));
            if (m) { orig_asbrInit = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)LC_asbrInit); LCLog("probe: AVSampleBufferAudioRenderer.init OK"); }
            Method me = class_getInstanceMethod(asbr, @selector(enqueueSampleBuffer:));
            if (me) { orig_asbrEnqueue = (void *)method_getImplementation(me); method_setImplementation(me, (IMP)LC_asbrEnqueue); LCLog("hook: ASBR enqueueSampleBuffer OK"); }
            // 尝试 hook 其他可能的方法名
            Method me2 = class_getInstanceMethod(asbr, @selector(dequeueSampleBuffer:));
            if (me2) { LCLog(@"hook: found dequeueSampleBuffer:"); }
            Method me3 = class_getInstanceMethod(asbr, @selector(processSampleBuffer:));
            if (me3) { LCLog(@"hook: found processSampleBuffer:"); }
        }
        Class avsrs = NSClassFromString(@"AVSampleBufferRenderSynchronizer");
        if (avsrs) {
            Method m = class_getInstanceMethod(avsrs, @selector(init));
            if (m) { orig_avsrsInit = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)LC_avsrsInit); LCLog("probe: AVSampleBufferRenderSynchronizer.init OK"); }
        }
        Class apn = NSClassFromString(@"AVAudioPlayerNode");
        if (apn) {
            Method m = class_getInstanceMethod(apn, @selector(init));
            if (m) { orig_avapnInit = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)LC_avapnInit); LCLog("probe: AVAudioPlayerNode.init OK"); }
        }
        Class as = NSClassFromString(@"AVAudioSession");
        if (as) {
            Method m1 = class_getInstanceMethod(as, @selector(setActive:error:));
            if (m1) { orig_avsasSetActive = (void *)method_getImplementation(m1); method_setImplementation(m1, (IMP)LC_avsasSetActive); LCLog("probe: AVAudioSession.setActive OK"); }
            Method m2 = class_getInstanceMethod(as, @selector(setCategory:error:));
            if (m2) { orig_avsasSetCategory = (void *)method_getImplementation(m2); method_setImplementation(m2, (IMP)LC_avsasSetCategory); LCLog("probe: AVAudioSession.setCategory OK"); }
        }
    } @catch (NSException *e) {
        LCLogF(@"probe: audio error %@", e);
    }
}

#pragma mark - 入口

static BOOL LCLazyStarted = NO;

// 语音识别授权：全局状态，需某个 App 触发。目标 App 声明了 NSSpeechRecognitionUsageDescription
// （如 YouTube）时，注入进程里请求是安全的，授权成功即全局生效。
// 1.0.12：无论授权状态如何，无授权时一律切换腾讯云在线识别（不依赖 iOS 授权）。
static void LCAuthSpeech(void) {
    SFSpeechRecognizerAuthorizationStatus st = [SFSpeechRecognizer authorizationStatus];
    LCLogF(@"speech: auth status=%ld", (long)st);
    if (st == SFSpeechRecognizerAuthorizationStatusAuthorized) {
        if ([[LCConfig shared] enabled]) {
            [[LCSpeech shared] startWithFormat:gProcessingFormat];
        }
        return;
    }
    if (st == SFSpeechRecognizerAuthorizationStatusDenied ||
        st == SFSpeechRecognizerAuthorizationStatusRestricted) {
        LCLog("speech: denied/restricted -> 切换腾讯云在线识别");
        if ([[LCConfig shared] enabled]) {
            [[LCHttpASR shared] startWithFormat:gProcessingFormat];
        }
        return;
    }
    // notDetermined：只有目标 App 声明了 usage description 才请求（无声明时请求可能被系统终止）
    NSString *desc = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSSpeechRecognitionUsageDescription"];
    if (desc.length == 0) {
        LCLog("speech: target app has NO speech usage description -> 使用腾讯云在线识别");
        if ([[LCConfig shared] enabled]) {
            [[LCHttpASR shared] startWithFormat:gProcessingFormat];
        }
        return;
    }
    LCLog("speech: requesting authorization (usage description present)");
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st2) {
        LCLogF(@"speech: request result %ld", (long)st2);
        if (st2 == SFSpeechRecognizerAuthorizationStatusAuthorized) {
            if ([[LCConfig shared] enabled]) {
                [[LCSpeech shared] startWithFormat:gProcessingFormat];
            }
        } else {
            LCLog("speech: not authorized -> 使用腾讯云在线识别");
            if ([[LCConfig shared] enabled]) {
                [[LCHttpASR shared] startWithFormat:gProcessingFormat];
            }
        }
    }];
}

static void LCLazyInit(void) {
    if (LCLazyStarted) return;
    LCLazyStarted = YES;
    LCLogF(@"init: [0/4] dylib loaded in %@ v%@",
           [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
           [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");
    LCLog("init: [1/4] swizzle avplayer");
    LCSwizzleAVPlayer();
    LCSwizzleAudioProbe();
    LCHookAudioUnitRender();
    LCLog("init: [1b/4] hook AudioUnitSetProperty done");
    LCLog("init: [2/4] swizzle shortcut");
    // LCSwizzleShortcut(); // v2.0.0: 移除 3D Touch 快捷菜单
    LCLog("init: [3/4] install shortcut item");
    // LCInstallShortcutItem(); // v2.0.0: 移除 3D Touch 快捷菜单
    LCLog("init: [4/4] speech auth + active observer");
    LCAuthSpeech();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        // LCScheduleShortcutRefresh(); // v2.0.0: 移除 3D Touch 快捷菜单  // 抢回被 App 覆盖的快捷菜单
        if ([[LCConfig shared] enabled]) {
            [[LCSubtitleOverlay shared] install];
        }
    }];
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState == UIApplicationStateActive && [[LCConfig shared] enabled]) {
        LCLog("init: active, install overlay");
        [[LCSubtitleOverlay shared] install];
    }
    LCLog("init: done");
}

// v2.2.1：对齐 XL-Roothide —— 运行时【不】做 App 白名单拦截。
// v2.2.0 的 enabledBundles 判定「不在列表就 return」有致命副作用：
// 面板一旦把列表写坏（roothide 下 Filter 回读为空 → 勾 1 个 App 就把原有
// 27 个默认 bundle 抹成 1 个），连原本能用的 YouTube 也会被 constructor
// 直接挡掉，表现就是「注入没效果 / 选了别的 App 还是不出字幕」。
// 注入范围只由 Filter.Bundles 精确匹配 + Dopamine Inject Manager 决定（XL 同款做法）。
// 这里只留诊断日志，真机可确认当前 App 与勾选列表的关系，绝不拦截 hook。
static void LCLogBundleSelection(void) {
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    NSArray *list = d[@"selectedApps"] ?: d[@"enabledBundles"];
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([list isKindOfClass:[NSArray class]] && list.count && bid.length &&
        ![list containsObject:bid]) {
        LCLog("init: not in enabledBundles (log only, injection not blocked)");
    }
}

__attribute__((constructor))
static void LCInit(void) {
    // 纯 C 诊断：构造函数第一行就写文件，不依赖 ObjC
    const char *exe = getprogname();
    if (!exe) return;
    
    // 写入 /var/mobile/Documents/（越狱设备可写）
    const char *diag_path = "/var/mobile/Documents/livecap_ctor.log";
    FILE *df = fopen(diag_path, "a");
    if (df) {
        fprintf(df, "=== LCInit ctor called at %ld prog=%s ===\n", (long)time(NULL), exe);
        fflush(df);
        fclose(df);
    }
    
    // 也尝试写入应用沙盒 Documents 目录
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count) {
            NSString *sandboxPath = [paths[0] stringByAppendingPathComponent:@"livecap_ctor_sandbox.log"];
            FILE *sf = fopen([sandboxPath UTF8String], "a");
            if (sf) {
                fprintf(sf, "=== LCInit sandbox ctor at %ld ===\n", (long)time(NULL));
                fflush(sf);
                fclose(sf);
            }
        }
    }

    // 系统音频守护进程检查
    if (strcmp(exe, "mediaserverd") == 0) {
        // 探测可写路径
        const char *mpaths[] = { "/tmp/livecap_media.log",
                                 "/var/mobile/Documents/livecap_media.log",
                                 NULL };
        for (int mi = 0; mpaths[mi]; mi++) {
            FILE *mf = fopen(mpaths[mi], "a");
            if (mf) {
                fprintf(mf, "=== LiveCap mediaserverd tap (1.0.83) ===\n");
                fprintf(mf, "[%lld] ctor ran: prog=%s path=%s\n", (long long)time(NULL), exe, mpaths[mi]);
                fflush(mf);
                fclose(mf);
                break;
            }
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @try {
                LCInitMediaServerTap();
            } @catch (NSException *e) {
                LCLogF(@"media: tap init error %@", e);
            }
        });
        return;
    }

    if (strncmp(exe, "/System", 7) == 0) return;
    if (strncmp(exe, "/usr", 4) == 0) return;
    if (strncmp(exe, "/bin", 4) == 0) return;
    // v2.2.1：不再用偏好白名单拦 hook（详见 LCLogBundleSelection 注释）
    LCLogBundleSelection();

    // 注入后先等 App 完全启动（3s），再在下一轮主线程空闲时做 hook，
    // 最大程度避免干扰 App 自身初始化。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LCLog("init: wake");
        @try {
            LCLazyInit();
        } @catch (NSException *e) {
            LCLogF(@"init: error %@", e);
        }
    });
}
