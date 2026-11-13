#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.2.18 回归：主面板字号弹窗 + 日语实时字幕质量链路（纯 Python 镜像）。

参考的业界方案（用户要求「全网找 PC/iOS 实时翻译软件做参考」后的落地项）：
  live-subtitle (Windows)     28 条 Whisper 幻觉黑名单 / 断句分包 / 10s 过期
  realtime_subtitle (PC)      短句合并 ≤20 词 / LLM 上下文窗口 / 连续性检测
  VideoCaptioner              上下文感知翻译 / 翻译-反思-翻译
  iOS Live Caption 实践       partial 就地更新、成句才滚动、scrim 保证可读性

本脚本镜像 LiveCap.m 里新增的四道闸门，并做双向验证：
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
# A. 幻觉黑名单（live-subtitle 的 28 条思路，这里取本项目用到的 16 条）
# ---------------------------------------------------------------------------
HALLUCINATIONS = [
    "ご視聴ありがとうございました", "ご視聴有難うございました",
    "チャンネル登録をお願いします", "高評価をお願いします",
    "次回もお楽しみに", "ご清聴ありがとうございました",
    "Thank you for watching", "Thanks for watching",
    "Please subscribe", "Like and subscribe",
    "感谢您的观看", "谢谢观看", "字幕由", "本字幕由",
    "请不吝点赞", "未完待续",
]


def is_hallucination(s):
    return any(w in s for w in HALLUCINATIONS)


def is_junk(s):
    if len(s) < 4:
        return True
    return len(set(s)) == 1


def has_sentence_end(s):
    return bool(s) and s[-1] in ".?!。？！、，"


print("=" * 70)
print("A. 幻觉 / 碎片闸门")
print("=" * 70)
HALLU_CASES = [
    ("ご視聴ありがとうございました", True),
    ("Thanks for watching", True),
    ("感谢您的观看", True),
    ("今日はいい天気ですね", False),
    ("時々あいつに話しかけるんだよ", False),
    ("彼", False),
]
for s, want in HALLU_CASES:
    check(is_hallucination(s) == want, "hallucination(%r)" % s,
          "期望 %r" % want)
JUNK_CASES = [("彼", True), ("うん", True), ("ああああ", True),
              ("今日はいい天気ですね", False), ("時々話しかける", False)]
for s, want in JUNK_CASES:
    check(is_junk(s) == want, "junk(%r)" % s, "期望 %r" % want)
print("  %d 例闸门判定完成" % (len(HALLU_CASES) + len(JUNK_CASES)))


# ---------------------------------------------------------------------------
# B. 短句合并状态机（realtime_subtitle 的短句合并思路）
# ---------------------------------------------------------------------------
class Committer(object):
    def __init__(self):
        self.carry = ""
        self.carry_at = 0.0
        self.last = ""
        self.sent = []

    def commit(self, raw, now):
        s = raw.strip()
        if len(s) < 2:
            return "drop-short"
        if is_hallucination(s):
            return "drop-hallucination"
        weak = not has_sentence_end(s)
        if weak and len(s) < 8 and not is_junk(s):
            self.carry += s
            self.carry_at = now
            if len(self.carry) < 12:
                return "hold"
            s = self.carry
            self.carry = ""
        elif self.carry:
            s = self.carry + s
            self.carry = ""
        if is_junk(s):
            return "drop-junk"
        if s == self.last:
            return "drop-duplicate"
        self.last = s
        self.sent.append((now, s))
        return "send"

    def flush(self, now):
        if not self.carry or now - self.carry_at < 2.5:
            return None
        c = self.carry
        self.carry = ""
        if len(c) >= 4 and not is_hallucination(c):
            self.last = c
            self.sent.append((now, c))
            return "flush"
        return "drop-junk-flush"


print("")
print("=" * 70)
print("B. 短句合并（碎句不再单独上屏）")
print("=" * 70)
c = Committer()
check(c.commit("彼", 1.0) in ("drop-short", "drop-junk"),
      "单字碎片必须丢弃", str(c.sent))
check(c.commit("ご視聴ありがとうございました", 1.1) == "drop-hallucination",
      "片尾幻觉必须丢弃", str(c.sent))
check(c.commit("時々話しかける", 2.0) == "hold",
      "7 字无标点短句先攒着", str(c.carry))
check(c.commit("んだよ", 3.0) == "send",
      "下一句到来时合并后送译", str(c.sent))
check(c.sent[-1][1] == "時々話しかけるんだよ",
      "合并结果完整", str(c.sent))
check(c.commit("今日はいい天気ですね", 4.0) == "send",
      "正常整句直接送译", str(c.sent))
check(c.commit("今日はいい天気ですね", 4.2) == "drop-duplicate",
      "同句去重", str(c.sent))

c2 = Committer()
check(c2.commit("時々話しかける", 1.0) == "hold", "尾句短句先攒着", "")
check(c2.flush(2.0) is None, "2.5s 内不误冲", "")
check(c2.flush(4.0) == "flush", "超时必须冲出，避免最后一句丢失", str(c2.sent))

c3 = Committer()
check(c3.commit("あ", 1.0) in ("drop-short", "drop-junk"),
      "纯语气词不进缓冲", str(c3.carry))


# ---------------------------------------------------------------------------
# C. LLM 上下文窗口（realtime_subtitle 的 LLM_TRANSLATION_HISTORY_SIZE）
# ---------------------------------------------------------------------------
print("")
print("=" * 70)
print("C. 上下文窗口（只含已送译的前 2 句）")
print("=" * 70)


class Context(object):
    def __init__(self):
        self.recent = []

    def pump(self, text):
        ctx = " / ".join(self.recent)
        self.recent.append(text)
        if len(self.recent) > 2:
            self.recent.pop(0)
        return ctx


