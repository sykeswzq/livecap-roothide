// LiveCap.m — roothide 实时视频字幕翻译 tweak (iOS 15-16, arm64e) v1.0.46
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
#import "fishhook.h"

// TC3 签名函数前置声明（定义在腾讯云 ASR 区，翻译区先调用）
static NSString *LCTencentAuthHeaderEx(NSString *secretId, NSString *secretKey,
                                       NSString *timestamp, NSString *date,
                                       NSData *payload, NSString *host,
                                       NSString *service, NSString *action);
static NSString *LCTencentAuthHeader(NSString *secretId, NSString *secretKey,
                                     NSString *timestamp, NSString *date,
                                     NSData *payload, NSString *host);

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

        // 0) OpenAI 兼容接口（agnes AI）：用户已配 apiKey + apiBase，优先级最高
        NSString *openaiKey = [[LCConfig shared] apiKey];
        NSString *openaiBase = [[LCConfig shared] apiBase];
        if (openaiKey.length && openaiBase.length) {
            LCLogF(@"translate: using OpenAI-compatible (agnes) keyLen=%lu base=%@ model=%@",
                   (unsigned long)openaiKey.length, openaiBase, [LCConfig shared].model);
            [self openaiTranslate:trimmed sysPrompt:sysPrompt cacheKey:cacheKey
                           apiKey:openaiKey apiBase:openaiBase
                             model:[LCConfig shared].model completion:completion];
            return;
        }
        // 1) 腾讯云机器翻译（用户已配 SecretId/Key，免费 500 万字符/月；未开通时返回错误则跳过）
        NSString *secretId = [[LCConfig shared] tencentSecretId];
        NSString *secretKey = [[LCConfig shared] tencentSecretKey];
        LCLogF(@"translate: start text=[%@] target=%@ hasSecret=%d", trimmed, target, (int)(secretId.length && secretKey.length));

        if (secretId.length && secretKey.length) {
            [self tencentTranslate:trimmed systemPrompt:sysPrompt cacheKey:cacheKey
                          secretId:secretId secretKey:secretKey
                        completion:completion];
            return;
        }
        // 2) MyMemory 免费翻译兜底（无需开通/密钥，立即可用）
        LCLogF(@"translate: using MyMemory fallback src=%@ dst=%@", [LCConfig shared].sourceLang, target);
        [self mymemoryTranslate:trimmed targetLang:target cacheKey:cacheKey completion:completion];
    });
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
    NSString *urlStr = [NSString stringWithFormat:
        @"https://api.mymemory.translated.net/get?q=%@&langpair=%@|%@",
        [text stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]],
        src, dst];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.timeoutInterval = 12.0;
    LCLogF(@"translate: mymemory request url=%@", urlStr);
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskErr) {
        if (taskErr) {
            LCLogF(@"translate: mymemory req err %@ url=%@", taskErr, urlStr);
            return;
        }
        NSError *__autoreleasing pe = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
        if (pe || !json) {
            LCLogF(@"translate: mymemory parse err %@ data len=%lu", pe, (unsigned long)data.length);
            return;
        }
        NSDictionary *rd = json[@"responseData"];
        NSString *content = rd[@"translatedText"];
        LCLogF(@"translate: mymemory response status=%@ content=[%@]", json[@"responseStatus"], content);
        if (![content isKindOfClass:[NSString class]] || content.length == 0) return;
        // 空查询/警告时不当作结果
        if ([content hasPrefix:@"NO QUERY SPECIFIED"] || [content hasPrefix:@"MY MEMORY WARNING"]) return;
        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        _cache[cacheKey] = result;
        if (_cache.count > 300) [_cache removeAllObjects];
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
    if (err || !payload) { LCLogF(@"translate: tencent json err %@", err); return; }

    long long ts = (long long)[[NSDate date] timeIntervalSince1970];
    NSString *tsStr = [NSString stringWithFormat:@"%lld", ts];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd"];
    [df setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
    NSString *dateStr = [df stringFromDate:[NSDate date]];

    NSString *host = @"tmt.tencentcloudapi.com";
    NSString *auth = LCTencentAuthHeaderEx(secretId, secretKey, tsStr, dateStr, payload, host,
                                           @"tmt", @"texttranslate");

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://tmt.tencentcloudapi.com"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
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
            return;
        }
        NSError *__autoreleasing parseErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr || !json) { LCLogF(@"translate: tencent parse err %@", parseErr); return; }
        NSDictionary *respD = json[@"Response"];
        if (respD[@"Error"]) {
            LCLogF(@"translate: tencent api err %@", respD[@"Error"]);
            return;
        }
        NSString *content = respD[@"TargetText"];
        if (![content isKindOfClass:[NSString class]] || content.length == 0) {
            LCLogF(@"translate: tencent empty target (%@)", json);
            return;
        }
        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        _cache[cacheKey] = result;
        if (_cache.count > 300) [_cache removeAllObjects];
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
                  model:(NSString *)model
             completion:(void (^)(NSString *result))completion {
    if (text.length > 1800) text = [text substringToIndex:1800];
    NSString *trimmedModel = model.length ? model : @"agnes-2.5-flash";
    NSDictionary *body = @{
        @"model": trimmedModel,
        @"messages": @[
            @{@"role": @"system", @"content": sysPrompt},
            @{@"role": @"user",   @"content": text}
        ],
        @"temperature": @0.1,
        @"max_tokens": @200
    };
    NSError *__autoreleasing err = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err || !payload) { LCLogF(@"translate: openai json err %@", err); return; }

    // 拼接 API URL（可能以 / 结尾）
    NSString *chatUrl = [apiBase hasSuffix:@"/"] ? [apiBase stringByAppendingString:@"chat/completions"]
                                                 : [apiBase stringByAppendingString:@"/chat/completions"];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:chatUrl]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = payload;
    req.timeoutInterval = 15.0;

    LCLogF(@"translate: openai request url=%@ model=%@", chatUrl, trimmedModel);
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskErr) {
        if (taskErr) {
            LCLogF(@"translate: openai req err %@ url=%@", taskErr, chatUrl);
            return;
        }
        NSError *__autoreleasing pe = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
        if (pe || !json) {
            LCLogF(@"translate: openai parse err %@ data len=%lu", pe, (unsigned long)data.length);
            return;
        }
        // 解析响应
        NSArray *choices = json[@"choices"];
        if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) {
            LCLogF(@"translate: openai no choices (%@)", json);
            return;
        }
        NSDictionary *firstChoice = choices[0];
        NSDictionary *msg = firstChoice[@"message"];
        NSString *content = msg[@"content"];
        if (![content isKindOfClass:[NSString class]] || content.length == 0) {
            LCLogF(@"translate: openai empty content (%@)", json);
            return;
        }
        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        LCLogF(@"translate: openai response len=%lu text=[%@]", (unsigned long)result.length, result);
        _cache[cacheKey] = result;
        if (_cache.count > 300) [_cache removeAllObjects];
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
                                       NSString *service, NSString *action) {
    // CanonicalRequest（action 转小写进签名，与实际 header 大小写无关）
    NSString *hashedPayload = LCDataToHex(LCSHA256(payload));
    NSString *canonicalHeaders = [NSString stringWithFormat:
        @"content-type:application/json; charset=utf-8\nhost:%@\nx-tc-action:%@\n", host, action];
    NSString *signedHeaders = @"content-type;host;x-tc-action";
    NSString *canonicalRequest = [NSString stringWithFormat:
        @"POST\n/\n\n%@\n%@\n%@",
        canonicalHeaders, signedHeaders, hashedPayload];

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
                                 @"asr", @"sentencerecognition");
}

