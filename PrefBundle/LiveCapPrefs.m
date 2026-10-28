// LiveCapPrefs.m —— 设置面板主控制器（LCRootListController）
// 范式：完全对齐 XL-Roothide（XLRootListController）——
//   PSViewController + 手写 grouped UITableView，不用 specifiers / Root.plist。
// 配置读写：CFPreferences 显式指定 appID = com.sykes.livecap（与 tweak 读取的
//   /var/mobile/Library/Preferences/com.sykes.livecap.plist 同一份，面板在"设置"进程，
//   默认域会是 bundle id com.sykes.livecap.prefs，必须显式指定否则 tweak 读不到）。
#import <UIKit/UIKit.h>
#import "LCPrivate.h"

#pragma mark - 配置读写（com.sykes.livecap 域）

static NSString *LCAppID = @"com.sykes.livecap";

static id LCGet(NSString *key) {
    @try {
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)LCAppID));
        return v;
    } @catch (NSException *e) { return nil; }
}

static void LCSet(id value, NSString *key) {
    @try {
        if (value == nil) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                                      (__bridge CFStringRef)LCAppID);
        } else {
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     (__bridge CFPropertyListRef)value,
                                     (__bridge CFStringRef)LCAppID);
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)LCAppID);
    } @catch (NSException *e) {}
}

static NSString *LCStr(NSString *key, NSString *fallback) {
    id v = LCGet(key);
    return ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0)
        ? (NSString *)v : fallback;
}

#pragma mark - 主控制器

@interface LCRootListController : PSViewController
    <UITableViewDataSource, UITableViewDelegate, UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) NSString *colorKey;
@end

@implementation LCRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"实时字幕翻译";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    if (!(self.navigationController && self.navigationController.viewControllers.count > 1)) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(lc_done)];
    }

    CGRect b = self.view.bounds;
    if (b.size.width <= 0) b = CGRectMake(0, 0, 375, 667);
    UITableView *tv = [[UITableView alloc] initWithFrame:b style:UITableViewStyleGrouped];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.dataSource = self;
    tv.delegate = self;
    tv.tag = 100;
    [self.view addSubview:tv];
}

- (instancetype)initForContentSize:(CGSize)size { return [self init]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.lc_tv reloadData];
}

