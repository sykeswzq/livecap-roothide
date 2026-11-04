#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按行替换 UIWindowDidChangeFrameNotification 监听块

锚点文字匹配失败（注释实际是「尺寸变化：旋转 / 全屏切换都会触发」，
与脚本里写的字有细微差异）→ 改为按行号精确定位。
"""
import io
import re

SRC = "LiveCap.m"
VERIFY = "verify_source_safety.py"

BAD = "UIWindowDidChangeFrameNotification"


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def main():
    src = read(SRC)
    lines = src.split("\n")

    # 找到 addObserverForName:UIWindowDidChangeFrameNotification 那一行
    idx = None
    for i, ln in enumerate(lines):
        if "addObserverForName:" + BAD in ln:
            idx = i
            break
    if idx is None:
        print("  [FAIL] 未找到 %s" % BAD)
        return 1

    # 该监听块的范围：从 idx 往前找注释起始，往后找 "}];"
    start = idx
    while start > 0 and not lines[start].strip().startswith("//"):
  # 往上找注释起点
        start -= 1
    end = idx
    while end < len(lines) and lines[end].strip() != "}];":
        end += 1
    if end >= len(lines):
        print("  [FAIL] 未找到监听块结尾")
        return 1

    print("  替换行区间 %d-%d" % (start + 1, end + 1))

    new_block = """    // 尺寸变化：旋转 / 全屏切换都会触发。
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
    }];""".split("\n")

    lines = lines[:start] + new_block + lines[end + 1:]
    src = "\n".join(lines)

    # 检查：注释里提到这个名字也会被静态检查拦 → 注释里改个说法
    src = src.replace(
        "//（UIWindowDidChangeFrameNotification 根本不存在，CI 编译会报 undeclared identifier）。",
        "//（UIKit 根本没有「window frame 变化」通知，CI 编译会报 undeclared identifier）。")

    write(SRC, src)

    # 校验
    src2 = read(SRC)
    if BAD in src2:
        print("  [FAIL] 仍存在 %s" % BAD)
        return 1
    print("  [OK] 已移除 %s" % BAD)
    for good in ["UIDeviceOrientationDidChangeNotification",
                 "UIApplicationDidChangeStatusBarOrientationNotification"]:
        if good not in src2:
            print("  [FAIL] 未加入有效通知 %s" % good)
            return 1
        print("  [OK] 已加入 %s" % good)

    # 给 verify 加拦截
    vsrc = read(VERIFY)
    if "INVALID_UIKIT_NOTIFICATIONS" not in vsrc:
        anchor = "def check_v84_fixes(src, panel_src=None):"
        inject = """# 不存在的 UIKit 通知名 —— 用了会直接编译失败
# （v1.0.84 就在这上面栽了一轮：CI 报 undeclared identifier）
INVALID_UIKIT_NOTIFICATIONS = [
    "UIWindowDidChangeFrameNotification",
    "UIWindowDidChangeBoundsNotification",
    "UIWindowWillChangeFrameNotification",
]


def check_v84_fixes(src, panel_src=None):"""
        if anchor not in vsrc:
            print("  [FAIL] verify 锚点未找到")
            return 1
        vsrc = vsrc.replace(anchor, inject, 1)

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
    raise SystemExit(main())
