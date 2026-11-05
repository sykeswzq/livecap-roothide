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

// v1.0.83：配置读写统一走【plist 文件】。
// 背景：面板原来用 CFPreferences 写、tweak 用文件直写同一个 plist，
//       两套机制互相覆盖 → 实测 showEnglish 写好的 false 被覆写成 true。
// 现在面板与 tweak 用完全相同的通道读写同一个文件，状态永远一致。
static NSString *LCConfigPath(void) {
    // 与 tweak 的 LCJBRootPath 保持一致：roothide 下需经 jbroot 解析
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
        // 同步 cfprefsd，避免它用内存里的旧值把文件覆盖回去
        CFPreferencesAppSynchronize((__bridge CFStringRef)LCAppID);
    } @catch (NSException *e) {}
}

static NSString *LCStr(NSString *key, NSString *fallback) {
    id v = LCGet(key);
    return ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0)
        ? (NSString *)v : fallback;
}

// ===== v1.0.87：安全的数值/布尔读取 =====
// 背景：postinst 写入的是 <string>16</string>（字符串），
// 面板却用 [(NSNumber *)LCGet(@"fontSize") doubleValue] 强转 —— 类型不匹配，
// 遇到字符串时是「未定义行为」（运气好能跑，运气不好直接崩）。
// 现在统一兼容 NSNumber / NSString 两种存法，和 tweak 侧读取逻辑保持一致。
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

#pragma mark - 主控制器

#pragma mark - v1.0.87：字幕字号选择器（滑块 + 实时预览）

// 设计要点：
//   ① 滑块 10~40，与 tweak 侧 fontSize 的取值范围完全一致
//   ② 拖动时实时改预览文字（所见即所得）
//   ③ 数值变化即写入配置（tweak 实时读盘 + 0.4s 监听）→ 字幕当场变大/变小
//   ④ 快捷档位按钮（小/标准/大/特大），单手可点
//   ⑤ 默认值 16，与 tweak 实际默认一致（原来面板显示 28、实际 16，两边对不上）
@interface LCFontSizeController : UIViewController
@end

