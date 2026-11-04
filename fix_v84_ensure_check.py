#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 v1.0.84 检查项补强：ensureInBestWindow 必须【所有】调用点都在

问题：源码里有 2 处 [self ensureInBestWindow]（bringToFrontIfNeeded 与
      key-window 监听回调），只删一处时检查项仍会通过 → 检查不严。
修法：要求调用点数量 ≥ 2。
"""
import io
import re

P = "verify_source_safety.py"

OLD = '''    if not re.search(r"\\[\\s*self\\s+ensureInBestWindow\\s*\\]", code):
        errors.append("v1.0.84 回归: 缺少 [self ensureInBestWindow] 调用 —— "
                      "全屏若新建 window，字幕必须跟着搬到新的 key window")'''

NEW = '''    # 要求【所有】调用点都在：源码有 2 处（渲染前提到最上层 + key window 变化回调），
    # 只保留一处不足以覆盖「全屏新建 window」的两种触发路径。
    ensure_calls = len(re.findall(r"\\[\\s*self\\s+ensureInBestWindow\\s*\\]", code))
    if ensure_calls < 2:
        errors.append("v1.0.84 回归: [self ensureInBestWindow] 调用点只有 %d 处（需 ≥2）—— "
                      "渲染时与 key window 变化时都要重新挂载，否则全屏新建 window "
                      "后字幕留在旧 window 里看不见" % ensure_calls)'''


def main():
    s = io.open(P, encoding="utf-8").read()
    if OLD not in s:
        print("FAIL: 锚点未找到")
        return 1
    s = s.replace(OLD, NEW, 1)
    io.open(P, "w", encoding="utf-8", newline="\n").write(s)
    print("已补强 ensureInBestWindow 检查（要求 ≥2 处调用）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
