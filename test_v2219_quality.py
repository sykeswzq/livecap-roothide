#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.2.19 回归：回退 2.2.18 激进链路 + 元话术闸门（纯 Python 镜像 + 双向验证）。

背景（2026-11-14 设备录屏 + 本地实测）：
  2.2.18 照搬 PC 实时字幕方案的「LLM 上下文 + 短句合并」后译文更差：
    「你 ✓」/「"我拿！"」/「你提供的内容不完整，没有日语文本需要翻译…」
  本地用录屏音轨跑腾讯云一句话识别，稳态句就是「スだけど。」这类残片；
  带上一句 Context 让 agnes 脑补出「我想了想」，无分隔拼接把两句粘成一句，
  写死日语场景的 prompt 遇到非日语正文会回元话语。
  故回退到 2.2.17 逐句忠实直译，只保留幻觉/碎片闸门，并加元话术闸门。

本脚本镜像 LiveCap.m 的三道闸门，并做双向验证：
把旧写法重新注入源码/面板/postinst，verify_source_safety 必须准确拦下。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verify_source_safety as V

SRC = io.open(os.path.join(HERE, "LiveCap.m"), encoding="utf-8").read()
PANEL = io.open(os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m"),
                encoding="utf-8").read()
POSTINST = io.open(os.path.join(HERE, "postinst"), encoding="utf-8").read()

failures = []


def check(cond, label, detail=""):
    if not cond:
        failures.append("%s %s" % (label, detail))
        print("  [FAIL] %s %s" % (label, detail))
    return cond


# ---------------------------------------------------------------------------
# A. 元话术闸门（镜像 LCIsMetaReply）
# ---------------------------------------------------------------------------
STRONG = [
    "请补充", "请提供需要", "请重新输入", "没有日语文本", "没有需要翻译",
    "内容不完整", "文本需要翻译", "无法翻译", "不能翻译", "无法完成",
    "作为一个AI", "作为AI语言", "（无内容）", "(无内容)",
    "字幕内容需要", "请提供日语", "No Japanese text", "Please provide the",
]
WEAK = ["请提供", "请输入", "抱歉", "对不起", "不清楚", "无法", "不完整"]


def is_meta(s):
    if any(w in s for w in STRONG):
        return True
    return sum(1 for w in WEAK if w in s) >= 2


META_CASES = [
    ("你提供的内容不完整，没有日语文本需要翻译。请补充需要翻译的日语字幕内容。", True),
    ("请补充需要翻译的日语字幕内容", True),
    ("（无内容）", True),
    ("无法翻译该内容", True),
    ("请提供需要翻译的文本", True),
    ("抱歉，请提供一下地址", True),
    ("请提供你的名字", False),
    ("有时候我会跟他搭话。", False),
    ("虽然说是美容，但感觉不太对劲。", False),
    ("这虽然是按摩，但我觉得不一样。", False),
]
print("=" * 70)
print("A. 元话术闸门")
print("=" * 70)
for text, want in META_CASES:
    check(is_meta(text) == want, "meta [%s]" % text[:22],
          "实得 %s 期望 %s" % (is_meta(text), want))
print("  %d 例元话术判定完成" % len(META_CASES))


# ---------------------------------------------------------------------------
# B. 译文闸门（镜像 isUsableTranslation）
# ---------------------------------------------------------------------------
def usable(res, orig):
    if not res:
        return False
    norm = res.strip()
    orig = orig.strip()
    if not norm or norm == orig:
        return False
    unquoted = norm
    if len(norm) >= 3:
        f, l = norm[0], norm[-1]
        if (f == "\u201c" and l == "\u201d") or (f == '"' and l == '"') or \
           (f == "\u300c" and l == "\u300d"):
            unquoted = norm[1:-1]
    if unquoted == orig or is_meta(norm):
        return False
    cjk = sum(1 for c in norm if "\u4e00" <= c <= "\u9fff")
    if not cjk:
        return False
    if any("\u3040" <= c <= "\u30ff" or "\uac00" <= c <= "\ud7a3" for c in norm):
        return False
    if cjk <= 1 and len(norm) <= 3:
        return False
    if len(orig) <= 6 and len(norm) >= 20:
        return False
    latin = 0
    has_ext = False
    for c in norm:
        if "A" <= c <= "Z" or "a" <= c <= "z":
            latin += 1
        elif "\u00c0" <= c <= "\u024f":
            has_ext = True
            latin += 1
    if has_ext:
        return False
    total = len(norm) or 1
    if latin >= 3 and latin * 100 // total > 20:
        return False
    return True