- (void)lc_done {
    @try {
        if (self.navigationController && self.navigationController.viewControllers.count > 1)
            [self.navigationController popViewControllerAnimated:YES];
        else
            [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *e) {}
}

- (UITableView *)lc_tv { return (UITableView *)[self.view viewWithTag:100]; }

#pragma mark - 展示值

- (NSString *)lc_sourceLangTitle {
    NSString *v = LCStr(@"sourceLang", @"en-US");
    if ([v isEqualToString:@"en-US"]) return @"英语";
    if ([v isEqualToString:@"ja-JP"]) return @"日语";
    if ([v isEqualToString:@"ko-KR"]) return @"韩语";
    if ([v isEqualToString:@"zh-CN"]) return @"中文";
    return v;
}

- (NSString *)lc_targetLangTitle {
    NSString *v = LCStr(@"targetLang", @"zh-Hans");
    if ([v isEqualToString:@"zh-Hans"]) return @"简体中文";
    if ([v isEqualToString:@"zh-Hant"]) return @"繁体中文";
    if ([v isEqualToString:@"en"]) return @"英语";
    return v;
}

- (NSString *)lc_bgStyleTitle {
    NSString *v = LCStr(@"backgroundStyle", @"frost");
    if ([v isEqualToString:@"none"]) return @"无背景描边";
    if ([v isEqualToString:@"darktrans"]) return @"半透明黑";
    if ([v isEqualToString:@"darksolid"]) return @"实黑";
    if ([v isEqualToString:@"lighttrans"]) return @"半透明白";
    return @"毛玻璃";
}

- (NSString *)lc_colorTitle {
    NSString *hex = LCStr(@"textColorHex", @"#FFFFFFFF");
    if ([hex caseInsensitiveCompare:@"#FFFFFFFF"] == NSOrderedSame ||
        [hex caseInsensitiveCompare:@"#FFFFFF"] == NSOrderedSame) return @"白色（默认）";
    return hex;
}

- (NSString *)lc_apiKeyTitle {
    NSString *k = LCStr(@"apiKey", @"");
    return (k.length == 0) ? @"未设置" : @"已设置";
}

- (NSString *)lc_tencentSecretTitle {
    NSString *k = LCStr(@"tencentSecretId", @"");
    return (k.length == 0) ? @"未设置" : @"已设置";
}

- (NSString *)lc_tencentSecretKeyTitle {
    NSString *k = LCStr(@"tencentSecretKey", @"");
    return (k.length == 0) ? @"未设置" : @"已设置";
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4; // 0 基本 / 1 翻译 API / 2 字幕显示 / 3 说明
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"基本";
    if (section == 1) return @"腾讯云语音识别（在线）";
    if (section == 2) return @"字幕显示";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"识别语言会按 App 记忆（例如 A 软件英语、B 软件日语），也可长按桌面 App 图标快捷切换。";
    if (section == 1)
        return @"在线语音识别无需 iOS 授权，任何 App 通用。腾讯云一句话识别每月免费 5000 次，密钥在控制台→访问管理→API 密钥管理获取。翻译使用内置 AI 服务。";
    if (section == 2)
        return @"字幕可长按拖动，位置按 App 记忆（重开 App 回到上次位置）。背景样式：无背景描边 / 半透明黑 / 实黑 / 半透明白 / 毛玻璃。";
    if (section == 3)
        return @"目标 App 需在 Dopamine Inject Manager 白名单勾选；完全退出目标 App 再打开生效。长按桌面 App 图标可快捷开关实时字幕翻译。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4;
    if (section == 1) return 2;  // 腾讯云 SecretId / SecretKey
    if (section == 2) return 4;
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const ID = @"LCRootCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:ID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"实时字幕翻译";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [(NSNumber *)LCGet(@"enabled") boolValue];
            [sw addTarget:self action:@selector(lc_enabledChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"注入目标 App";
            id apps = LCGet(@"injectApps");
            long n = [apps isKindOfClass:[NSArray class]] ? (long)((NSArray *)apps).count : 0;
            cell.detailTextLabel.text = (n > 0) ? [NSString stringWithFormat:@"已选 %ld 个", n] : nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"识别语言（按 App 记忆）";
            cell.detailTextLabel.text = [self lc_sourceLangTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"翻译成";
            cell.detailTextLabel.text = [self lc_targetLangTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"SecretId";
            cell.detailTextLabel.text = [self lc_tencentSecretTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"SecretKey";
            cell.detailTextLabel.text = [self lc_tencentSecretKeyTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"字号";
            CGFloat fs = [(NSNumber *)LCGet(@"fontSize") doubleValue];
            if (fs < 10) fs = 28;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", fs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"粗体";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [(NSNumber *)LCGet(@"boldText") boolValue];
            [sw addTarget:self action:@selector(lc_boldChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"文字颜色";
            cell.detailTextLabel.text = [self lc_colorTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"背景样式";
            cell.detailTextLabel.text = [self lc_bgStyleTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0 && indexPath.row == 1) {
        @try {
            Class cls = NSClassFromString(@"LiveCapAppListController");
            UIViewController *appList = [cls new];
            if (self.navigationController)
                [self.navigationController pushViewController:appList animated:YES];
            else {
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:appList];
                [self presentViewController:nav animated:YES completion:nil];
            }
        } @catch (NSException *e) {}
    }
    else if (indexPath.section == 0 && indexPath.row == 2) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"识别语言"
                                                                       message:@"默认值；可按 App 记忆，长按图标可快速切换"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *items = @[@"英语 en-US", @"日语 ja-JP", @"韩语 ko-KR", @"中文 zh-CN"];
        for (NSString *s in items) {
            [alert addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                NSString *code = [s componentsSeparatedByString:@" "].lastObject;
                LCSet(code, @"sourceLang");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 0 && indexPath.row == 3) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"翻译成"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *items = @[@"简体中文 zh-Hans", @"繁体中文 zh-Hant", @"英语 en"];
        for (NSString *s in items) {
            [alert addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                LCSet([s componentsSeparatedByString:@" "].lastObject, @"targetLang");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 1) {
        NSString *key = nil, *title = nil, *cur = nil, *ph = nil;
        BOOL secure = NO;
        if (indexPath.row == 0) { key = @"tencentSecretId"; title = @"SecretId"; cur = LCStr(key, @""); ph = @"AKID..."; }
        else { key = @"tencentSecretKey"; title = @"SecretKey"; cur = LCStr(key, @""); ph = @"腾讯云 API 密钥管理"; secure = YES; }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = cur;
            tf.placeholder = ph;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.secureTextEntry = secure;
            if (!secure) tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *v = alert.textFields.firstObject.text;
            if (v == nil) v = @"";
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            LCSet((v.length > 0) ? v : nil, key);
            [self.lc_tv reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 2 && indexPath.row == 0) {
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
    }
    else if (indexPath.section == 2 && indexPath.row == 2) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文字颜色"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:@"白色（默认）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            LCSet(@"#FFFFFFFF", @"textColorHex");
            [self.lc_tv reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"自定义颜色" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.colorKey = @"textColorHex";
            UIColorPickerViewController *p = [[UIColorPickerViewController alloc] init];
            p.delegate = self;
            p.selectedColor = [self lc_colorFromHex:LCStr(@"textColorHex", @"#FFFFFFFF")] ?: [UIColor whiteColor];
            [self presentViewController:p animated:YES completion:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 2 && indexPath.row == 3) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"背景样式"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *items = @[@"无背景描边 none", @"半透明黑 darktrans", @"实黑 darksolid",
                           @"半透明白 lighttrans", @"毛玻璃 frost"];
        for (NSString *s in items) {
            [alert addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                LCSet([s componentsSeparatedByString:@" "].lastObject, @"backgroundStyle");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - 开关

- (void)lc_enabledChanged:(UISwitch *)sw { LCSet(@(sw.on), @"enabled"); }
- (void)lc_boldChanged:(UISwitch *)sw { LCSet(@(sw.on), @"boldText"); }

#pragma mark - 颜色

- (UIColor *)lc_colorFromHex:(NSString *)hex {
    if (!hex || hex.length < 7) return nil;
    NSScanner *sc = [NSScanner scannerWithString:hex];
    [sc setScanLocation:1];
    unsigned rgb = 0;
    if (![sc scanHexInt:&rgb]) return nil;
    CGFloat a = 1.0;
    if (hex.length >= 9) {
        a = ((rgb & 0xFF) / 255.0);
        rgb = (rgb >> 8);
    }
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0 alpha:a];
}

- (NSString *)lc_hexFromColor:(UIColor *)color {
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X",
            (int)(r * 255), (int)(g * 255), (int)(b * 255), (int)(a * 255)];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)picker didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    LCSet([self lc_hexFromColor:color], self.colorKey);
}

@end