ctx = Context()
for line, want in [("第一句", ""), ("第二句", "第一句"),
                   ("第三句", "第一句 / 第二句"),
                   ("第四句", "第二句 / 第三句")]:
    got = ctx.pump(line)
    check(got == want, "pump(%r)" % line, "期望上下文 %r 实得 %r" % (want, got))


# ---------------------------------------------------------------------------
# D. 译文最小长度闸门（拦「他 ✓」）
# ---------------------------------------------------------------------------
print("")
print("=" * 70)
print("D. 译文最小长度闸门")
print("=" * 70)


def usable(res, orig):
    norm = (res or "").strip()
    o = (orig or "").strip()
    if not norm or norm == o:
        return False
    cjk = sum(1 for ch in norm if "\u4e00" <= ch <= "\u9fff")
    if cjk == 0:
        return False
    if any("\u3040" <= ch <= "\u30ff" or "\uac00" <= ch <= "\ud7a3"
           for ch in norm):
        return False
    if any("\u00c0" <= ch <= "\u024f" for ch in norm):
        return False
    latin = sum(1 for ch in norm if ("A" <= ch <= "Z") or ("a" <= ch <= "z")
                or ("\u00c0" <= ch <= "\u024f"))
    if latin >= 3 and latin * 100 // len(norm) > 20:
        return False
    if len(o) >= 6 and cjk <= 1:
        return False
    return True


GATE_CASES = [
    ("他", "これは長い日本語の原文です", False),
    ("好", "今日はいい天気ですね", False),
    ("今天天气真好啊", "今日はいい天気ですね", True),
    ("你好", "こんにちは", True),           # 原文短，允许短译文
    ("ありがとう", "長い原文がここにあります", False),
    ("您好，我是 La Von。", "長い原文がここにあります", False),
    ("哇，花 khöp", "長い原文がここにあります", False),
    ("有时我告诉它", "時々あいつに話しかけるんだよ", True),
]
for res, orig, want in GATE_CASES:
    check(usable(res, orig) == want, "usable(%r)" % res,
          "期望 %r" % want)
print("  %d 例译文闸门完成" % len(GATE_CASES))


# ---------------------------------------------------------------------------
# E. 双向验证：把旧写法注入，检查器必须准确拦下
# ---------------------------------------------------------------------------
print("")
print("=" * 70)
print("E. 双向验证")
print("=" * 70)


def run_check(src_text=None, panel_text=None, postinst_text=None):
    V.errors = []
    V.warnings = []
    V.check_v2218_fixes(src_text if src_text is not None else SRC,
                        panel_text if panel_text is not None else PANEL,
                        postinst_text if postinst_text is not None else POSTINST)
    return list(V.errors)


def mutate(text, old, new, tag):
    if old not in text:
        raise AssertionError("[%s] 锚点未命中: %r" % (tag, old[:80]))
    return text.replace(old, new, 1)


def mutate_all(text, old, new, tag):
    """方法名在定义处和调用处都出现，变异必须两处一起改。"""
    if old not in text:
        raise AssertionError("[%s] 锚点未命中: %r" % (tag, old[:80]))
    return text.replace(old, new)


errs = run_check()
check(not errs, "修复版零误报", str(errs[:2]))

NEGATIVE = [
    ("删掉主面板弹窗",
     dict(panel_text=mutate(PANEL, 'alertControllerWithTitle:@"字体大小"',
                            'alertControllerWithTitle:@"字号"', "no-alert")),
     "字号输入弹窗"),
    ("弹窗丢掉严格解析",
     dict(panel_text=mutate_all(PANEL, "lc_parseFontInput:",
                                "lc_noParse:", "no-parse")),
     "严格数值解析"),
    ("字号页完成按钮改回 pop",
     dict(panel_text=mutate(
         PANEL, "    [self dismissViewControllerAnimated:YES completion:nil];\n}",
         "    [self.navigationController popViewControllerAnimated:YES];\n}",
         "pop-again")),
     "pop 关模态 root"),
    ("postinst 不刷新 Preferences",
     dict(postinst_text=POSTINST.replace("killall -9 Preferences", "")),
     "未刷新 Preferences"),
    ("去掉上下文窗口",
     dict(src_text=SRC.replace("_recentLines", "_noRecent")),
     "上下文窗口"),
    ("prompt 改回半成品照翻",
     dict(src_text=SRC.replace("Output ONLY Chinese: no quotes",
                               "If the input is an incomplete fragment, leave it incomplete. "
                               "Output ONLY Chinese: no quotes", 1)),
     "半成品照翻不补全"),
    ("删掉幻觉黑名单",
     dict(src_text=SRC.replace("LCIsHallucination", "LCNoHallucination")),
     "幻觉黑名单"),
    ("删掉译文最小长度闸门",
     dict(src_text=SRC.replace("orig.length >= 6 && cjkCount <= 1",
                               "orig.length >= 6000 && cjkCount <= 1")),
     "译文最小长度闸门"),
]

for label, kwargs, keyword in NEGATIVE:
    errs = run_check(**kwargs)
    hit = [e for e in errs if keyword in e]
    if check(bool(hit), "[%s] 被拦截" % label,
             "错误列表=%s" % errs[:2]):
        print("  [PASS] %s -> %s" % (label, hit[0][:70]))

print("")
print("=" * 70)
if failures:
    print("v2.2.18 回归: %d 项失败" % len(failures))
    for f in failures[:12]:
        print("  - %s" % f)
    sys.exit(1)
print("v2.2.18 回归全部通过 ✅")
sys.exit(0)