TRANSLATION_CASES = [
    ("你", "違います", False, "单字译文「你 ✓」必须拦"),
    ("我拿！", "我拿！", False, "原文回显"),
    ("\u201c我拿！\u201d", "我拿！", False, "包引号的原文回显（录屏）"),
    ("你提供的内容不完整，没有日语文本需要翻译。请补充需要翻译的日语字幕内容。",
     "スだけど", False, "模型元话术（录屏）"),
    ("这是一段非常非常长的无关翻译记忆库串入内容测试句子",
     "あ", False, "短原文吐长段"),
    ("日本語です", "にほんご", False, "含假名不是中文"),
    ("您好，我是 La Von。", "こんにちはラヴォンです", False, "半中半洋"),
    ("哇，花 kh\u00f6p", "かわいい", False, "带变音拉丁字母"),
    ("虽然说是美容，但感觉不太对劲。", "エステだけど違います", True, "正常译文"),
    ("有时候我会跟他说上几句话。", "時々あいつに話しかけるんだよ", True, "正常译文"),
    ("好的，OK", "はい", True, "短句带缩写不误杀"),
    ("不是", "違います", True, "两字正常译文不误杀"),
]
print("")
print("=" * 70)
print("B. 译文闸门")
print("=" * 70)
for res, orig, want, label in TRANSLATION_CASES:
    check(usable(res, orig) == want, "usable [%s]" % label,
          "res=[%s] 实得 %s 期望 %s" % (res[:20], usable(res, orig), want))
print("  %d 例译文闸门完成" % len(TRANSLATION_CASES))


# ---------------------------------------------------------------------------
# C. 幻觉 / 碎片闸门：只丢垃圾，绝不跨句拼接
# ---------------------------------------------------------------------------
HALLU = [
    "ご視聴ありがとうございました", "ご視聴有難うございました",
    "チャンネル登録をお願いします", "高評価をお願いします",
    "次回もお楽しみに", "ご清聴ありがとうございました",
    "Thank you for watching", "Thanks for watching",
    "Please subscribe", "Like and subscribe",
    "感谢您的观看", "谢谢观看", "字幕由", "本字幕由",
    "请不吝点赞", "未完待续",
]


def is_hallucination(s):
    return any(w in s for w in HALLU)


def is_junk(s):
    if len(s) < 3:
        return True
    return len(set(s)) == 1


print("")
print("=" * 70)
print("C. 幻觉 / 碎片闸门（不拼接）")
print("=" * 70)
FRAG_CASES = [
    ("ご視聴ありがとうございました", True, False),
    ("Thanks for watching", True, False),
    ("今日はいい天気ですね", False, False),
    ("スだけど。", False, False),
    ("違います", False, False),
    ("あ", False, True),
    ("あああ", False, True),
]
for s, want_h, want_j in FRAG_CASES:
    check(is_hallucination(s) == want_h, "hallu [%s]" % s[:14], "")
    check(is_junk(s) == want_j, "junk [%s]" % s[:14], "")
# 负向断言：源码里绝不能出现跨句拼接缓冲 / 上下文窗口
for token in ("_recentLines", "fullPrompt", "_shortCarry", "LCHasSentenceEnd",
              "asr: ws carry merged", "asr: ws hold short"):
    check(token not in SRC, "源码不含 %s" % token, "2.2.18 残留会串句/脑补")
print("  幻觉/碎片判定 + 无跨句拼接断言完成")


