#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.2.16 回归测试：ASR 引擎降级决策 + 译文质量闸门（纯 Python 镜像）。

本地实测依据（2026-11-13，同一账号、同一份用户反馈视频音轨）：
  实时 WebSocket  16k_multi_lang -> code=4004 资源包耗尽
                  16k_ja / 16k_ko / 16k_en / 16k_zh -> code=0
  HTTP 一句话识别 16k_multi_lang -> 正常（但 1.5s 切片会切碎日语）
  agnes 对正确日语 -> 准确中文；对碎片源文 -> 忠实直译出怪句子
本测试锁定「显式覆盖生效 / 按源语言选可用引擎 / 4004 只降级一次 /
译文闸门拦半中半洋」四件事，并从 LiveCap.m 提取常量防止被改回去。
"""
import re
import sys

SRC = 'LiveCap.m'
source = open(SRC, 'r', encoding='utf-8').read()
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


# ---------- 1) 源码断言 ----------
for token, why in (
        ('if (s.length) return s;', 'asrEngine 显式覆盖生效'),
        ('return @"16k_ja";', 'ja 映射'),
        ('return @"16k_ko";', 'ko 映射'),
        ('return @"16k_en";', 'en 映射'),
        ('return @"16k_zh";', 'zh 映射'),
        ('return @"16k_multi_lang";', 'auto 仍优先多语种大模型'),
        ('_engineOverride', '会话内降级引擎'),
        ('_engineFallbackDone', '降级只做一次'),
        ('latin * 100 / total > 20', '译文闸门占比阈值'),
        ('backcheck mymemory daily quota exhausted', '回译自检复用冷却')):
    check(token in source, '源码缺少 %s —— %s' % (token, why))
check('NSString *eng = @"16k_multi_lang";' not in source,
      'HTTP 分片路径仍写死 16k_multi_lang')
check('[[LCConfig shared] asrEngine]' in source,
      'HTTP 分片路径未接入统一引擎选择')

# ---------- 2) 镜像 asrEngine ----------
KNOWN = {'auto', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru', 'ar', 'th', 'zh'}


def asr_engine(plist_engine, src_lang):
    if plist_engine:
        return plist_engine                      # 显式覆盖一律生效
    if src_lang not in KNOWN:
        src_lang = 'auto'
    return {'ja': '16k_ja', 'ko': '16k_ko',
            'en': '16k_en', 'zh': '16k_zh'}.get(src_lang, '16k_multi_lang')


ENGINE_CASES = [
    (None, 'auto', '16k_multi_lang', 'auto 仍优先多语种（充值后自动用回）'),
    (None, 'ja', '16k_ja', '面板选日语 -> 直接可用的日语引擎'),
    (None, 'ko', '16k_ko', '面板选韩语'),
    (None, 'en', '16k_en', '面板选英语'),
    (None, 'zh', '16k_zh', '面板选中文'),
    (None, 'fr', '16k_multi_lang', '未映射语种回落多语种'),
    ('16k_en', 'ja', '16k_en', '显式覆盖不再被越权改写（v2.2.9 的坑）'),
    ('16k_multi_lang', 'ja', '16k_multi_lang', '充值后可手动用回大模型'),
]
for p, lang, want, why in ENGINE_CASES:
    got = asr_engine(p, lang)
    check(got == want, '引擎映射错误: plist=%s lang=%s -> %s，应为 %s（%s）'
          % (p, lang, got, want, why))

# ---------- 3) 镜像 4004 降级状态机 ----------
class Stream(object):
    def __init__(self, src_lang):
        self.src_lang = src_lang
        self.override = None
        self.done = False
        self.stopped = False

    def on_code(self, code):
        if code in (4002, 4003):
            self.stopped = True
            return 'stop'
        if code == 4004:
            if self.done:
                self.stopped = True
                return 'stop'
            self.done = True
            self.override = {'ko': '16k_ko', 'en': '16k_en',
                             'zh': '16k_zh'}.get(self.src_lang, '16k_ja')
            return 'reconnect:' + self.override
        return 'reconnect'

    def engine(self):
        return self.override or asr_engine(None, self.src_lang)


s = Stream('auto')
check(s.on_code(4004) == 'reconnect:16k_ja', '首次 4004 应降级重连到 16k_ja')
check(s.engine() == '16k_ja', '降级后握手必须使用新引擎')
check(s.on_code(4004) == 'stop', '降级后再次 4004 必须停，防止死循环')
check(s.stopped is True, '二次 4004 后应回落 HTTP')
s2 = Stream('en')
check(s2.on_code(4004) == 'reconnect:16k_en', '英文源应降级到 16k_en')
check(Stream('auto').on_code(4002) == 'stop', '签名错误不应重连')

# ---------- 4) 镜像 isUsableTranslation ----------
def usable(res, text):
    norm = (res or '').strip()
    orig = (text or '').strip()
    if not norm or norm == orig:
        return False
    has_cjk = False
    has_kana = False
    latin = 0
    has_latin_ext = False
    for ch in norm:
        c = ord(ch)
        if 0x4E00 <= c <= 0x9FFF:
            has_cjk = True
        elif (0x3040 <= c <= 0x30FF) or (0xAC00 <= c <= 0xD7A3):
            has_kana = True
        if (65 <= c <= 90) or (97 <= c <= 122):
            latin += 1
        elif 0x00C0 <= c <= 0x024F:
            has_latin_ext = True
            latin += 1
    if not has_cjk or has_kana:
        return False
    if has_latin_ext:
        return False
    total = len(norm) or 1
    return not (latin >= 3 and latin * 100 // total > 20)


TEXT_CASES = [
    ('您好，我是 La Von。', 'こんにちは', False, '视频里的怪句子必须被拦'),
    ('哇，花 khöp', 'わぁ', False, '带变音拉丁字母的碎片必须被拦'),
    ('比如光彩照人的东西。', '例えば', True, '正常中文译文放行'),
    ('你在哪里吃饭？', 'どこで食べるの', True, '正常中文译文放行'),
    ('好久不见，你还好吗？', '久しぶり', True, 'agnes 准确译文放行'),
    ('好的，OK', 'はい', True, '少量缩写不误杀（20% 阈值内）'),
    ('栄養あるものを食べてね', '栄養', False, '日文回显拒绝'),
    ('한국어입니다', '한국어', False, '韩文回显拒绝'),
    ('Hello world', 'hello', False, '纯英文拒绝'),
]
for res, txt, want, why in TEXT_CASES:
    got = usable(res, txt)
    check(got == want, '译文闸门错误: [%s] -> %s，应为 %s（%s）'
          % (res, got, want, why))

# ---------- 结果 ----------
if errors:
    for e in errors:
        print('  FAIL:', e)
    print('v2.2.16 回归: %d 项失败' % len(errors))
    sys.exit(1)
print('v2.2.16 回归全部通过 ✅')
print('  引擎映射 %d 例 / 4004 降级状态机 %d 例 / 译文闸门 %d 例'
      % (len(ENGINE_CASES), 5, len(TEXT_CASES)))
