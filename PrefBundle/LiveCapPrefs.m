// LiveCapPrefs.m - 设置面板入口（纯 specifiers，无需自定义逻辑）
#import <Preferences/PSListController.h>

@interface LiveCapPrefsListController : PSListController
@end

@implementation LiveCapPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"实时字幕翻译";
}

@end
