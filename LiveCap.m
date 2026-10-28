// LiveCap.m — roothide 实时视频字幕翻译 tweak (iOS 15-16, arm64e) v1.0.12
// 原理：swizzle AVPlayer 拿到 AVPlayerItem，挂 MTAudioProcessingTap 抓 PCM
//      → SFSpeech 实时转写（有授权时）；无授权自动切腾讯云一句话识别（在线 ASR）
//      → 原文经 OpenAI 兼容接口翻译（agnes）
//      → 悬浮双语字幕显示在 keyWindow.rootViewController.view（不新建 UIWindow）
// 依赖：AVFoundation / Speech / MediaToolbox / AudioToolbox / CommonCrypto
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <MediaToolbox/MTAudioProcessingTap.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#import <mach-o/dyld.h>

#pragma mark - 日志

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
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                @try {
                    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
                    [fh seekToEndOfFile];
                    [fh writeData:data];
                    [fh closeFile];
                } @catch (NSException *e) {}
            } else {
                [data writeToFile:p atomically:YES];
            }
        }
        // 尽力写全局路径（App Store 沙盒可能拒绝，失败静默）
        [data writeToFile:@"/var/mobile/Documents/livecap.log" atomically:YES];
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
@property (readonly) CGFloat manualX;
@property (readonly) CGFloat manualY;
- (void)saveManualX:(CGFloat)x y:(CGFloat)y;
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
    [d writeToFile:path atomically:YES];
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

- (void)saveManualX:(CGFloat)x y:(CGFloat)y {
    NSString *path = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    NSMutableDictionary *pos = [NSMutableDictionary dictionaryWithDictionary:
        [d[@"manualPositions"] isKindOfClass:[NSDictionary class]] ? d[@"manualPositions"] : @{}];
    pos[self.bundleId] = @{@"x": @(x), @"y": @(y)};
    d[@"manualPositions"] = pos;
    [d writeToFile:path atomically:YES];
    _d = d;  // 内存同步，下一次 show 直接生效
    LCLogF(@"pos: saved for %@ x=%.2f y=%.2f", self.bundleId, x, y);
}

@end

#pragma mark - 翻译（OpenAI 兼容 chat/completions）

@interface LCTranslator : NSObject
+ (instancetype)shared;
- (void)translate:(NSString *)text completion:(void (^)(NSString *result))completion;
@end

@implementation LCTranslator {
    NSURLSession *_session;
    dispatch_queue_t _queue;
    NSMutableDictionary *_cache;
    NSMutableDictionary *_lastSentText;
    NSMutableDictionary *_lastSentTime;
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
    });
    return s;
}

- (void)translate:(NSString *)text completion:(void (^)(NSString *))completion {
    if (!text || text.length == 0) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", [LCConfig shared].targetLang, trimmed];
    NSString *cached = _cache[cacheKey];
    if (cached) {
        if (completion) completion(cached);
        return;
    }

    // 相同文本 1.0s 内不重复请求（partial 节流）
    NSNumber *nowN = @([[NSDate date] timeIntervalSince1970]);
    NSString *lastText = _lastSentText[cacheKey];
    NSNumber *lastTime = _lastSentTime[cacheKey];
    if (lastText && [lastText isEqualToString:trimmed] && lastTime &&
        ([nowN doubleValue] - [lastTime doubleValue]) < 1.0) {
        return;
    }
    _lastSentText[cacheKey] = trimmed;
    _lastSentTime[cacheKey] = nowN;

    dispatch_async(_queue, ^{
        NSString *target = [[LCConfig shared] targetLang];
        NSString *sysPrompt = [NSString stringWithFormat:
            @"You are a subtitle translation engine. Translate the user's subtitle text into %@ (简体中文 if unspecified). "
            @"Output ONLY the translated text. No explanations, no quotation marks, no extra punctuation. "
            @"Keep line breaks where they make sense.", target];

        NSDictionary *body = @{
            @"model": [LCConfig shared].model ?: @"agnes-3.0-flash",
            @"messages": @[
                @{@"role": @"system", @"content": sysPrompt},
                @{@"role": @"user", @"content": trimmed}
            ],
            @"temperature": @0
        };

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:[[[LCConfig shared] apiBase] stringByAppendingString:@"/chat/completions"]]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", [LCConfig shared].apiKey] forHTTPHeaderField:@"Authorization"];
        req.timeoutInterval = 12.0;
        NSError *__autoreleasing err = nil;
        NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
        if (err || !payload) {
            LCLogF(@"translate: json err %@", err);
            return;
        }
        req.HTTPBody = payload;

        NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskErr) {
            if (taskErr) {
                LCLogF(@"translate: req err %@", taskErr);
                return;
            }
            NSError *__autoreleasing parseErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
            if (parseErr || !json) {
                LCLogF(@"translate: parse err %@", parseErr);
                return;
            }
            NSArray *choices = json[@"choices"];
            if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) return;
            NSString *content = choices[0][@"message"][@"content"];
            if (![content isKindOfClass:[NSString class]] || content.length == 0) return;
            NSString *result = [content stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            _cache[cacheKey] = result;
            if (_cache.count > 300) [_cache removeAllObjects];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            }
        }];
        [task resume];
    });
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

