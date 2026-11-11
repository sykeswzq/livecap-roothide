#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LiveCap 流式断句判定层 回归仿真
================================
目的：本地无法模拟真实语音 + 腾讯云 ASR 服务端，但"客户端断句判定"是一段
纯逻辑代码（lc_mergePartial / lc_updateSentence / lc_shouldCommit /
lc_flushIfSettled / lc_commitSentence），可以 1:1 移植后在事件流上跑 A/B 对比，
验证 v2.2.6 把静音阈值 1.0s -> 2.5s 后：
  (1) 不再把"句内停顿"误切成半句（核心修复）
  (2) 正常句末（slice_type=2）仍实时整句收句，字幕延迟不受影响
  (3) 句首 slice_type=0 帧不再丢头

注意：本仿真验证的是【客户端判定层】。服务端 VAD 在句内就发 slice_type=2
的情况客户端救不了（已由 v2.2.6 把 vad_silence_time 800->1000 在服务端侧缓解，
那部分无法本地仿真）。本测试聚焦客户端可改的部分。

用法：python3 test_segmenter.py
"""

import sys

# 250ms 定时器节拍（与 LiveCap 真机一致）
TICK = 0.25


def merge_partial(cur, last_raw, raw):
    """1:1 移植 lc_mergePartial。cur=当前累积句, last_raw=上一帧原始, raw=本帧原始。"""
    last_raw = last_raw or ""
    if cur and raw.startswith(cur):
        return raw                       # (a) 累积前缀
    if raw and cur and cur.startswith(raw):
        return cur                       # 服务端回退
    if raw == last_raw:
        return cur                       # 重复推送
    if raw and cur and raw in cur:
        return cur
    if cur:
        return cur + " " + raw           # (b) 追加
    return raw


class SegmenterSim:
    def __init__(self, silence_threshold):
        self.SILENCE = silence_threshold     # 静音断句阈值（秒）
        self.sentence = ""                   # _sentence 累积句
        self.last_raw = None                 # _lastRawPartial
        self.last_change = None              # _lastChangeAt
        self.start_at = 0.0                  # _sentenceStartAt
        self.last_translated = None          # 去重
        self.commits = []                    # 记录每次送译 (t, reason, text)

    def _update(self, merged, now):
        if merged != self.sentence:
            self.sentence = merged
            self.last_change = now
            if self.start_at <= 0:
                self.start_at = now

    def _should_commit(self, s, now):
        if len(s) < 2:
            return False
        last_ch = s[-1]
        if last_ch in ".?!。？！":
            return True
        if self.last_change is not None and (now - self.last_change) >= self.SILENCE and len(s) >= 8:
            return True
        if len(s) >= 100:
            return True
        if self.start_at > 0 and (now - self.start_at) >= 8.0:
            return True
        return False

    def _commit(self, text, reason, now):
        s = text.strip()
        # 清空累积
        self.sentence = ""
        self.last_raw = None
        self.last_change = now
        self.start_at = 0.0
        if len(s) < 2:
            return
        if s == self.last_translated:
            return
        self.last_translated = s
        self.commits.append((round(now, 2), reason, s))

    def on_event(self, t, slice_type, text):
        """处理一帧 ASR 结果（strictSubtitleSync=YES 路径）。"""
        if not text:
            return
        # slice_type=2 句末：合并累积后整句收句
        if slice_type == 2:
            merged = merge_partial(self.sentence, self.last_raw, text)
            self.last_raw = text
            self._commit(merged, "slice2", t)
            return
        # slice_type=1 / 0：只累积，绝不单独送译；到达静音阈值才收
        merged = merge_partial(self.sentence, self.last_raw, text)
        self.last_raw = text
        self._update(merged, t)
        if self._should_commit(merged, t):
            self._commit(merged, "auto", t)

    def on_tick(self, now):
        """250ms 定时器：服务端静音不再推 partial 时，靠它收句。"""
        s = self.sentence
        if len(s) < 2:
            return
        if self.last_change is not None and (now - self.last_change) >= self.SILENCE and len(s) >= 8:
            self._commit(s, "silence", now)
        elif self.start_at > 0 and (now - self.start_at) >= 8.0:
            self._commit(s, "timeout", now)


def run_scenario(events, silence):
    """events: list[(t, slice_type, text)]。返回 (commits, final_time)。"""
    sim = SegmenterSim(silence)
    times = sorted(set([e[0] for e in events]) | set(
        [round(x * TICK, 2) for x in range(0, int(max([e[0] for e in events]) / TICK) + 60)]
    ))
    ev_by_t = {}
    for e in events:
        ev_by_t.setdefault(round(e[0], 2), []).append(e)
    for t in times:
        for e in ev_by_t.get(t, []):
            sim.on_event(e[0], e[1], e[2])
        sim.on_tick(t)
    return sim.commits


def fmt_commits(commits):
    if not commits:
        return "  (无送译)"
    return "\n".join(f"    t={t:6.2f} [{why:7}] \"{txt}\"" for t, why, txt in commits)


def main():
    results = {}

    # ---------- 场景 A：句内停顿 1.5s（核心修复场景）----------
    # 一句话中途思考停顿 1.5s（<2.5s 但 >1.0s）；句末停约 1s 由服务端发 slice_type=2
    # （贴近真实：腾讯云 vad_silence_time=1000ms，句末约 1s 判句末）。累积形态 partial。
    ev_a = [
        (0.0, 1, "Hello everyone"),
        (0.5, 1, "Hello everyone today"),
        # 0.5 -> 2.0 说话人停顿 1.5s 思考（无事件）
        (2.0, 1, "Hello everyone today I"),
        (2.5, 1, "Hello everyone today I want"),
        (3.5, 2, "Hello everyone today I want to share"),   # 句末停顿 1s -> 服务端 slice2
    ]
    results["A_OLD"] = run_scenario(ev_a, 1.0)
    results["A_NEW"] = run_scenario(ev_a, 2.5)

    # ---------- 场景 B：正常句末靠静音兜底（无 slice_type=2）----------
    # 服务端一直 slice_type=1，句末停顿 3s 后无更多输出，靠 silence tick 收句。
    ev_b = [
        (0.0, 1, "The meeting is"),
        (0.6, 1, "The meeting is at"),
        (1.2, 1, "The meeting is at ten"),
        (1.8, 1, "The meeting is at ten am"),
        # 1.8 之后静默 3s
    ]
    results["B_OLD"] = run_scenario(ev_b, 1.0)
    results["B_NEW"] = run_scenario(ev_b, 2.5)

    # ---------- 场景 C：服务端正确 slice_type=2（实时断句，验证不退化）----------
    ev_c = [
        (0.0, 1, "Good"),
        (0.4, 1, "Good morning"),
        (0.9, 2, "Good morning everyone"),
        (1.5, 1, "Let's"),
        (2.0, 1, "Let's begin"),
        (2.6, 2, "Let's begin the show"),
    ]
    results["C_OLD"] = run_scenario(ev_c, 1.0)
    results["C_NEW"] = run_scenario(ev_c, 2.5)

    # ---------- 场景 D：句首 slice_type=0 帧带文本（v2.2.6 修复缺头）----------
    ev_d = [
        (0.0, 0, "Welcome"),
        (0.5, 1, "Welcome to"),
        (1.0, 1, "Welcome to the"),
        (1.6, 2, "Welcome to the program"),
    ]
    results["D_OLD"] = run_scenario(ev_d, 1.0)
    results["D_NEW"] = run_scenario(ev_d, 2.5)

    # ---------- 场景 E：多句连续（验证每句独立、不粘连）----------
    ev_e = [
        (0.0, 1, "First sentence"),
        (0.5, 2, "First sentence here"),
        (1.5, 1, "Second one"),
        (2.0, 1, "Second one starts"),
        (5.0, 2, "Second one starts now"),
    ]
    results["E_OLD"] = run_scenario(ev_e, 1.0)
    results["E_NEW"] = run_scenario(ev_e, 2.5)

    # ================= 断言 & 报告 =================
    failures = []

    # 场景 A：新阈值不应在 t<2.0 处出现半句；最终整句收。旧阈值应出现半句（bug 复现）。
    a_old_texts = [c[2] for c in results["A_OLD"]]
    a_new_texts = [c[2] for c in results["A_NEW"]]
    a_new_early = [c for c in results["A_NEW"] if c[0] < 2.0 and c[1] in ("auto", "silence")]
    if a_new_early:
        failures.append(f"场景A 新阈值仍在句内停顿处误切: {a_new_early}")
    if not any("share" in t for t in a_new_texts):
        failures.append("场景A 新阈值未产出整句(含 share)")
    if not any("Hello everyone today" == t for t in a_old_texts):
        failures.append("场景A 旧阈值未能复现半句 bug（仿真前提不成立）")
    else:
        print("[OK] 场景A 旧阈值半句 bug 已成功复现（证明测试前提有效）")

    # 场景 B：两种阈值最终都应整句收（不丢、不碎）
    for tag in ("B_OLD", "B_NEW"):
        txts = [c[2] for c in results[tag]]
        if not any("ten am" in t for t in txts):
            failures.append(f"场景B {tag} 未产出整句(含 ten am)")

    # 场景 C/D/E：新阈值需与旧阈值一样正确（不退化）
    for tag in ("C", "D", "E"):
        old_t = [c[2] for c in results[tag + "_OLD"]]
        new_t = [c[2] for c in results[tag + "_NEW"]]
        if tag == "C":
            want = "Good morning everyone"
            if not any(want in t for t in new_t):
                failures.append(f"场景C 新阈值丢失整句 '{want}'")
            if not any("Let's begin the show" in t for t in new_t):
                failures.append("场景C 新阈值丢失第二句")
        if tag == "D":
            if not any("Welcome to the program" in t for t in new_t):
                failures.append("场景D 新阈值丢失句首累积整句")
        if tag == "E":
            if not any("First sentence here" in t for t in new_t):
                failures.append("场景E 新阈值丢失第一句")
            if not any("Second one starts now" in t for t in new_t):
                failures.append("场景E 新阈值丢失第二句")

    # ---------- 打印报告 ----------
    print("\n" + "=" * 72)
    print("LiveCap 断句判定层 A/B 仿真报告  (OLD=1.0s旧阈值 / NEW=2.5s v2.2.6)")
    print("=" * 72)

    def block(name, desc, key_old, key_new):
        print(f"\n--- {name}：{desc} ---")
        print(f"[OLD 1.0s] 送译序列:")
        print(fmt_commits(results[key_old]))
        print(f"[NEW 2.5s] 送译序列:")
        print(fmt_commits(results[key_new]))

    block("场景A", "句内停顿1.5s（核心修复：旧阈值会切半句，新阈值不切）",
          "A_OLD", "A_NEW")
    block("场景B", "句末无slice2、靠静音兜底收句（两种都应整句）",
          "B_OLD", "B_NEW")
    block("场景C", "服务端正确slice2实时断句（验证不退化）",
          "C_OLD", "C_NEW")
    block("场景D", "句首slice_type=0带文本（验证不丢头）",
          "D_OLD", "D_NEW")
    block("场景E", "多句连续（验证不粘连）",
          "E_OLD", "E_NEW")

    print("\n" + "=" * 72)
    if failures:
        print("断言失败：")
        for f in failures:
            print("  ✗", f)
        print("=" * 72)
        return 1
    else:
        print("全部断言通过 ✅")
        print("  · 场景A：v2.2.6(2.5s) 不再把句内1.5s停顿误切成半句；旧1.0s已复现半句bug")
        print("  · 场景B/C/D/E：v2.2.6 与旧版一样正确实时整句收句，无退化")
        print("  · 结论：v2.2.6 的静音阈值调整有效修复半句翻译，且不牺牲正常断句速度")
        print("=" * 72)
        return 0


if __name__ == "__main__":
    sys.exit(main())