@implementation LCFontSizeController {
    UISlider *_slider;
    UILabel *_valueLabel;
    UILabel *_preview;
    double _value;
    double _lastWritten;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"字幕字号";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _value = [self lc_currentFontSize];
    _lastWritten = _value;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(lc_done)];

    // 说明文字
    UILabel *desc = [[UILabel alloc] init];
    desc.text = @"拖动滑块调整字幕字号，设置后立即生效，无需重启 App";
    desc.font = [UIFont systemFontOfSize:13];
    desc.textColor = [UIColor secondaryLabelColor];
    desc.numberOfLines = 0;
    desc.textAlignment = NSTextAlignmentCenter;
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:desc];

    // 当前数值
    _valueLabel = [[UILabel alloc] init];
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", _value];
    _valueLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_valueLabel];

    // 滑块
    _slider = [[UISlider alloc] init];
    _slider.minimumValue = 10.0;
    _slider.maximumValue = 40.0;
    _slider.value = (float)_value;
    _slider.minimumTrackTintColor = [UIColor systemBlueColor];
    [_slider addTarget:self
                action:@selector(lc_sliderChanged:)
      forControlEvents:UIControlEventValueChanged];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_slider];

    // 预览（模拟字幕样式：白字深色底）
    _preview = [[UILabel alloc] init];
    _preview.text = @"这是字幕预览效果 Example 123";
    _preview.numberOfLines = 0;
    _preview.textAlignment = NSTextAlignmentCenter;
    _preview.textColor = [UIColor whiteColor];
    _preview.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    _preview.layer.cornerRadius = 8.0;
    _preview.layer.masksToBounds = YES;
    _preview.font = [UIFont systemFontOfSize:(CGFloat)_value];
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_preview];

    // 快捷档位
    UIStackView *presets = [[UIStackView alloc] init];
    presets.axis = UILayoutConstraintAxisHorizontal;
    presets.distribution = UIStackViewDistributionFillEqually;
    presets.spacing = 8.0;
    NSArray *names = @[@"小 14", @"标准 18", @"大 24", @"特大 30"];
    NSArray *vals = @[@14, @18, @24, @30];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:names[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.backgroundColor = [UIColor secondarySystemBackgroundColor];
        b.layer.cornerRadius = 8.0;
        b.tag = [vals[i] integerValue];
        [b addTarget:self
                action:@selector(lc_presetTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        [presets addArrangedSubview:b];
    }
    presets.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:presets];

    // 布局
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [desc.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18],
        [desc.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [desc.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [_valueLabel.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:10],
        [_valueLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_valueLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [_slider.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:6],
        [_slider.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_slider.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [_preview.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:22],
        [_preview.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_preview.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_preview.heightAnchor constraintGreaterThanOrEqualToConstant:90],

        [presets.topAnchor constraintEqualToAnchor:_preview.bottomAnchor constant:18],
        [presets.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [presets.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [presets.heightAnchor constraintEqualToConstant:42],
    ]];
}

// 当前字号（与 tweak 侧范围一致：10~40，默认 16）
- (double)lc_currentFontSize {
    double fs = LCGetNum(@"fontSize", 16.0);
    if (fs < 10.0 || fs > 40.0) fs = 16.0;
    return fs;
}

- (void)lc_sliderChanged:(UISlider *)slider {
    double v = (double)slider.value;
    // 取整（字号没必要有小数）
    v = (double)(long long)(v + 0.5);
    if (v < 10.0) v = 10.0;
    if (v > 40.0) v = 40.0;
    _value = v;
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", v];
    _preview.font = [UIFont systemFontOfSize:(CGFloat)v];
    [self applyValue:v];
}

- (void)lc_presetTapped:(UIButton *)btn {
    _slider.value = (float)btn.tag;
    [self lc_sliderChanged:_slider];
}

// 写入配置：字号是整数，值没变就不写盘（拖动时不做无意义的文件写入）
- (void)applyValue:(double)v {
    if ((v - _lastWritten) < 0.5 && (_lastWritten - v) < 0.5) return;
    _lastWritten = v;
    LCSet(@((NSInteger)v), @"fontSize");
}

- (void)lc_done {
    @try {
        [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *e) {}
}

@end

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
        return @"字幕可长按拖动，位置按 App 记忆（重开 App 回到上次位置）。背景样式：无背景描边 / 半透明黑 / 实黑 / 半透明白 / 毛玻璃。\n点「字幕字号」可用滑块调整大小，改完立即生效，无需重启 App。\n默认只显示中文译文一行；打开「显示英文原文」可恢复上下两行（英文在上、中文在下）。";
    if (section == 3)
        return @"目标 App 需在 Dopamine Inject Manager（或 Filza/真皮）白名单勾选；完全退出目标 App 再打开生效。长按桌面 App 图标可快捷开关实时字幕翻译。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4;
    if (section == 1) return 2;  // 腾讯云 SecretId / SecretKey
    if (section == 2) return 6;  // 字号 / 粗体 / 文字颜色 / 背景样式 / 识别分片 / 显示英文原文
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
            sw.on = LCGetBool(@"enabled", YES);
            [sw addTarget:self action:@selector(lc_enabledChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"注入目标 App";
            // 与「选择注入 App」页口径一致：真实注入 = 白名单 ∩ Inject Manager 允许 ∩ 已安装
            NSUInteger n = [LCReallyInjectedIDs() count];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已注入 %lu 个", (unsigned long)n];
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
            // v1.0.87：字号行 → 点开滑块选择器（不再是数字键盘输入）
            cell.textLabel.text = @"字幕字号";
            // 默认值与 tweak 保持一致（16）。原来这里写 28，
            // 与 tweak 实际的默认 16 不一致 → 用户看到「28」但画面是 16，误以为没生效。
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
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"背景样式";
            cell.detailTextLabel.text = [self lc_bgStyleTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 4) {
            // v1.0.84：ASR 分片时长（秒）—— 直接影响字幕延迟
            cell.textLabel.text = @"识别分片";
            double cs = LCGetNum(@"asrChunkSeconds", 2.5);
            if (cs < 1.0 || cs > 8.0) cs = 2.5;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f 秒", cs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            // row == 5：显示英文原文
            // v1.0.82：默认只显示中文一行；打开后恢复「英文原文 + 中文翻译」两行
            cell.textLabel.text = @"显示英文原文";
            UISwitch *sw = [[UISwitch alloc] init];
            // v1.0.83：只认 showBilingual（默认 NO = 只显示中文一行）。
            // 老键 showEnglish 语义相反且会被覆写，已废弃不用。
            sw.on = LCGetBool(@"showBilingual", NO);
            [sw addTarget:self action:@selector(lc_showEnglishChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
        // ===== v1.0.87：字号选择器（滑块 + 实时预览）=====
        // 原来是一个数字键盘输入框：要先点「字号」→ 弹键盘 → 输入 → 确定，
        // 步骤多、而且看不到效果，改完还要退出 App 才生效（tweak 侧读的是启动时缓存）。
        // 现在：独立的滑块页面，拖动即改、即时预览、即时写入，
        // tweak 侧改为实时读盘 + 0.4s 监听 → 字幕大小当场变化，不用重启 App。
        @try {
            LCFontSizeController *vc = [[LCFontSizeController alloc] init];
            UINavigationController *nav =
                [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:nav animated:YES completion:nil];
        } @catch (NSException *e) {
            NSLog(@"[LiveCapPrefs] font size picker failed: %@", e);
        }
    }
    else if (indexPath.section == 2 && indexPath.row == 4) {
        // v1.0.84：ASR 分片时长选择
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"识别分片时长"
                                                                       message:@"分片越短字幕延迟越低，但句子越容易被切断"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *opts = @[@1.5, @2.5, @3.5, @5.0];
        for (NSNumber *v in opts) {
            double s = [v doubleValue];
            NSString *title = [NSString stringWithFormat:@"%.1f 秒%@", s,
                               (s == 2.5 ? @"（推荐）" : @"")];
            [alert addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
                LCSet(@(s), @"asrChunkSeconds");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
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
- (void)lc_showEnglishChanged:(UISwitch *)sw { LCSet(@(sw.on), @"showBilingual"); }

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
