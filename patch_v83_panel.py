# -*- coding: utf-8 -*-
"""v1.0.83 面板补丁：showEnglish → showBilingual，且与 tweak 共用文件写入通道

背景：
  面板原来用 CFPreferencesSetAppValue 写 com.sykes.livecap 域，
  tweak 用文件直读写同一个 plist → 两套机制互相覆盖
  （实测 showEnglish 写好的 false 被覆写成 true → 英文行莫名出现）。

修复：
  1. 开关语义反转：showEnglish(默认NO=只中文) → showBilingual(默认NO=只中文)
     读取时【只认 showBilingual】，忽略老键，天然免疫覆写。
  2. 面板写入改为【文件直写 + CFPreferences 同步】，与 tweak 同一条通道。
  3. 开关读取也改为文件直读，保证面板显示的状态与 tweak 实际用的完全一致。
"""
import io, sys

P = 'PrefBundle/LiveCapPrefs.m'
src = io.open(P, encoding='utf-8').read()
orig = len(src.encode('utf-8'))

# ---------------------------------------------------------------- 1
old = '''static id LCGet(NSString *key) {
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
}'''

new = '''// v1.0.83：配置读写统一走【plist 文件】。
// 背景：面板原来用 CFPreferences 写、tweak 用文件直写同一个 plist，
//       两套机制互相覆盖 → 实测 showEnglish 写好的 false 被覆写成 true。
// 现在面板与 tweak 用完全相同的通道读写同一个文件，状态永远一致。
static NSString *LCConfigPath(void) {
    // 与 tweak 的 LCJBRootPath 保持一致：roothide 下需经 jbroot 解析
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sym = dlsym(RTLD_DEFAULT, "jbroot");
        NSString *path = @"/var/mobile/Library/Preferences/com.sykes.livecap.plist";
        if (sym) {
            typedef const char *(*fn_t)(const char *);
            fn_t fn = (fn_t)sym;
            @try {
                const char *real = fn([path UTF8String]);
                if (real) path = [NSString stringWithUTF8String:real];
            } @catch (NSException *e) {}
        }
        p = path;
    });
    return p;
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
}'''

if old not in src:
    print("!! 1 锚点未命中")
    sys.exit(1)
src = src.replace(old, new, 1)
print("  [1] 面板配置读写改为文件直读（与 tweak 同通道）")

# ---------------------------------------------------------------- 2
old2 = '''            cell.textLabel.text = @"显示英文原文";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [(NSNumber *)LCGet(@"showEnglish") boolValue];
            [sw addTarget:self action:@selector(lc_showEnglishChanged:) forControlEvents:UIControlEventValueChanged];'''
new2 = '''            cell.textLabel.text = @"显示英文原文";
            UISwitch *sw = [[UISwitch alloc] init];
            // v1.0.83：只认 showBilingual（默认 NO = 只显示中文一行）。
            // 老键 showEnglish 语义相反且会被覆写，已废弃不用。
            sw.on = [(NSNumber *)LCGet(@"showBilingual") boolValue];
            [sw addTarget:self action:@selector(lc_showEnglishChanged:) forControlEvents:UIControlEventValueChanged];'''
if old2 not in src:
    print("!! 2 锚点未命中")
    sys.exit(1)
src = src.replace(old2, new2, 1)
print("  [2] 面板开关读 showBilingual")

# ---------------------------------------------------------------- 3
old3 = '''- (void)lc_showEnglishChanged:(UISwitch *)sw { LCSet(@(sw.on), @"showEnglish"); }'''
new3 = '''- (void)lc_showEnglishChanged:(UISwitch *)sw { LCSet(@(sw.on), @"showBilingual"); }'''
if old3 not in src:
    print("!! 3 锚点未命中")
    sys.exit(1)
src = src.replace(old3, new3, 1)
print("  [3] 面板开关写 showBilingual")

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("已写入 %s (+%d 字节)" % (P, len(src.encode('utf-8')) - orig))
