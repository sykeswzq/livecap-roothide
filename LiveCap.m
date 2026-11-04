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
static const NSInteger LC_ASR_MAX_CONCURRENCY = 2;

// 请求结束时释放一个并发槽位（防止计数变负）
#define LC_ASR_DONE() do { \
    if (_inFlightCount > 0) _inFlightCount--; \
} while (0)

// ===== v1.0.85：AAC 编码（压缩上传）=====
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
// 调用方自动回退 WAV/PCM（速度退回 v1.0.84 水平，不会更差）。

typedef struct {
    const uint8_t *data;
    size_t len;
    size_t pos;
} LCPcmCursor;

// AudioConverter 输入回调：把 PCM16 分片喂给编码器
// 签名必须严格等于 AudioConverterComplexInputDataProc：
//   OSStatus (*)(void *inRefCon, UInt32 *ioNumberDataPackets, void **outData)
// 返回类型是 OSStatus(int)，不是 UInt32 / size_t —— 用错 CI 会报
// "incompatible function pointer types"。
static OSStatus LCAACInputProc(void *inRefCon, UInt32 *ioNumDataPackets, void **ioData) {
    LCPcmCursor *cur = (LCPcmCursor *)inRefCon;
    size_t remain = cur->len - cur->pos;
    size_t want = (size_t)(*ioNumDataPackets) * 2;   // 每包 2 字节（16bit mono）
    size_t give = (remain < want) ? remain : want;
    if (give == 0) { *ioNumDataPackets = 0; return noErr; }
    *ioData = (void *)(cur->data + cur->pos);
    cur->pos += give;
    *ioNumDataPackets = (UInt32)(give / 2);
    return noErr;
}

// AudioConverter 输出回调：把编码好的 AAC 帧收集起来
static OSStatus LCAACOutputProc(void *inRefCon, UInt32 *ioNumDataPackets,
                               const AudioBufferList **ioData) {
    NSMutableData *out = (__bridge NSMutableData *)inRefCon;
    const AudioBufferList *abl = *ioData;
    if (abl && abl->mNumberBuffers > 0) {
        // 注意：这里必须用 C 指针，不能用 C++ 引用语法 `AudioBuffer &b`。
        // Objective-C 不支持引用声明，CI 会报
        // "expected identifier or '('" + "use of undeclared identifier 'b'"。
        const AudioBuffer *b = &abl->mBuffers[0];
        if (b->mDataByteSize > 0 && b->mData) {
            [out appendBytes:b->mData length:b->mDataByteSize];
        }
    }
    *ioNumDataPackets = 0;   // 已取走
    return noErr;
}

