// LiveCap.m — roothide 实时视频字幕翻译 tweak (iOS 15-16, arm64e)
// 原理：swizzle AVPlayer 拿到 AVPlayerItem，挂 MTAudioProcessingTap 抓 PCM
//      → 喂 SFSpeechRecognizer 实时转写
//      → 原文经 OpenAI 兼容接口翻译
//      → 悬浮双语字幕显示在 keyWindow.rootViewController.view（不新建 UIWindow）
// 依赖：AVFoundation / Speech / MediaToolbox / AudioToolbox
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <MediaToolbox/MTAudioProcessingTap.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#import <mach-o/dyld.h>

#pragma mark - 日志

static void LCLog(const char *msg) {
    NSLog(@"[LiveCap] %s", msg);
    int fd = open("/tmp/livecap.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
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
@property (readonly) CGFloat fontSize;
@property (readonly) BOOL boldText;
@property (readonly) UIColor *textColor;
@property (readonly) NSString *backgroundStyle;
@property (readonly) CGFloat manualX;
@property (readonly) CGFloat manualY;
- (void)saveManualX:(CGFloat)x y:(CGFloat)y;
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
    NSString *s = _d[@"sourceLang"];
    return (s && s.length) ? s : @"en-US";
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
    id p = [self manualPositions][self.bundleId];
    if ([p isKindOfClass:[NSDictionary class]]) {
        NSNumber *v = p[@"x"];
        if (v && [v doubleValue] >= 0 && [v doubleValue] <= 1) return [v doubleValue];
    }
    return 0.5;
}

- (CGFloat)manualY {
    id p = [self manualPositions][self.bundleId];
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
        NSError *err = nil;
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

#pragma mark - 语音识别（SFSpeech）

// tap 回调（C 函数）与 LCSpeech 共用的音频格式描述
static AudioStreamBasicDescription gProcessingFormat;

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
}

+ (instancetype)shared {
    static LCSpeech *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LCSpeech alloc] init]; s->_accum = [NSMutableString string]; });
    return s;
}

- (void)startWithFormat:(AudioStreamBasicDescription)asbd {
    if (_recording) return;
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:[LCConfig shared].sourceLang];
    SFSpeechRecognizer *rec = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!rec || !rec.isAvailable) {
        // 该 locale 不可用则退回 en-US
        rec = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
        if (!rec || !rec.isAvailable) {
            LCLog("speech: recognizer unavailable");
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
            LCLogF(@"speech: task error %@", error);
            self->_recording = NO;
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
    if (!_recording || !_request || frames == 0) return;
    if (![[LCConfig shared] enabled]) return;  // 合并开关关闭时忽略音频
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithStreamDescription:&gProcessingFormat];
    if (!fmt) return;
    AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
    pcm.frameLength = frames;
    BOOL interleaved = !(gProcessingFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    if (interleaved) {
        memcpy(pcm.floatChannelData[0], list->mBuffers[0].mData, list->mBuffers[0].mDataByteSize);
    } else {
        UInt32 nch = MIN(list->mNumberBuffers, fmt.channelCount);
        for (UInt32 i = 0; i < nch; i++) {
            memcpy(pcm.floatChannelData[i], list->mBuffers[i].mData, list->mBuffers[i].mDataByteSize);
        }
    }
    [_request appendAudioPCMBuffer:pcm];
}

- (void)stop {
    _recording = NO;
    if (_request) {
        [_request endAudio];
        _request = nil;
    }
    _recognizer = nil;
}

@end

#pragma mark - MTAudioProcessingTap 回调

static void LCTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    *tapStorageOut = clientInfo;
}

static void LCTapFinalize(MTAudioProcessingTapRef tap) {}

static void LCTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                         const AudioStreamBasicDescription *processingFormat) {
    // 记录格式供后续 PCM 转换
    void *client = MTAudioProcessingTapGetStorage(tap);
    if (!client) return;
    if (processingFormat) {
        memcpy(&gProcessingFormat, processingFormat, sizeof(AudioStreamBasicDescription));
    }
    LCSpeech *speech = (__bridge LCSpeech *)client;
    dispatch_async(dispatch_get_main_queue(), ^{
        [speech startWithFormat:gProcessingFormat];
    });
}