static NSString *LCTencentAuthHeader(NSString *secretId, NSString *secretKey,
                                     NSString *timestamp, NSString *date,
                                     NSData *payload, NSString *host) {
    // CanonicalRequest
    NSString *hashedPayload = LCDataToHex(LCSHA256(payload));
    NSString *canonicalHeaders = [NSString stringWithFormat:
        @"content-type:application/json; charset=utf-8\nhost:%@\nx-tc-action:sentencerecognition\n", host];
    NSString *signedHeaders = @"content-type;host;x-tc-action";
    NSString *canonicalRequest = [NSString stringWithFormat:
        @"POST\n/\n\n%@\n%@\n%@",
        canonicalHeaders, signedHeaders, hashedPayload];

    NSString *credentialScope = [NSString stringWithFormat:@"%@/asr/tc3_request", date];
    NSString *stringToSign = [NSString stringWithFormat:
        @"TC3-HMAC-SHA256\n%@\n%@\n%@",
        timestamp, credentialScope, LCDataToHex(LCSHA256(LCBytes(canonicalRequest)))];

    // 密钥派生（TC3+SecretKey 是二进制 HMAC 键）
    NSMutableData *tc3Key = [NSMutableData data];
    [tc3Key appendBytes:"TC3" length:3];
    [tc3Key appendData:LCBytes(secretKey)];

    NSData *secretDate = LCHMACSHA256(tc3Key, LCBytes(date));
    NSData *secretService = LCHMACSHA256(secretDate, LCBytes(@"asr"));
    NSData *secretSigning = LCHMACSHA256(secretService, LCBytes(@"tc3_request"));
    NSData *signature = LCHMACSHA256(secretSigning, LCBytes(stringToSign));

    return [NSString stringWithFormat:
        @"TC3-HMAC-SHA256 Credential=%@/%@, SignedHeaders=%@, Signature=%@",
        secretId, credentialScope, signedHeaders, LCDataToHex(signature)];
}

// tap 输入格式（LCTapPrepare 记录，供 PCM 转换 / SFSpeech 缓冲）
static AudioStreamBasicDescription gProcessingFormat;
static BOOL gProcessingFormatValid = NO;

@class LCSubtitleOverlay;  // 前向声明：LCHttpASR 在 LCSubtitleOverlay 之前引用

@interface LCHttpASR : NSObject
+ (instancetype)shared;
- (BOOL)isRunning;
- (void)startWithFormat:(AudioStreamBasicDescription)asbd;
- (void)appendBufferList:(AudioBufferList *)list frames:(UInt32)frames;
- (void)stop;
@end