// PCM16@16k mono → AAC-LC@16k mono（裸帧流，无 ADTS 头）
// 失败返回 nil（调用方回退 WAV）
static NSData *LCAACEncode16kMono(NSData *pcm16) {
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

    UInt32 bitRate = 16000;   // 16 kbps：足够语音识别，体积是 PCM 的 1/16
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

    NSMutableData *out = [NSMutableData dataWithCapacity:pcm16.length / 8];
    UInt32 outCount = 0;
    OSStatus status =
        AudioConverterFillComplexBuffer(conv, LCAACInputProc, &cur, &outCount,
                                        LCAACOutputProc, (__bridge void *)out);
    AudioConverterDispose(conv);

    // 编码失败或输出过短 → 返回 nil 让调用方回退 WAV
    if (status != noErr) return nil;
    if (out.length < 512) return nil;
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
@property (readonly) NSString *sourceLang;
@property (readonly) NSString *targetLang;
@property (readonly) NSString *apiBase;
@property (readonly) NSString *apiKey;
@property (readonly) NSString *model;
@property (readonly) NSString *tencentSecretId;
@property (readonly) NSString *tencentSecretKey;
@property (readonly) CGFloat fontSize;
@property (readonly) BOOL boldText;
@property (readonly) UIColor *textColor;
@property (readonly) NSString *backgroundStyle;
@property (readonly) BOOL showEnglish;   // 是否同时显示英文原文（默认 NO：只显示中文一行）
@property (readonly) CGFloat manualX;
@property (readonly) CGFloat manualY;
@property (readonly) double asrChunkSeconds;   // v1.0.84：ASR 分片时长（秒）
- (void)saveManualX:(CGFloat)x y:(CGFloat)y;
- (void)writeConfig:(NSMutableDictionary *)d;
- (void)setSourceLang:(NSString *)lang forBundle:(NSString *)bid;
- (void)reload;
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

- (BOOL)enabled {
    NSNumber *v = _d[@"enabled"];
    return v ? [v boolValue] : YES;
}

- (NSString *)sourceLang {
    // 每个 App 单独覆盖：sourceLang_<bundleId> 优先，否则用全局 sourceLang
    NSString *per = _d[[NSString stringWithFormat:@"sourceLang_%@", self.bundleId]];
    if (per && per.length) return per;
    NSString *s = _d[@"sourceLang"];
    return (s && s.length) ? s : @"en-US";
}

- (void)setSourceLang:(NSString *)lang forBundle:(NSString *)bid {
    NSString *path = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    d[[NSString stringWithFormat:@"sourceLang_%@", bid]] = lang;
    [self writeConfig:d];
    _d = d;
}

- (NSString *)targetLang {
    NSString *s = _d[@"targetLang"];
    return (s && s.length) ? s : @"zh-CN";
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
    // 默认用 agnes-2.5-flash：实测 agnes-3.0-flash 无论 prompt 长短都要 29~40s，
    // 远超字幕场景可接受延迟（设备网络超时上限只有 15s → 必然全失败）。
    // agnes-2.5-flash 实测 0.87~3.4s。
    return (s && s.length) ? s : @"agnes-2.5-flash";
}

- (NSString *)tencentSecretId {
    NSString *s = _d[@"tencentSecretId"];
    return (s && s.length) ? s : @"";
}

- (NSString *)tencentSecretKey {
    NSString *s = _d[@"tencentSecretKey"];
    return (s && s.length) ? s : @"";
}

- (CGFloat)fontSize {
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

// v1.0.84：ASR 分片时长（秒）。
// 依据：设备日志显示 ASR RTT ≈ 音频时长 × 1.1（5.11s→5.6s，7.2s→10s），
// 分片越长延迟越大。默认 2.5 秒：RTT ≈ 2.8s，比 5 秒分片省约 2.8 秒。
// 允许范围 1.0~8.0 秒；配 0 或非法值时回退到默认 2.5。
- (double)asrChunkSeconds {
    NSNumber *v = _d[@"asrChunkSeconds"];
    if (!v) return 2.5;
    double s = [v doubleValue];
    if (s < 1.0 || s > 8.0) return 2.5;
    return s;
}

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

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", [LCConfig shared].targetLang, trimmed];
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

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", [[LCConfig shared] targetLang], text];
    NSString *cached = nil;
    @synchronized(self) { cached = _cache[cacheKey]; }
    if (cached.length > 0) {
        if (comp) dispatch_async(dispatch_get_main_queue(), ^{ comp(cached); });
        [self pumpQueue];
        return;
    }

    _inflight = YES;
    NSString *target = [[LCConfig shared] targetLang];

    // ===== prompt 精简（v1.0.81）=====
    // 实测（设备 → apihub.agnes-ai.cn 网关）：
    //   agnes-3.0-flash + 1401 字节长 prompt → 29~40s（必然超时）
    //   agnes-2.5-flash +  232 字节中 prompt → 0.96~7.6s（可用）
    // 长 prompt 不只是慢，还会显著抬高网关排队时间。
    // 这里保留最关键的三条约束（只输出译文 / 输入可能是脏片段要照翻 / 绝不回显英文），
    // 去掉示例和冗长规则，压到 ~230 字节。
    NSString *sysPrompt = [NSString stringWithFormat:
        @"Translate to %@. Output ONLY the translation: no quotes, no explanation. "
        @"The input may be a noisy speech-to-text fragment: infer the meaning and output Chinese. "
        @"NEVER echo the English input; the output MUST contain Chinese characters.",
        target];

    __weak typeof(self) weakSelf = self;
    [self raceTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey target:target
             completion:^(NSString *result) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf->_queue, ^{
            strongSelf->_inflight = NO;
            if (comp) dispatch_async(dispatch_get_main_queue(), ^{ comp(result); });
            [strongSelf pumpQueue];
        });
    }];
}

