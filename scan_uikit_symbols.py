#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""系统性排查：不存在的 UIKit 符号

v1.0.84 在 CI 上栽了一轮：
  LiveCap.m:1796: error: use of undeclared identifier
  'UIWindowDidChangeFrameNotification'

教训：本地「括号配平 + 括号类型」扫描查不出【符号不存在】这类错误。
本次把 LiveCap.m 里用到的全部 UIKit 符号提取出来，
对照一份【已知存在的 UIKit 符号白名单】做交叉比对，
把同类错误一次性挖出来，而不是等 CI 逐个报。

白名单来源：UIKit 公开 API 的常见符号 + 已在项目里成功编译过的符号。
"""
import io
import os
import re
import sys

SRC = "LiveCap.m"
# v2.2.17：CI Run 43445056817 在【面板】里写出 UITextFieldBorderStyleRoundedRect
# （不存在的枚举，正确的是 UITextBorderStyleRoundedRect）导致编译失败。
# 原来只扫 LiveCap.m，面板是盲区；现在把两个面板源码一起纳入白名单交叉检查。
PANEL_SRCS = ("PrefBundle/LiveCapPrefs.m",
              "PrefBundle/LiveCapAppListController.m")

# 已确认存在于 UIKit 的符号（框架/类/常量/通知/函数）
KNOWN = set("""
UIApplication UIWindow UIView UILabel UIButton UIColor UIFont UIScreen UIScene
UIWindowScene UIViewController UIWindowScene UITraitCollection
UIEvent UIControl UIGestureRecognizer UIPanGestureRecognizer UITapGestureRecognizer
UILongPressGestureRecognizer UIImageView UIImage UIColor UIEdgeInsets
UIVisualEffectView UIBlurEffect UIBezierPath CAShapeLayer CALayer
NSLayoutConstraint NSLayoutAnchor UITableView UITableViewCell UITableViewController
UIActivityIndicatorView UISlider UISwitch UIAlertController UIAlertAction
UIActionSheetController UITextField UITextView UISearchBar UISegmentedControl
UINavigationController UITabBarController UIToolbar UIPageControl
UIStatusBarManager UIDevice UIApplicationDelegate
UISceneDelegate UIWindowGroup UITextInputTraits UIControlState
NSObject NSString NSNumber NSArray NSDictionary NSMutableArray NSMutableDictionary
NSMutableString NSData NSMutableData NSURL NSURLRequest NSMutableURLRequest
NSURLSession NSURLSessionDataTask NSURLSessionTask NSURLSessionConfiguration
NSURLResponse NSError NSException NSNotificationCenter NSNotification NSOperationQueue
NSUserDefaults NSBundle NSThread NSDate NSDateFormatter NSTimeZone NSTimeInterval
NSLocale NSCoder NSKeyedArchiver NSKeyedUnarchiver NSUUID NSIndexSet NSRange
NSRegularExpression NSTextCheckingResult NSScanner NSCharacterSet NSValue
NSPredicate NSSortDescriptor NSTimer NSRunLoop NSLock NSRecursiveLock
NSFileManager NSFileHandle NSInputStream NSOutputStream NSProcessInfo
NSURLComponents NSURLQueryItem NSHTTPURLResponse NSURLCache NSURLProtocol
UIApplicationDidBecomeActiveNotification
UIApplicationWillResignActiveNotification
UIApplicationDidEnterBackgroundNotification
UIApplicationWillEnterForegroundNotification
UIApplicationDidChangeStatusBarOrientationNotification
UIApplicationDidChangeStatusBarFrameNotification
UIApplicationWillChangeStatusBarOrientationNotification
UIWindowDidBecomeVisibleNotification
UIWindowDidBecomeKeyNotification
UIWindowWillBecomeVisibleNotification
UIWindowWillBecomeKeyNotification
UIWindowDidBecomeVisibleNotification
UIDeviceOrientationDidChangeNotification
UIDeviceOrientationWillChangeNotification
UIKeyboardDidShowNotification
UIKeyboardDidHideNotification
UIKeyboardWillShowNotification
UIKeyboardWillHideNotification
UIKeyboardDidChangeFrameNotification
UIKeyboardWillChangeFrameNotification
UIScreenBrightnessDidChangeNotification
UITextFieldTextDidChangeNotification
UITextViewTextDidChangeNotification
UIAccessibilityAnnouncementNotification
UIWindowSceneDidActivateNotification
UIWindowSceneWillDeactivateNotification
UIWindowSceneDidDisconnectNotification
UISceneWillConnectNotification
UISceneDidDisconnectNotification
NSUserDefaultsDidChangeNotification
NSLocaleCurrentLocaleDidChangeNotification
CFPreferencesAppSynchronize
UIApplicationDidBecomeActiveNotification
UIViewAnimationCurveEaseInOut
UIFontWeightRegular UIFontWeightMedium UIFontWeightSemibold UIFontWeightBold
UIFontWeightLight UIFontWeightHeavy UIFontWeightBlack
UILineBreakModeWordWrapping NSLineBreakByWordWrapping
UITableViewCellAccessoryNone UITableViewCellAccessoryDisclosureIndicator
UITableViewCellStyleValue1 UITableViewCellStyleDefault UITableViewCellStyleSubtitle
UITableViewCellSelectionStyleNone UITableViewCellSelectionStyleDefault
UIControlEventValueChanged UIControlEventEditingChanged
UIEdgeInsetsZero CGRectZero CGSizeZero CGPointZero CGRectMake CGSizeMake CGPointMake
CGRectZero CGSizeZero CGPointZero
UIFontSystemFontSize UIFontSystemFontSize
UITextAlignmentCenter NSTextAlignmentLeft NSTextAlignmentCenter NSTextAlignmentRight
UIKeyboardTypeNumberPad UIKeyboardTypeDefault
UIAlertControllerStyleAlert UIAlertControllerStyleActionSheet
UIAlertActionStyleDefault UIAlertActionStyleCancel UIAlertActionStyleDestructive
UIStatusBarStyleDefault
UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft
UIInterfaceOrientationLandscapeRight
UISceneActivationStateForegroundActive UISceneActivationStateForegroundInactive
UISceneActivationStateBackground UISceneActivationStateUnattached
UIApplicationStateActive UIApplicationStateBackground UIApplicationStateInactive
UIWindowLevelNormal UIWindowLevelAlert UIWindowLevelStatusBar UIWindowLevelPopover
UIViewAnimationTransitionCrossDissolve
UISemanticContentAttributeUnspecified
UIUserInterfaceStyleLight UIUserInterfaceStyleDark
NSUnderlineStyleNone
NSStringDrawingUsesLineFragmentOrigin NSStringDrawingUsesFontLeading
NSAttributedStringKey NSFontAttributeName NSForegroundColorAttributeName
NSStrokeColorAttributeName NSStrokeWidthAttributeName
NSParagraphStyleAttributeName NSLineBreakByWordWrapping
UIViewAutoresizingFlexibleWidth UIViewAutoresizingFlexibleHeight
UIViewAutoresizingNone
UIImageRenderingModeAlwaysOriginal
UIProgressViewStyleDefault
UITextAlignmentNatural
UIColorClearColor
NSNotFound
UIApplicationShortcutItem
UIApplicationShortcutIcon
UIApplicationShortcutIconTypePlay
UIApplicationShortcutIconTypeSearch
UIBlurEffectStyleSystemMaterialDark
UIBlurEffectStyleSystemMaterialLight
UIBlurEffectStyleDark
UIBlurEffectStyleLight
UIBlurEffectStyleExtraLight
UIGestureRecognizerDelegate
UIGestureRecognizerStatePossible
UIGestureRecognizerStateBegan
UIGestureRecognizerStateChanged
UIGestureRecognizerStateEnded
UIGestureRecognizerStateCancelled
UIGestureRecognizerStateFailed
UIGestureRecognizerStateRecognized
UIGestureRecognizerSubclass
UIBarButtonItem UIBarButtonItemStyleDone UIBarButtonSystemItemFlexibleSpace
UIColorPickerViewController UIColorPickerViewControllerDelegate
UIKeyboardTypeDecimalPad UIKeyboardTypeNumberPad
UITableViewDataSource UITableViewDelegate
UITableViewStyleGrouped UITableViewStylePlain UITableViewRowAnimationNone
UITextAutocorrectionTypeNo UITextBorderStyleRoundedRect
UITextBorderStyleNone UITextBorderStyleLine UITextBorderStyleBezel
UITextFieldDelegate UITextFieldViewModeWhileEditing
UIScrollView UISearchBarDelegate
""".split())

# 明确不是 UIKit 符号的（类型别名 / 注释里的词），避免误判
NOT_UIKIT = set("""
UInt8 UInt16 UInt32 UInt64 UIntptr Int8 Int16 Int32 Int64
UIKit Foundation CoreFoundation
""".split())


def scan_text(src):
    """剥掉注释与字符串后提取 UI* 标识符，返回 (found, own, unknown)。

    抽成函数是为了让回归测试能直接在内存里做双向验证：
    把错误枚举注入文本，必须被判为 unknown。
    """
    code = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    code = re.sub(r"//[^\n]*", " ", code)
    code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
    code = re.sub(r"'(?:[^'\\]|\\.)*'", "''", code)

    found = {}
    for m in re.finditer(r"\b(UI[A-Za-z0-9_]+)\b", code):
        found.setdefault(m.group(1), []).append(code[:m.start()].count("\n") + 1)

    own = set(re.findall(r"@interface\s+(UI[A-Za-z0-9_]+)", src))
    own |= set(re.findall(r"@implementation\s+(UI[A-Za-z0-9_]+)", src))

    unknown = [(name, ls) for name, ls in sorted(found.items())
               if name not in KNOWN and name not in own and name not in NOT_UIKIT]
    return found, own, unknown


def main():
    print("=" * 70)
    print("UIKit 符号白名单交叉检查")
    print("=" * 70)
    all_unknown = []
    for path in (SRC,) + PANEL_SRCS:
        # CI 双向验证会在临时目录里跑检查脚本，缺文件要静默跳过，不能误报
        if not os.path.exists(path):
            print("  (跳过 %s：文件不存在)" % path)
            continue
        src = io.open(path, encoding="utf-8").read()
        found, own, unknown = scan_text(src)
        print("  %-44s UI* %2d 个 / 自定义 %d 个 / 可疑 %d 个"
              % (path, len(found), len(own), len(unknown)))
        for name, ls in unknown:
            print("     %-46s 行 %s"
                  % (name, ",".join(str(x) for x in ls[:5])))
            all_unknown.append((path, name, ls))
    print()
    if not all_unknown:
        print("未发现可疑符号 ✅")
        return 0
    print("提示：若确认是真实 UIKit API，加入 KNOWN 白名单即可；")
    print("     若确认不存在 → 编译必然失败，必须修。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
