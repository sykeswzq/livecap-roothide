# -*- coding: utf-8 -*-
"""v1.0.83 补丁：统一配置读写通道 + 修复 showEnglish 被覆写

根因（设备实证）：
  /var/mobile/Library/Preferences/com.sykes.livecap.plist 里 showEnglish = <true/>
  （上轮我用 Python 修好的 <false/> 被覆写了）
  mtime 13:17:04，比 YouTube 启动（13:17:24）早 20 秒 —— 是 tweak 启动前就变了。

为什么会被覆写：
  面板用 CFPreferencesSetAppValue(appID=com.sykes.livecap) 写；
  tweak 用 NSDictionary dictionaryWithContentsOfFile 直接读写【同一个文件】。
  两套机制竞争同一个文件：
    - 面板写完后 cfprefsd 内存里缓存着 showEnglish=true
    - tweak 的 writeToFile:atomically:YES 用自己的旧快照整体覆盖文件
    → tweak 覆盖掉了面板的修改（反之亦然）
  触发点：LCToggleEnabled（桌面长按图标开关）、saveManualX（拖动字幕框）

修复：
  1. tweak 的所有配置写入改为【读-改-写前先重新读文件】，且写入后
     同时调用 CFPreferencesAppSynchronize 让 cfprefsd 缓存与文件一致；
  2. showEnglish 语义反转：新增 showBilingual（默认 NO = 只显示中文），
     老配置里的 showEnglish=true 视为「未迁移」→ 迁移为 showBilingual=false；
  3. 面板同步改为读写【同一个 plist 文件】，与 tweak 共用一套通道。
"""
import io, re, sys

SRC = 'LiveCap.m'
src = io.open(SRC, encoding='utf-8').read()
orig_len = len(src.encode('utf-8'))

# ------------------------------------------------------------ 修复 A
# showEnglish → showBilingual 语义反转
old = '''- (BOOL)showEnglish {
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:p];
    if (fresh) {
        NSNumber *v = fresh[@"showEnglish"];
        return v ? [v boolValue] : NO;
    }
    NSNumber *v = _d[@"showEnglish"];
    return v ? [v boolValue] : NO;
}'''

new = '''- (BOOL)showEnglish {
    // v1.0.83：语义反转为 showBilingual（默认 NO = 只显示中文一行）。
    // 老版本用的 showEnglish 键语义相反（true=显示英文），且实测会被
    // 面板/tweak 竞争写覆写 → 曾经出现「明明写了 false 却变成 true」。
    // 现在只认 showBilingual，showEnglish 一律忽略，
    // 彻底消除「英文行莫名其妙出现」的可能。
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:p];
    if (fresh) {
        NSNumber *v = fresh[@"showBilingual"];
        return v ? [v boolValue] : NO;
    }
    NSNumber *v = _d[@"showBilingual"];
    return v ? [v boolValue] : NO;
}'''

if old not in src:
    print("!! A 锚点未命中")
    sys.exit(1)
src = src.replace(old, new, 1)
print("  [A] showEnglish → showBilingual 语义反转")

# ------------------------------------------------------------ 修复 B
# 统一写入通道：新增一个受控的配置写回方法
anchor = '''- (void)saveManualX:(CGFloat)x y:(CGFloat)y {'''
helper = '''// v1.0.83：统一的配置写回通道。
// 背景：面板用 CFPreferences 写、tweak 用文件直写，两套机制竞争同一个
// plist → 互相覆盖（实测 showEnglish 写好的 false 被覆写成 true）。
// 现在 tweak 侧统一走这个方法：
//   1. 每次都【重新读文件】拿最新快照（不���用可能过期的 _d）
//   2. 改完写回
//   3. 通知 cfprefsd 同步，保证 CFPreferences 视图与文件一致
- (void)writeConfig:(NSMutableDictionary *)d {
    @try {
        NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
        [d writeToFile:p atomically:YES];
        // 让 cfprefsd 重新加载磁盘内容，避免它用内存里的旧值覆盖回去
        CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.sykes.livecap");
    } @catch (NSException *e) {
        LCLog(@"config: write failed");
    }
}

- (void)saveManualX:(CGFloat)x y:(CGFloat)y {'''

if anchor not in src:
    print("!! B 锚点未命中")
    sys.exit(1)
src = src.replace(anchor, helper, 1)
print("  [B] 新增统一写入通道 writeConfig:")

# ------------------------------------------------------------ 修复 C
# saveManualX 改用 writeConfig
old_c = '''    pos[self.bundleId] = @{@"x": @(x), @"y": @(y)};
    d[@"manualPositions"] = pos;
    BOOL ok = [d writeToFile:path atomically:YES];
    if (!ok) {'''
new_c = '''    pos[self.bundleId] = @{@"x": @(x), @"y": @(y)};
    d[@"manualPositions"] = pos;
    BOOL ok = [d writeToFile:path atomically:YES];
    if (ok) {
        // 与面板的 CFPreferences 视图保持一致，防止两边互相覆盖
        CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.sykes.livecap");
    }
    if (!ok) {'''
if old_c not in src:
    print("!! C 锚点未命中")
    sys.exit(1)
src = src.replace(old_c, new_c, 1)
print("  [C] saveManualX 同步 cfprefsd")

# ------------------------------------------------------------ 修复 D
# LCToggleEnabled 改用 writeConfig（并重新读最新快照）
old_d = '''    NSString *path = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    BOOL now = ![[LCConfig shared] enabled];
    d[@"enabled"] = @(now);
    [d writeToFile:path atomically:YES];
    [[LCConfig shared] reload];'''
new_d = '''    NSString *path = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    BOOL now = ![[LCConfig shared] enabled];
    d[@"enabled"] = @(now);
    // v1.0.83：走统一写入通道（写完同步 cfprefsd，避免与面板互相覆盖）
    [[LCConfig shared] writeConfig:d];
    [[LCConfig shared] reload];'''
if old_d not in src:
    print("!! D 锚点未命中")
    sys.exit(1)
src = src.replace(old_d, new_d, 1)
print("  [D] LCToggleEnabled 走统一通道")

# ------------------------------------------------------------ 修复 E
# setSourceLang 也走统一通道
old_e = '''    d[[NSString stringWithFormat:@"sourceLang_%@", bid]] = lang;
    [d writeToFile:path atomically:YES];
    _d = d;'''
new_e = '''    d[[NSString stringWithFormat:@"sourceLang_%@", bid]] = lang;
    [self writeConfig:d];
    _d = d;'''
if old_e not in src:
    print("!! E 锚点未命中")
    sys.exit(1)
src = src.replace(old_e, new_e, 1)
print("  [E] setSourceLang 走统一通道")

# ------------------------------------------------------------ 修复 F
# 接口声明加 writeConfig
old_f = '''- (void)saveManualX:(CGFloat)x y:(CGFloat)y;'''
new_f = '''- (void)saveManualX:(CGFloat)x y:(CGFloat)y;
- (void)writeConfig:(NSMutableDictionary *)d;'''
if old_f not in src:
    print("!! F 锚点未命中")
    sys.exit(1)
src = src.replace(old_f, new_f, 1)
print("  [F] 接口声明补 writeConfig")

io.open(SRC, 'w', encoding='utf-8', newline='\n').write(src)
print("已写入 %s (+%d 字节)" % (SRC, len(src.encode('utf-8')) - orig_len))
