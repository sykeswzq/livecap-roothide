#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.86 双向验证。

必须满足：
  A. 修复版（当前源码）全部检查项通过
  B. 注入每个历史 bug 后，必须被【准确】拦在对应检查项上
  C. 合法写法不得误报

B 组是重点 —— v1.0.86 的 mediaserverd 事故说明：
「检查脚本看起来在跑」不等于「真能拦住」，
必须有「把 bug 放回去，看它是否被抓到」的闭环。
"""
import io
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verify_source_safety as V

REAL_SRC = os.path.join(HERE, "LiveCap.m")
REAL_PANEL = os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m")
REAL_PLIST = os.path.join(HERE, "LiveCap.plist")
REAL_POSTINST = os.path.join(HERE, "postinst")


def run_check(src_text, plist_text=None, postinst_text=None):
    """在临时目录里跑 v1.0.86 检查项，返回错误列表。"""
    tmp = tempfile.mkdtemp(prefix="v86chk_")
    try:
        V.errors = []
        V.warnings = []
        src_path = os.path.join(tmp, "LiveCap.m")
        io.open(src_path, "w", encoding="utf-8").write(src_text)
        if plist_text is not None:
            io.open(os.path.join(tmp, "LiveCap.plist"), "w",
                    encoding="utf-8").write(plist_text)
        if postinst_text is not None:
            io.open(os.path.join(tmp, "postinst"), "w",
                    encoding="utf-8").write(postinst_text)
        # 面板
        os.makedirs(os.path.join(tmp, "PrefBundle"), exist_ok=True)
        if os.path.exists(REAL_PANEL):
            shutil.copy(REAL_PANEL, os.path.join(tmp, "PrefBundle",
                                                 "LiveCapPrefs.m"))
        V.SRC = src_path
        V.PANEL = os.path.join(tmp, "PrefBundle", "LiveCapPrefs.m")
        V.check_v86_fixes(src_text, None)
        return list(V.errors)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def mutate(text, old, new, tag):
    """做一处变异；锚点没命中直接报错（避免「变异没生效 → 假通过」）。"""
    if old not in text:
        raise AssertionError("[%s] 变异锚点未命中：\n%s" % (tag, old[:160]))
    if text.count(old) != 1:
        raise AssertionError("[%s] 变异锚点出现 %d 次（必须唯一）"
                             % (tag, text.count(old)))
    return text.replace(old, new)


BASE_SRC = io.open(REAL_SRC, encoding="utf-8").read()
BASE_PLIST = io.open(REAL_PLIST, encoding="utf-8").read()
BASE_POST = io.open(REAL_POSTINST, encoding="utf-8").read()

print("=" * 68)
print("A. 正向：修复版必须全部通过")
print("=" * 68)
errs = run_check(BASE_SRC, BASE_PLIST, BASE_POST)
if errs:
    for e in errs:
        print("  [FAIL] %s" % e)
    print("  => A 组失败")
    sys.exit(1)
print("  [PASS] v1.0.86 检查项在修复版上零误报")

print("")
print("=" * 68)
print("B. 回归：注入历史 bug 必须被准确拦截")
print("=" * 68)

# ---- B1: 把 mediaserverd 放回 plist（v1.0.74 的原始 bug）----
bad_plist = BASE_PLIST.replace(
    "\t\t<key>Bundles</key>",
    "\t\t<key>Executables</key>\n\t\t<array>\n"
    "\t\t\t<string>mediaserverd</string>\n\t\t</array>\n"
    "\t\t<key>Bundles</key>")
assert bad_plist != BASE_PLIST
errs = run_check(BASE_SRC, bad_plist, BASE_POST)
hit = [e for e in errs if "mediaserverd" in e]
print("  [B1] plist 加回 mediaserverd  -> %s"
      % ("拦截 ✅ " + hit[0][:70] if hit else "❌ 没拦住！"))
if not hit:
    sys.exit(1)

# ---- B2: postinst 又去杀 mediaserverd ----
bad_post = BASE_POST.replace(
    'echo "skip mediaserverd restart (not injected since v1.0.86)" >> "$LOG"',
    'killall mediaserverd 2>/dev/null || true')
errs = run_check(BASE_SRC, BASE_PLIST, bad_post)
hit = [e for e in errs if "mediaserverd" in e and "postinst" in e]
print("  [B2] postinst 恢复 killall mediaserverd -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！"))
if not hit:
    sys.exit(1)

# ---- B3: C++ 引用语法复活 ----
bad_src = mutate(
    BASE_SRC,
    "        const AudioBuffer *b = &abl->mBuffers[0];",
    "        const AudioBuffer &b = abl->mBuffers[0];",
    "B3")
errs = run_check(bad_src, BASE_PLIST, BASE_POST)
hit = [e for e in errs if "引用声明" in e or "C++" in e]
print("  [B3] AudioBuffer &b 引用语法  -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！"))
if not hit:
    sys.exit(1)

# ---- B4: 不存在的常量复活 ----
# 每个符号用【它在源码里的真实位置】做变异，不能共用一个锚点，
# 否则有的符号根本没被插进去，测出来是「假通过」。
B4_CASES = [
    ("kAudioFormatFlagIsEncoded",
     "    outFmt.mFormatFlags      = kMPEG4Object_AAC_LC;",
     "    outFmt.mFormatFlags      = kAudioFormatFlagIsEncoded;"),
    ("kAudioConverterEncodeQuality",
     "    AudioConverterSetProperty(conv, kAudioConverterCodecQuality,",
     "    AudioConverterSetProperty(conv, kAudioConverterEncodeQuality,"),
    ("kCFNetworkProxiesHTTPSEnable",
     '    [proxy setObject:@NO forKey:@"HTTPSEnable"];',
     "    [proxy setObject:@NO forKey:(__bridge NSString *)kCFNetworkProxiesHTTPSEnable];"),
    ("kCFNetworkProxiesSOCKSEnable",
     '    [proxy setObject:@NO forKey:@"SOCKSEnable"];',
     "    [proxy setObject:@NO forKey:(__bridge NSString *)kCFNetworkProxiesSOCKSEnable];"),
    ("AudioConverterInputStatus",
     "    OSStatus status =\n        AudioConverterFillComplexBuffer(",
     "    AudioConverterInputStatus status =\n        AudioConverterFillComplexBuffer("),
]
for sym, anchor, repl in B4_CASES:
    bad = mutate(BASE_SRC, anchor, repl, "B4-" + sym)
    errs = run_check(bad, BASE_PLIST, BASE_POST)
    hit = [e for e in errs if sym in e]
    print("  [B4] 复活 %s -> %s"
          % (sym, "拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
    if not hit:
        sys.exit(1)

# ---- B5: AudioConverter 回调签名改回 size_t ----
bad = mutate(
    BASE_SRC,
    "static UInt32 LCAACInputProc(void *inRefCon",
    "static size_t LCAACInputProc(void *inRefCon",
    "B5")
errs = run_check(bad, BASE_PLIST, BASE_POST)
hit = [e for e in errs if "LCAACInputProc" in e]
print("  [B5] LCAACInputProc 返回 size_t -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！"))
if not hit:
    sys.exit(1)

print("")
print("=" * 68)
print("C. 反向：合法写法不得误报")
print("=" * 68)
# 注释里提到 mediaserverd 不该被误判（plist 里已经用注释说明了原因）
errs = run_check(BASE_SRC, BASE_PLIST, BASE_POST)
if errs:
    print("  [FAIL] 修复版被误报：%s" % errs[0])
    sys.exit(1)
print("  [PASS] 注释中提及 mediaserverd 不误报")

print("")
print("=" * 68)
print("双向验证全部通过 ✅")
print("=" * 68)
