// LiveCapAppListController.m —— v2.2.1
// 注入目标 App 列表（自动扫描 + 逐个开关）
//
// 对齐 XL-Roothide（sykeswzq/XL-Roothide）已验证可用的成熟实现：
//   ① 勾选状态真相放在【偏好 plist】的 selectedApps（XL 用 apps 键），
//      不再从 Filter plist 回读。roothide 下 Filter 路径在「设置」进程里
//      不稳定，回读为空时面板显示全部未勾选，用户勾 1 个就把打包时的
//      默认 bundle 列表抹成 1 个 —— 正是「选其他 App 无效」的根因。
//   ② 写偏好 = 直接写 plist 文件 + notify_post（XL 的 XLSetValue 同理）。
//      LiveCap 的 tweak 是实时读盘（LCConfig freshValueForKey），不走
//      CFPreferences，故刻意不调 CFPreferencesAppSynchronize：cfprefsd 的
//      旧快照会反向覆盖刚写好的文件（v2.2.0 踩过这个坑）。
//   ③ Filter.Bundles 只是「注入声明」，写完必须立刻 killall runningboardd
//      刷新注入框架缓存（XL 在 XLWriteFilterBundles 里 posix_spawn 做），
//      否则改了 plist 也要注销才生效。
//   ④ 所有候选 Filter 路径都同步写，不因某条影子路径写成就提前 return。
//   ⑤ 老配置没有 selectedApps 时从 Filter 做一次性迁移；回读为空则用
//      打包默认列表兜底，绝不丢掉原有 App。

#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import "LCPrivate.h"

static NSString *const LCAppListDomain = @"com.sykes.livecap";
static NSString *const LCAppListKey = @"selectedApps";

static NSString *LCAppListConfigPath(void) {
    return LCJbRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
}

static id LCAppListValue(NSString *key) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:LCAppListConfigPath()];
        if (d && d[key] != nil) return d[key];
    } @catch (NSException *e) {}
    @try {
        CFTypeRef c = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                (__bridge CFStringRef)LCAppListDomain);
        if (c) return CFBridgingRelease(c);
    } @catch (NSException *e) {}
    return nil;
}

// 只写文件 + 发通知；不写 CFPreferences，避免 cfprefsd 旧快照反向覆盖。
static void LCAppListSetValue(id value, NSString *key) {
    @try {
        NSString *p = LCAppListConfigPath();
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p]
                               ?: [NSMutableDictionary dictionary];
        if (value) d[key] = value; else [d removeObjectForKey:key];
        [d writeToFile:p atomically:YES];
    } @catch (NSException *e) {}
    notify_post("com.sykes.livecap.reload");
}

// 打包时 LiveCap.plist 的默认 Bundles。Filter 回读失败时用它兜底，
// 保证「全新安装 / Filter 路径不可读」时不会把已有 App 全部抹掉。
static NSArray<NSString *> *LCDefaultBundles(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"com.google.ios.youtube",
            @"com.bilibili.app.blue",
            @"com.bilibili.app.in",
            @"com.ss.android.ugc.aweme",
            @"com.google.android.youtube.kids",
            @"com.netflix.Netflix",
            @"com.hulu.plus",
            @"com.hbo.hbonow",
            @"com.amazon.avod.thirdpartyclient",
            @"com.disney.disneyplus",
            @"com.apple.tv",
            @"tv.twitch.android.app",
            @"com.google.android.youtube.music",
            @"com.baidu.iapp.video",
            @"com.iqiyi.i18n",
            @"com.iqiyi.video",
            @"com.youku.youku",
            @"com.tencent.qqlive",
            @"com.sohu.svplayer",
            @"cn.wanshizheng.pinshipin",
            @"com.apple.mobilepodcasts",
            @"com.vimeo.vimeo",
            @"com.dailymotion.dailymotion-app",
            @"com.pandora.android",
            @"com.spotify.client",
            @"com.soundcloud.android",
            @"com.tencent.tmgp.sgame",
            @"com.miHoYo.Yuushen",
        ];
    });
    return list;
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

