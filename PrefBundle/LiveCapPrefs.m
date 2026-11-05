// LiveCapPrefs.m \u2014\u2014 \u8bbe\u7f6e\u9762\u677f\u4e3b\u63a7\u5236\u5668\uff08LCRootListController\uff09
// \u8303\u5f0f\uff1a\u5b8c\u5168\u5bf9\u9f50 XL-Roothide\uff08XLRootListController\uff09\u2014\u2014
//   PSViewController + \u624b\u5199 grouped UITableView\uff0c\u4e0d\u7528 specifiers / Root.plist\u3002
// \u914d\u7f6e\u8bfb\u5199\uff1aCFPreferences \u663e\u5f0f\u6307\u5b9a appID = com.sykes.livecap\uff08\u4e0e tweak \u8bfb\u53d6\u7684
//   /var/mobile/Library/Preferences/com.sykes.livecap.plist \u540c\u4e00\u4efd\uff0c\u9762\u677f\u5728"\u8bbe\u7f6e"\u8fdb\u7a0b\uff0c
//   \u9ed8\u8ba4\u57df\u4f1a\u662f bundle id com.sykes.livecap.prefs\uff0c\u5fc5\u987b\u663e\u5f0f\u6307\u5b9a\u5426\u5219 tweak \u8bfb\u4e0d\u5230\uff09\u3002
#import <UIKit/UIKit.h>
#import "LCPrivate.h"

#pragma mark - \u914d\u7f6e\u8bfb\u5199\uff08com.sykes.livecap \u57df\uff09

static NSString *LCAppID = @"com.sykes.livecap";

// v1.0.83\uff1a\u914d\u7f6e\u8bfb\u5199\u7edf\u4e00\u8d70\u3010plist \u6587\u4ef6\u3011\u3002
// \u80cc\u666f\uff1a\u9762\u677f\u539f\u6765\u7528 CFPreferences \u5199\u3001tweak \u7528\u6587\u4ef6\u76f4\u5199\u540c\u4e00\u4e2a plist\uff0c
//       \u4e24\u5957\u673a\u5236\u4e92\u76f8\u8986\u76d6 \u2192 \u5b9e\u6d4b showEnglish \u5199\u597d\u7684 false \u88ab\u8986\u5199\u6210 true\u3002
// \u73b0\u5728\u9762\u677f\u4e0e tweak \u7528\u5b8c\u5168\u76f8\u540c\u7684\u901a\u9053\u8bfb\u5199\u540c\u4e00\u4e2a\u6587\u4ef6\uff0c\u72b6\u6001\u6c38\u8fdc\u4e00\u81f4\u3002
static NSString *LCConfigPath(void) {
    // \u4e0e tweak \u7684 LCJBRootPath \u4fdd\u6301\u4e00\u81f4\uff1aroothide \u4e0b\u9700\u7ecf jbroot \u89e3\u6790
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
        // \u540c\u6b65 cfprefsd\uff0c\u907f\u514d\u5b83\u7528\u5185\u5b58\u91cc\u7684\u65e7\u503c\u628a\u6587\u4ef6\u8986\u76d6\u56de\u53bb
        CFPreferencesAppSynchronize((__bridge CFStringRef)LCAppID);
    } @catch (NSException *e) {}
}

static NSString *LCStr(NSString *key, NSString *fallback) {
    id v = LCGet(key);
    return ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0)
        ? (NSString *)v : fallback;
}