// tap 输入格式（LCTapPrepare 记录，供 PCM 转换 / SFSpeech 缓冲）
static AudioStreamBasicDescription gProcessingFormat;
static BOOL gProcessingFormatValid = NO;

@interface LCSubtitleOverlay : NSObject
+ (instancetype)shared;
- (void)install;
- (void)showOriginal:(NSString *)origin translation:(NSString *)translation;
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
    BOOL _inFlight;               // 上一次请求未返回时跳过本段
    NSURLSession *_session;
}

+ (instancetype)shared {
    static LCHttpASR *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[LCHttpASR alloc] init];
        s->_pcm = [NSMutableData data];
        s->_pcm16 = [NSMutableData data];
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
        double secs = (double)_pcm.length / sizeof(float) / _inRate;
        if (secs >= 5.0 && !_inFlight) {
            NSData *chunk = [_pcm copy];
            [_pcm setLength:0];
            [self processChunk:chunk];
        } else if (secs >= 8.0) {
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
        if (_pcm16.length >= 16000 * 2 * 5 && !_inFlight) {
            NSData *chunk = [_pcm16 copy];
            [_pcm16 setLength:0];
            [self processChunk16:chunk];
        } else if (_pcm16.length >= 16000 * 2 * 8) {
            [_pcm16 setLength:0];
        }
    }
}

