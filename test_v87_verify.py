#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 双向验证。

用户反馈：「好像还是有延迟，然后字体要在UI里面可以设置大小」

必须满足：
  A. 修复版（当前源码）全部检查项通过
  B. 注入每个历史 bug 后，必须被【准确】拦在对应检查项上
  C. 合法写法不得误报

B 组是重点 —— v1.0.86 的 mediaserverd 事故说明：
「检查脚本看起来在跑」不等于「真能拦住」，
必须有「把 bug 放回去，看它是否被抓到」的闭环。
本轮同样适用：v1.0.87 修了「一次失败即永久禁用」这个老设计，
如果反向断言写得不准，改回去就没人拦得住。
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


def run_check(src_text, panel_text=None):
    """在内存里跑 v1.0.87 检查项，返回错误列表。"""
    V.errors = []
    V.warnings = []
    V.check_v87_fixes(src_text, panel_text)
    return list(V.errors)


def mutate(text, old, new, tag, count=1):
    """做一处变异；锚点没命中直接报错（避免「变异没生效 → 假通过」）。"""
    if old not in text:
        raise AssertionError("[%s] 变异锚点未命中：\n%s" % (tag, old[:200]))
    n = text.count(old)
    if n != count:
        raise AssertionError("[%s] 变异锚点出现 %d 次（期望 %d 次）"
                             % (tag, n, count))
    return text.replace(old, new)


BASE_SRC = io.open(REAL_SRC, encoding="utf-8").read()
BASE_PANEL = io.open(REAL_PANEL, encoding="utf-8").read()

print("=" * 70)
print("A. 正向：修复版必须全部通过")
print("=" * 70)
errs = run_check(BASE_SRC, BASE_PANEL)
if errs:
    for e in errs:
        print("  [FAIL] %s" % e)
    print("  => A 组失败")
    sys.exit(1)
print("  [PASS] v1.0.87 检查项在修复版上零误报")

print("")
print("=" * 70)
print("B. 回归：注入历史 bug 必须被准确拦截")
print("=" * 70)

# ---- B1: 裸 AAC 编码器复活（v1.0.85 的原始 bug）----
# 腾讯云拒收无 ADTS 头的 AAC → 压缩完全失效 → 退回 82KB WAV → 延迟反弹
bad = mutate(
    BASE_SRC,
    "static NSData *LCAACEncodeADTSFramed(NSData *pcm16) {",
    "static NSData *LCAACEncode16kMono(NSData *pcm16) {",
    "B1")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "LCAACEncode16kMono" in e]
print("  [B1] 复活裸 AAC 编码器 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B2: ADTS syncword 被改掉 ----
bad = mutate(
    BASE_SRC,
    "        0xFF, 0xF1, 0x60, 0x00, 0x00, 0x1F, 0xFC",
    "        0x00, 0x00, 0x60, 0x00, 0x00, 0x1F, 0xFC",
    "B2")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "syncword" in e]
print("  [B2] ADTS syncword 被改坏 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B3: frame_length 漏掉 7 字节头长 ----
bad = mutate(
    BASE_SRC,
    "            uint32_t frameLen = 7 + produced;",
    "            uint32_t frameLen = produced;",
    "B3")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "frame_length" in e]
print("  [B3] frame_length 漏算 7 字节头 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B4: 「一次失败即永久禁用」复活 ----
bad = mutate(
    BASE_SRC,
    "    NSTimeInterval _aacRetryAfter;      // AAC 冷却截止时间戳（0 = 可用 AAC）",
    "    BOOL _aacBroken;\n"
    "    NSTimeInterval _aacRetryAfter;      // AAC 冷却截止时间戳（0 = 可用 AAC）",
    "B4")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "_aacBroken" in e]
print("  [B4] 复活 _aacBroken（永久禁用 AAC） -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B5: 「直连失败永久切代理」复活 ----
bad = mutate(
    BASE_SRC,
    "    NSTimeInterval _directRetryAfter;   // 直连冷却截止时间戳（0 = 可直连）",
    "    BOOL _directFailed;\n"
    "    NSTimeInterval _directRetryAfter;   // 直连冷却截止时间戳（0 = 可直连）",
    "B5")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "_directFailed" in e]
print("  [B5] 复活 _directFailed（永久切代理） -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B6: 并发满时整段清空音频（v1.0.85 的原始 bug）----
bad = mutate(
    BASE_SRC,
    "            [self trimPCM16KeepingSeconds:chunkSecs];",
    "            [_pcm16 setLength:0];",
    "B6")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "整段清空" in e]
print("  [B6] 并发满就整段清空音频 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B6b: float 路径也整段清空 ----
bad = mutate(
    BASE_SRC,
    "                [self trimPCMKeepingSeconds:chunkSecs];",
    "                [_pcm setLength:0];",
    "B6b")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "整段清空" in e]
print("  [B6b] float 路径整段清空 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B7: 字号改回读启动缓存（改了不生效）----
bad = mutate(
    BASE_SRC,
    """    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:p];
    if (fresh) {
        id v = fresh[key];
        if (v) return v;
    }
    return _d[key];""",
    "    return _d[key];",
    "B7")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "实时读盘" in e or "freshValueForKey" in e]
