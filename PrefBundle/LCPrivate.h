// LCPrivate.h —— 手动声明系统私有类（Preferences 框架 / 应用列表）
// 编译设置面板 bundle 时用 -undefined dynamic_lookup，符号运行时由「设置」App 提供。
// 范式：完全对齐 XL-Roothide —— 主控制器继承 PSViewController + 手写 UITableView，
// 不再使用 PSListController / specifiers / Root.plist（iOS 26 SDK 下该链路不可靠）。
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <mach-o/dyld.h>

#pragma mark - Preferences 私有类

// PSListController push detail 控制器时会调用 setRootController:/setParentController:，
// 普通 UIViewController 没有这些方法 → unrecognized selector 闪退。补齐注入点。
@interface PSViewController : UIViewController
- (void)setRootController:(id)rootController;
- (void)setParentController:(id)parentController;
- (id)rootController;
- (id)parentController;
@end

#pragma mark - 列出已安装 App

@interface LSApplicationProxy : NSObject
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
@end

#pragma mark - 注入判定（真实注入 = LiveCap 白名单 ∩ roothide 白名单 ∩ 已安装）
//
// 依据（已在设备实测确认）：
//   · LiveCap 白名单  = /var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist → Filter/Bundles
//   · roothide 白名单 = /var/mobile/Library/RootHide/cn.zqbb.inject.plist（XL-Roothide 面板管理）
//   · 真正被注入的 App = LiveCap 白名单 ∩ roothide 白名单 ∩ 设备上已安装的 App
// 用户通过 XL-Roothide 面板勾选 App，roothide 白名单机制决定注入

// roothide: /var/jb 是符号链接，jbroot() 可把 jbroot 路径转成真实 rootfs 路径
static inline NSString *LCJbRootPath(NSString *path) {
    @try {
        void *sym = dlsym(RTLD_DEFAULT, "jbroot");
        if (sym) {
            typedef const char *(*fn_t)(const char *);
            fn_t fn = (fn_t)sym;
            const char *r = fn([path UTF8String]);
            if (r && r[0]) return [NSString stringWithUTF8String:r];
        }
    } @catch (NSException *e) {}
    return path;
}

// 注入 filter plist 路径：从已加载的 dylib / bundle 路径反推 jbroot
static inline NSString *LCFilterPlistPath(void) {
    @try {
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *p = _dyld_get_image_name(i);
            if (!p || !p[0]) continue;
            NSString *s = [NSString stringWithUTF8String:p];
            for (NSString *needle in @[
                @"/usr/lib/TweakInject/LiveCap.dylib",
                @"/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib",
                @"/Library/PreferenceBundles/LiveCapPrefs.bundle"]) {
                NSRange r = [s rangeOfString:needle];
                if (r.location != NSNotFound) {
                    NSString *jb = [s substringToIndex:r.location];
                    return [jb stringByAppendingPathComponent:
                        @"Library/MobileSubstrate/DynamicLibraries/LiveCap.plist"];
                }
            }
        }
        const char *e = getenv("JBROOT");
        if (e && e[0]) {
            return [[NSString stringWithUTF8String:e] stringByAppendingPathComponent:
                @"Library/MobileSubstrate/DynamicLibraries/LiveCap.plist"];
        }
    } @catch (NSException *e) {}
    return nil;
}

// LiveCap 白名单（用户在设置里勾选的 bundle）
static inline NSArray *LCReadFilterBundles(void) {
    @try {
        NSString *p = LCFilterPlistPath();
        if (p.length == 0) return @[];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        id b = d[@"Filter"][@"Bundles"];
        if ([b isKindOfClass:[NSArray class]]) return b;
    } @catch (NSException *e) {}
    return @[];
}