# ---------------------------------------------------------------------------
# D/E. 双向验证
# ---------------------------------------------------------------------------
def run_check(src_text=None, panel_text=None, postinst_text=None):
    V.errors = []
    V.warnings = []
    V.check_v2219_fixes(src_text if src_text is not None else SRC,
                        panel_text if panel_text is not None else PANEL,
                        postinst_text if postinst_text is not None else POSTINST)
    return list(V.errors)


def mutate(text, old, new, tag):
    if old not in text:
        raise AssertionError("[%s] 锚点未命中: %r" % (tag, old[:80]))
    return text.replace(old, new, 1)


def mutate_all(text, old, new, tag):
    if old not in text:
        raise AssertionError("[%s] 锚点未命中: %r" % (tag, old[:80]))
    return text.replace(old, new)


print("")
print("=" * 70)
print("D. 双向验证（修复版零误报 / 旧 bug 被准确拦下）")
print("=" * 70)
errs = run_check()
check(not errs, "修复版零误报", str(errs[:2]))

NEGATIVE = [
    ("删掉元话术闸门",
     dict(src_text=SRC.replace("LCIsMetaReply(norm)", "LCNoMeta(norm)", 1)),
     "元话术闸门"),
    ("恢复 LLM 上下文窗口",
     dict(src_text=SRC.replace("NSDate *t0 = [NSDate date];",
                               "NSMutableArray *_recentLines;\n    NSDate *t0 = [NSDate date];", 1)),
     "仍残留"),
    ("恢复跨句拼接缓冲",
     dict(src_text=SRC.replace("NSDate *t0 = [NSDate date];",
                               "NSMutableString *_shortCarry;\n    NSDate *t0 = [NSDate date];", 1)),
     "仍残留"),
    ("恢复写死日语的 prompt",
     dict(src_text=SRC.replace("You are a subtitle translator.",
                               "Translate this Japanese subtitle.", 1)),
     "仍残留"),
    ("agnes 超时改回 3.5s",
     dict(src_text=SRC.replace("req.timeoutInterval = 4.5;",
                               "req.timeoutInterval = 3.5;", 1)),
     "agnes 超时放宽"),
    ("429 冷却改回 10s",
     dict(src_text=SRC.replace("+ 4.0;", "+ 10.0;")),
     "429 冷却缩短"),
    ("单字闸门放宽",
     dict(src_text=SRC.replace("cjkCount <= 1 && norm.length <= 3",
                               "cjkCount <= 0 && norm.length <= 0", 1)),
     "单字译文"),
    ("删掉主面板弹窗",
     dict(panel_text=mutate(PANEL, 'alertControllerWithTitle:@"字体大小"',
                            'alertControllerWithTitle:@"字号"', "no-alert")),
     "字号输入弹窗"),
    ("弹窗丢掉严格解析",
     dict(panel_text=mutate_all(PANEL, "lc_parseFontInput:", "lc_noParse:", "no-parse")),
     "严格数值解析"),
    ("字号页完成按钮改回 pop",
     dict(panel_text=mutate(
         PANEL, "    [self dismissViewControllerAnimated:YES completion:nil];\n}",
         "    [self.navigationController popViewControllerAnimated:YES];\n}", "pop-again")),
     "pop 关模态 root"),
    ("postinst 不刷新 Preferences",
     dict(postinst_text=POSTINST.replace("killall -9 Preferences", "")),
     "未刷新 Preferences"),
    ("删掉幻觉黑名单",
     dict(src_text=SRC.replace("LCIsHallucination", "LCNoHallucination")),
     "幻觉黑名单"),
]

for label, kwargs, keyword in NEGATIVE:
    errs = run_check(**kwargs)
    hit = [e for e in errs if keyword in e]
    if check(bool(hit), "[%s] 被拦截" % label, "错误列表=%s" % errs[:2]):
        print("  [PASS] %s -> %s" % (label, hit[0][:66]))

print("")
print("=" * 70)
if failures:
    print("v2.2.19 回归: %d 项失败" % len(failures))
    for f in failures[:12]:
        print("  - %s" % f)
    sys.exit(1)
print("v2.2.19 回归全部通过 ✅")
sys.exit(0)
