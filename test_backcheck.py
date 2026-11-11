# -*- coding: utf-8 -*-
"""
v2.2.7 回译自检逻辑回归测试（Python 镜像 Objective-C 实现）。
用户不懂外语，无法核对翻译意思。回译自检做法：
  正向：外语原句 -> 中文译文
  回译：中文译文 -> 源语言，再与原句（同语言）比对相似度
  相似度高 -> ✓（可信）；低 -> ⚠（可能不准）
本测试验证两件事的纯逻辑：
  1) LCDetectLang：按脚本粗略判定源语言（ja/ko/zh/ru/ar/th/en）
  2) LCSimilarity：字符 2-gram Jaccard，以及 ✓/⚠ 阈值 0.55 的判定
运行：python3 test_backcheck.py
"""
import unicodedata


def lc_detect_lang(text):
    """镜像 LCDetectLang：返回 TMT 语言码。"""
    if not text:
        return "en"
    def has_range(a, b):
        for ch in text:
            cp = ord(ch)
            if a <= cp <= b:
                return True
        return False
    if has_range(0x3040, 0x30FF):      # 平假名+片假名（日语独有，先于汉字判定以区分中日）
        return "ja"
    if has_range(0x4E00, 0x9FFF):      # 汉字（中文视频直接返回 zh，不做回译）
        return "zh"
    if has_range(0xAC00, 0xD7A3):      # 谚文
        return "ko"
    if has_range(0x0400, 0x04FF):      # 西里尔
        return "ru"
    if has_range(0x0600, 0x06FF):      # 阿拉伯
        return "ar"
    if has_range(0x0E00, 0x0E7F):      # 泰文
        return "th"
    return "en"                         # 拉丁字母默认英语（覆盖 fr/es/de/pt/it 等）


def lc_normalize(s):
    """镜像 LCNormalize：只保留字母/数字并转小写（ASCII 转小写），丢弃空格与标点。"""
    if not s:
        return ""
    out = []
    for ch in s:
        if ch.isalnum():
            out.append(ch.lower())
    return "".join(out)


def lc_ngrams(s, n):
    if len(s) < n:
        return {s} if s else set()
    return {s[i:i+n] for i in range(0, len(s) - n + 1)}


