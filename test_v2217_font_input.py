#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.2.17 回归测试：字幕字号改为手动输入（纯 Python 镜像，不依赖设备）。

覆盖三件事：
  1. -[LCFontSizeController lc_parse:value:] 的严格数值语义（NSScanner 整串匹配）
  2. lc_apply:syncInput: 的单一写入口语义（预览/标签/滑块/输入框/plist 同步）
  3. 面板输入框 / 主面板显示 / tweak -fontSize 三处范围必须都是 8~72

外加双向验证：把关键实现替换回旧写法，verify_source_safety 必须准确报出。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verify_source_safety as V

REAL_SRC = os.path.join(HERE, "LiveCap.m")
REAL_PANEL = os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m")

FONT_MIN = 8.0
FONT_MAX = 72.0

SRC = io.open(REAL_SRC, encoding="utf-8").read()
PANEL = io.open(REAL_PANEL, encoding="utf-8").read()

failures = []


def check(cond, label, detail=""):
    if not cond:
        failures.append("%s %s" % (label, detail))
        print("  [FAIL] %s %s" % (label, detail))
    return cond


# ---------------------------------------------------------------------------
# 1) lc_parse:value: 的镜像（NSScanner scanDouble + isAtEnd）
# ---------------------------------------------------------------------------
_FLOAT_RE = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\Z")


def lc_parse(raw):
    """返回合法字号，或 None（不动预览、不写 plist）。"""
    s = (raw or "").strip()
    if not s:
        return None
    # NSScanner 的 scanDouble: 不接受尾随字符；isAtEnd 再兜一层。
    # 全角数字、逗号小数点、中文单位一律拒绝。
    if not _FLOAT_RE.match(s):
        return None
    try:
        v = float(s)
    except ValueError:
        return None
    if v < FONT_MIN or v > FONT_MAX:
        return None
    return v


PARSE_CASES = [
    # (输入, 期望值)  —— 合法
    ("16", 16.0), ("16.5", 16.5), (" 24 ", 24.0),
    ("8", 8.0), ("72", 72.0), ("8.0", 8.0), ("72.0", 72.0),
    ("18.25", 18.25), ("+20", 20.0), (".0", None),
    # —— 非法 / 脏输入
    ("", None), ("   ", None), ("abc", None), ("16abc", None),
    ("16 pt", None), ("7", None), ("7.9", None), ("73", None),
    ("999", None), ("-5", None), (".", None), ("1.2.3", None),
    ("０", None), ("16,5", None), ("１", None), (None, None),
]

print("=" * 70)
print("A. 输入解析（严格数值）")
print("=" * 70)
for raw, want in PARSE_CASES:
    got = lc_parse(raw)
    check(got == want, "parse(%r)" % raw, "期望 %r 实得 %r" % (want, got))
print("  %d 例输入解析完成" % len(PARSE_CASES))

# 输入途中不动作：想输 72，先打了 7；想输 16，先打了 1
print("  -- 输入途中不写脏值 --")
for seq, want_first, want_final in (("72", None, 72.0), ("16", None, 16.0),
                                    ("24.5", None, 24.5)):
    got = [lc_parse(seq[:i + 1]) for i in range(len(seq))]
    check(got[0] == want_first and got[-1] == want_final,
          "输入序列 %r" % seq, "期望首帧不动作、末帧生效，实得 %r" % (got,))


# ---------------------------------------------------------------------------
# 2) lc_apply:syncInput: 的镜像
# ---------------------------------------------------------------------------
print("")
print("=" * 70)
print("B. 单一写入口同步语义")
print("=" * 70)


def lc_apply(state, v, sync_input):
    state["preview_font"] = v
    state["label"] = "%g pt" % v
    state["slider"] = v
    if sync_input:
        state["input"] = "%g" % v
    state["fontSize"] = v      # LCSet(@(v), @"fontSize")
    state["lastWritten"] = v
    return state


st = {"input": "16", "preview_font": 16.0, "label": "16 pt",
      "slider": 16.0, "fontSize": 16.0, "lastWritten": 16.0}
# 手动输入 20：输入框不能被覆写（否则光标/文字会被打断），其余全部同步
lc_apply(st, 20.0, False)
check(st["fontSize"] == 20.0 and st["lastWritten"] == 20.0,
      "手动输入写回 plist", str(st))
check(st["preview_font"] == 20.0 and st["slider"] == 20.0
      and st["label"] == "20 pt", "手动输入同步预览/滑块/标签", str(st))
check(st["input"] == "16", "手动输入不得覆写输入框", str(st))

# 拖滑块到 30.5：输入框要跟着变，避免两处数值打架
lc_apply(st, 30.5, True)
check(st["input"] == "30.5" and st["fontSize"] == 30.5,
      "滑块微调回写输入框", str(st))