// ===== v1.0.87\uff1a\u5b89\u5168\u7684\u6570\u503c/\u5e03\u5c14\u8bfb\u53d6 =====
// \u80cc\u666f\uff1apostinst \u5199\u5165\u7684\u662f <string>16</string>\uff08\u5b57\u7b26\u4e32\uff09\uff0c
// \u9762\u677f\u5374\u7528 [(NSNumber *)LCGet(@"fontSize") doubleValue] \u5f3a\u8f6c \u2014\u2014 \u7c7b\u578b\u4e0d\u5339\u914d\uff0c
// \u9047\u5230\u5b57\u7b26\u4e32\u65f6\u662f\u300c\u672a\u5b9a\u4e49\u884c\u4e3a\u300d\uff08\u8fd0\u6c14\u597d\u80fd\u8dd1\uff0c\u8fd0\u6c14\u4e0d\u597d\u76f4\u63a5\u5d29\uff09\u3002
// \u73b0\u5728\u7edf\u4e00\u517c\u5bb9 NSNumber / NSString \u4e24\u79cd\u5b58\u6cd5\uff0c\u548c tweak \u4fa7\u8bfb\u53d6\u903b\u8f91\u4fdd\u6301\u4e00\u81f4\u3002
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

#pragma mark - \u4e3b\u63a7\u5236\u5668

#pragma mark - v1.0.87\uff1a\u5b57\u5e55\u5b57\u53f7\u9009\u62e9\u5668\uff08\u6ed1\u5757 + \u5b9e\u65f6\u9884\u89c8\uff09

// \u8bbe\u8ba1\u8981\u70b9\uff1a
//   \u2460 \u6ed1\u5757 10~40\uff0c\u4e0e tweak \u4fa7 fontSize \u7684\u53d6\u503c\u8303\u56f4\u5b8c\u5168\u4e00\u81f4
//   \u2461 \u62d6\u52a8\u65f6\u5b9e\u65f6\u6539\u9884\u89c8\u6587\u5b57\uff08\u6240\u89c1\u5373\u6240\u5f97\uff09
//   \u2462 \u6570\u503c\u53d8\u5316\u5373\u5199\u5165\u914d\u7f6e\uff08tweak \u5b9e\u65f6\u8bfb\u76d8 + 0.4s \u76d1\u542c\uff09\u2192 \u5b57\u5e55\u5f53\u573a\u53d8\u5927/\u53d8\u5c0f
//   \u2463 \u5feb\u6377\u6863\u4f4d\u6309\u94ae\uff08\u5c0f/\u6807\u51c6/\u5927/\u7279\u5927\uff09\uff0c\u5355\u624b\u53ef\u70b9
//   \u2464 \u9ed8\u8ba4\u503c 16\uff0c\u4e0e tweak \u5b9e\u9645\u9ed8\u8ba4\u4e00\u81f4\uff08\u539f\u6765\u9762\u677f\u663e\u793a 28\u3001\u5b9e\u9645 16\uff0c\u4e24\u8fb9\u5bf9\u4e0d\u4e0a\uff09
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
    self.title = @"\u5b57\u5e55\u5b57\u53f7";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _value = [self lc_currentFontSize];
    _lastWritten = _value;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"\u5b8c\u6210"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(lc_done)];

    // \u8bf4\u660e\u6587\u5b57
    UILabel *desc = [[UILabel alloc] init];
    desc.text = @"\u62d6\u52a8\u6ed1\u5757\u8c03\u6574\u5b57\u5e55\u5b57\u53f7\uff0c\u8bbe\u7f6e\u540e\u7acb\u5373\u751f\u6548\uff0c\u65e0\u9700\u91cd\u542f App";
    desc.font = [UIFont systemFontOfSize:13];
    desc.textColor = [UIColor secondaryLabelColor];
    desc.numberOfLines = 0;
    desc.textAlignment = NSTextAlignmentCenter;
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:desc];

    // \u5f53\u524d\u6570\u503c
    _valueLabel = [[UILabel alloc] init];
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", _value];
    _valueLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_valueLabel];

    // \u6ed1\u5757
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

    // \u9884\u89c8\uff08\u6a21\u62df\u5b57\u5e55\u6837\u5f0f\uff1a\u767d\u5b57\u6df1\u8272\u5e95\uff09
    _preview = [[UILabel alloc] init];
    _preview.text = @"\u8fd9\u662f\u5b57\u5e55\u9884\u89c8\u6548\u679c Example 123";
    _preview.numberOfLines = 0;
    _preview.textAlignment = NSTextAlignmentCenter;
    _preview.textColor = [UIColor whiteColor];
    _preview.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    _preview.layer.cornerRadius = 8.0;
    _preview.layer.masksToBounds = YES;
    _preview.font = [UIFont systemFontOfSize:(CGFloat)_value];
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_preview];

    // \u5feb\u6377\u6863\u4f4d
    UIStackView *presets = [[UIStackView alloc] init];
    presets.axis = UILayoutConstraintAxisHorizontal;
    presets.distribution = UIStackViewDistributionFillEqually;
    presets.spacing = 8.0;
    NSArray *names = @[@"\u5c0f 14", @"\u6807\u51c6 18", @"\u5927 24", @"\u7279\u5927 30"];
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

    // \u5e03\u5c40
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