// 译文有效性校验：模型对识别质量差的输入（乱码/短片段）常原样返回英文 ——
// 这不算翻译成功。必须与原文比对，且目标语言为中文时结果里必须含中文字符。
- (BOOL)isUsableTranslation:(NSString *)res forText:(NSString *)text {
    if (!res.length) return NO;
    NSString *norm = [res stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!norm.length) return NO;
    NSString *orig = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([norm isEqualToString:orig]) return NO;
    NSString *dst = [[LCConfig shared] targetLang];
    if ([dst hasPrefix:@"zh"]) {
        BOOL hasCJK = NO;
        for (NSUInteger i = 0; i < norm.length; i++) {
            unichar ch = [norm characterAtIndex:i];
            if (ch >= 0x4E00 && ch <= 0x9FFF) { hasCJK = YES; break; }
        }
        if (!hasCJK) return NO;
    }
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
               cacheKey:(NSString *)cacheKey target:(NSString *)target
             completion:(void (^)(NSString *result))completion {
    NSString *apiKey = [[LCConfig shared] apiKey];
    NSString *apiBase = [[LCConfig shared] apiBase];
    NSString *model = [[LCConfig shared] model];

    // 参赛厂商
    NSMutableArray *providers = [NSMutableArray array];
    if (apiKey.length && apiBase.length) [providers addObject:@"agnes"];
    [providers addObject:@"mymemory"];               // 永远保留的免费兜底
    BOOL tencentDisabled = NO;
    @synchronized(self) { tencentDisabled = _tencentDisabled; }
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
            LCLogF(@"translate: race -> mymemory");
            [self mymemoryTranslate:text targetLang:target cacheKey:cacheKey
                         completion:^(NSString *r) { onResult(p, r); }];
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

// MyMemory 免费翻译（GET api.mymemory.translated.net，无需密钥）
- (void)mymemoryTranslate:(NSString *)text targetLang:(NSString *)target
                 cacheKey:(NSString *)cacheKey completion:(void (^)(NSString *result))completion {
    NSString *src = LCShortLang([LCConfig shared].sourceLang);
    NSString *dst = LCShortLang(target);
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
    req.timeoutInterval = 12.0;
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
    NSString *src = LCTmtLang([LCConfig shared].sourceLang);
    NSString *dst = LCTmtLang([LCConfig shared].targetLang);
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
    req.timeoutInterval = 12.0;

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
    NSString *trimmedModel = model.length ? model : @"agnes-2.5-flash";
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
    // 超时放宽到 30s：实测网关慢模型单次要 29~40s，15s 必然 -1001 超时。
    // 但因为 v1.0.81 改成了并行竞速（MyMemory 同时在跑），慢的这一路超时
    // 也不会拖累整句 —— 快的那个早已返回。
    req.timeoutInterval = 30.0;

    LCLogF(@"translate: openai request url=%@ model=%@ attempt=%ld", chatUrl, trimmedModel, (long)attempt);
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskErr) {
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
    BOOL _directFailed;           // 直连失败标记：一旦失败永久回退走代理
    BOOL _aacBroken;              // AAC 编码/识别失败标记：一旦失败永久回退 WAV
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
            [_pcm appendBytes:tmp length:frames * sizeof(float)];
            free(tmp);

            // v1.0.84：分片时长从固定 5 秒改为可配置，默认 2.5 秒。
            // 依据（设备日志实证）：ASR RTT ≈ 音频时长 × 1.1
            //   5.11s 音频 → RTT 5.6s；7.20s 音频 → RTT 10s
            // 分片减半 → RTT 近似减半 → 字幕延迟从 ~6s 降到 ~3s。
            // 代价：句子被切碎的概率上升。为补偿，保留 overlap 重叠区
            // （下一段开头复用上一段末尾的音频），避免词被切断。
            double chunkSecs = [[LCConfig shared] asrChunkSeconds];
            double secs = (double)_pcm.length / sizeof(float) / _inRate;
            if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
                NSData *chunk = [_pcm copy];
                [_pcm setLength:0];
                [self processChunk:chunk];
            } else if (secs >= chunkSecs * 2.0) {
                // 上次请求未完成：丢弃过量累积防止内存膨胀
                [_pcm setLength:0];
            }
        } @catch (NSException *e) {
            LCLogF(@"asr: append err %@", e);
        }
    }
}

