#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""差集校验：本次新增的 UIKit/Foundation 符号是否都安全？

原理：v1.0.83 已成功编译通过 → 它用到的所有 UI*/NS* 符号都是【真实存在】的。
      把 v1.0.84 新增的符号与 v1.0.83 求差集，
      新增符号必须逐个确认存在（人工核对白名单）。

这比「全文件扫 UI 前缀」更精准 —— 直接锁定本次改动引入的新符号。
"""
import io
import os
import re
import subprocess
import sys

CUR = "LiveCap.m"
BASE_REF = "HEAD"   # v1.0.83 已编译成功的版本


def get_base():
    r = subprocess.run(["git", "show", "%s:%s" % (BASE_REF, CUR)],
                       capture_output=True)
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace")


def symbols(src):
    """提取 UI*/NS*/CF* 标识符（去掉注释与字符串）"""
    code = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    code = re.sub(r"//[^\n]*", " ", code)
    code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
    code = re.sub(r"'(?:[^'\\]|\\.)*'", "''", code)
    out = set()
    for m in re.finditer(r"\b((?:UI|NS|CF|CG)[A-Za-z0-9_]+)\b", code):
        out.add(m.group(1))
    return out


def main():
    cur_src = io.open(CUR, encoding="utf-8").read()
    base = get_base()
    if base is None:
        print("FAIL: 取不到基线 %s:%s" % (BASE_REF, CUR))
        return 1

    cur = symbols(cur_src)
    old = symbols(base)

    added = sorted(cur - old)
    removed = sorted(old - cur)

    print("=" * 72)
    print("差集校验：v1.0.84 相对 v1.0.83（已编译通过版本）")
    print("=" * 72)
    print("基线符号数: %d   当前符号数: %d" % (len(old), len(cur)))
    print()
    print("新增符号 %d 个（必须逐个确认真实存在）：" % len(added))
    for s in added:
        print("  + %s" % s)
    if removed:
        print()
        print("移除符号 %d 个：" % len(removed))
        for s in removed:
            print("  - %s" % s)
    print()

    # 已知危险名单：不存在的 UIKit 符号
    DANGER = {
        "UIWindowDidChangeFrameNotification": "UIKit 无此通知（v1.0.84 首次 CI 就栽在这）",
        "UIWindowDidChangeBoundsNotification": "UIKit 无此通知",
        "UIWindowWillChangeFrameNotification": "UIKit 无此通知",
        "UIWindowDidChangeScreenNotification": "UIKit 无此通知",
    }

    bad = [s for s in added if s in DANGER]
    if bad:
        print("!!! 发现危险符号：")
        for s in bad:
            print("   %s —— %s" % (s, DANGER[s]))
        return 1

    # 新增符号里含 Notification 的，必须逐个核对
    noti = [s for s in added if s.endswith("Notification")]
    print("新增通知类符号 %d 个（必须真实存在）：" % len(noti))
    for s in noti:
        print("  ? %s" % s)
    print()
    print("提示：通知名写错 = 编译直接失败（undeclared identifier）。")
    print("     请逐个对照 UIKit 文档确认，或在 scan_uikit_symbols.py 的白名单中登记。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