print("  [B7] 字号改回读启动缓存 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B8: 监听到字号变化但不重绘 ----
bad = mutate(
    BASE_SRC,
    """        LCLogF(@"overlay: fontSize changed %.0f -> %.0f, re-render", old, fs);
        [self renderCurrent];""",
    """        LCLogF(@"overlay: fontSize changed %.0f -> %.0f, re-render", old, fs);""",
    "B8")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "renderCurrent" in e]
print("  [B8] 字号变了但不重绘 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B9: 面板退回数字键盘（没有滑块）----
bad_panel = BASE_PANEL.replace("UISlider", "ZzSlider")
assert bad_panel != BASE_PANEL
errs = run_check(BASE_SRC, bad_panel)
hit = [e for e in errs if "滑块" in e]
print("  [B9] 面板没有字号滑块 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B9b: 滑块存在但不绑定回调（拖了没反应）----
bad_panel = mutate(
    BASE_PANEL,
    "                action:@selector(lc_sliderChanged:)",
    "                action:@selector(lc_nothingHappened:)",
    "B9b-panel")
errs = run_check(BASE_SRC, bad_panel)
hit = [e for e in errs if "lc_sliderChanged" in e]
print("  [B9b] 滑块没绑回调 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B10: 面板退回 [(NSNumber *)LCGet(...)] 强转 ----
bad_panel = mutate(
    BASE_PANEL,
    '            CGFloat fs = LCGetNum(@"fontSize", 16.0);',
    '            CGFloat fs = [(NSNumber *)LCGet(@"fontSize") doubleValue];',
    "B10-panel")
errs = run_check(BASE_SRC, bad_panel)
hit = [e for e in errs if "强转" in e]
print("  [B10] 面板强转 NSNumber 读字号 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B11: 面板默认值又变回 28（与 tweak 的 16 不一致）----
bad_panel = mutate(
    BASE_PANEL,
    '            CGFloat fs = LCGetNum(@"fontSize", 16.0);',
    '            CGFloat fs = LCGetNum(@"fontSize", 28.0);',
    "B11-panel")
errs = run_check(BASE_SRC, bad_panel)
hit = [e for e in errs if "默认值" in e]
print("  [B11] 面板字号默认值回到 28 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B12: 在 LCLogF 定义之前调用它（v1.0.87 首次 CI 失败的根因）----
bad = mutate(
    BASE_SRC,
    """    // 注意：这里【不能】打日志 —— LCLogF 的定义在本函数之后（文件里更靠后），
    // 在此处调用会报 "call to undeclared function 'LCLogF'"（CI 实证）。
    // 调用方（processChunk: / processChunk16:）会打 "asr: sending N bytes"，信息足够。
    (void)frames;
    return out;""",
    """    LCLogF(@"asr: aac-adts frames=%d bytes=%lu", frames, (unsigned long)out.length);
    return out;""",
    "B12")
errs = run_check(bad, BASE_PANEL)
hit = [e for e in errs if "LCLogF" in e]
print("  [B12] 在 LCLogF 定义之前调用它 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

# ---- B13: 字号选择器只剩前向声明（CI 第二次构建失败的根因）----
# 模拟：把 @interface/@implementation 整块删掉，只留 @class 前向声明，
#       此时 [[LCFontSizeController alloc] 会报
#       "receiver for class message is a forward declaration"。
bad_panel = BASE_PANEL
_i = bad_panel.find("#pragma mark - v1.0.87：字幕字号选择器（滑块 + 实时预览）")
_j = bad_panel.find("@interface LCRootListController : PSViewController")
assert _i > 0 and _j > _i
bad_panel = (bad_panel[:_i]
             + "@class LCFontSizeController;\n\n"
             + bad_panel[_j:])
errs = run_check(BASE_SRC, bad_panel)
hit = [e for e in errs if "forward declaration" in e or "LCFontSizeController" in e]
print("  [B13] 字号选择器只剩前向声明 -> %s"
      % ("拦截 ✅" if hit else "❌ 没拦住！ (%s)" % errs[:1]))
if not hit:
    sys.exit(1)

print("")
print("=" * 70)
print("C. 反向：合法写法不得误报")
print("=" * 70)
errs = run_check(BASE_SRC, BASE_PANEL)
if errs:
    print("  [FAIL] 修复版被误报：%s" % errs[0])
    sys.exit(1)
print("  [PASS] 修复版零误报")

# 注释里出现被禁用的标识符不得误报（历史说明里经常要提一嘴）
t = BASE_SRC.replace(
    "// ===== v1.0.85：失败改为【可恢复】，不再永久拉黑 =====",
    "// 历史：以前叫 _aacBroken / _directFailed（已废弃）")
errs = run_check(t, BASE_PANEL)
if errs:
    print("  [FAIL] 注释里提及旧标识符被误报：%s" % errs[0])
    sys.exit(1)
print("  [PASS] 注释里提及旧标识符不误报")

# 面板注释里举的「错误写法」例子不得误报
t = BASE_PANEL.replace(
    '// 面板却用 [(NSNumber *)LCGet(@"fontSize") doubleValue] 强转 —— 类型不匹配，',
    '// 面板却用 NSNumber 强转读值 —— 类型不匹配，')
errs = run_check(BASE_SRC, t)
if errs:
    print("  [FAIL] 面板注释里的示例被误报：%s" % errs[0])
    sys.exit(1)
print("  [PASS] 面板注释里的示例不误报")

print("")
print("=" * 70)
print("双向验证全部通过 ✅")
print("=" * 70)
