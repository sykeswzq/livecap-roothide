// LiveCapColorController.m - 文字颜色自定义（参考 XL-Roothide 下拉时间：系统取色器 + hex 存储）
#import <UIKit/UIKit.h>
#import "LCPrivate.h"
#import <dlfcn.h>

static NSString *LCPrefsFile(void) {
    @try {
        void *sym = dlsym(RTLD_DEFAULT, "jbroot");
        if (sym) {
            typedef const char *(*fn_t)(const char *);
            fn_t fn = (fn_t)sym;
            const char *r = fn("/var/mobile/Library/Preferences/com.sykes.livecap.plist");
            if (r && r[0]) return [NSString stringWithUTF8String:r];
        }
    } @catch (NSException *e) {}
    return @"/var/mobile/Library/Preferences/com.sykes.livecap.plist";
}

static id LCValue(NSString *key) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:LCPrefsFile()];
        if (d && d[key] != nil) return d[key];
    } @catch (NSException *e) {}
    return nil;
}

static void LCSetValue(NSString *key, id value) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:LCPrefsFile()] ?: [NSMutableDictionary dictionary];
        if (value) d[key] = value; else [d removeObjectForKey:key];
        [d writeToFile:LCPrefsFile() atomically:YES];
    } @catch (NSException *e) {}
    // 同步 cfprefsd，避免面板/tweak 读到旧缓存
    @try {
        if (value) CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR("com.sykes.livecap"));
        else CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, CFSTR("com.sykes.livecap"));
        CFPreferencesAppSynchronize(CFSTR("com.sykes.livecap"));
    } @catch (NSException *e) {}
}

@interface LiveCapColorController : PSViewController <UITableViewDataSource, UITableViewDelegate, UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) UIView *swatch;
@end

@implementation LiveCapColorController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"文字颜色";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    [self.view addSubview:table];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    cell.textLabel.text = @"文字颜色";
    UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    sw.layer.cornerRadius = 13;
    sw.layer.borderColor = [UIColor separatorColor].CGColor;
    sw.layer.borderWidth = 1;
    sw.backgroundColor = [self currentColor];
    cell.accessoryView = sw;
    _swatch = sw;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 参考 XL-Roothide 下拉时间：点开弹「白色（默认）/自定义颜色」两个选项
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"文字颜色"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"白色（默认）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCSetValue(@"textColorHex", @"#FFFFFFFF");
        _swatch.backgroundColor = [UIColor whiteColor];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"自定义颜色" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIColorPickerViewController *p = [[UIColorPickerViewController alloc] init];
        p.supportsAlpha = YES;
        p.selectedColor = [self currentColor];
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UIColor *)currentColor {
    NSString *hex = LCValue(@"textColorHex");
    UIColor *c = [self colorFromHex:hex];
    return c ?: [UIColor whiteColor];
}

- (UIColor *)colorFromHex:(NSString *)hex {
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
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF)/255.0
                           green:((rgb >> 8) & 0xFF)/255.0
                            blue:(rgb & 0xFF)/255.0 alpha:a];
}

- (NSString *)hexFromColor:(UIColor *)color {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return @"#FFFFFFFF";
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X",
            (int)(r*255), (int)(g*255), (int)(b*255), (int)(a*255)];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)picker didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    LCSetValue(@"textColorHex", [self hexFromColor:color]);
    _swatch.backgroundColor = color;
}

@end