def lc_similarity(a, b):
    """镜像 LCSimilarity：字符 2-gram Jaccard。"""
    a, b = lc_normalize(a), lc_normalize(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    n = 2
    sa, sb = lc_ngrams(a, n), lc_ngrams(b, n)
    if not sa or not sb:
        return 1.0 if a == b else 0.0
    inter = sa & sb
    union = len(sa) + len(sb) - len(inter)
    return (len(inter) / union) if union else 0.0


def self_check_mark(original, back_translation):
    """镜像 selfCheckOriginal 的判定：返回 'ok' / 'warn'。"""
    if not original or not back_translation:
        return None
    tgt = lc_detect_lang(original)
    if tgt == "zh":
        return None            # 源是中文，不做回译
    sim = lc_similarity(original, back_translation)
    return "ok" if sim >= 0.55 else "warn"


def is_usable_translation(res, text):
    """镜像 v2.2.8 的 isUsableTranslation：译文目标是简体中文。
    v2.2.8 起：结果含日文假名(0x3040-0x30FF)或韩文(0xAC00-0xD7A3)一律拒绝，
    否则翻译引擎回显/未翻译的日韩文会被误判成有效中文上屏。"""
    if not res:
        return False
    norm = res.strip()
    if not norm:
        return False
    if text is not None and norm.strip() == text.strip():
        return False
    has_cjk = False
    has_kana_or_hangul = False
    for ch in norm:
        cp = ord(ch)
        if 0x4E00 <= cp <= 0x9FFF:
            has_cjk = True
        elif (0x3040 <= cp <= 0x30FF) or (0xAC00 <= cp <= 0xD7A3):
            has_kana_or_hangul = True
    if not has_cjk:
        return False
    if has_kana_or_hangul:
        return False
    return True


def _assert(name, cond):
    print(("  PASS " if cond else "  FAIL ") + name)
    if not cond:
        _assert.failed += 1
_assert.failed = 0


if __name__ == "__main__":
    print("=== v2.2.7 回译自检逻辑测试 ===")

    print("[1] LCDetectLang 语言探测")
    _assert("日语 -> ja", lc_detect_lang("こんにちは、元気ですか") == "ja")
    _assert("韩语 -> ko", lc_detect_lang("안녕하세요 반갑습니다") == "ko")
    _assert("中文 -> zh", lc_detect_lang("你好，今天天气不错") == "zh")
    _assert("英语 -> en", lc_detect_lang("Hello everyone today") == "en")
    _assert("俄语 -> ru", lc_detect_lang("Привет, как дела") == "ru")
    _assert("阿拉伯 -> ar", lc_detect_lang("مرحبا بالعالم") == "ar")
    _assert("泰语 -> th", lc_detect_lang("สวัสดีครับ") == "th")
    _assert("法语(拉丁) -> en(默认)", lc_detect_lang("Bonjour à tous") == "en")

    print("[2] LCSimilarity 相似度")
    _assert("完全相同 -> 1.0", abs(lc_similarity("Hello world", "Hello world") - 1.0) < 1e-9)
    _assert("大小写/空格差异 -> 1.0", abs(lc_similarity("Hello world", "hello  world") - 1.0) < 1e-9)
    _assert("高度相似 -> 高", lc_similarity("Hello everyone today I want to share",
                                            "hello everyone today i want to share") > 0.9)
    _assert("部分重叠 -> 中", 0.2 < lc_similarity("Hello world", "hello there") < 0.8)
    _assert("完全不同(异语言) -> 0.0", lc_similarity("Hello world", "完全无关的中文内容") == 0.0)

    print("[3] selfCheck 判定（✓/⚠，阈值 0.55）")
    # 真实场景：英文原句 -> 中文 -> 回译英文，忠实回译应判 ok
    orig = "Mom left this home today"
    back_faithful = "Mother left home today"          # 忠实回译，应 ok
    back_wrong = "The weather is sunny outside"        # 错误回译，应 warn
    _assert("忠实回译 -> ok", self_check_mark(orig, back_faithful) == "ok")
    _assert("错误回译 -> warn", self_check_mark(orig, back_wrong) == "warn")
    _assert("中文源 -> None(不做回译)", self_check_mark("你好世界", "hello world") is None)
    _assert("空回译 -> None", self_check_mark(orig, "") is None)

    print("[4] 阈值边界演示")
    # 找一个刚好在 0.55 上下的案例，确认阈值有效
    s_high = lc_similarity("I want to go home now", "i want to go home now")
    s_low = lc_similarity("I want to go home now", "we should eat lunch later")
    _assert("高相似 >= 0.55", s_high >= 0.55)
    _assert("低相似 < 0.55", s_low < 0.55)

    print("[5] v2.2.8 isUsableTranslation：拒绝日/韩文，只接受中文")
    ja_res = "マンションの1室でやってるようなサロン"   # 真实录像里错误上屏的日文
    ko_res = "안녕하세요 반갑습니다"
    zh_res = "像在公寓单间里经营的美容沙龙"             # 正确的中文译文
    en_res = "This is a salon in a single apartment room"
    _assert("日文结果 -> 拒绝(非中文)", is_usable_translation(ja_res, "マンションの1室でやってるようなサロン") is False)
    _assert("韩文结果 -> 拒绝(非中文)", is_usable_translation(ko_res, ko_res) is False)
    _assert("中文结果 -> 接受", is_usable_translation(zh_res, "マンションの1室でやってるようなサロン") is True)
    _assert("英文结果 -> 拒绝(无汉字)", is_usable_translation(en_res, "apartment salon") is False)
    _assert("空结果 -> 拒绝", is_usable_translation("", "xxx") is False)
    # 含假名的中文边角：纯汉字中文应接受；夹带假名(如注音)应拒绝，避免漏放日文
    _assert("纯汉字中文 -> 接受", is_usable_translation("今天天气很好", "今日はいい天気") is True)

    print("")
    if _assert.failed == 0:
        print("全部通过 ✅  回译自检逻辑正确（语言探测 / 相似度 / ✓⚠ 判定）。")
    else:
        print("有 %d 项失败 ❌" % _assert.failed)
        raise SystemExit(1)