// roothide 白名单允许列表：决定某个 App 是否真的会被注入
// 载体文件：/var/mobile/Library/RootHide/cn.zqbb.inject.plist（XL-Roothide 面板管理）
// 格式：dict<executableName:bool>，如 @"YouTube": @(YES)
// 注意：key 是执行名（Executable Name），不是 bundle ID；需要映射关系来判断
// 如果文件不存在，返回 nil 表示"不强制 roothide 白名单"
static inline NSDictionary *LCReadXLRootHideWhitelist(void) {
    @try {
        NSArray *paths = @[
            @"/var/mobile/Library/RootHide/cn.zqbb.inject.plist",
            @"/var/jb/var/mobile/Library/RootHide/cn.zqbb.inject.plist",
        ];
        for (NSString *p in paths) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            if (d.count == 0) continue;
            return d;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 判断 bundle ID 是否在 roothide 白名单中
// 策略：按 . 拆分 bid，取最后一节作为 executable 候选；再尝试常见映射
static inline BOOL LCBidInXLWhitelist(NSString *bid) {
    @try {
        NSDictionary *xl = LCReadXLRootHideWhitelist();
        if (!xl || xl.count == 0) return YES;  // 无白名单文件 → 不过滤
        // 取 bundle ID 最后一节（通常是 executable 名）
        NSString *last = [[bid componentsSeparatedByString:@"."] lastObject];
        if ([xl objectForKey:last] != nil) return [xl[last] boolValue];
        // 尝试常见映射：YouTube → com.google.ios.youtube, Animoji 等
        // 使用静态指针 + dispatch_once 确保只初始化一次
        static dispatch_once_t onceToken;
        static NSDictionary *BID_TO_EXEC = nil;
        dispatch_once(&onceToken, ^{
            BID_TO_EXEC = @{
                @"com.google.ios.youtube":          @"YouTube",
                @"com.ss.android.ugc.aweme":        @"Aweme",
                @"com.miHoYo.Yuanshen":            @"Yuanshen",
                @"com.miHoYo.GenshinImpact":       @"GstarCAD",  // placeholder - no match likely
                @"com.tencent.jkchess":            @"jkchess",
                @"com.miHoYo.hkrpg":               @"hkrpg",
                @"com.tencent.xin":                @"WeChat",
                @"com.alipay.ip":                  @"AlipayWallet",
            };
        });
        NSString *exec = BID_TO_EXEC[bid];
        if (exec && [xl objectForKey:exec] != nil) return [xl[exec] boolValue];
        // 默认放行（不过滤）
        return YES;
    } @catch (NSException *e) { return YES; }
}

// 设备上已安装的 bundle id
static inline NSSet *LCInstalledAppIDs(void) {
    NSMutableSet *out = [NSMutableSet set];
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) return out;
        id ws = [wsClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        if (!ws) return out;

        SEL atlSel  = NSSelectorFromString(@"atl_allInstalledApplications");
        SEL allISel = NSSelectorFromString(@"allInstalledApplications");
        SEL allSel  = NSSelectorFromString(@"allApplications");

        NSArray *proxies = nil;
        if ([ws respondsToSelector:atlSel]) proxies = [ws performSelector:atlSel];
        if (![proxies isKindOfClass:[NSArray class]] || proxies.count == 0)
            if ([ws respondsToSelector:allISel]) proxies = [ws performSelector:allISel];
        if (![proxies isKindOfClass:[NSArray class]] || proxies.count == 0)
            if ([ws respondsToSelector:allSel]) proxies = [ws performSelector:allSel];
        if (![proxies isKindOfClass:[NSArray class]]) return out;

        for (id proxy in proxies) {
            @try {
                id v = [proxy valueForKey:@"bundleIdentifier"];
                if (![v isKindOfClass:[NSString class]] || !((NSString *)v).length)
                    v = [proxy valueForKey:@"applicationIdentifier"];
                if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length)
                    [out addObject:(NSString *)v];
            } @catch (NSException *e) { continue; }
        }
    } @catch (NSException *e) {}
    return out;
}

// 真正会被注入 LiveCap 的 bundle 集合
// 逻辑：以 XL Roohhide 白名单为主（有则用它），否则用 LiveCap Filter/Bundles
static inline NSSet *LCReallyInjectedIDs(void) {
    NSMutableSet *out = [NSMutableSet set];
    @try {
        NSDictionary *xl = LCReadXLRootHideWhitelist();
        NSSet *installed = LCInstalledAppIDs();

        if (xl && xl.count > 0) {
            // XL 白名单模式：遍历已安装 App，检查是否在白名单里
            for (id b in installed) {
                if (![b isKindOfClass:[NSString class]]) continue;
                NSString *bid = (NSString *)b;
                if (!bid.length) continue;
                if ([bid hasSuffix:@".disabled"]) continue;
                if (LCBidInXLWhitelist(bid)) [out addObject:bid];
            }
        } else {
            // 无 XL 白名单时回退到 LiveCap Filter 模式
            for (id b in LCReadFilterBundles()) {
                if (![b isKindOfClass:[NSString class]]) continue;
                NSString *bid = (NSString *)b;
                if (!bid.length) continue;
                if ([bid hasSuffix:@".disabled"]) continue;
                if (![installed containsObject:bid]) continue;
                [out addObject:bid];
            }
        }
    } @catch (NSException *e) {}
    return out;
}
