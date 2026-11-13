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

// v2.2.17：字号改为手动输入。范围与 tweak 侧 -fontSize 严格一致（8~72，默认 16），
// 放宽上限是因为手动输入本来就是为了拿到滑块拖不准/够不到的值。
static const CGFloat kLCFontMin = 8.0;
static const CGFloat kLCFontMax = 72.0;

@interface LCFontSizeController : UIViewController <UIColorPickerViewControllerDelegate, UITextFieldDelegate>
@end

@implementation LCFontSizeController {
    UISlider *_slider;
    UITextField *_input;
    UILabel *_valueLabel;
    UILabel *_preview;
    double _lastWritten;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"字幕字号";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    CGFloat fs = LCGetNum(@"fontSize", 16.0);
    if (fs < kLCFontMin || fs > kLCFontMax) fs = 16.0;
    _lastWritten = fs;

    UILabel *tip = [[UILabel alloc] init];
    tip.text = @"直接输入字号（8~72），下方滑块可微调";
    tip.font = [UIFont systemFontOfSize:13];
    tip.textColor = [UIColor secondaryLabelColor];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.numberOfLines = 0;
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tip];

    // 主输入：数字键盘 + 严格数值校验（lc_parse:value: 整串匹配）。
    // 旧的竖直旋转滑块手指拖不准，现在只留水平滑块做微调。
    _input = [[UITextField alloc] init];
    _input.borderStyle = UITextBorderStyleRoundedRect;
    _input.keyboardType = UIKeyboardTypeDecimalPad;
    _input.textAlignment = NSTextAlignmentCenter;
    _input.font = [UIFont boldSystemFontOfSize:24];
    _input.text = [NSString stringWithFormat:@"%g", (double)fs];
    _input.placeholder = @"16";
    _input.clearButtonMode = UITextFieldViewModeWhileEditing;
    _input.autocorrectionType = UITextAutocorrectionTypeNo;
    _input.delegate = self;
    [_input addTarget:self action:@selector(lc_inputChanged:) forControlEvents:UIControlEventEditingChanged];
    _input.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_input];

    // 数字键盘没有 return 键，补一条「收起键盘」工具条
    UIToolbar *kbBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *kbDone = [[UIBarButtonItem alloc]
        initWithTitle:@"收起键盘" style:UIBarButtonItemStyleDone target:self action:@selector(lc_dismissKeyboard)];
    [kbBar setItems:@[flex, kbDone] animated:NO];
    _input.inputAccessoryView = kbBar;

    _valueLabel = [[UILabel alloc] init];
    _valueLabel.font = [UIFont boldSystemFontOfSize:17];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.text = [NSString stringWithFormat:@"%g pt", (double)fs];
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_valueLabel];

    _preview = [[UILabel alloc] init];
    _preview.text = @"实时字幕翻译";
    _preview.font = [UIFont systemFontOfSize:fs];
    _preview.textAlignment = NSTextAlignmentCenter;
    _preview.numberOfLines = 0;
    _preview.alpha = 0.85;
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_preview];

    // 微调滑块：不再旋转 90°（旧版旋转后约束与手势都错乱）
    _slider = [[UISlider alloc] init];
    _slider.minimumValue = (float)kLCFontMin;
    _slider.maximumValue = (float)kLCFontMax;
    _slider.value = (float)fs;
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider addTarget:self action:@selector(lc_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_slider];

    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(lc_done)];
    self.navigationItem.rightBarButtonItem = doneBtn;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(lc_dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [tip.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [tip.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [tip.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        [_input.topAnchor constraintEqualToAnchor:tip.bottomAnchor constant:20],
        [_input.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_input.widthAnchor constraintEqualToConstant:140],
        [_input.heightAnchor constraintEqualToConstant:44],

        [_valueLabel.topAnchor constraintEqualToAnchor:_input.bottomAnchor constant:18],
        [_valueLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_preview.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:24],
        [_preview.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_preview.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        [_slider.topAnchor constraintEqualToAnchor:_preview.bottomAnchor constant:28],
        [_slider.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [_slider.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

// 严格数值解析：整串必须被 NSScanner 完整消费。
// "16abc" / "abc" / 空串 / 超范围一律拒绝；输入途中（想输 16 只打了 1）也先不动作，
// 避免预览和滑块跟着乱跳，更不会把 1 或 999 这种脏值写进 plist。
- (BOOL)lc_parse:(NSString *)raw value:(double *)out {
    NSString *s = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return NO;
    NSScanner *sc = [NSScanner scannerWithString:s];
    double v = 0;
    if (![sc scanDouble:&v] || ![sc isAtEnd]) return NO;
    if (v < kLCFontMin || v > kLCFontMax) return NO;
    if (out) *out = v;
    return YES;
}

// 单一写入口：预览 / 数值标签 / 滑块 / 输入框 / plist 全部同步，避免三处各写各的。
- (void)lc_apply:(double)v syncInput:(BOOL)sync {
    _preview.font = [UIFont systemFontOfSize:(CGFloat)v];
    _valueLabel.text = [NSString stringWithFormat:@"%g pt", v];
    _slider.value = (float)v;
    if (sync) _input.text = [NSString stringWithFormat:@"%g", v];
    LCSet(@(v), @"fontSize");
    _lastWritten = v;
}

- (void)lc_inputChanged:(UITextField *)sender {
    double v = 0;
    if (![self lc_parse:sender.text value:&v]) return;
    [self lc_apply:v syncInput:NO];
}

- (void)lc_sliderChanged:(UISlider *)sender {
    CGFloat v = sender.value;
    [self lc_apply:(double)v syncInput:YES];
}

- (void)lc_dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)lc_done {
    double v = 0;
    if (![self lc_parse:_input.text value:&v]) {
        // 非法/清空：回落到最近一次有效值，绝不写脏数据
        v = _lastWritten;
        _input.text = [NSString stringWithFormat:@"%g", v];
    }
    [self lc_apply:v syncInput:NO];
    [self lc_dismissKeyboard];
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

// v2.2.7：源语言选项中文名
- (NSString *)lc_srcLangTitle {
    NSString *v = LCStr(@"srcLang", @"auto");
    NSDictionary *map = @{@"auto":@"自动", @"en":@"英语", @"ja":@"日语", @"ko":@"韩语",
                          @"fr":@"法语", @"de":@"德语", @"es":@"西班牙语", @"ru":@"俄语",
                          @"ar":@"阿拉伯语", @"th":@"泰语", @"zh":@"中文"};
    NSString *t = map[v];
    return t ? t : @"自动";
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
        return @"启用后会自动监听目标 App 音频并生成实时字幕翻译。流式识别边说边推、不攒音频；关闭后回到旧的分片识别。分片时长只在关闭流式时生效。严格同步：凑成整句才翻译，字幕与原版字幕对齐；关闭则回到旧的定时兜底（可作对照）。「视频源语言」用于回译自检，看不懂外语选「自动」即可。";
    if (section == 1)
        return @"使用 OpenAI 兼容的翻译 API，默认使用 agnes-3.0-flash。";
    if (section == 2)
        return @"字幕可长按拖动，位置按 App 记忆。字号拖完立即生效无需重启。";
    if (section == 3)
        return @"「同时显示原文」打开后显示英文原文 + 中文译文两行。「回译自检」开启后，字幕末尾会显示 ✓（翻译可信）或 ⚠（可能不准），帮你判断翻译质量——这是弱提示，不能替代核对。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 6;
    if (section == 1) return 3;
    if (section == 2) return 4;
    if (section == 3) return 2;
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
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"选择注入 App";
            // v2.2.13：与 App 列表页同口径，显示「实际注入」数（Filter ∩ 已安装），
            // 不再数旧版落盘的 29 个默认 Bundle。
            NSUInteger n = [LCRealInjectedList() count];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"实际注入 %lu 个", (unsigned long)n];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"识别分片时长";
            double secs = LCGetNum(@"asrChunkSeconds", 1.5);
            if (secs < 1.0 || secs > 3.0) secs = 1.5;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f 秒", secs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 3) {
            // v2.1.1：流式识别一键回退开关。真机若出现「只有圆点、没有字幕框」，
            // 关掉这里即可立刻回到已验证可用的 HTTP 分片链路，无需重新编译或改 plist。
            cell.textLabel.text = @"流式识别（不攒音频）";
            cell.detailTextLabel.text = LCGetBool(@"streamASR", YES) ? @"开" : @"关";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"streamASR", YES);
            [sw addTarget:self action:@selector(lc_streamChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 4) {
            // v2.2.0：整句才送译。关掉回到 v2.1.1 的定时兜底，便于真机对照。
            cell.textLabel.text = @"严格同步（整句才翻译）";
            cell.detailTextLabel.text = LCGetBool(@"strictSubtitleSync", YES) ? @"开" : @"关";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"strictSubtitleSync", YES);
            [sw addTarget:self action:@selector(lc_strictSyncChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            // v2.2.7：视频源语言（回译自检用）。默认自动（按脚本探测）。
            cell.textLabel.text = @"视频源语言";
            cell.detailTextLabel.text = [self lc_srcLangTitle];
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
            cell.detailTextLabel.text = LCStr(@"model", @"agnes-3.0-flash");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"字体大小";
            CGFloat fs = LCGetNum(@"fontSize", 16.0);
            if (fs < kLCFontMin || fs > kLCFontMax) fs = 16.0;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%g", (double)fs];
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
        if (indexPath.row == 0) {
            cell.textLabel.text = @"同时显示原文";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"showBilingual", NO);
            [sw addTarget:self action:@selector(lc_showEnglishChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            // v2.2.7：回译自检开关（字幕末尾显示 ✓/⚠，提示翻译可信度）。
            cell.textLabel.text = @"回译自检（✓/⚠）";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"backCheckEnabled", YES);
            [sw addTarget:self action:@selector(lc_backCheckChanged:) forControlEvents:UIControlEventValueChanged];
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
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"识别分片时长"
                           message:@"越短越跟嘴、延迟越低；越长句子越完整。改动最多 2 秒后生效。"
                    preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *vals = @[@1.0, @1.2, @1.5, @2.0, @2.5];
        for (NSNumber *n in vals) {
            NSString *title = [NSString stringWithFormat:@"%.1f 秒%@", [n doubleValue],
                               ([n doubleValue] == 1.5) ? @"（推荐）" : @""];
            [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                LCSet(n, @"asrChunkSeconds");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 0 && indexPath.row == 5) {
        // v2.2.7：视频源语言选择（回译自检用）。看不懂外语时一般选「自动」即可。
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"视频源语言"
                           message:@"用于「回译自检」判断翻译可信度。看不懂外语通常选「自动」；若自动识别不准可手动指定。"
                    preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *items = @[@"自动 auto", @"英语 en", @"日语 ja", @"韩语 ko",
                           @"法语 fr", @"德语 de", @"西班牙语 es", @"俄语 ru", @"阿拉伯语 ar", @"泰语 th"];
        for (NSString *s in items) {
            [alert addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                LCSet([s componentsSeparatedByString:@" "].lastObject, @"srcLang");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
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
        NSString *current = LCStr(@"model", @"agnes-3.0-flash");
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"模型名称"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = current;
            tf.placeholder = @"agnes-3.0-flash";
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

- (void)lc_streamChanged:(UISwitch *)sw {
    LCSet(@(sw.on), @"streamASR");
    [self.lc_tv reloadData];
}
- (void)lc_strictSyncChanged:(UISwitch *)sw {
    // tweak 的 freshValueForKey 是直接读同一个 plist 文件（不走 CFPreferences 缓存），
    // 所以这里与面板其它设置一样用 LCSet 写文件即可，立即生效。
    LCSet(@(sw.on), @"strictSubtitleSync");
    [self.lc_tv reloadData];
}
- (void)lc_enabledChanged:(UISwitch *)sw { LCSet(@(sw.on), @"enabled"); }
- (void)lc_boldChanged:(UISwitch *)sw { LCSet(@(sw.on), @"boldText"); }
- (void)lc_showEnglishChanged:(UISwitch *)sw { LCSet(@(sw.on), @"showBilingual"); }
- (void)lc_backCheckChanged:(UISwitch *)sw { LCSet(@(sw.on), @"backCheckEnabled"); }

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