static void LCTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                         MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                         CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut,
                                                         NULL, numberFramesOut);
    if (status == noErr) {
        void *client = MTAudioProcessingTapGetStorage(tap);
        LCSpeech *speech = (__bridge LCSpeech *)client;
        if (speech) {
            [speech appendBufferList:bufferListInOut frames:(UInt32)*numberFramesOut];
        }
    }
}

#pragma mark - AVPlayer hook

static void LCAttachTapToItem(AVPlayerItem *item) {
    if (!item || item.audioMix != nil) return;
    @try {
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParameters];
        // 栈上构造 callbacks（16 字节自然对齐，规避 arm64e 链接器对全局字面量指针重定位的检查；
        // MTAudioProcessingTapCreate 会拷贝该结构）
        MTAudioProcessingTapCallbacks callbacks = {0};
        callbacks.version = 0;
        callbacks.init = LCTapInit;
        callbacks.prepare = LCTapPrepare;
        callbacks.process = LCTapProcess;
        callbacks.finalize = LCTapFinalize;
        callbacks.clientInfo = NULL;
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
        LCLog("tap: attached to item");
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
    } @catch (NSException *e) {
        LCLogF(@"hook: error %@", e);
    }
}

#pragma mark - 长按屏幕快速开关（在目标 App 内长按 0.8s 切换实时字幕翻译）

#pragma mark - 长按图标快捷开关（在目标 App 内通过主屏图标菜单切换）

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
        [[LCSpeech shared] startWithFormat:gProcessingFormat];
    } else {
        [[LCSpeech shared] stop];
        [[LCSubtitleOverlay shared] showToast:@"实时字幕翻译：已关闭"];
    }
}

#pragma mark - 桌面图标快捷菜单（长按已注入 App 图标 → 开关实时字幕翻译）

static BOOL LCShortcutInstalled = NO;

static void LCInstallShortcutItem(void) {
    if (LCShortcutInstalled) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        for (UIApplicationShortcutItem *it in app.shortcutItems) {
            if ([it.type isEqualToString:@"com.sykes.livecap.toggle"]) {
                LCShortcutInstalled = YES;
                return;
            }
        }
        UIApplicationShortcutItem *item = [[UIApplicationShortcutItem alloc]
            initWithType:@"com.sykes.livecap.toggle"
            localizedTitle:@"开关实时字幕翻译"
            localizedSubtitle:nil
            icon:[UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypePlay]
            userInfo:nil];
        NSMutableArray *items = [app.shortcutItems mutableCopy] ?: [NSMutableArray array];
        [items addObject:item];
        app.shortcutItems = items;
        LCShortcutInstalled = YES;
        LCLog("shortcut: installed");
    } @catch (NSException *e) {
        LCLogF(@"shortcut: error %@", e);
    }
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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LCLog("init: start");
        LCSwizzleAVPlayer();
        LCSwizzleShortcut();
        LCInstallShortcutItem();

        // SFSpeech 授权是跨 App 共享的：任一 App 授权过即全局可用。
        // iOS16 上目标 App 无 usage description 时 requestAuthorization 返回 denied（不崩溃）。
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
            switch (st) {
                case SFSpeechRecognizerAuthorizationStatusAuthorized:
                    LCLog("speech: authorized");
                    break;
                case SFSpeechRecognizerAuthorizationStatusDenied:
                    LCLog("speech: denied（若目标App无语音识别权限，请先在系统设置→隐私→语音识别 确认已授权）");
                    break;
                case SFSpeechRecognizerAuthorizationStatusRestricted:
                    LCLog("speech: restricted");
                    break;
                default:
                    LCLog("speech: notDetermined");
                    break;
            }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            if ([[LCConfig shared] enabled]) {
                [[LCSubtitleOverlay shared] install];
            }
        }];

        UIApplication *app = [UIApplication sharedApplication];
        if (app.applicationState == UIApplicationStateActive && [[LCConfig shared] enabled]) {
            LCLog("init: active, install overlay");
            [[LCSubtitleOverlay shared] install];
        }
    });
}
