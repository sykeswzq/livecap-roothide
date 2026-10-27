// LCPrivate.h —— 手动声明系统私有类（Preferences 框架 / 应用列表）
// 编译设置面板 bundle 时用 -undefined dynamic_lookup，符号运行时由「设置」App 提供。
#import <UIKit/UIKit.h>

#pragma mark - Preferences 私有类

// 面板控制器继承 PSViewController：
// PSListController push detail 控制器时会调用 setRootController:/setParentController:，
// 普通 UIViewController 没有这些方法 → unrecognized selector 闪退。补齐注入点。
@interface PSViewController : UIViewController
- (void)setRootController:(id)rootController;
- (void)setParentController:(id)parentController;
- (id)rootController;
- (id)parentController;
@end

// 主面板控制器（Root.plist 入口）继承 PSListController
@interface PSListController : UITableViewController
@property (nonatomic, retain) id specifiers;
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

#pragma mark - 列出已安装 App

@interface LSApplicationProxy : NSObject
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
@end
