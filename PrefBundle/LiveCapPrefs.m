// LiveCapPrefs.m - 设置面板入口（纯 specifiers，无需自定义逻辑）
// iOS 26 SDK 不再公开 Preferences 头文件，私有类声明见 LCPrivate.h
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

@interface LiveCapPrefsListController : PSListController
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
    if (!_specifiers) {
        PLog("prefs: loadSpecifiersFromPlistName Root");
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        PLog("prefs: specifiers loaded");
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    PLog("prefs: viewDidLoad");
    self.title = @"实时字幕翻译";
}

@end

