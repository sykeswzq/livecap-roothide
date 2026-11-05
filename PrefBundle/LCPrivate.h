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

#pragma mark - 注入判定（真实注入 = LiveCap 白名单 ∩ Inject Manager 允许 ∩ 已安装）
//
// 依据（已在设备实测确认）：
//   · LiveCap 白名单  = /var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist → Filter/Bundles
//   · Inject Manager   = /var/jb/Library/Preferences/com.dopamine2.InjectManager.plist → Whitelist（标准 bundle id）
//   · 真正被注入的 App = 上面两者交集 ∩ 设备上已安装的 App
// 三者缺一都不会生效，所以 UI 上的“已注入个数”必须按交集算，不能只数白名单。

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

// Dopamine2 Inject Manager 允许列表：决定某个 App 是否真的会被注入
// 注意：如果文件不存在（如仅用 Filza/真皮管理白名单），返回 nil 表示"不强制 InjectManager"
static inline NSArray *LCReadInjectManagerWhitelist(void) {
    @try {
        NSMutableArray *cands = [NSMutableArray array];
        const char *env = getenv("JBROOT");
        if (env && env[0]) {
            [cands addObject:[[NSString stringWithUTF8String:env]
                stringByAppendingPathComponent:@"Library/Preferences/com.dopamine2.InjectManager.plist"]];
        }
        [cands addObject:LCJbRootPath(@"/var/jb/Library/Preferences/com.dopamine2.InjectManager.plist")];
        [cands addObject:@"/var/jb/Library/Preferences/com.dopamine2.InjectManager.plist"];
        [cands addObject:@"/var/mobile/Library/Preferences/com.dopamine2.InjectManager.plist"];
        for (NSString *p in cands) {
            if (!p.length) continue;
            // 文件不存在 → 返回 nil（不强制 InjectManager）
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            id w = d[@"Whitelist"];
            if (![w isKindOfClass:[NSArray class]]) continue;
            NSMutableArray *out = [NSMutableArray array];
            for (id s in (NSArray *)w) {
                if ([s isKindOfClass:[NSString class]] && ((NSString *)s).length)
                    [out addObject:(NSString *)s];
            }
            if (out.count) return out;
        }
    } @catch (NSException *e) {}
    return nil;  // 文件不存在或为空 → 不强制 InjectManager
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
// 逻辑：LiveCap Bundle 白名单 ∩ 已安装 App
// InjectManager 白名单是可选的（仅在有 dopamin2.InjectManager.plist 时才检查）
static inline NSSet *LCReallyInjectedIDs(void) {
    NSMutableSet *out = [NSMutableSet set];
    @try {
        // InjectManager 白名单（可能为 nil，表示不强制检查）
        NSArray *white = LCReadInjectManagerWhitelist();
        NSSet *installed = LCInstalledAppIDs();
        for (id b in LCReadFilterBundles()) {
            if (![b isKindOfClass:[NSString class]]) continue;
            NSString *bid = (NSString *)b;
            if (!bid.length) continue;
            if ([bid hasSuffix:@".disabled"]) continue;   // 未勾选时的哨兵值
            // 只有 InjectManager 白名单存在且非空时，才检查是否在白名单内
            if (white && white.count > 0 && ![white containsObject:bid]) continue;
            if (![installed containsObject:bid]) continue;
            [out addObject:bid];
        }
    } @catch (NSException *e) {}
    return out;
}
