// LiveCapPrefs.m - 设置面板入口（纯 specifiers，无需自定义逻辑）
// Rebuild marker: 1.0.3 重新触发编译
// iOS 26 SDK 不再公开 Preferences 头文件，私有类声明见 LCPrivate.h
// 注意：不可用 _specifiers 作缓存 ivar（与父类 PSListController 同名 ivar 冲突会导致 specifiers
// 内存错位、部分行不渲染），改用自定义名 _lcSpecifiers。
#import "LCPrivate.h"
#import <stdio.h>
#import <unistd.h>

static void PLog(const char *msg) {
    int fd = open("/var/mobile/Documents/livecap_prefs.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
    }
}

static void PLogF(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    PLog([s UTF8String]);
}

@interface LiveCapPrefsListController : PSListController {
    NSArray *_lcSpecifiers;
}
@end

@implementation LiveCapPrefsListController

+ (void)load {
    PLog("prefs: class LiveCapPrefsListController loaded");
}

- (instancetype)init {
    self = [super init];
    if (self) PLog("prefs: init called");
    return self;
}

- (NSArray *)specifiers {
    if (!_lcSpecifiers) {
        PLog("prefs: loadSpecifiersFromPlistName Root start");
        _lcSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        PLogF(@"prefs: specifiers loaded count=%lu", (unsigned long)_lcSpecifiers.count);
        if (_lcSpecifiers.count > 0) {
            for (id spec in _lcSpecifiers) {
                @try {
                    PLogF(@"prefs:   item %@", [spec description]);
                } @catch (NSException *e) {
                    PLog("prefs:   item (description error)");
                }
            }
        }
    }
    return _lcSpecifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    PLog("prefs: viewDidLoad");
    self.title = @"实时字幕翻译";
}

@end
