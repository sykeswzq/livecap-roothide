#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.84 双向验证：新增的静态检查项必须真能拦住对应回归

原则（历史教训）：检查脚本如果只验证「修复版通过」，
      那它可能形同虚设 —— 必须同时验证「注入 bug 会被准确拦在正确位置」。
"""
import io
import re
import shutil
import subprocess
import sys

SRC = "LiveCap.m"
BAK = SRC + ".v84test.bak"
PY = sys.executable


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def run(script):
    r = subprocess.run([PY, script], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def check(name, cond, detail=""):
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name,
                           ("  -> " + detail) if detail and not cond else ""))
    return cond


def main():
    shutil.copy2(SRC, BAK)
    original = read(SRC)
    allpass = True

    try:
        # ==========================================================
        print("=== A. 正向：修复版必须通过所有检查 ===")
        rc_safety, out_safety = run("verify_source_safety.py")
        rc_risk, out_risk = run("scan_compile_risk.py")
        allpass &= check("verify_source_safety 通过", rc_safety == 0,
                         out_safety[-400:])
        allpass &= check("scan_compile_risk 通过", rc_risk == 0, out_risk[-400:])

        # ==========================================================
        print()
        print("=== B. 回归：注入 v1.0.84 相关 bug，检查脚本必须拦住 ===")

        cases = [
            # (名称, 变异函数, 期望被哪个脚本拦住)
            ("LC_ASR_CHUNK_DEFAULT 被移除（延迟回归）",
             lambda s: s.replace(
                 "#define LC_ASR_CHUNK_DEFAULT 1.5",
                 "// removed"),
             "verify_source_safety"),

            ("移除 bringSubviewToFront（全屏字幕被盖住回归）",
             lambda s: s.replace(
                 "        [parent bringSubviewToFront:_container];",
                 "        // removed")
              if "        [parent bringSubviewToFront:_container];" in s
              else s,
             "verify_source_safety"),

            ("移除位置钳制（旋转后字幕跑出屏幕回归）",
             lambda s: s.replace(
                 "            f.origin.y = MIN(MAX(f.origin.y, minY - h / 2.0), maxY - h / 2.0);",
                 "            // removed")
              if "            f.origin.y = MIN(MAX(f.origin.y, minY - h / 2.0), maxY - h / 2.0);" in s
              else s,
             "verify_source_safety"),

            ("移除全部 ensureInBestWindow 调用（全屏新 window 回归）",
             lambda s: s.replace("    [self ensureInBestWindow];", "    // removed")
              if "[self ensureInBestWindow];" in s
              else s,
             "verify_source_safety"),

            # 注：v1.0.87 把这条日志加上了 fmt=%@ 字段，锚点必须跟着改，
            #     否则「锚点不存在 → 变异未生效」会被判成失败。
            ("移除毫秒级 RTT 打点（无法再定位延迟）",
             lambda s: s.replace(
                 '                    LCLogF(@"asr: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",',
                 '                    // removed')
              if '                    LCLogF(@"asr: rtt=%.0fms audio=%.2fs bytes=%lu fmt=%@",' in s
              else s,
             "verify_source_safety"),
        ]

        for name, mutate, expect_script in cases:
            mutated = mutate(original)
            if mutated == original:
                print("  [SKIP] %s —— 锚点不存在，变异未生效" % name)
                allpass = False
                continue
            write(SRC, mutated)
            rc_s, out_s = run("verify_source_safety.py")
            rc_r, out_r = run("scan_compile_risk.py")
            combined = out_s + out_r
            # 必须【至少有一个】脚本报错
            detected = (rc_s != 0) or (rc_r != 0)
            allpass &= check(name + " → 被拦截", detected,
                             "两个脚本都没报错（rc_s=%d rc_r=%d）" % (rc_s, rc_r))
            if detected:
                # 确认拦截信息里提到了相关关键字（避免误拦到别的问题）
                kws = ["chunkSecs", "lc_chunkSeconds", "LC_ASR_CHUNK_DEFAULT",
                       "LC_ASR_CHUNK_SECONDS", "bringSubviewToFront",
                       "ensureInBestWindow", "UIWindowDidBecomeKeyNotification",
                       "钳制", "rtt"]
                hit = [k for k in kws if k.lower() in combined.lower()]
                allpass &= check("   拦截信息命中相关关键字 %s" % (hit or "无"),
                                 bool(hit), combined[-300:])

        # 恢复
        write(SRC, original)
        print()
        print("=== C. 反向：合法写法不得被误报 ===")
        rc_s, out_s = run("verify_source_safety.py")
        rc_r, out_r = run("scan_compile_risk.py")
        allpass &= check("恢复后两个脚本仍通过", rc_s == 0 and rc_r == 0,
                         (out_s + out_r)[-300:])

    finally:
        shutil.move(BAK, SRC)

    print()
    print("=" * 60)
    print("v1.0.84 双向验证：%s" % ("全部通过 ✅" if allpass else "存在失败 ❌"))
    print("=" * 60)
    return 0 if allpass else 1


if __name__ == "__main__":
    sys.exit(main())
