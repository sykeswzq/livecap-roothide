#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scan_compile_risk.py 的双向验证。

原则：修复版必须 PASS；把历史真实编译错误重新注入后必须被准确拦截。

历史真实案例：
  1. v1.0.82：`completion ?: [NSNull null]` → 编译错误
     (incompatible operand types: 'void (^)(NSString *)' and 'NSNull *')
  2. v1.0.82：`pad` 先用后定义 → 编译错误 use of undeclared identifier 'pad'
     → 白跑一轮 CI（约 5 分钟往返）
本检查就是为了在 push 之前把这两类错误拦下来。

用法: python3 test_compile_risk.py
"""
import io
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCAN = os.path.join(HERE, "scan_compile_risk.py")
SRC = os.path.join(HERE, "LiveCap.m")
PY = sys.executable

failures = []
backup = SRC + ".ctest"


def run():
    p = subprocess.run([PY, SCAN], cwd=HERE, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, p.stdout + p.stderr


def apply_transform(label, transform, expect_kw, note):
    """transform(content) -> new_content；注入后必须被拦截"""
    with io.open(SRC, "r", encoding="utf-8") as f:
        s = f.read()
    s2 = transform(s)
    if s2 == s:
        print("  FAIL: %s —— 变换未生效（源码已变，需更新测试）" % label)
        failures.append(label + ": 变换未生效")
        return
    with io.open(SRC, "w", encoding="utf-8") as f:
        f.write(s2)
    rc, out = run()
    shutil.copy2(backup, SRC)
    caught = rc != 0 and (expect_kw in out)
    print("  %s: %s  [%s]" % ("PASS" if caught else "FAIL",
                              "被准确拦下" if caught else out[-400:], note))
    if not caught:
        failures.append(label + ": 未被拦截")


def t_pad_moved(s):
    """把 pad 的声明从使用之前挪到使用之后 → undeclared identifier"""
    old = """        CGFloat pad = 10;
        // 完整测量两段文本高度（不截断，文本多长框多高）"""
    new = """        // 完整测量两段文本高度（不截断，文本多长框多高）"""
    if old not in s:
        return s
    s = s.replace(old, new, 1)
    s = s.replace(
        """        CGFloat measureW = maxW - handleSpace - pad * 2;""",
        """        CGFloat measureW = maxW - handleSpace - pad * 2;
        CGFloat pad = 10;""", 1)
    return s


def t_ternary_block_null(s):
    """还原 v1.0.82 的真实错误：completion ?: [NSNull null]"""
    old = """        id compBox = completion ? (id)completion : (id)[NSNull null];"""
    new = """        id compBox = completion ?: [NSNull null];"""
    return s.replace(old, new, 1)


def t_unbalanced(s):
    return s.replace("@implementation LCSubtitleOverlay",
                      "@implementation LCSubtitleOverlay (", 1)


def t_missing_selector(s):
    return s.replace("[[LCConfig shared] textColor]",
                      "[[LCConfig shared] totallyMissingSelector]", 1)


def t_legal_shadow(s):
    """合法作用域遮蔽（内层同名变量）—— 不得误报"""
    old = """        CGFloat pad = 10;
        // 完整测量两段文本高度（不截断，文本多长框多高）"""
    new = """        CGFloat pad = 10;
        {
            int32_t pad = 7;
            (void)pad;
        }
        // 完整测量两段文本高度（不截断，文本多长框多高）"""
    return s.replace(old, new, 1)


def main():
    print("[基线] 当前源码应通过编译风险扫描")
    rc, out = run()
    if rc != 0:
        print("  FAIL: 基线未通过\n" + out)
        failures.append("基线")
    else:
        print("  PASS")

    shutil.copy2(SRC, backup)
    try:
        print("\n[用例A] pad 声明挪到使用之后（v1.0.82 真实历史错误）")
        apply_transform("用例A", t_pad_moved, "pad", "undeclared identifier")

        print("\n[用例B] ?: 两侧 block 与 NSNull* 混用（v1.0.82 真实历史错误）")
        apply_transform("用例B", t_ternary_block_null, "NSNull",
                        "incompatible operand types")

        print("\n[用例C] 括号不配平")
        apply_transform("用例C", t_unbalanced, "配平", "brace balance")

        print("\n[用例D] 调用 LCConfig 不存在的 selector")
        apply_transform("用例D", t_missing_selector, "未实现该方法",
                        "undeclared selector")

        print("\n[用例E] 反向用例：合法作用域遮蔽不应误报")
        with io.open(SRC, "r", encoding="utf-8") as f:
            s = f.read()
        s2 = t_legal_shadow(s)
        if s2 != s:
            with io.open(SRC, "w", encoding="utf-8") as f:
                f.write(s2)
            rc, out = run()
            shutil.copy2(backup, SRC)
            ok = rc == 0
            print("  %s: %s" % ("PASS" if ok else "FAIL",
                                "合法遮蔽未误报" if ok else out[-400:]))
            if not ok:
                failures.append("用例E: 合法遮蔽被误报")
        else:
            print("  SKIP: 锚点不存在")
    finally:
        shutil.copy2(backup, SRC)
        if os.path.exists(backup):
            os.remove(backup)

    print("\n[还原] 还原后应再次通过")
    rc, out = run()
    if rc != 0:
        print("  FAIL: 还原后未通过\n" + out)
        failures.append("还原")
    else:
        print("  PASS")

    print("\n" + "=" * 56)
    if failures:
        print("双向验证 FAILED：%s" % "；".join(failures))
        return 1
    print("双向验证全部通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