// v2.2.13：勾选状态 = 实际注入（Filter 声明 ∩ 本机已安装 App），三处显示同口径。
// 旧版把 29 个打包默认 Bundle 落盘进 selectedApps，postinst 与 dylib 又拿它
// 重建 Filter，所以「已勾选 29 个」而实际只有装在机上的 2 个生效 —— 只改标题
// 没用，必须同时把这份脏数据对齐掉，否则下次同步又被写回 29。
- (NSMutableSet<NSString *> *)lc_selected {
    if (_selected) return _selected;
    NSArray<NSString *> *real = LCRealInjectedList();
    _selected = [NSMutableSet setWithArray:real];
    // 一次性对齐：把历史落盘的 29 个默认 Bundle 清成真实注入集合，让
    // selectedApps / enabledBundles / injectApps 与 Filter 一致。标记存在后
    // 永不再执行，之后完全以用户勾选为准（避免抹掉刚勾、Filter 还没同步的 App）。
    id flag = LCAppListValue(@"appListAlignedV213");
    if (!([flag isKindOfClass:[NSNumber class]] && [flag boolValue])) {
        NSArray *picked = [real sortedArrayUsingSelector:@selector(compare:)];
        LCAppListSetValue(picked, LCAppListKey);
        LCAppListSetValue(picked, @"enabledBundles");
        LCAppListSetValue(picked, @"injectApps");
        LCAppListSetValue(@YES, @"appListAlignedV213");
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

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_shown.count == 0) return 1;
    return (NSInteger)_shown.count;
}

// v2.2.13：只显示「实际注入」数量，不再出现与真实注入不符的 29，
// 也不带同步状态小尾巴（用户反馈界面要干净）。
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSUInteger n = [[self lc_selected] count];
    return [NSString stringWithFormat:@"实际注入 %lu 个 App", (unsigned long)n];
}

// v2.2.10：移除底部灰色小字说明块（用户反馈影响观看）。
// 同步状态已体现在分组标题末尾的「注入同步成功/失败」，无需再占一块 footer。
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 0.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return nil;
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
    cell.detailTextLabel.text = bid;   // 保留 Bundle ID，便于真机核对
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [[self lc_selected] containsObject:bid];
    sw.tag = (NSInteger)indexPath.row;
    [sw addTarget:self action:@selector(lc_switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)lc_save {
    NSArray *picked = [[[self lc_selected] allObjects]
                       sortedArrayUsingSelector:@selector(compare:)];
    // ① 真相写偏好（XL 做法），不再让 UI 状态依赖 Filter 回读
    LCAppListSetValue(picked, LCAppListKey);
    // 兼容 v2.2.0 残留键：保留同一份列表，避免回滚旧包时被运行时白名单误杀
    LCAppListSetValue(picked, @"enabledBundles");
    // ② Filter 写入交由「已注入 App 内的 dylib」代为完成（roothide 下面板无写权限）。
    //    面板只负责写偏好 + notify_post("com.sykes.livecap.reload")，
    //    由 dylib 监听后在进程内写入 Filter 并刷新注入缓存。
    //    是否成功以 dylib 回写的 lastFilterWriteOK 为准。
    id ok = LCAppListValue(@"lastFilterWriteOK");
    _filterWriteOK = [ok isKindOfClass:[NSNumber class]] ? [ok boolValue] : YES;
}

- (void)lc_switchChanged:(UISwitch *)sw {
    @try {
        NSInteger row = sw.tag;
        if (row < 0 || row >= (NSInteger)_shown.count) return;
        NSString *bid = _shown[(NSUInteger)row][@"id"];
        if (!bid) return;
        if (sw.on) [[self lc_selected] addObject:bid];
        else       [[self lc_selected] removeObject:bid];
        [self lc_save];
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
