// LiveCapAppListController.m —— 注入目标 App 列表（搜索框 + 逐个开关）
// 改编自 XL-Roothide 的 XLAppListController：勾选直接改写注入 filter plist（LiveCap.plist），注销/重启 App 生效
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <mach-o/dyld.h>
#import "LCPrivate.h"

#pragma mark - jbroot + filter 路径（自包含，不依赖 XLCommon）

static NSString *LCAppID = @"com.sykes.livecap";

static void LCSetPref(id value, NSString *key) {
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
}

static NSString *LCJbRootPath(NSString *path) {
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

static NSString *LCFilterPlistPath(void) {
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

static NSArray *LCReadFilterBundles(void) {
    @try {
        NSString *p = LCFilterPlistPath();
        if (p.length == 0) return @[];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        id b = d[@"Filter"][@"Bundles"];
        if ([b isKindOfClass:[NSArray class]]) return b;
    } @catch (NSException *e) {}
    return @[];
}

static BOOL LCWriteFilterBundles(NSArray *raw) {
    @try {
        NSMutableArray *bundles = [NSMutableArray array];
        for (id b in raw) {
            if (![b isKindOfClass:[NSString class]]) continue;
            NSString *bid = (NSString *)b;
            if (bid.length == 0) continue;
            if ([bid isEqualToString:@"com.apple.springboard"]) continue;
            if ([bid hasPrefix:@"com.apple."]) continue;
            [bundles addObject:bid];
        }
        if (bundles.count == 0) bundles = [@[@"com.sykes.livecap.disabled"] mutableCopy];

        NSString *path = LCFilterPlistPath();
        if (path.length == 0) return NO;

        NSMutableDictionary *plist = [NSMutableDictionary dictionary];
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:path];
        if (old) [plist addEntriesFromDictionary:old];
        plist[@"Filter"] = @{@"Bundles": bundles};

        NSData *data = [NSPropertyListSerialization
                        dataWithPropertyList:plist
                                      format:NSPropertyListXMLFormat_v1_0
                                     options:0 error:NULL];
        if (!data.length) return NO;
        if (![data writeToFile:path atomically:YES]) return NO;

        NSArray *back = LCReadFilterBundles();
        @try {
            pid_t pid;
            const char *argv[] = {"/usr/bin/killall", "runningboardd", NULL};
            posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
            waitpid(pid, NULL, 0);
        } @catch (NSException *e2) {}
        return (back.count == bundles.count);
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - 控制器

@interface LiveCapAppListController : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation LiveCapAppListController {
    UITableView *_tv;
    UISearchBar *_searchBar;
    NSArray<NSDictionary *> *_allApps;
    NSArray<NSDictionary *> *_shown;
    NSMutableSet<NSString *> *_selected;
    BOOL _filterWriteOK;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择注入 App";
    _filterWriteOK = YES;

    if (!(self.navigationController && self.navigationController.viewControllers.count > 1)) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(lc_close)];
    }

    CGRect b = self.view.bounds;
    if (b.size.width <= 0) b = CGRectMake(0, 0, 375, 667);

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 44.0)];
    _searchBar.placeholder = @"搜索 App 名称或 Bundle ID";
    _searchBar.delegate = self;
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 44.0)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.backgroundColor = [UIColor systemBackgroundColor];
    [header addSubview:_searchBar];

    _tv = [[UITableView alloc] initWithFrame:b style:UITableViewStylePlain];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.dataSource = self;
    _tv.delegate = self;
    _tv.tableHeaderView = header;
    [self.view addSubview:_tv];

    [self lc_filter:_searchBar.text ?: @""];
    [_tv reloadData];
}

- (NSMutableSet<NSString *> *)lc_selected {
    if (_selected) return _selected;
    _selected = [NSMutableSet set];
    for (NSString *b in LCReadFilterBundles()) {
        if ([b isKindOfClass:[NSString class]] && b.length) [_selected addObject:b];
    }
    return _selected;
}

- (NSArray<NSDictionary *> *)lc_allApps {
    if (_allApps) return _allApps;
    _allApps = [self lc_loadApps];
    return _allApps ?: @[];
}