@implementation LCHttpASR {
    NSMutableData *_pcm;          // float32 单声道样本累积
    double _inRate;               // 输入采样率
    BOOL _running;
    BOOL _inFlight;               // 上一次请求未返回时跳过本段
    NSURLSession *_session;
}

+ (instancetype)shared {
    static LCHttpASR *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[LCHttpASR alloc] init];
        s->_pcm = [NSMutableData data];
        s->_session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
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
    _inFlight = NO;
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

            // 每 ~5 秒切一段识别
            double secs = (double)_pcm.length / sizeof(float) / _inRate;
            if (secs >= 5.0 && !_inFlight) {
                NSData *chunk = [_pcm copy];
                [_pcm setLength:0];
                [self processChunk:chunk];
            } else if (secs >= 8.0) {
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
    _inFlight = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
                // 1) 重采样到 16k（最近邻） + 量化 SInt16
                NSUInteger inCount = floatMono.length / sizeof(float);
                const float *in = (const float *)floatMono.bytes;
                double ratio = _inRate / 16000.0;
                NSUInteger outCount = (NSUInteger)(inCount / ratio);
                if (outCount < 160) { _inFlight = NO; return; }  // 太短
                NSMutableData *pcm16 = [NSMutableData dataWithCapacity:outCount * 2];
                SInt16 *out = (SInt16 *)malloc(outCount * 2);
                if (!out) { _inFlight = NO; return; }
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

                // 2) WAV 头（16bit mono 16k）
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

                // 3) base64 + 请求
                NSString *b64 = [wav base64EncodedStringWithOptions:0];
                NSString *secretId = [[LCConfig shared] tencentSecretId];
                NSString *secretKey = [[LCConfig shared] tencentSecretKey];
                if (secretId.length == 0 || secretKey.length == 0) {
                    LCLog("asr: tencent keys missing");
                    _inFlight = NO;
                    return;
                }
                // 识别语言映射
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
                    @"VoiceFormat": @"wav",
                    @"UsrAudioKey": [NSString stringWithFormat:@"livecap-%@", [[NSUUID UUID] UUIDString]],
                    @"Data": b64,
                    @"DataLen": @(wav.length),
                    @"FilterDirty": @0,
                    @"FilterModal": @0,
                    @"FilterPunc": @1
                };
                NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
                if (!payload) { _inFlight = NO; return; }

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
                [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
                [req setValue:host forHTTPHeaderField:@"Host"];
                [req setValue:@"SentenceRecognition" forHTTPHeaderField:@"X-TC-Action"];
                [req setValue:@"2019-06-14" forHTTPHeaderField:@"X-TC-Version"];
                [req setValue:tsStr forHTTPHeaderField:@"X-TC-Timestamp"];
                [req setValue:auth forHTTPHeaderField:@"Authorization"];
                req.HTTPBody = payload;
                req.timeoutInterval = 10.0;

                LCLogF(@"asr: sending %lu bytes (%@)", (unsigned long)wav.length, eng);
                NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    _inFlight = NO;
                    if (err) {
                        LCLogF(@"asr: req err %@", err);
                        return;
                    }
                    NSError *__autoreleasing pe = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
                    if (pe || !json) { LCLogF(@"asr: parse err %@", pe); return; }
                    NSDictionary *respD = json[@"Response"];
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
                        [[LCSubtitleOverlay shared] showOriginal:text translation:nil];
                        [[LCTranslator shared] translate:text
                            completion:^(NSString *tr) {
                                if (tr.length) [[LCSubtitleOverlay shared] showOriginal:text translation:tr];
                            }];
                    });
                }];
                [task resume];
            } @catch (NSException *e) {
                _inFlight = NO;
                LCLogF(@"asr: process err %@", e);
            }
        }
    });
}

- (void)stop {
    _running = NO;
    _inFlight = NO;
    [_pcm setLength:0];
}

@end

#pragma mark - 悬浮字幕

@interface LCSubtitleOverlay : NSObject
+ (instancetype)shared;
- (void)install;
- (void)showOriginal:(NSString *)origin translation:(NSString *)translation;
- (void)hide;
@end

