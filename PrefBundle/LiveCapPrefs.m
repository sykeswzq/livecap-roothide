// LiveCapPrefs.m —— v2.0.0 精简版
// 设置面板主控制器，完全对齐新 UI 结构
#import <UIKit/UIKit.h>
#import "LCPrivate.h"

static NSString *LCAppID = @"com.sykes.livecap";

static NSString *LCConfigPath(void) {
    return LCJbRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
}

static id LCGet(NSString *key) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:LCConfigPath()];
        if (!d) return nil;
        return d[key];
    } @catch (NSException *e) { return nil; }
}

static void LCSet(id value, NSString *key) {
    @try {
        NSMutableDictionary *d =
            [NSMutableDictionary dictionaryWithContentsOfFile:LCConfigPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        if (value == nil) {
            [d removeObjectForKey:key];
        } else {
            d[key] = value;
        }
        [d writeToFile:LCConfigPath() atomically:YES];
        CFPreferencesAppSynchronize((__bridge CFStringRef)LCAppID);
    } @catch (NSException *e) {}
}

static NSString *LCStr(NSString *key, NSString *fallback) {
    id v = LCGet(key);
    return ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0)
        ? (NSString *)v : fallback;
}

static double LCGetNum(NSString *key, double fallback) {
    id v = LCGet(key);
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

static BOOL LCGetBool(NSString *key, BOOL fallback) {
    id v = LCGet(key);
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return fallback;
}

#pragma mark - 字体大小控制器

@interface LCFontSizeController : UIViewController <UIColorPickerViewControllerDelegate>
@end

@implementation LCFontSizeController {
    UISlider *_slider;
    UILabel *_valueLabel;
    UILabel *_preview;
    double _lastWritten;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"字幕字号";
    CGFloat fs = LCGetNum(@"fontSize", 16.0);
    if (fs < 10 || fs > 40) fs = 16.0;

    UILabel *tip = [[UILabel alloc] init];
    tip.text = @"拖动调节，立即生效";
    tip.font = [UIFont systemFontOfSize:13];
    tip.textColor = [UIColor secondaryLabelColor];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tip];

    _slider = [[UISlider alloc] init];
    _slider.minimumValue = 10.0;
    _slider.maximumValue = 40.0;
    _slider.value = (float)fs;
    _slider.transform = CGAffineTransformMakeRotation(M_PI_2);
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider addTarget:self action:@selector(lc_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_slider];

    _valueLabel = [[UILabel alloc] init];
    [_valueLabel sizeToFit];
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", fs];
    _valueLabel.font = [UIFont boldSystemFontOfSize:17];
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_valueLabel];

    _preview = [[UILabel alloc] init];
    _preview.text = @"实时字幕翻译";
    _preview.font = [UIFont systemFontOfSize:(float)fs];
    _preview.alpha = 0.85;
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_preview];

    // 保存按钮
    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(lc_done)];
    self.navigationItem.rightBarButtonItem = doneBtn;

    NSArray<NSLayoutConstraint *> *constraints = @[
        [tip.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [tip.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [tip.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_slider.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_slider.centerYAnchor constraintEqualToAnchor:tip.bottomAnchor constant:24],
        [_slider.widthAnchor constraintEqualToConstant:180],

        [_valueLabel.centerXAnchor constraintEqualToAnchor:_slider.centerXAnchor],
        [_valueLabel.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:12],

        [_preview.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:24],
        [_preview.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ];
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)lc_sliderChanged:(UISlider *)sender {
    CGFloat v = sender.value;
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", v];
    _preview.font = [UIFont systemFontOfSize:v];
    if ((v - _lastWritten) >= 1.0 || fabs(v - _lastWritten) > 99.0) {
        LCSet(@(v), @"fontSize");
        _lastWritten = v;
    }
}

- (void)lc_done {
    CGFloat v = _slider.value;
    LCSet(@(v), @"fontSize");
    _lastWritten = v;
    if (self.navigationController)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

@end

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

#pragma mark - 表格数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4; // 基本 / 接口设置 / 字幕外观 / 显示选项
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"基本设置";
    if (section == 1) return @"接口设置";
    if (section == 2) return @"字幕外观";
    if (section == 3) return @"显示选项";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"启用后会自动监听目标 App 音频并生成实时字幕翻译。";
    if (section == 1)
        return @"使用 OpenAI 兼容的翻译 API，默认使用 agnes-2.5-flash。";
    if (section == 2)
        return @"字幕可长按拖动，位置按 App 记忆。字号拖完立即生效无需重启。";
    if (section == 3)
        return @"打开后同时显示英文原文 + 中文译文两行。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return 3;
    if (section == 2) return 4;
    if (section == 3) return 1;
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
            cell.textLabel.text = @"启用字幕翻译";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"enabled", YES);
            [sw addTarget:self action:@selector(lc_enabledChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"选择注入 App";
            NSUInteger n = [LCReallyInjectedIDs() count];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已注入 %lu 个", (unsigned long)n];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"API 地址";
            cell.detailTextLabel.text = LCStr(@"apiBase", @"https://apihub.agnes-ai.cn/v1");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"API Key";
            cell.detailTextLabel.text = [self lc_apiKeyTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"模型名称";
            cell.detailTextLabel.text = LCStr(@"model", @"agnes-2.5-flash");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"字体大小";
            CGFloat fs = LCGetNum(@"fontSize", 16.0);
            if (fs < 10 || fs > 40) fs = 16.0;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", fs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"粗体";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"boldText", NO);
            [sw addTarget:self action:@selector(lc_boldChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"文字颜色";
            cell.detailTextLabel.text = [self lc_colorTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"背景风格";
            cell.detailTextLabel.text = [self lc_bgStyleTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    else if (indexPath.section == 3) {
        cell.textLabel.text = @"同时显示原文";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = LCGetBool(@"showBilingual", NO);
        [sw addTarget:self action:@selector(lc_showEnglishChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
    else if (indexPath.section == 1 && indexPath.row == 0) {
        NSString *current = LCStr(@"apiBase", @"https://apihub.agnes-ai.cn/v1");
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"API 地址"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = current;
            tf.placeholder = @"https://api.example.com/v1";
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *v = alert.textFields.firstObject.text;
            if (!v) v = @"";
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            LCSet((v.length > 0) ? v : nil, @"apiBase");
            [self.lc_tv reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 1 && indexPath.row == 1) {
        NSString *current = LCStr(@"apiKey", @"");
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"API Key"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = current;
            tf.placeholder = @"sk-...";
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.secureTextEntry = YES;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *v = alert.textFields.firstObject.text;
            if (!v) v = @"";
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            LCSet((v.length > 0) ? v : nil, @"apiKey");
            [self.lc_tv reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 1 && indexPath.row == 2) {
        NSString *current = LCStr(@"model", @"agnes-2.5-flash");
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"模型名称"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = current;
            tf.placeholder = @"agnes-2.5-flash";
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *v = alert.textFields.firstObject.text;
            if (!v) v = @"";
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            LCSet((v.length > 0) ? v : nil, @"model");
            [self.lc_tv reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 2 && indexPath.row == 0) {
        @try {
            LCFontSizeController *vc = [[LCFontSizeController alloc] init];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:nav animated:YES completion:nil];
        } @catch (NSException *e) {
            NSLog(@"[LiveCapPrefs] font size picker failed: %@", e);
        }
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"背景风格"
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

#pragma mark - 开关回调

- (void)lc_enabledChanged:(UISwitch *)sw { LCSet(@(sw.on), @"enabled"); }
- (void)lc_boldChanged:(UISwitch *)sw { LCSet(@(sw.on), @"boldText"); }
- (void)lc_showEnglishChanged:(UISwitch *)sw { LCSet(@(sw.on), @"showBilingual"); }

#pragma mark - 颜色选择器

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
