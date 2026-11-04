#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正 v1.0.84 编译错误：UIWindowDidChangeFrameNotification 不存在

CI 报错：
  LiveCap.m:1796:28: error: use of undeclared identifier
  'UIWindowDidChangeFrameNotification'; did you mean 'UIKeyboardDidChangeFrameNotification'?

正确做法：UIKit 没有「window frame 变化」的通知。
旋转/全屏切换用这两个替代：
  - UIDeviceOrientationDidChangeNotification  （设备旋转）
  - UIApplicationDidChangeStatusBarOrientationNotification（状态栏方向变化）
另外 UIWindowDidBecomeVisibleNotification 已在监听里覆盖了「全屏新 window 出现」。

同时补一条静态检查，避免这类「不存在的通知名」再次溜到 CI。
"""
import io
import re
import sys

SRC = "LiveCap.m"
VERIFY = "verify_source_safety.py"


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def main():
    src = read(SRC)
    orig = src

    old = """    // 尺寸变化：旋转 / 全屏切换都会触发
    [nc addObserverForName:UIWindowDidChangeFrameNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];"""

    new = """    // 尺寸变化：旋转 / 全屏切换都会触发。
    // 注意：UIKit 没有「window frame 变化」这种通知
    //（UIWindowDidChangeFrameNotification 根本不存在，CI 编译会报 undeclared identifier）。
    // 旋转用下面这两个通知覆盖：
    //   UIDeviceOrientationDidChangeNotification —— 设备物理旋转
    //   UIApplicationDidChangeStatusBarOrientationNotification —— 状态栏方向变化
    [nc addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];
    [nc addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];"""

    if old not in src:
        print("  [FAIL] 锚点未找到")
        return 1
    src = src.replace(old, new, 1)
    print("  [OK] 替换为有效通知（UIDeviceOrientation / StatusBarOrientation）")

    # 扫一遍是否还有其他不存在的 UIKit 通知名
    KNOWN_BAD = ["UIWindowDidChangeFrameNotification",
                 "UIWindowDidChangeBoundsNotification",
                 "UIWindowWillChangeFrameNotification"]
    for bad in KNOWN_BAD:
        if bad in src:
            print("  [FAIL] 仍存在无效通知名: %s" % bad)
            return 1
    print("  [OK] 无其他无效通知名")

    write(SRC, src)

    # 给静态检查加一条：禁止出现不存在的通知名
    vsrc = read(VERIFY)
    if "INVALID_UIKIT_NOTIFICATIONS" not in vsrc:
        anchor = "def check_v84_fixes(src, panel_src=None):"
        inject = '''# 不存在的 UIKit 通知名 —— 用了会直接编译失败（CI 才暴露，浪费一轮）
INVALID_UIKIT_NOTIFICATIONS = [
    "UIWindowDidChangeFrameNotification",
    "UIWindowDidChangeBoundsNotification",
    "UIWindowWillChangeFrameNotification",
]


def check_v84_fixes(src, panel_src=None):'''
        if anchor not in vsrc:
            print("  [FAIL] verify 锚点未找到")
            return 1
        vsrc = vsrc.replace(anchor, inject, 1)

        # 在 check_v84_fixes 末尾追加检查
        body_anchor = """    if not re.search(r"f\\.origin\\.y\\s*=\\s*MIN\\(\\s*MAX\\(", code):
        errors.append("v1.0.84 回归: 缺少位置钳制 —— "
                      "竖屏拖动位置转横屏后字幕会跑出屏幕外（全屏时看不见）")"""
        body_new = body_anchor + """

    # ---- 6) 不得使用不存在的 UIKit 通知名 ----
    for bad in INVALID_UIKIT_NOTIFICATIONS:
        if bad in src:
            line = src[:src.index(bad)].count("\\n") + 1
            errors.append("v1.0.84 回归 行%d: 用了不存在的通知名 %s —— "
                          "UIKit 没有这个通知，编译会报 undeclared identifier"
                          % (line, bad))"""
        if body_anchor not in vsrc:
            print("  [FAIL] verify body 锚点未找到")
            return 1
        vsrc = vsrc.replace(body_anchor, body_new, 1)
        write(VERIFY, vsrc)
        print("  [OK] verify 新增无效通知名拦截")

    print("\n已修正")
    return 0


if __name__ == "__main__":
    sys.exit(main())