@implementation LCSubtitleOverlay {
    UIView *_container;
    UIVisualEffectView *_blurView;
    UILabel *_originLabel;
    UILabel *_transLabel;
    BOOL _installed;
    BOOL _dragging;
    CGPoint _dragStartCenter;
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
        UIWindow *keyWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (!keyWindow) { LCLog("overlay: no keyWindow"); return; }
        UIView *parent = keyWindow.rootViewController.view;
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
        container.userInteractionEnabled = YES;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePan:)];
        [container addGestureRecognizer:pan];

        [parent addSubview:container];
        _container = container;
        _installed = YES;
        LCLog("overlay: installed");
    } @catch (NSException *e) {
        LCLog("overlay: install error");
        _container = nil;
        _installed = NO;
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!_container) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        _dragStartCenter = _container.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (!_dragging) return;
        CGPoint t = [g translationInView:_container.superview];
        _container.center = CGPointMake(_dragStartCenter.x + t.x, _dragStartCenter.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        _dragging = NO;
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

- (void)showOriginal:(NSString *)origin translation:(NSString *)translation {
    if (!_container || !_installed) return;
    @try {
        if (origin.length == 0 && translation.length == 0) return;
        UIColor *tc = [[LCConfig shared] textColor];
        _originLabel.attributedText = LCStrokedText(origin, tc, _originLabel.font);
        _transLabel.attributedText = LCStrokedText(translation, tc, _transLabel.font);

        CGFloat fs = [LCConfig shared].fontSize;
        CGFloat margin = 16;
        CGFloat maxW = [UIScreen mainScreen].bounds.size.width - margin * 2;

        // 完整测量两段文本高度（不截断，文本多长框多高）
        CGFloat oh = 0, th = 0;
        if (origin.length) {
            oh = [origin boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{NSFontAttributeName:_originLabel.font} context:nil].size.height;
        }
        if (translation.length) {
            th = [translation boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{NSFontAttributeName:_transLabel.font} context:nil].size.height;
        }

        CGFloat pad = 10;
        CGFloat w = maxW + pad * 2;
        CGFloat h = pad * 2 + oh + th + (origin.length && translation.length ? 4 : 0);
        if (h < fs + pad * 2) h = fs + pad * 2;

        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        // 安全上限：极端长文本时最多占 45% 屏高，防止霸屏
        h = MIN(h, sh * 0.45);
        [self applyBackgroundStyle:CGSizeMake(w, h)];

        // 按当前 App 记忆的位置（0-1 百分比）定位
        CGFloat mx = [[LCConfig shared] manualX];
        CGFloat my = [[LCConfig shared] manualY];
        CGFloat spanX = MAX(sw - w, 1);
        CGFloat spanY = MAX(sh - h, 1);
        CGFloat x = mx * spanX;
        CGFloat y = my * spanY;
        _container.frame = CGRectMake(x, y, w, h);
        CGFloat ly = pad;
        if (origin.length) {
            _originLabel.frame = CGRectMake(pad, ly, maxW, oh);
            ly += oh + 4;
        }
        if (translation.length) {
            _transLabel.frame = CGRectMake(pad, ly, maxW, th);
        }
        _container.hidden = NO;
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
    }
}

- (void)hide {
    _container.hidden = YES;
}

// 快速开关提示（复用字幕条，2 秒后自动消失）
- (void)showToast:(NSString *)text {
    if (!_container || !_installed) return;
    @try {
        _originLabel.attributedText = LCStrokedText(text, [[LCConfig shared] textColor], _originLabel.font);
        _transLabel.attributedText = nil;
        CGFloat fs = [LCConfig shared].fontSize;
        CGFloat margin = 24;
        CGFloat maxW = [UIScreen mainScreen].bounds.size.width - margin * 2;
        CGFloat oh = [text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin
            attributes:@{NSFontAttributeName:_originLabel.font} context:nil].size.height;
        CGFloat pad = 10;
        CGFloat w = maxW + pad * 2;
        CGFloat h = pad * 2 + oh;
        [self applyBackgroundStyle:CGSizeMake(w, h)];
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        UIEdgeInsets insets = UIEdgeInsetsZero;
        if (@available(iOS 11.0, *)) {
            insets = [UIApplication sharedApplication].keyWindow.safeAreaInsets;
        }
        _container.frame = CGRectMake((sw - w) / 2, sh - insets.bottom - h - 120, w, h);
        _originLabel.frame = CGRectMake(pad, pad, maxW, oh);
        _container.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            _container.hidden = YES;
            _originLabel.attributedText = nil;
            _transLabel.attributedText = nil;
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
                LCLogF(@"speech: final [%@]", self->_pendingFinal);
                [[LCSubtitleOverlay shared] showOriginal:self->_pendingFinal translation:nil];
                // 合并开关：翻译跟随总开关
                [[LCTranslator shared] translate:self->_pendingFinal
                    completion:^(NSString *tr) {
                        if (tr.length) [[LCSubtitleOverlay shared] showOriginal:self->_pendingFinal translation:tr];
                    }];
            }
        } else {
            if (text.length == 0) return;
            // partial 节流：1.0s 内不重复刷
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - self->_lastPartialAt < 1.0) return;
            self->_lastPartialAt = now;
            [[LCSubtitleOverlay shared] showOriginal:text translation:nil];
            // 合并开关：翻译跟随总开关
            [[LCTranslator shared] translate:text
                completion:^(NSString *tr) {
                    if (tr.length) [[LCSubtitleOverlay shared] showOriginal:text translation:tr];
                }];
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

static void LCAttachTapToItem(AVPlayerItem *item) {
    if (!item) return;
    @try {
        // 不检查 item.audioMix：目标 App（如 YouTube）可能已设自己的 audioMix
        // （音效/均衡），旧代码因此跳过挂载 tap → 音频抓不到。直接强制挂我们的 tap。
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParameters];
        // 栈上构造 callbacks（16 字节自然对齐，规避 arm64e 链接器对全局字面量指针重定位的检查；
        // MTAudioProcessingTapCreate 会拷贝该结构）
        MTAudioProcessingTapCallbacks callbacks = {0};
        callbacks.version = 0;
        callbacks.init = LCTapInit;
        callbacks.finalize = LCTapFinalize;
        callbacks.prepare = LCTapPrepare;
        callbacks.process = LCTapProcess;
        callbacks.clientInfo = (__bridge void *)[LCSpeech shared];  // 音频数据经 storage 送识别器
        MTAudioProcessingTapRef tap = NULL;
        OSStatus st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                 kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
        if (st != noErr || !tap) {
            LCLogF(@"tap: create failed st=%d", (int)st);
            return;
        }
        params.audioTapProcessor = tap;
        mix.inputParameters = @[params];
        item.audioMix = mix;
        LCLogF(@"tap: attached to item %p (forced)", item);
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
        Method mi = class_getInstanceMethod([AVPlayerItem class],
                                            @selector(initWithAsset:automaticallyLoadedAssetKeys:));
        if (mi) {
            orig_itemInitAssetKeys = (void *)method_getImplementation(mi);
            method_setImplementation(mi, (IMP)LC_itemInitAssetKeys);
            LCLog("hook: item init OK");
        }
        Method ma = class_getInstanceMethod([AVPlayerItem class], @selector(setAudioMix:));
        if (ma) {
            orig_setAudioMix = (void *)method_getImplementation(ma);
            method_setImplementation(ma, (IMP)LC_setAudioMix);
            LCLog("hook: setAudioMix OK");
        }
    } @catch (NSException *e) {
        LCLogF(@"hook: error %@", e);
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
    [d writeToFile:path atomically:YES];
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
    const char *exe = getprogname();
    if (!exe) return;
    char m[256];
    snprintf(m, sizeof(m), "ctor: prog=%s", exe);
    LCLog(m);

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
