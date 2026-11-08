// LiveCapAppListController.m \u2014\u2014 \u6ce8\u5165\u76ee\u6807 App \u5217\u8868\uff08\u641c\u7d22\u6846 + \u9010\u4e2a\u5f00\u5173\uff09
// \u6539\u7f16\u81ea XL-Roothide \u7684 XLAppListController\uff1a\u52fe\u9009\u76f4\u63a5\u6539\u5199\u6ce8\u5165 filter plist\uff08LiveCap.plist\uff09\uff0c\u6ce8\u9500/\u91cd\u542f App \u751f\u6548
// \u8868\u5934\u7684"\u5df2\u6ce8\u5165\u4e2a\u6570"\u6309\u771f\u5b9e\u6ce8\u5165\u96c6\u5408\u7b97\uff1aLiveCap \u767d\u540d\u5355 \u2229 roothide \u767d\u540d\u5355 \u2229 \u5df2\u5b89\u88c5
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <mach-o/dyld.h>
#import "LCPrivate.h"

#pragma mark - filter \u5199\u5165\uff08\u8def\u5f84/\u8bfb\u53d6\u5b9e\u73b0\u89c1 LCPrivate.h\uff09

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
        // \u4e0d\u5728\u6b64\u5904\u81ea\u52a8 killall runningboardd\uff08\u90a3\u7b49\u540c\u4e8e\u81ea\u52a8\u6ce8\u9500\uff09\uff1a\u7531\u7528\u6237\u624b\u52a8\u6ce8\u9500\u540e\u751f\u6548
        return (back.count == bundles.count);
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - \u63a7\u5236\u5668

@interface LiveCapAppListController : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation LiveCapAppListController {
    UITableView *_tv;
    UISearchBar *_searchBar;
    NSArray<NSDictionary *> *_allApps;
    NSArray<NSDictionary *> *_shown;
    NSMutableSet<NSString *> *_selected;
    NSArray<NSString *> *_injectWhite;
    BOOL _filterWriteOK;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
}

- (NSArray<NSString *> *)lc_injectWhitelist {
    // 返回空数组表示"不强制 roothide 白名单检查"，实际判断由 LCBidInXLWhitelist 完成
    return @[];
}

// roothide \u767d\u540d\u5355\u53ef\u80fd\u88ab roothide \u9762\u677f\u6539\u8fc7\uff0c\u56de\u5230\u672c\u9875\u65f6\u91cd\u65b0\u8bfb\u53d6
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _injectWhite = nil;
    [_tv reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"\u9009\u62e9\u6ce8\u5165 App";
    _filterWriteOK = YES;

    if (!(self.navigationController && self.navigationController.viewControllers.count > 1)) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"\u5b8c\u6210"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(lc_close)];
    }

    CGRect b = self.view.bounds;
    if (b.size.width <= 0) b = CGRectMake(0, 0, 375, 667);

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 44.0)];
    _searchBar.placeholder = @"\u641c\u7d22 App \u540d\u79f0\u6216 Bundle ID";
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
    // 真实注入集合 = LiveCap 白名单 ∩ XL Roohhide 白名单 ∩ 已安装
    NSArray *filter = LCReadFilterBundles();
    NSUInteger realN = [LCReallyInjectedIDs() count];

    NSDictionary *xlWhitelist = LCReadXLRootHideWhitelist();
    NSUInteger xlCount = xlWhitelist ? xlWhitelist.count : 0;

    NSMutableString *s = [NSMutableString stringWithFormat:@"已注入 %lu 个 App", (unsigned long)realN];
    if (xlWhitelist && xlWhitelist.count > 0) {
        [s appendFormat:@"（勾选 %lu · XL Roohhide 白名单 %lu）",
                       (unsigned long)filter.count, (unsigned long)xlCount];
    } else {
        [s appendFormat:@"（勾选 %lu · 未检测到 XL Roohhide 白名单）",
                       (unsigned long)filter.count];
    }
    [s appendString:@" · 注销后生效"];
    if (!_filterWriteOK)
        [s appendString:@" · 写入注入配置失败"];
    return s;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const ID = @"LCAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (_shown.count == 0) {
        cell.textLabel.text = @"\u672a\u627e\u5230\u5339\u914d\u7684 App";
        cell.detailTextLabel.text = nil;
        cell.accessoryView = nil;
        return cell;
    }

    NSDictionary *app = _shown[(NSUInteger)indexPath.row];
    NSString *bid = app[@"id"];
    cell.textLabel.text = app[@"name"] ?: bid;
    cell.detailTextLabel.text = bid;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    BOOL picked = [[self lc_selected] containsObject:bid];

    // \u6807\u6ce8\u662f\u5426\u771f\u4f1a\u6ce8\u5165\uff1a\u9700\u540c\u65f6\u6ee1\u8db3\u300c\u5df2\u52fe\u9009\u300d+\u300croothide \u767d\u540d\u5355\u300d\uff0c\u5426\u5219\u4e0d\u4f1a\u88ab\u6ce8\u5165
    NSArray<NSString *> *white = [self lc_injectWhitelist];
    if (white.count > 0 && bid.length) {
        BOOL allowed = [white containsObject:bid];
        if (picked && !allowed) {
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%@ \u00b7 \u672a\u8fdb roothide \u767d\u540d\u5355\uff0c\u4e0d\u4f1a\u6ce8\u5165", bid];
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else if (!picked && allowed) {
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%@ \u00b7 roothide \u767d\u540d\u5355\u5df2\u542b\uff0c\u672a\u52fe\u9009", bid];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
    } else {
        // roothide \u767d\u540d\u5355\u4e0d\u5b58\u5728 \u2192 \u53ea\u4f9d\u8d56 LiveCap Bundle \u767d\u540d\u5355
        if (!picked) {
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%@ \u00b7 \u672a\u52fe\u9009\uff08\u9700\u5728\u8bbe\u7f6e\u9762\u677f\u52fe\u9009\uff09", bid];
        }
    }

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = picked;
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