- (void)processChunk:(NSData *)floatMono {
    if (!floatMono || floatMono.length < sizeof(float) * 1600) return;  // <0.1s 丢弃
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

                // 2) v1.0.85：优先 AAC 压缩上传。
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
                NSString *lang = [[LCConfig shared] sourceLang];
                NSString *eng = @"16k_multi_lang";   // 多语言大模型引擎
                if ([lang isEqualToString:@"zh-CN"]) eng = @"16k_zh";
                else if ([lang isEqualToString:@"ja-JP"]) eng = @"16k_ja";
                else if ([lang isEqualToString:@"ko-KR"]) eng = @"16k_ko";

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
                    }
                    NSError *__autoreleasing pe = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
                    if (pe || !json) { LCLogF(@"asr: parse err %@", pe); return; }
                    NSDictionary *respD = json[@"Response"];
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
}

// ===== AVSampleBuffer 管线（YouTube 自研播放器）输入 =====

// 单声道 float32 输入（appendCMSampleBuffer 转换后）：与现有 float32 累积/重采样/POST 完全复用
- (void)appendMonoFloat:(const float *)mono frames:(UInt32)frames {
    if (!_running) return;
    if (![[LCConfig shared] enabled]) return;
    if (!mono || frames == 0) return;
    @autoreleasepool {
        [_pcm appendBytes:mono length:frames * sizeof(float)];
        // v1.0.84：分片时长与 appendBufferList: 保持一致（可配置，默认 2.5 秒）。
        // 依据（设备日志实证）：ASR RTT ≈ 音频时长 × 1.1，
        // 分片越长延迟越大；5 秒分片 → RTT 5.6s，2.5 秒分片 → RTT 约 2.8s。
        double chunkSecs = [[LCConfig shared] asrChunkSeconds];
        double secs = (double)_pcm.length / sizeof(float) / _inRate;
        if (secs >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm copy];
            [_pcm setLength:0];
            [self processChunk:chunk];
        } else if (secs >= chunkSecs * 2.0) {
            // 上次请求未完成：丢弃过量累积防止内存膨胀
            [_pcm setLength:0];
        }
    }
}

