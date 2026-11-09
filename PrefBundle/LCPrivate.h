// LCPrivate.h —— v2.0.0 精简版
// 手动声明系统私有类（Preferences 框架 / 应用列表）
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <mach-o/dyld.h>

#pragma mark - Preferences 私有类

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

#pragma mark - 注入判定（LiveCap Filter ∩ 已安装，完全不依赖外部面板）

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

static inline NSSet *LCReallyInjectedIDs(void) {
    NSMutableSet *out = [NSMutableSet set];
    @try {
        NSSet *installed = LCInstalledAppIDs();
        for (id b in LCReadFilterBundles()) {
            if (![b isKindOfClass:[NSString class]]) continue;
            NSString *bid = (NSString *)b;
            if (!bid.length) continue;
            if ([bid hasSuffix:@".disabled"]) continue;
            if (![installed containsObject:bid]) continue;
            [out addObject:bid];
        }
    } @catch (NSException *e) {}
    return out;
}