# 非法输入点「完成」：回落到最近一次有效值，绝不写脏数据
last = st["lastWritten"]
raw = "abc"
v = lc_parse(raw)
if v is None:
    v = last
lc_apply(st, v, False)
check(st["fontSize"] == last and st["fontSize"] != 0,
      "非法输入回落有效值", str(st))


# ---------------------------------------------------------------------------
# 3) 三处范围一致性
# ---------------------------------------------------------------------------
print("")
print("=" * 70)
print("C. 范围一致性（面板 / 主面板 / tweak）")
print("=" * 70)

mn = re.search(r"kLCFontMin\s*=\s*([\d.]+)", PANEL)
mx = re.search(r"kLCFontMax\s*=\s*([\d.]+)", PANEL)
g = re.search(r"if \(val < ([\d.]+) \|\| val > ([\d.]+)\) val = 16\.0;", SRC)
check(mn is not None and float(mn.group(1)) == FONT_MIN,
      "面板下限", "实得 %s" % (mn.group(1) if mn else None))
check(mx is not None and float(mx.group(1)) == FONT_MAX,
      "面板上限", "实得 %s" % (mx.group(1) if mx else None))
check(g is not None and float(g.group(1)) == FONT_MIN
      and float(g.group(2)) == FONT_MAX,
      "tweak -fontSize 范围", "实得 %s" % (str(g.groups()) if g else "None"))
check("if (fs < kLCFontMin || fs > kLCFontMax) fs = 16.0;" in PANEL,
      "主面板显示用同一对常量", "")
check(PANEL.count("if (fs < kLCFontMin || fs > kLCFontMax) fs = 16.0;") >= 2,
      "viewDidLoad 与 cell 都按新范围钳制", "")


# ---------------------------------------------------------------------------
# 4) 双向验证：把实现退回旧写法，检查器必须准确拦下
# ---------------------------------------------------------------------------
print("")
print("=" * 70)
print("D. 双向验证（重注入旧写法必须被拦）")
print("=" * 70)


def run_check(src_text, panel_text):
    V.errors = []
    V.warnings = []
    V.check_v2217_font_input(src_text, panel_text)
    return list(V.errors)


errs = run_check(SRC, PANEL)
check(not errs, "修复版零误报", str(errs[:2]))


def mutate(text, old, new, tag):
    if old not in text:
        raise AssertionError("[%s] 变异锚点未命中: %r" % (tag, old[:100]))
    return text.replace(old, new, 1)


NEGATIVE = [
    ("去掉手动输入框", mutate(PANEL, "UITextField *_input;", "", "no-input"),
     SRC, "手动输入框"),
    ("换回普通键盘", mutate(PANEL, "UIKeyboardTypeDecimalPad",
                          "UIKeyboardTypeDefault", "kbd"), SRC, "数字键盘"),
    ("放宽整串校验(允许 16abc)", mutate(PANEL,
     "[sc scanDouble:&v] || ![sc isAtEnd]", "[sc scanDouble:&v]",
     "loose"), SRC, "整串匹配"),
    ("上限退回 40", mutate(PANEL, "kLCFontMax = 72.0",
                         "kLCFontMax = 40.0", "max"), SRC, "字号上限"),
    ("加回竖直旋转滑块", PANEL.replace("    _slider.minimumValue",
     "    _slider.transform = CGAffineTransformMakeRotation(M_PI_2);\n"
     "    _slider.minimumValue", 1), SRC, "竖直旋转滑块"),
    ("主面板仍按 10~40", mutate(PANEL,
     "if (fs < kLCFontMin || fs > kLCFontMax) fs = 16.0;",
     "if (fs < 10 || fs > 40) fs = 16.0;", "cell-range"), SRC, "仍按 10~40"),
    ("tweak 仍按 10~40", PANEL,
     mutate(SRC, "if (val < 8 || val > 72) val = 16.0;",
            "if (val < 10 || val > 40) val = 16.0;", "getter"), "10~40"),
    ("tweak 漏同步放宽", PANEL,
     mutate(SRC, "if (val < 8 || val > 72) val = 16.0;", "", "no-getter"),
     "8~72"),
]

for label, bad_panel, bad_src, keyword in NEGATIVE:
    errs = run_check(bad_src, bad_panel)
    hit = [e for e in errs if keyword in e]
    if not check(bool(hit), "[%s] 被拦截" % label,
                 "错误列表=%s" % errs[:2]):
        continue
    print("  [PASS] %s -> %s" % (label, hit[0][:60]))

print("")
print("=" * 70)
if failures:
    print("v2.2.17 回归: %d 项失败" % len(failures))
    for f in failures[:12]:
        print("  - %s" % f)
    sys.exit(1)
print("v2.2.17 回归全部通过 ✅")
sys.exit(0)