- (void)appendPCM16:(NSData *)pcm16 {
    if (!_running) return;
    if (![[LCConfig shared] enabled]) return;
    if (!pcm16 || pcm16.length == 0) return;
    @autoreleasepool {
        [_pcm16 appendData:pcm16];
        // v1.0.85：修掉写死的 5 秒分片（v1.0.84 只改了 float 路径，漏了这里）。
        // 统一使用 asrChunkSeconds 配置，默认 2.5 秒。
        double chunkSecs = [[LCConfig shared] asrChunkSeconds];
        double secs16 = (double)_pcm16.length / 2.0 / 16000.0;
        if (secs16 >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {
            NSData *chunk = [_pcm16 copy];
            [_pcm16 setLength:0];
            [self processChunk16:chunk];
        } else if (secs16 >= chunkSecs * 2.0) {
            // 并发槽位满：丢弃过量累积防止内存膨胀
            [_pcm16 setLength:0];
        }
    }
}

- (void)processChunk16:(NSData *)pcm16 {
    if (!pcm16 || pcm16.length < 1600) return;
    _inFlightCount++;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
                // 2) v1.0.85：优先 AAC 压缩上传。
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
                NSString *lang = [[LCConfig shared] sourceLang];
                NSString *eng = @"16k_zh";
                if ([lang isEqualToString:@"en-US"]) eng = @"16k_en";
                else if ([lang isEqualToString:@"ja-JP"]) eng = @"16k_ja";
                else if ([lang isEqualToString:@"ko-KR"]) eng = @"16k_ko";
                else if ([lang isEqualToString:@"zh-CN"]) eng = @"16k_zh";

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
                    }
                    NSError *__autoreleasing pe = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
                    if (pe || !json) { LCLogF(@"asr16: parse err %@", pe); return; }
                    NSDictionary *respD = json[@"Response"];
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

        LCLog("overlay: installed");
    } @catch (NSException *e) {
        LCLog("overlay: install error");
        _container = nil;
        _installed = NO;
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
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:[LCConfig shared].sourceLang];
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

#pragma mark - 长按图标快捷开关（桌面图标长按菜单）

static void LCAuthSpeech(void);  // 前向声明（定义在文件末尾入口段）

static void LCToggleEnabled(void) {
    NSString *path = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    BOOL now = ![[LCConfig shared] enabled];
    d[@"enabled"] = @(now);
    // v1.0.83：走统一写入通道（写完同步 cfprefsd，避免与面板互相覆盖）
    [[LCConfig shared] writeConfig:d];
    [[LCConfig shared] reload];
    LCLogF(@"toggle: now=%d", now);
    if (now) {
        [[LCSubtitleOverlay shared] install];
        [[LCSubtitleOverlay shared] showToast:@"实时字幕翻译：已开启"];
        LCAuthSpeech();  // 授权检查 + 补启动识别（无授权自动切在线）
    } else {
        [[LCSpeech shared] stop];
        [[LCSubtitleOverlay shared] showToast:@"实时字幕翻译：已关闭"];
    }
}

#pragma mark - 桌面图标快捷菜单（长按已注入 App 图标 → 开关实时字幕翻译）

static BOOL LCShortcutInstalled = NO;

static void LCInstallShortcutItem(void) {
    // 每次调用都重新设置（去掉一次性保护）：目标 App（如 YouTube）自己也会写
    // shortcutItems，会覆盖我们的菜单。didBecomeActive 时重新装一遍抢回来。
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        // 接管菜单（不保留 App 原有快捷项），并限制总数 ≤4：
        // iOS 主屏长按菜单最多显示 4 项，5 项会被截断（之前语言项就是这么消失的）。
        // 4 项 = 开关 + 识别英语/日语/韩语；中文是默认翻译目标不进快捷。
        NSMutableArray *items = [NSMutableArray array];

        // 总开关项
        [items addObject:[[UIApplicationShortcutItem alloc]
            initWithType:@"com.sykes.livecap.toggle"
            localizedTitle:@"开关实时字幕翻译"
            localizedSubtitle:nil
            icon:[UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypePlay]
            userInfo:nil]];

        // 语言快捷切换（每个 App 单独记忆，长按图标即可改，不用进设置）。
        // 中文是默认翻译目标，不做识别快捷；识别语言 = 英/日/韩（正好 4 项含开关）。
        NSArray *langs = @[
            @{@"t": @"com.sykes.livecap.lang.en", @"n": @"识别英语"},
            @{@"t": @"com.sykes.livecap.lang.ja", @"n": @"识别日语"},
            @{@"t": @"com.sykes.livecap.lang.ko", @"n": @"识别韩语"},
        ];
        for (NSDictionary *ld in langs) {
            [items addObject:[[UIApplicationShortcutItem alloc]
                initWithType:ld[@"t"]
                localizedTitle:ld[@"n"]
                localizedSubtitle:nil
                icon:[UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypeSearch]
                userInfo:nil]];
        }

        app.shortcutItems = items;
        LCShortcutInstalled = YES;
        LCLog("shortcut: reinstalled (toggle+en+ja+zh)");
    } @catch (NSException *e) {
        LCLogF(@"shortcut: error %@", e);
    }
}