// \u5f53\u524d\u5b57\u53f7\uff08\u4e0e tweak \u4fa7\u8303\u56f4\u4e00\u81f4\uff1a10~40\uff0c\u9ed8\u8ba4 16\uff09
- (double)lc_currentFontSize {
    double fs = LCGetNum(@"fontSize", 16.0);
    if (fs < 10.0 || fs > 40.0) fs = 16.0;
    return fs;
}

- (void)lc_sliderChanged:(UISlider *)slider {
    double v = (double)slider.value;
    // \u53d6\u6574\uff08\u5b57\u53f7\u6ca1\u5fc5\u8981\u6709\u5c0f\u6570\uff09
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

// \u5199\u5165\u914d\u7f6e\uff1a\u5b57\u53f7\u662f\u6574\u6570\uff0c\u503c\u6ca1\u53d8\u5c31\u4e0d\u5199\u76d8\uff08\u62d6\u52a8\u65f6\u4e0d\u505a\u65e0\u610f\u4e49\u7684\u6587\u4ef6\u5199\u5165\uff09
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
    self.title = @"\u5b9e\u65f6\u5b57\u5e55\u7ffb\u8bd1";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    if (!(self.navigationController && self.navigationController.viewControllers.count > 1)) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"\u5b8c\u6210"
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

#pragma mark - \u5c55\u793a\u503c

- (NSString *)lc_sourceLangTitle {
    NSString *v = LCStr(@"sourceLang", @"en-US");
    if ([v isEqualToString:@"en-US"]) return @"\u82f1\u8bed";
    if ([v isEqualToString:@"ja-JP"]) return @"\u65e5\u8bed";
    if ([v isEqualToString:@"ko-KR"]) return @"\u97e9\u8bed";
    if ([v isEqualToString:@"zh-CN"]) return @"\u4e2d\u6587";
    return v;
}

- (NSString *)lc_targetLangTitle {
    NSString *v = LCStr(@"targetLang", @"zh-Hans");
    if ([v isEqualToString:@"zh-Hans"]) return @"\u7b80\u4f53\u4e2d\u6587";
    if ([v isEqualToString:@"zh-Hant"]) return @"\u7e41\u4f53\u4e2d\u6587";
    if ([v isEqualToString:@"en"]) return @"\u82f1\u8bed";
    return v;
}

- (NSString *)lc_bgStyleTitle {
    NSString *v = LCStr(@"backgroundStyle", @"frost");
    if ([v isEqualToString:@"none"]) return @"\u65e0\u80cc\u666f\u63cf\u8fb9";
    if ([v isEqualToString:@"darktrans"]) return @"\u534a\u900f\u660e\u9ed1";
    if ([v isEqualToString:@"darksolid"]) return @"\u5b9e\u9ed1";
    if ([v isEqualToString:@"lighttrans"]) return @"\u534a\u900f\u660e\u767d";
    return @"\u6bdb\u73bb\u7483";
}

- (NSString *)lc_colorTitle {
    NSString *hex = LCStr(@"textColorHex", @"#FFFFFFFF");
    if ([hex caseInsensitiveCompare:@"#FFFFFFFF"] == NSOrderedSame ||
        [hex caseInsensitiveCompare:@"#FFFFFF"] == NSOrderedSame) return @"\u767d\u8272\uff08\u9ed8\u8ba4\uff09";
    return hex;
}

- (NSString *)lc_apiKeyTitle {
    NSString *k = LCStr(@"apiKey", @"");
    return (k.length == 0) ? @"\u672a\u8bbe\u7f6e" : @"\u5df2\u8bbe\u7f6e";
}

- (NSString *)lc_tencentSecretTitle {
    NSString *k = LCStr(@"tencentSecretId", @"");
    return (k.length == 0) ? @"\u672a\u8bbe\u7f6e" : @"\u5df2\u8bbe\u7f6e";
}

- (NSString *)lc_tencentSecretKeyTitle {
    NSString *k = LCStr(@"tencentSecretKey", @"");
    return (k.length == 0) ? @"\u672a\u8bbe\u7f6e" : @"\u5df2\u8bbe\u7f6e";
}

#pragma mark - \u8868\u683c

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4; // 0 \u57fa\u672c / 1 \u7ffb\u8bd1 API / 2 \u5b57\u5e55\u663e\u793a / 3 \u8bf4\u660e
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"\u57fa\u672c";
    if (section == 1) return @"\u817e\u8baf\u4e91\u8bed\u97f3\u8bc6\u522b\uff08\u5728\u7ebf\uff09";
    if (section == 2) return @"\u5b57\u5e55\u663e\u793a";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"\u8bc6\u522b\u8bed\u8a00\u4f1a\u6309 App \u8bb0\u5fc6\uff08\u4f8b\u5982 A \u8f6f\u4ef6\u82f1\u8bed\u3001B \u8f6f\u4ef6\u65e5\u8bed\uff09\uff0c\u4e5f\u53ef\u957f\u6309\u684c\u9762 App \u56fe\u6807\u5feb\u6377\u5207\u6362\u3002";
    if (section == 1)
        return @"\u5728\u7ebf\u8bed\u97f3\u8bc6\u522b\u65e0\u9700 iOS \u6388\u6743\uff0c\u4efb\u4f55 App \u901a\u7528\u3002\u817e\u8baf\u4e91\u4e00\u53e5\u8bdd\u8bc6\u522b\u6bcf\u6708\u514d\u8d39 5000 \u6b21\uff0c\u5bc6\u94a5\u5728\u63a7\u5236\u53f0\u2192\u8bbf\u95ee\u7ba1\u7406\u2192API \u5bc6\u94a5\u7ba1\u7406\u83b7\u53d6\u3002\u7ffb\u8bd1\u4f7f\u7528\u5185\u7f6e AI \u670d\u52a1\u3002";
    if (section == 2)
        return @"\u5b57\u5e55\u53ef\u957f\u6309\u62d6\u52a8\uff0c\u4f4d\u7f6e\u6309 App \u8bb0\u5fc6\uff08\u91cd\u5f00 App \u56de\u5230\u4e0a\u6b21\u4f4d\u7f6e\uff09\u3002\u80cc\u666f\u6837\u5f0f\uff1a\u65e0\u80cc\u666f\u63cf\u8fb9 / \u534a\u900f\u660e\u9ed1 / \u5b9e\u9ed1 / \u534a\u900f\u660e\u767d / \u6bdb\u73bb\u7483\u3002\n\u70b9\u300c\u5b57\u5e55\u5b57\u53f7\u300d\u53ef\u7528\u6ed1\u5757\u8c03\u6574\u5927\u5c0f\uff0c\u6539\u5b8c\u7acb\u5373\u751f\u6548\uff0c\u65e0\u9700\u91cd\u542f App\u3002\n\u9ed8\u8ba4\u53ea\u663e\u793a\u4e2d\u6587\u8bd1\u6587\u4e00\u884c\uff1b\u6253\u5f00\u300c\u663e\u793a\u82f1\u6587\u539f\u6587\u300d\u53ef\u6062\u590d\u4e0a\u4e0b\u4e24\u884c\uff08\u82f1\u6587\u5728\u4e0a\u3001\u4e2d\u6587\u5728\u4e0b\uff09\u3002";
    if (section == 3)
        return @"\u76ee\u6807 App \u9700\u5728 Dopamine Inject Manager\uff08\u6216 Filza/\u771f\u76ae\uff09\u767d\u540d\u5355\u52fe\u9009\uff1b\u5b8c\u5168\u9000\u51fa\u76ee\u6807 App \u518d\u6253\u5f00\u751f\u6548\u3002\u957f\u6309\u684c\u9762 App \u56fe\u6807\u53ef\u5feb\u6377\u5f00\u5173\u5b9e\u65f6\u5b57\u5e55\u7ffb\u8bd1\u3002";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4;
    if (section == 1) return 2;  // \u817e\u8baf\u4e91 SecretId / SecretKey
    if (section == 2) return 6;  // \u5b57\u53f7 / \u7c97\u4f53 / \u6587\u5b57\u989c\u8272 / \u80cc\u666f\u6837\u5f0f / \u8bc6\u522b\u5206\u7247 / \u663e\u793a\u82f1\u6587\u539f\u6587
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
            cell.textLabel.text = @"\u5b9e\u65f6\u5b57\u5e55\u7ffb\u8bd1";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"enabled", YES);
            [sw addTarget:self action:@selector(lc_enabledChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"\u6ce8\u5165\u76ee\u6807 App";
            // \u4e0e\u300c\u9009\u62e9\u6ce8\u5165 App\u300d\u9875\u53e3\u5f84\u4e00\u81f4\uff1a\u771f\u5b9e\u6ce8\u5165 = \u767d\u540d\u5355 \u2229 Inject Manager \u5141\u8bb8 \u2229 \u5df2\u5b89\u88c5
            NSUInteger n = [LCReallyInjectedIDs() count];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"\u5df2\u6ce8\u5165 %lu \u4e2a", (unsigned long)n];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"\u8bc6\u522b\u8bed\u8a00\uff08\u6309 App \u8bb0\u5fc6\uff09";
            cell.detailTextLabel.text = [self lc_sourceLangTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"\u7ffb\u8bd1\u6210";
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
            // v1.0.87\uff1a\u5b57\u53f7\u884c \u2192 \u70b9\u5f00\u6ed1\u5757\u9009\u62e9\u5668\uff08\u4e0d\u518d\u662f\u6570\u5b57\u952e\u76d8\u8f93\u5165\uff09
            cell.textLabel.text = @"\u5b57\u5e55\u5b57\u53f7";
            // \u9ed8\u8ba4\u503c\u4e0e tweak \u4fdd\u6301\u4e00\u81f4\uff0816\uff09\u3002\u539f\u6765\u8fd9\u91cc\u5199 28\uff0c
            // \u4e0e tweak \u5b9e\u9645\u7684\u9ed8\u8ba4 16 \u4e0d\u4e00\u81f4 \u2192 \u7528\u6237\u770b\u5230\u300c28\u300d\u4f46\u753b\u9762\u662f 16\uff0c\u8bef\u4ee5\u4e3a\u6ca1\u751f\u6548\u3002
            CGFloat fs = LCGetNum(@"fontSize", 16.0);
            if (fs < 10 || fs > 40) fs = 16.0;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", fs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"\u7c97\u4f53";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LCGetBool(@"boldText", NO);
            [sw addTarget:self action:@selector(lc_boldChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"\u6587\u5b57\u989c\u8272";
            cell.detailTextLabel.text = [self lc_colorTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"\u80cc\u666f\u6837\u5f0f";
            cell.detailTextLabel.text = [self lc_bgStyleTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 4) {
            // v1.0.84\uff1aASR \u5206\u7247\u65f6\u957f\uff08\u79d2\uff09\u2014\u2014 \u76f4\u63a5\u5f71\u54cd\u5b57\u5e55\u5ef6\u8fdf
            cell.textLabel.text = @"\u8bc6\u522b\u5206\u7247";
            double cs = LCGetNum(@"asrChunkSeconds", 2.5);
            if (cs < 1.0 || cs > 8.0) cs = 2.5;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f \u79d2", cs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            // row == 5\uff1a\u663e\u793a\u82f1\u6587\u539f\u6587
            // v1.0.82\uff1a\u9ed8\u8ba4\u53ea\u663e\u793a\u4e2d\u6587\u4e00\u884c\uff1b\u6253\u5f00\u540e\u6062\u590d\u300c\u82f1\u6587\u539f\u6587 + \u4e2d\u6587\u7ffb\u8bd1\u300d\u4e24\u884c
            cell.textLabel.text = @"\u663e\u793a\u82f1\u6587\u539f\u6587";
            UISwitch *sw = [[UISwitch alloc] init];
            // v1.0.83\uff1a\u53ea\u8ba4 showBilingual\uff08\u9ed8\u8ba4 NO = \u53ea\u663e\u793a\u4e2d\u6587\u4e00\u884c\uff09\u3002
            // \u8001\u952e showEnglish \u8bed\u4e49\u76f8\u53cd\u4e14\u4f1a\u88ab\u8986\u5199\uff0c\u5df2\u5e9f\u5f03\u4e0d\u7528\u3002
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"\u8bc6\u522b\u8bed\u8a00"
                                                                       message:@"\u9ed8\u8ba4\u503c\uff1b\u53ef\u6309 App \u8bb0\u5fc6\uff0c\u957f\u6309\u56fe\u6807\u53ef\u5feb\u901f\u5207\u6362"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *items = @[@"\u82f1\u8bed en-US", @"\u65e5\u8bed ja-JP", @"\u97e9\u8bed ko-KR", @"\u4e2d\u6587 zh-CN"];
        for (NSString *s in items) {
            [alert addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                NSString *code = [s componentsSeparatedByString:@" "].lastObject;
                LCSet(code, @"sourceLang");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"\u53d6\u6d88" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 0 && indexPath.row == 3) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"\u7ffb\u8bd1\u6210"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *items = @[@"\u7b80\u4f53\u4e2d\u6587 zh-Hans", @"\u7e41\u4f53\u4e2d\u6587 zh-Hant", @"\u82f1\u8bed en"];
        for (NSString *s in items) {
            [alert addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                LCSet([s componentsSeparatedByString:@" "].lastObject, @"targetLang");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"\u53d6\u6d88" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 1) {
        NSString *key = nil, *title = nil, *cur = nil, *ph = nil;
        BOOL secure = NO;
        if (indexPath.row == 0) { key = @"tencentSecretId"; title = @"SecretId"; cur = LCStr(key, @""); ph = @"AKID..."; }
        else { key = @"tencentSecretKey"; title = @"SecretKey"; cur = LCStr(key, @""); ph = @"\u817e\u8baf\u4e91 API \u5bc6\u94a5\u7ba1\u7406"; secure = YES; }

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
        [alert addAction:[UIAlertAction actionWithTitle:@"\u53d6\u6d88" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"\u786e\u5b9a" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *v = alert.textFields.firstObject.text;
            if (v == nil) v = @"";
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            LCSet((v.length > 0) ? v : nil, key);
            [self.lc_tv reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 2 && indexPath.row == 0) {
        // ===== v1.0.87\uff1a\u5b57\u53f7\u9009\u62e9\u5668\uff08\u6ed1\u5757 + \u5b9e\u65f6\u9884\u89c8\uff09=====
        // \u539f\u6765\u662f\u4e00\u4e2a\u6570\u5b57\u952e\u76d8\u8f93\u5165\u6846\uff1a\u8981\u5148\u70b9\u300c\u5b57\u53f7\u300d\u2192 \u5f39\u952e\u76d8 \u2192 \u8f93\u5165 \u2192 \u786e\u5b9a\uff0c
        // \u6b65\u9aa4\u591a\u3001\u800c\u4e14\u770b\u4e0d\u5230\u6548\u679c\uff0c\u6539\u5b8c\u8fd8\u8981\u9000\u51fa App \u624d\u751f\u6548\uff08tweak \u4fa7\u8bfb\u7684\u662f\u542f\u52a8\u65f6\u7f13\u5b58\uff09\u3002
        // \u73b0\u5728\uff1a\u72ec\u7acb\u7684\u6ed1\u5757\u9875\u9762\uff0c\u62d6\u52a8\u5373\u6539\u3001\u5373\u65f6\u9884\u89c8\u3001\u5373\u65f6\u5199\u5165\uff0c
        // tweak \u4fa7\u6539\u4e3a\u5b9e\u65f6\u8bfb\u76d8 + 0.4s \u76d1\u542c \u2192 \u5b57\u5e55\u5927\u5c0f\u5f53\u573a\u53d8\u5316\uff0c\u4e0d\u7528\u91cd\u542f App\u3002
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
        // v1.0.84\uff1aASR \u5206\u7247\u65f6\u957f\u9009\u62e9
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"\u8bc6\u522b\u5206\u7247\u65f6\u957f"
                                                                       message:@"\u5206\u7247\u8d8a\u77ed\u5b57\u5e55\u5ef6\u8fdf\u8d8a\u4f4e\uff0c\u4f46\u53e5\u5b50\u8d8a\u5bb9\u6613\u88ab\u5207\u65ad"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *opts = @[@1.5, @2.5, @3.5, @5.0];
        for (NSNumber *v in opts) {
            double s = [v doubleValue];
            NSString *title = [NSString stringWithFormat:@"%.1f \u79d2%@", s,
                               (s == 2.5 ? @"\uff08\u63a8\u8350\uff09" : @"")];
            [alert addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
                LCSet(@(s), @"asrChunkSeconds");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"\u53d6\u6d88" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 2 && indexPath.row == 2) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"\u6587\u5b57\u989c\u8272"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:@"\u767d\u8272\uff08\u9ed8\u8ba4\uff09" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            LCSet(@"#FFFFFFFF", @"textColorHex");
            [self.lc_tv reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"\u81ea\u5b9a\u4e49\u989c\u8272" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.colorKey = @"textColorHex";
            UIColorPickerViewController *p = [[UIColorPickerViewController alloc] init];
            p.delegate = self;
            p.selectedColor = [self lc_colorFromHex:LCStr(@"textColorHex", @"#FFFFFFFF")] ?: [UIColor whiteColor];
            [self presentViewController:p animated:YES completion:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"\u53d6\u6d88" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 2 && indexPath.row == 3) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"\u80cc\u666f\u6837\u5f0f"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *items = @[@"\u65e0\u80cc\u666f\u63cf\u8fb9 none", @"\u534a\u900f\u660e\u9ed1 darktrans", @"\u5b9e\u9ed1 darksolid",
                           @"\u534a\u900f\u660e\u767d lighttrans", @"\u6bdb\u73bb\u7483 frost"];
        for (NSString *s in items) {
            [alert addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                LCSet([s componentsSeparatedByString:@" "].lastObject, @"backgroundStyle");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"\u53d6\u6d88" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - \u5f00\u5173

- (void)lc_enabledChanged:(UISwitch *)sw { LCSet(@(sw.on), @"enabled"); }
- (void)lc_boldChanged:(UISwitch *)sw { LCSet(@(sw.on), @"boldText"); }
- (void)lc_showEnglishChanged:(UISwitch *)sw { LCSet(@(sw.on), @"showBilingual"); }

#pragma mark - \u989c\u8272

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