- (void)processChunk16:(NSData *)pcm16 {
    if (!pcm16 || pcm16.length < 1600) return;
    _inFlight = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
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

                NSString *b64 = [wav base64EncodedStringWithOptions:0];
                NSString *secretId = [[LCConfig shared] tencentSecretId];
                NSString *secretKey = [[LCConfig shared] tencentSecretKey];
                if (secretId.length == 0 || secretKey.length == 0) {
                    LCLog("asr16: tencent keys missing");
                    _inFlight = NO;
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

                LCLogF(@"asr16: sending %lu bytes (%@)", (unsigned long)wav.length, eng);
                NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    _inFlight = NO;
                    if (err) { LCLogF(@"asr16: req err %@", err); return; }
                    NSError *__autoreleasing pe = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
                    if (pe || !json) { LCLogF(@"asr16: parse err %@", pe); return; }
                    NSDictionary *respD = json[@"Response"];
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
                LCLogF(@"speech: final [%@] -> sending for translation", self->_pendingFinal);
                [[LCSubtitleOverlay shared] showOriginal:self->_pendingFinal translation:nil];
                // 合并开关：翻译跟随总开关
                [[LCTranslator shared] translate:self->_pendingFinal
                    completion:^(NSString *tr) {
                        LCLogF(@"speech: translation result len=%lu text=[%@]", (unsigned long)tr.length, tr);
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

// AAC 解码输入回调（AudioConverterFillComplexBuffer，带 packet 描述）
typedef struct {
    uint8_t *data;
    size_t len;
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
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = in->data + in->descs[in->idx].mStartOffset;
    ioData->mBuffers[0].mDataByteSize = in->descs[in->idx].mDataByteSize;
    if (outPacketDesc) *outPacketDesc = &in->descs[in->idx];
    *numPackets = n;
    in->idx += n;
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
    LCLogF(@"asbr: got buffer sr=%u ch=%u fmt=0x%x (%s) frames=%lld",
           (unsigned)asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
           (unsigned)asbd.mFormatID,
           asbd.mFormatID == kAudioFormatLinearPCM ? "LPCM" :
           asbd.mFormatID == 'aac ' ? "AAC" :
           asbd.mFormatID == 'mp4a' ? "MP4A" : "other",
           (long long)CMSampleBufferGetNumSamples(sbuf));
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

    LCLogF(@"audio: dec in sr=%.0f fmt=0x%08x ch=%u fpp=%u len=%zu",
           inASBD2.mSampleRate, (unsigned)inASBD2.mFormatID,
           (unsigned)inASBD2.mChannelsPerFrame, (unsigned)inASBD2.mFramesPerPacket, dataLen);

    // 打印数据头部，判断封装格式
    {
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

    // 尝试获取 magic cookie
    CMFormatDescriptionRef fmtD = CMSampleBufferGetFormatDescription(sbuf);
    if (fmtD) {
        CFTypeRef cookieRef = CMFormatDescriptionGetExtension(fmtD, CFSTR("MagicCookie"));
        if (cookieRef && CFGetTypeID(cookieRef) == CFDataGetTypeID()) {
            CFDataRef cookieData = (CFDataRef)cookieRef;
            if (CFDataGetLength(cookieData) > 0) {
                AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                          (UInt32)CFDataGetLength(cookieData),
                                          CFDataGetBytePtr(cookieData));
                LCLogF(@"audio: dec cookie %ldB", (long)CFDataGetLength(cookieData));
            }
        }
    }

    // 构建 packet 描述：YouTube 数据通常是一个大 packet
    // 尝试从 CMSampleBuffer 获取 packet 描述
    AudioStreamPacketDescription *descs = NULL;
    UInt32 descCount = 0;
    CMItemCount dCnt = 0;
    st = CMSampleBufferGetAudioStreamPacketDescriptions(sbuf, 0, NULL, &dCnt);
    if (st == noErr && dCnt > 0) {
        descs = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * (size_t)dCnt);
        if (descs) {
            st = CMSampleBufferGetAudioStreamPacketDescriptions(sbuf, dCnt, descs, &dCnt);
            if (st == noErr) descCount = (UInt32)dCnt;
            else { free(descs); descs = NULL; }
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
    LCLogF(@"audio: dec pkts=%u", (unsigned)descCount);

    // 计算输出缓冲大小
    CMItemCount totalSamples = CMSampleBufferGetNumSamples(sbuf);
    if (totalSamples <= 0) {
        // 估算：假设每 packet 1024 帧
        totalSamples = (CMItemCount)descCount * 1024;
    }
    UInt32 maxOut = 4096;
    UInt32 propSz = sizeof(maxOut);
    AudioConverterGetProperty(conv, kAudioConverterPropertyMaximumOutputPacketSize, &propSz, &maxOut);
    UInt32 outCapacity = (UInt32)(totalSamples * outASBD.mBytesPerFrame + maxOut * 8);
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
    LCConvInput in = { (uint8_t *)dataPtr, dataLen, descs, descCount, 0 };
    UInt32 outNumPackets = (UInt32)(outCapacity / outASBD.mBytesPerFrame);
    if (outNumPackets > 16384) outNumPackets = 16384;
    if (outNumPackets < 1) outNumPackets = 1;

    st = AudioConverterFillComplexBuffer(conv, LCInputProc, &in, &outNumPackets, &outList, NULL);
    AudioConverterDispose(conv);
    free(descs);

    if (st != noErr) {
        LCLogF(@"audio: decode fill err %d (0x%08x)", (int)st, (unsigned)st);
        free(outData);
        return;
    }

    UInt32 producedFrames = outList.mBuffers[0].mDataByteSize / outASBD.mBytesPerFrame;
    if (producedFrames == 0 || producedFrames > 262144) {
        free(outData);
        return;
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
    LCLogF(@"audio: decoded %u frames", (unsigned)producedFrames);
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
    const char *diag_path = "/var/mobile/Documents/livecap_ctor.log";
    FILE *df = fopen(diag_path, "a");
    if (df) {
        fprintf(df, "=== LCInit ctor called at %ld ===\n", (long)time(NULL));
        fflush(df);
        fclose(df);
    }

    const char *exe = getprogname();
    if (!exe) return;
    char m[256];
    snprintf(m, sizeof(m), "ctor: prog=%s", exe);
    LCLog(m);

    // 系统音频守护进程：先纯 C 写文件验证注入+可写路径，再延迟 2s 启用音频 tap。
    // 注意：绝不能在构造器内同步 rebind_symbols —— dlopen 早期 dyld image 列表未就绪会段错误（已实测 -11 崩溃）。
    if (strcmp(exe, "mediaserverd") == 0) {
        // 探测可写路径（纯 C，不依赖 ObjC）：/var/log → /var/mobile/Documents → /tmp → /var/jb 系列
        const char *mpaths[] = { "/var/log/livecap_media.log",
                                 "/var/mobile/Documents/livecap_media.log",
                                 "/tmp/livecap_media.log",
                                 "/var/jb/var/log/livecap_media.log",
                                 "/var/jb/tmp/livecap_media.log",
                                 "/var/mobile/Library/Preferences/livecap_media.log",
                                 NULL };
        for (int mi = 0; mpaths[mi]; mi++) {
            FILE *mf = fopen(mpaths[mi], "a");
            if (mf) {
                fprintf(mf, "=== LiveCap mediaserverd tap (1.0.28) ===\n");
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
