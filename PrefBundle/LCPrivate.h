// LCPrivate.h —— 手动声明系统私有类（Preferences 框架 / 应用列表）
// 编译设置面板 bundle 时用 -undefined dynamic_lookup，符号运行时由「设置」App 提供。
// 范式：完全对齐 XL-Roothide —— 主控制器继承 PSViewController + 手写 UITableView，
// 不再使用 PSListController / specifiers / Root.plist（iOS 26 SDK 下该链路不可靠）。
#import <UIKit/UIKit.h>

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
