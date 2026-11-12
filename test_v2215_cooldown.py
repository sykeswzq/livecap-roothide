#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.2.15 限流恢复状态机回归测试（纯 Python 镜像 raceTranslate 决策）。

背景：2026-11-12 设备日志里 agnes 一次 429 就停 90 秒，同时 MyMemory
当日额度耗尽、腾讯 TMT 未开通 → 三条通道全断，连续 38 句没有中文。
本测试锁定「短冷却 + 半开探测 + 免费兜底停摆时 agnes 强制参赛 +
providers 永不为空」这套逻辑，并从 LiveCap.m 提取常量防止以后被改回去。
"""
import re
import sys

SRC = 'LiveCap.m'
source = open(SRC, 'r', encoding='utf-8').read()

# ---- 常量必须与源码一致 ----
m = re.search(r'_agnesPausedUntil = \[NSDate timeIntervalSinceReferenceDate\] \+ ([\d.]+);', source)
AGNES_COOLDOWN = float(m.group(1)) if m else None
m = re.search(r'_mymemoryPausedUntil = \[NSDate timeIntervalSinceReferenceDate\] \+ ([\d.]+);', source)
MYMEM_COOLDOWN = float(m.group(1)) if m else None
m = re.search(r'_lastAgnesSendAt < ([\d.]+)', source)
AGNES_MIN_GAP = float(m.group(1)) if m else None
PROBE_EVERY = 5 if 'seq % 5 == 0' in source else None

errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


check(AGNES_COOLDOWN == 10.0, 'agnes 冷却应为 10 秒，实际 %s（旧版 90 秒会长时间没中文）' % AGNES_COOLDOWN)
check(MYMEM_COOLDOWN == 600.0, 'MyMemory 额度耗尽冷却应为 600 秒，实际 %s' % MYMEM_COOLDOWN)
check(AGNES_MIN_GAP == 0.35, 'agnes 最小发送间隔应为 0.35s，实际 %s' % AGNES_MIN_GAP)
check(PROBE_EVERY == 5, '半开探测应为每 5 句一次')
for token, why in (
        ('_mymemoryPausedUntil', 'MyMemory 冷却状态'),
        ('mymemory daily quota exhausted', '429 日额度识别'),
        ('halfOpenProbe', '冷却期半开探测'),
        ('forceAgnes', '兜底停摆时 agnes 强制参赛'),
        ('providers.count == 0', 'providers 永不为空的保护'),
        ('_lastAgnesSendAt', 'agnes 请求节流'),
        ('_agnesPausedUntil = 0;', 'agnes 成功即解除冷却')):
    check(token in source, '源码缺少 %s —— %s' % (token, why))
check('pause 90s' not in source, '仍残留旧的 pause 90s 逻辑')


class Translator(object):
    """镜像 LCTranslator 的参赛厂商决策（不含网络）。"""

    def __init__(self):
        self.t = 0.0
        self.agnes_until = 0.0
        self.mymem_until = 0.0
        self.last_agnes_send = 0.0
        self.seq = 0
        self.tencent_disabled = True   # 设备实测：TMT 服务未开通
        self.has_key = True

    def on_agnes_429(self):
        self.agnes_until = self.t + AGNES_COOLDOWN

    def on_agnes_success(self):
        self.agnes_until = 0.0

    def on_mymem_quota(self):
        self.mymem_until = self.t + MYMEM_COOLDOWN

    def decide(self):
        self.seq += 1
        agnes_paused = self.agnes_until > 0 and self.t < self.agnes_until
        mymem_cooling = self.mymem_until > 0 and self.t < self.mymem_until
        probe = (self.seq % PROBE_EVERY == 0)
        force_agnes = mymem_cooling
        providers = []
        if self.has_key and (not agnes_paused or probe or force_agnes):
            providers.append('agnes')
        if not mymem_cooling:
            providers.append('mymemory')
        if not self.tencent_disabled:
            providers.append('tencent')
        if not providers:
            providers.append('mymemory')
        return providers

    def send_gap(self):
        """agnes 请求节流：返回本句需要延迟多少秒。"""
        delay = 0.0
        if self.last_agnes_send > 0 and self.t - self.last_agnes_send < AGNES_MIN_GAP:
            delay = AGNES_MIN_GAP - (self.t - self.last_agnes_send)
        self.last_agnes_send = self.t + delay
        return delay


# ---- 场景 1：正常态 ----
x = Translator()
check(x.decide() == ['agnes', 'mymemory'], '正常态应有 agnes + mymemory')

# ---- 场景 2：agnes 偶发 429（MyMemory 仍可用）----
x = Translator()
x.on_agnes_429()
seqs_with_agnes = []
for i in range(2, 10):
    x.t = i * 1.5
    ps = x.decide()
    check('mymemory' in ps, 'agnes 冷却期 MyMemory 应继续兜底 (t=%.1f)' % x.t)
    if 'agnes' in ps:
        seqs_with_agnes.append(x.seq)
check(any(s % 5 == 0 for s in seqs_with_agnes), '冷却期内应有半开探测让 agnes 参赛')
x.t = 11.0
check('agnes' in x.decide(), '10 秒冷却到期后 agnes 必须恢复参赛')

# ---- 场景 3：MyMemory 当日额度耗尽（本次用户遇到的情况）----
x = Translator()
x.on_mymem_quota()
x.on_agnes_429()          # 最坏：两条同时挂
for i in range(1, 12):
    x.t = i * 1.5
    ps = x.decide()
    check('agnes' in ps, 'MyMemory 冷却 + agnes 冷却时，agnes 仍须强制参赛 (t=%.1f)' % x.t)
    check('mymemory' not in ps, 'MyMemory 冷却期间不应再发无效请求 (t=%.1f)' % x.t)
    check(len(ps) > 0, 'providers 不能为空 (t=%.1f)' % x.t)

# ---- 场景 4：agnes 翻出中文后立刻解除冷却 ----
x = Translator()
x.on_agnes_429()
x.t = 2.0
x.on_agnes_success()
check('agnes' in x.decide(), 'agnes 成功后应立刻解除冷却')

# ---- 场景 5：请求节流 ----
x = Translator()
gaps = []
for i in range(6):
    x.t = i * 0.1
    gaps.append(x.send_gap())
check(gaps[0] == 0.0, '首个 agnes 请求不应延迟')
check(all(g >= 0 for g in gaps), '节流延迟不能为负')
check(x.last_agnes_send >= 0.5 - 1e-9, '预约机制应把 6 个请求摊开到至少 0.5 秒')

# ---- 场景 6：无 API key 且 MyMemory 冷却 → 仍不能空 ----
x = Translator()
x.has_key = False
x.on_mymem_quota()
check(len(x.decide()) > 0, '无 key 且兜底冷却时 providers 仍不能为空')

if errors:
    for e in errors:
        print('  FAIL:', e)
    print('共 %d 项失败' % len(errors))
    sys.exit(1)
print('v2.2.15 限流恢复状态机: 6 个场景全部通过')
print('  agnes 冷却 %.0fs / 半开探测每 %d 句 / MyMemory 冷却 %.0fs / 最小间隔 %.2fs'
      % (AGNES_COOLDOWN, PROBE_EVERY, MYMEM_COOLDOWN, AGNES_MIN_GAP))
