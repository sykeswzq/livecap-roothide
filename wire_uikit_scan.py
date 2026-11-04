#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 UIKit 符号扫描接入 CI，并修正白名单

1. 白名单补充经人工确认的真实 UIKit API（都是历史版本已编译通过的符号）
2. 非 UIKit 前缀的误判项（UInt32/UInt64/UInt8/UIKit 注释）排除
3. 接入 build.yml 作为 CI 步骤
"""
import io
import re

SCAN = "scan_uikit_symbols.py"
WF = ".github/workflows/build.yml"


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def main():
    s = read(SCAN)

    # 1) 补白名单
    old = """UITextAlignmentNatural
UIColorClearColor
NSNotFound
\"\"\".split())"""
    new = """UITextAlignmentNatural
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
\"\"\".split())

# 明确不是 UIKit 符号的（类型别名 / 注释里的词），避免误判
NOT_UIKIT = set(\"\"\"
UInt8 UInt16 UInt32 UInt64 UIntptr Int8 Int16 Int32 Int64
UIKit Foundation CoreFoundation
\"\"\".split())"""
    if old not in s:
        print("  [FAIL] 白名单锚点未找到")
        return 1
    s = s.replace(old, new, 1)
    print("  [OK] 白名单已补充")

    # 2) 排除 NOT_UIKIT
    old2 = """        if name in KNOWN or name in own:
            continue"""
    new2 = """        if name in KNOWN or name in own or name in NOT_UIKIT:
            continue"""
    if old2 not in s:
        print("  [FAIL] 过滤锚点未找到")
        return 1
    s = s.replace(old2, new2, 1)
    print("  [OK] 排除非 UIKit 标识符")

    write(SCAN, s)

    # 3) 接入 CI
    wf = read(WF)
    if "scan_uikit_symbols" not in wf:
        old3 = """          python3 scan_compile_risk.py"""
        new3 = """          python3 scan_compile_risk.py
          echo "  (7) OK UIKit 符号白名单检查通过"
          python3 scan_uikit_symbols.py"""
        if old3 not in wf:
            print("  [FAIL] CI 锚点未找到")
            return 1
        wf = wf.replace(old3, new3, 1)
        write(WF, wf)
        print("  [OK] 已接入 CI")
    else:
        print("  [OK] CI 已接入")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