- (NSArray<NSDictionary *> *)lc_loadApps {
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) return @[];
        id ws = [wsClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        if (!ws) return @[];

        SEL atlSel  = NSSelectorFromString(@"atl_allInstalledApplications");
        SEL allISel = NSSelectorFromString(@"allInstalledApplications");
        SEL allSel  = NSSelectorFromString(@"allApplications");

        NSArray *proxies = nil;
        if ([ws respondsToSelector:atlSel]) proxies = [ws performSelector:atlSel];
        if (![proxies isKindOfClass:[NSArray class]] || proxies.count == 0)
            if ([ws respondsToSelector:allISel]) proxies = [ws performSelector:allISel];
        if (![proxies isKindOfClass:[NSArray class]] || proxies.count == 0)
            if ([ws respondsToSelector:allSel]) proxies = [ws performSelector:allSel];
        if (![proxies isKindOfClass:[NSArray class]]) return @[];

        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        for (id proxy in proxies) {
            @try {
                NSString *bid = nil, *name = nil;
                BOOL system = NO;
                id v = [proxy valueForKey:@"bundleIdentifier"];
                if ([v isKindOfClass:[NSString class]]) bid = v;
                if (bid.length == 0) {
                    v = [proxy valueForKey:@"applicationIdentifier"];
                    if ([v isKindOfClass:[NSString class]]) bid = v;
                }
                v = [proxy valueForKey:@"localizedName"];
                if ([v isKindOfClass:[NSString class]]) name = v;
                if (name.length == 0) name = bid;
                if (bid.length == 0) continue;

                v = [proxy valueForKey:@"applicationType"];
                if ([v isKindOfClass:[NSString class]])
                    system = ![(NSString *)v isEqualToString:@"User"];
                else {
                    v = [proxy valueForKey:@"isSystemApplication"];
                    if ([v respondsToSelector:@selector(boolValue)]) system = [v boolValue];
                }
                [out addObject:@{@"id": bid, @"name": name, @"system": @(system)}];
            } @catch (NSException *e) { continue; }
        }
        [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name"
                                                                   ascending:YES
                                                                    selector:@selector(localizedCaseInsensitiveCompare:)]]];
        return out;
    } @catch (NSException *e) { return @[]; }
}

- (void)lc_filter:(NSString *)text {
    NSString *q = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *app in [self lc_allApps]) {
        if (q.length > 0) {
            NSString *name = app[@"name"] ?: @"";
            NSString *bid  = app[@"id"]   ?: @"";
            if ([name rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [bid  rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        [out addObject:app];
    }
    _shown = out;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    @try { [self lc_filter:searchText]; [_tv reloadData]; } @catch (NSException *e) {}
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    @try { [searchBar resignFirstResponder]; } @catch (NSException *e) {}
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    @try { [_searchBar resignFirstResponder]; } @catch (NSException *e) {}
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_shown.count == 0) return 1;
    return (NSInteger)_shown.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSUInteger n = (unsigned long)[[self lc_selected] count];
    NSString *s = [NSString stringWithFormat:@"已选 %lu 个 App（勾选后完全退出目标 App 再打开生效）", (unsigned long)n];
    if (n > 0) {
        s = _filterWriteOK ? [s stringByAppendingString:@" · 注入配置已写入"]
                           : [s stringByAppendingString:@" · 写入注入配置失败"];
    }
    return s;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const ID = @"LCAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (_shown.count == 0) {
        cell.textLabel.text = @"未找到匹配的 App";
        cell.detailTextLabel.text = nil;
        cell.accessoryView = nil;
        return cell;
    }

    NSDictionary *app = _shown[(NSUInteger)indexPath.row];
    NSString *bid = app[@"id"];
    cell.textLabel.text = app[@"name"] ?: bid;
    cell.detailTextLabel.text = bid;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [[self lc_selected] containsObject:bid];
    sw.tag = (NSInteger)indexPath.row;
    [sw addTarget:self action:@selector(lc_switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)lc_switchChanged:(UISwitch *)sw {
    @try {
        NSInteger row = sw.tag;
        if (row < 0 || row >= (NSInteger)_shown.count) return;
        NSString *bid = _shown[(NSUInteger)row][@"id"];
        if (!bid) return;
        if (sw.on) [[self lc_selected] addObject:bid];
        else       [[self lc_selected] removeObject:bid];
        _filterWriteOK = LCWriteFilterBundles(
            [[[self lc_selected] allObjects] sortedArrayUsingSelector:@selector(compare:)]);
        LCSetPref([[[self lc_selected] allObjects] sortedArrayUsingSelector:@selector(compare:)],
                  @"injectApps");
        [_tv reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    } @catch (NSException *e) {}
}

- (void)lc_close {
    @try {
        if (self.navigationController && self.navigationController.viewControllers.count > 1)
            [self.navigationController popViewControllerAnimated:YES];
        else
            [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *e) {}
}

@end
