#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.83 校验脚本的双向验证（回归注入测试）。

原则：修复版必须【通过】；把原始 bug 重新注入后必须【被准确拦在正确位置】。
不做这一步，就无法证明检查脚本真的有效 —— 它可能只是恒返回 OK。

用法: python3 test_v83_verify.py
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "verify_source_safety.py")
SRC = os.path.join(HERE, "LiveCap.m")
PANEL = os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m")

PY = sys.executable


def run_verify():
    p = subprocess.run([PY, SCRIPT], cwd=HERE, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, p.stdout + p.stderr


def inject(src_path, old, new, label):
    """把原始 bug 注入到源文件副本，返回 (新文件路径, 是否成功)"""
    with io.open(src_path, "r", encoding="utf-8") as f:
        content = f.read()
    if old not in content:
        print("    [注入失败] %s: 找不到目标片段" % label)
        return None, False
    content = content.replace(old, new, 1)
    tmpdir = tempfile.mkdtemp(prefix="lc83_")
    new_path = os.path.join(tmpdir, os.path.basename(src_path))
    with io.open(new_path, "w", encoding="utf-8") as f:
        f.write(content)
    return new_path, True


def main():
    failures = []

    # ---------- 基线：修复版必须通过 ----------
    print("[基线] 未改动的修复版应通过校验")
    rc, out = run_verify()
    if rc != 0:
        print("  FAIL: 修复版居然没通过，输出：\n" + out)
        failures.append("基线未通过")
    else:
        print("  PASS: 修复版通过")

    # 备份原文件
    src_backup = SRC + ".b83test"
    panel_backup = PANEL + ".b83test"
    shutil.copy2(SRC, src_backup)
    shutil.copy2(PANEL, panel_backup)

    try:
        # ---------- 用例 1: 注入「容器尺寸冻结」原始 bug ----------
        print("\n[用例1] 回归注入：_userMoved 分支不更新 frame.size"
              "（v1.0.82「中文没显示全」根因）")
        with io.open(SRC, "r", encoding="utf-8") as f:
            s = f.read()
        bug1_old = """            CGRect f = _container.frame;
            f.size = CGSizeMake(w, h);
            // 保持中心点不变（用户拖到的位置），只改尺寸
            f.origin = CGPointMake(_userCenter.x - w / 2.0, _userCenter.y - h / 2.0);
            _container.frame = f;
            _userCenter = _container.center;"""
        bug1_new = """            _container.center = _userCenter;"""
        if bug1_old in s:
            with io.open(SRC, "w", encoding="utf-8") as f:
                f.write(s.replace(bug1_old, bug1_new, 1))
            rc, out = run_verify()
            caught = ("没有更新容器尺寸" in out) and rc != 0
            print("  %s: %s" % ("PASS" if caught else "FAIL",
                                "被准确拦下" if caught else out[-500:]))
            if not caught:
                failures.append("用例1 未被拦截")
        else:
            print("  FAIL: 找不到用例1 的目标片段（代码已变，需更新测试）")
            failures.append("用例1 片段不存在")
        shutil.copy2(src_backup, SRC)

        # ---------- 用例 2: 注入「读取老键 showEnglish」原始 bug ----------
        print("\n[用例2] 回归注入：showEnglish 方法改回读老键 showEnglish"
              "（v1.0.82「还有英文」根因）")
        with io.open(SRC, "r", encoding="utf-8") as f:
            s = f.read()
        bug2_old = """        NSNumber *v = fresh[@"showBilingual"];
        return v ? [v boolValue] : NO;"""
        bug2_new = """        NSNumber *v = fresh[@"showEnglish"];
        return v ? [v boolValue] : YES;"""
        if bug2_old in s:
            with io.open(SRC, "w", encoding="utf-8") as f:
                f.write(s.replace(bug2_old, bug2_new, 1))
            rc, out = run_verify()
            caught = (rc != 0) and ("showBilingual" in out or "showEnglish" in out)
            print("  %s: %s" % ("PASS" if caught else "FAIL",
                                "被准确拦下" if caught else out[-500:]))
            if not caught:
                failures.append("用例2 未被拦截")
        else:
            print("  FAIL: 找不到用例2 的目标片段")
            failures.append("用例2 片段不存在")
        shutil.copy2(src_backup, SRC)

        # ---------- 用例 3: 注入「面板改回 CFPreferences 写」原始 bug ----------
        print("\n[用例3] 回归注入：面板开关改回用 CFPreferencesSetAppValue 写"
              "（配置互相覆写根因）")
        with io.open(PANEL, "r", encoding="utf-8") as f:
            p = f.read()
        bug3_old = """    sw.on = [(NSNumber *)LCGet(@"showBilingual") boolValue];"""
        bug3_new = """    sw.on = [(NSNumber *)LCGet(@"showEnglish") boolValue];"""
        if bug3_old in p:
            with io.open(PANEL, "w", encoding="utf-8") as f:
                f.write(p.replace(bug3_old, bug3_new, 1))
            rc, out = run_verify()
            caught = (rc != 0) and ("showBilingual" in out)
            print("  %s: %s" % ("PASS" if caught else "FAIL",
                                "被准确拦下" if caught else out[-500:]))
            if not caught:
                failures.append("用例3 未被拦截")
        else:
            print("  FAIL: 找不到用例3 的目标片段")
            failures.append("用例3 片段不存在")
        shutil.copy2(panel_backup, PANEL)

        # ---------- 用例 4: 注入「measureW 不扣内边距」原始 bug ----------
        print("\n[用例4] 回归注入：measureW 不扣左右内边距（末行被裁）")
        with io.open(SRC, "r", encoding="utf-8") as f:
            s = f.read()
        bug4_old = """    CGFloat measureW = maxW - handleSpace - pad * 2;"""
        bug4_new = """    CGFloat measureW = maxW - handleSpace;"""
        if bug4_old in s:
            with io.open(SRC, "w", encoding="utf-8") as f:
                f.write(s.replace(bug4_old, bug4_new, 1))
            rc, out = run_verify()
            caught = (rc != 0) and ("内边距" in out)
            print("  %s: %s" % ("PASS" if caught else "FAIL",
                                "被准确拦下" if caught else out[-500:]))
            if not caught:
                failures.append("用例4 未被拦截")
        else:
            print("  FAIL: 找不到用例4 的目标片段")
            failures.append("用例4 片段不存在")
        shutil.copy2(src_backup, SRC)

        # ---------- 用例 5: 注入「英文标签不清空文本」原始 bug ----------
        print("\n[用例5] 回归注入：收起英文标签时不清空 attributedText（英文残留）")
        with io.open(SRC, "r", encoding="utf-8") as f:
            s = f.read()
        bug5_old = """            // 清空文本，彻底杜绝英文残留（只中文模式下的最后一道保险）
            _originLabel.attributedText = nil;"""
        bug5_new = """            // （bug 注入：不清空文本）"""
        if bug5_old in s:
            with io.open(SRC, "w", encoding="utf-8") as f:
                f.write(s.replace(bug5_old, bug5_new, 1))
            rc, out = run_verify()
            caught = (rc != 0) and ("attributedText" in out)
            print("  %s: %s" % ("PASS" if caught else "FAIL",
                                "被准确拦下" if caught else out[-500:]))
            if not caught:
                failures.append("用例5 未被拦截")
        else:
            print("  FAIL: 找不到用例5 的目标片段")
            failures.append("用例5 片段不存在")
        shutil.copy2(src_backup, SRC)

    finally:
        # 无论成败都要还原
        shutil.copy2(src_backup, SRC)
        shutil.copy2(panel_backup, PANEL)
        for p in (src_backup, panel_backup):
            if os.path.exists(p):
                os.remove(p)

    # ---------- 还原后必须仍然通过 ----------
    print("\n[还原] 还原后的源码应再次通过校验")
    rc, out = run_verify()
    if rc != 0:
        print("  FAIL: 还原后未通过：\n" + out)
        failures.append("还原后未通过")
    else:
        print("  PASS: 还原后通过")

    print("\n" + "=" * 56)
    if failures:
        print("双向验证 FAILED：%s" % "；".join(failures))
        return 1
    print("双向验证全部通过 ✅（修复版 PASS + 5 个原始 bug 全部被拦截）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
