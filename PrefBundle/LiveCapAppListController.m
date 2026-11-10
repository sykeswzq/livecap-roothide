// LiveCapAppListController.m —— v2.0.0
// 注入目标 App 列表（自动扫描 + 逐个开关）
// 逻辑：LiveCap Filter/Bundles ∩ 已安装 App，独立于任何外部面板

#import <UIKit/UIKit.h>
#import "LCPrivate.h"

// v2.2.0：配置写入统一走「直接写 plist 文件」——tweak 的 freshValueForKey
// 与 LCInit 自检读的是同一路径。混用 CFPreferencesAppSynchronize 会让
// cfprefsd 用旧快照把刚写好的新键覆盖掉（面板显示开了、tweak 仍按旧值跑）。
static NSString *LCAppListConfigPath(void) {
    return LCJbRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
}

static void LCAppListSetPref(id value, NSString *key) {
    @try {
        NSString *p = LCAppListConfigPath();
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p];
        if (!d) d = [NSMutableDictionary dictionary];
        if (value) d[key] = value; else [d removeObjectForKey:key];
        [d writeToFile:p atomically:YES];
    } @catch (NSException *e) {}
}

// Filter 白名单只能决定「能不能被注入」，且要注销才生效；
// 这份 enabledBundles 让「取消勾选」在重启该 App 后立即停用，不必注销。
static void LCSaveEnabledBundles(NSArray *ids) {
    LCAppListSetPref(ids ?: @[], @"enabledBundles");
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
        NSSet *want = [NSSet setWithArray:bundles];

        // v2.2.0：逐条尝试所有候选路径；只改 Filter.Bundles，保留 plist 其它键
        // （旧实现 plist[@"Filter"] = @{@"Bundles":...} 会整体覆盖 Filter）。
        // 回读比对【内容集合】而非数量，杜绝「写到影子目录却判成功」。
        for (NSString *path in LCFilterPlistCandidates()) {
            NSMutableDictionary *plist = [NSMutableDictionary dictionary];
            NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:path];
            if (old) [plist addEntriesFromDictionary:old];
            NSMutableDictionary *filter = [NSMutableDictionary dictionary];
            if ([plist[@"Filter"] isKindOfClass:[NSDictionary class]])
                [filter addEntriesFromDictionary:plist[@"Filter"]];
            filter[@"Bundles"] = bundles;
            plist[@"Filter"] = filter;

            NSData *data = [NSPropertyListSerialization
                            dataWithPropertyList:plist
                                          format:NSPropertyListXMLFormat_v1_0
                                         options:0 error:NULL];
            if (!data.length) continue;
            if (![data writeToFile:path atomically:YES]) continue;

            NSDictionary *back = [NSDictionary dictionaryWithContentsOfFile:path];
            NSArray *bb = back[@"Filter"][@"Bundles"];
            if (![bb isKindOfClass:[NSArray class]]) continue;
            if (![[NSSet setWithArray:bb] isEqualToSet:want]) continue;

            // 面板写入后别把 Filter 变成只读，否则下次勾选会静默失败
            @try {
                [[NSFileManager defaultManager]
                    setAttributes:@{NSFilePosixPermissions: @(0666)}
                    ofItemAtPath:path error:NULL];
            } @catch (NSException *e) {}
            LCAppListSetPref(path, @"lastFilterWritePath");
            LCAppListSetPref(@YES, @"lastFilterWriteOK");
            return YES;
        }
        LCAppListSetPref(@NO, @"lastFilterWriteOK");
        return NO;
    } @catch (NSException *e) {
        LCAppListSetPref(@NO, @"lastFilterWriteOK");
        return NO;
    }
}

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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_tv reloadData];
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
    // v2.2.0：旧标题写「已注入 N 个」是假象 —— 这里只是 Filter 勾选数，
    // 真正注入还受 Dopamine Inject Manager 控制。改为如实显示勾选与写入结果。
    NSArray *filter = LCReadFilterBundles();
    NSMutableString *s = [NSMutableString stringWithFormat:
        @"已勾选 %lu 个 App", (unsigned long)filter.count];
    [s appendString:_filterWriteOK ? @" · 白名单写入成功" : @" · 白名单写入失败"];
    [s appendFormat:@" · 实际生效 %lu 个", (unsigned long)[LCReallyInjectedIDs() count]];
    return s;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 104.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    // 明确告诉用户机制限制，避免「勾了却没反应」时无从排查
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 104.0)];
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, tableView.bounds.size.width - 32, 92)];
    lb.numberOfLines = 0;
    lb.font = [UIFont systemFontOfSize:12];
    lb.textColor = [UIColor secondaryLabelColor];
    lb.text = @"新增勾选后要真正生效，需两步：\n"
             @"① Dopamine → Inject Manager 里勾选该 App；\n"
             @"② 完全杀掉目标 App 再打开（或注销设备）。\n"
             @"取消勾选：重启该 App 后立即停用，无需注销。\n"
             @"若一直显示「写入失败」，说明 Filter 路径不可写，"
             @"可在 Filza 手动改 /var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist。";
    [v addSubview:lb];
    return v;
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

    BOOL picked = [[self lc_selected] containsObject:bid];

    if (picked) {
        cell.detailTextLabel.text = @"已勾选注入";
        cell.detailTextLabel.textColor = [UIColor systemGreenColor];
    } else {
        cell.detailTextLabel.text = @"未勾选";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
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
        NSArray *picked = [[[self lc_selected] allObjects]
                           sortedArrayUsingSelector:@selector(compare:)];
        _filterWriteOK = LCWriteFilterBundles(picked);
        // 运行时白名单：取消勾选无需注销即可停用（tweak 启动自检读这个键）
        LCSaveEnabledBundles(picked);
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