// 回到前台后延迟重装快捷菜单（防 App 自己的 shortcutItems 覆盖）
static void LCScheduleShortcutRefresh(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { LCInstallShortcutItem(); } @catch (NSException *e) {}
    });
}

static NSString *LCLangDisplay(NSString *loc) {
    if ([loc isEqualToString:@"en-US"]) return @"英语";
    if ([loc isEqualToString:@"ja-JP"]) return @"日语";
    if ([loc isEqualToString:@"ko-KR"]) return @"韩语";
    if ([loc isEqualToString:@"zh-CN"]) return @"中文";
    return loc;
}

static void (*orig_performAction)(id, SEL, UIApplicationShortcutItem *, id);
static void LC_performAction(id self, SEL _cmd, UIApplicationShortcutItem *item, id completionHandler) {
    @try {
        if (item && [item.type isEqualToString:@"com.sykes.livecap.toggle"]) {
            LCLog("shortcut: toggle tapped");
            LCToggleEnabled();
            if (completionHandler) {
                void (^handler)(BOOL) = (void (^)(BOOL))completionHandler;
                handler(YES);
            }
            return;
        }
        if (item && [item.type hasPrefix:@"com.sykes.livecap.lang."]) {
            NSString *code = [item.type substringFromIndex:[@"com.sykes.livecap.lang." length]];
            NSString *loc = nil;
            if ([code isEqualToString:@"en"]) loc = @"en-US";
            else if ([code isEqualToString:@"ja"]) loc = @"ja-JP";
            else if ([code isEqualToString:@"ko"]) loc = @"ko-KR";
            else if ([code isEqualToString:@"zh"]) loc = @"zh-CN";
            if (loc) {
                NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
                [[LCConfig shared] setSourceLang:loc forBundle:bid];
                [[LCSpeech shared] stop];
                if ([[LCConfig shared] enabled]) {
                    [[LCSpeech shared] startWithFormat:gProcessingFormat];
                }
                [[LCSubtitleOverlay shared] showToast:
                    [NSString stringWithFormat:@"本 App 识别语言：%@", LCLangDisplay(loc)]];
                LCLogF(@"lang: set %@ for %@", loc, bid);
            }
            if (completionHandler) {
                void (^handler)(BOOL) = (void (^)(BOOL))completionHandler;
                handler(YES);
            }
            return;
        }
    } @catch (NSException *e) {}
    if (orig_performAction) orig_performAction(self, _cmd, item, completionHandler);
}

static void LCSwizzleShortcut(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        id delegate = app.delegate;
        if (!delegate) return;
        SEL sel = @selector(application:performActionForShortcutItem:completionHandler:);
        Method m = class_getInstanceMethod([delegate class], sel);
        if (m) {
            orig_performAction = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)LC_performAction);
        } else {
            BOOL ok = class_addMethod([delegate class], sel, (IMP)LC_performAction, "v@:@?");
            if (!ok) {
                m = class_getInstanceMethod([delegate class], sel);
                if (m) method_setImplementation(m, (IMP)LC_performAction);
            }
        }
        LCLog("hook: shortcut action OK");
    } @catch (NSException *e) {
        LCLogF(@"hook: shortcut error %@", e);
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
    LCSwizzleShortcut();
    LCLog("init: [3/4] install shortcut item");
    LCInstallShortcutItem();
    LCLog("init: [4/4] speech auth + active observer");
    LCAuthSpeech();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        LCScheduleShortcutRefresh();  // 抢回被 App 覆盖的快捷菜单
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
