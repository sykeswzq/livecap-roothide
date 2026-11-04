#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 v1.0.84 的 CI 教训追加到工作日志"""
import io

P = r"C:\Users\Administrator\WorkBuddy\ZDFY\.workbuddy\memory\2026-11-04.md"

TEXT = """

### ⚠️ v1.0.84 第一轮 CI 失败（重要教训）
CI run `41784344031` Build 步骤失败：
```
LiveCap.m:1796:28: error: use of undeclared identifier
'UIWindowDidChangeFrameNotification'; did you mean 'UIKeyboardDidChangeFrameNotification'?
```

**根因**：UIKit **没有**「window frame 变化」这种通知。
我以为有，实际不存在 —— 本地静态检查（括号配平 / `?:` 类型 / selector 存在性）
**完全查不出「符号不存在」**这类错误，只在 CI 上暴露，白跑一轮。

**修正**：改用两个真实存在的通知覆盖「旋转 / 全屏切换导致尺寸变化」
- `UIDeviceOrientationDidChangeNotification` —— 设备物理旋转
- `UIApplicationDidChangeStatusBarOrientationNotification` —— 状态栏方向变化

### 新增两类检查（补上「符号存在性」这个盲区）
1. `scan_uikit_symbols.py` —— UIKit 符号白名单交叉检查
   提取全部 `UI*` 标识符，与已确认存在的 UIKit API 白名单比对。
   实测：除已修的那个，其余 42 个 `UI*` 符号全部是历史版本已编译通过的真实 API
   （ShortcutItem / BlurEffectStyle / GestureRecognizerState…）。

2. `scan_new_symbols.py` —— **差集校验**（更精准，推荐）
   以「上一个已成功编译的版本」为基线，取本次新增符号的差集。
   v1.0.84 实测结果：只新增 2 个符号，均为官方文档确认存在的通知；
   同时确认已移除 `UIWindowDidChangeFrameNotification`。
   → **每次改动后跑这个，就能提前发现「新增了不存在的符号」**。

3. `verify_source_safety.py` 增加 `INVALID_UIKIT_NOTIFICATIONS` 黑名单拦截。

**铁律（补充）**：静态检查要覆盖三类编译错误 ——
① 语法/括号配平  ② 类型混用  ③ **符号不存在**（最容易漏，前两类都查不出）。

### 关键认知
「已成功编译过的版本」是**最好的符号白名单**。
用差集法（新增符号 vs 基线符号）比全量白名单更精准、更少误报。
"""


def main():
    s = io.open(P, encoding="utf-8").read()
    if "v1.0.84 第一轮 CI 失败" in s:
        print("已存在该段落，跳过")
        return 0
    if not s.endswith("\n"):
        s += "\n"
    io.open(P, "w", encoding="utf-8", newline="\n").write(s + TEXT)
    print("已追加 CI 教训")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
