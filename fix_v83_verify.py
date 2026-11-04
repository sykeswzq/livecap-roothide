#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正 verify_source_safety.py 中 v1.0.83 检查函数自身的两个 bug：

1) writeConfig 的方法体提取正则会先匹配到 @interface 里的【声明行】
   `- (void)writeConfig:(NSMutableDictionary *)d;`（以 ; 结尾），
   导致后续大括号配平跑到别的方法上 → 误报「没有 writeToFile」。
   修复：只在匹配后紧跟 `{`（而非 `;`）时才算方法实现。

2) PANEL 常量没有注入到 verify_source_safety.py → 面板检查被跳过。
"""
import io
import os
import re
import sys

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "verify_source_safety.py")

with io.open(SCRIPT, "r", encoding="utf-8") as f:
    content = f.read()

# ---- 修复 1) writeConfig 方法体提取 ----
old = '''    # ---- 2) 统一写回通道 ----
    m = re.search(r"-\\s*\\(void\\)\\s*writeConfig\\s*:\\s*\\(", src)
    if not m:
        errors.append("v1.0.83 回归: 缺少 writeConfig: 统一配置写回通道 —— "
                      "面板与 tweak 会互相覆写同一个 plist")
    else:'''
new = '''    # ---- 2) 统一写回通道 ----
    # 注意：@interface 里也有 `- (void)writeConfig:(NSMutableDictionary *)d;` 声明行，
    #       提取方法体必须跳过以 `;` 结尾的声明，只认以 `{` 开头的实现。
    m = None
    for cand in re.finditer(r"-\\s*\\(void\\)\\s*writeConfig\\s*:\\s*\\([^)]*\\)\\s*(\\w+)\\s*(\\{|;)",
                            src):
        if cand.group(2) == "{":
            m = cand
            break
    if not m:
        errors.append("v1.0.83 回归: 缺少 writeConfig: 统一配置写回通道 —— "
                      "面板与 tweak 会互相覆写同一个 plist")
    else:'''
if old in content:
    content = content.replace(old, new, 1)
    print("fixed: writeConfig 方法体提取")
else:
    print("WARN: 未找到 writeConfig 提取片段（可能已修过）")

# ---- 修复 2) 注入 PANEL 常量 ----
if re.search(r"^PANEL\s*=", content, re.M):
    print("skip: PANEL 常量已存在")
else:
    anchor = "\ndef main():"
    inject = ('\nPANEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),\n'
              '                      "PrefBundle", "LiveCapPrefs.m")\n')
    if anchor in content:
        content = content.replace(anchor, inject + anchor, 1)
        print("injected: PANEL 常量")
    else:
        print("ERROR: 找不到 main() 锚点")

with io.open(SCRIPT, "w", encoding="utf-8") as f:
    f.write(content)
sys.exit(0)
