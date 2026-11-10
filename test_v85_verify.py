#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.85 检查项的双向验证。

铁律（v1.0.84 教训）：
  A 正向 —— 修复版必须通过所有检查项
  B 回归 —— 把每个修复改回旧写法，必须被【准确拦在正确的位置】
  C 反向 —— 合法写法不得误报

如果 B 段拦不住，说明检查项形同虚设。
"""
import io
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "LiveCap.m")
CHECK = os.path.join(HERE, "verify_source_safety.py")


def run_check(src_text, tag):
    """把 src_text 写到临时目录，跑检查脚本，返回错误列表"""
    tmp = tempfile.mkdtemp(prefix="lc_v85_")
    try:
        src_p = os.path.join(tmp, "LiveCap.m")
        chk_p = os.path.join(tmp, "verify_source_safety.py")
        io.open(src_p, "w", encoding="utf-8").write(src_text)
        io.open(chk_p, "w", encoding="utf-8").write(
            io.open(CHECK, encoding="utf-8").read())
        # 复制【真实】面板文件：v1.0.83 的检查项要读面板源码，
        # 传空文件会产生与本次改动无关的误报。
        os.makedirs(os.path.join(tmp, "PrefBundle"), exist_ok=True)
        real_panel = os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m")
        if os.path.exists(real_panel):
            io.open(os.path.join(tmp, "PrefBundle", "LiveCapPrefs.m"),
                    "w", encoding="utf-8").write(
                        io.open(real_panel, encoding="utf-8").read())
        # v1.0.86 新增的检查项要读 LiveCap.plist 和 postinst；
        # v2.2.1 新增的检查项还要读 PrefBundle/LiveCapAppListController.m。
        # 缺了会产生「读不到文件」这种与本用例无关的误报。
        for extra in ("LiveCap.plist", "postinst",
                      os.path.join("PrefBundle", "LiveCapAppListController.m")):
            src_extra = os.path.join(HERE, extra)
            dst_extra = os.path.join(tmp, extra)
            if os.path.exists(src_extra):
                os.makedirs(os.path.dirname(dst_extra), exist_ok=True)
                io.open(dst_extra, "w", encoding="utf-8").write(
                    io.open(src_extra, encoding="utf-8").read())
        p = subprocess.run([sys.executable, chk_p], cwd=tmp,
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
        errs = []
        for line in (p.stdout or "").splitlines():
            m = re.search(r"ERROR:\s*(.+)$", line)
            if m:
                errs.append(m.group(1).strip())
        return errs
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


def mutate(src, old, new, tag):
    if old not in src:
        raise AssertionError("变异锚点未命中: %s" % tag)
    return src.replace(old, new, 1)


def main():
    base = io.open(SRC, encoding="utf-8").read()
    results = []

    # ============ A. 正向 ============
    print("=== A. 正向：当前源码必须通过 ===")
    errs = run_check(base, "base")
    if errs:
        print("  [FAIL] 当前源码竟然报 %d 个错:" % len(errs))
        for e in errs:
            print("     -", e[:150])
        results.append(("A 正向", False))
    else:
        print("  [PASS] 当前源码通过全部检查")
        results.append(("A 正向", True))

    # ============ B. 回归：每个修复改回旧写法必须被拦 ============
    print("\n=== B. 回归：改回旧写法必须被准确拦截 ===")
    mutants = []

    # B1: 并发改回 BOOL 串行锁
    mutants.append((
        "B1 并发改回串行锁",
        mutate(base,
               "NSInteger _inFlightCount;",
               "BOOL _inFlight;",
               "ivar"),
        "并发"))

    # B2: v2.2.0 起回落 HTTP 链路允许【刻意】串行（2 路并发的 POST 响应乱序
    #     会让字幕顺序颠倒），但必须带顺序修复说明。删掉说明 = 误改回串行，
    #     check_v85_fixes 仍要能拦下（否则防回归形同虚设）。
    mutants.append((
        "B2 串行缺少顺序修复说明",
        mutate(base,
               "回落链路改回串行",
               "",
               "order-note"),
        "并发上限"))

    # B3: 释放槽位不防负数
    mutants.append((
        "B3 计数释放不防负数",
        mutate(base,
               "    if (_inFlightCount > 0) _inFlightCount--; \\",
               "    _inFlightCount--; \\",
               "macro"),
        "负数"))

    # B4: 只在一条路径用 AAC（删掉 processChunk16: 的调用）
    # v1.0.87：编码器改名 LCAACEncode16kMono → LCAACEncodeADTSFramed，
    #           且失败标记从 _aacBroken 改成可恢复的 aacUsable/markAacFailure。
    aac_call = """                if ([self aacUsable]) {
                    NSData *aac = LCAACEncodeADTSFramed(pcm16);"""
    # 找到第二处调用并替换为不压缩
    idx1 = base.find(aac_call)
    idx2 = base.find(aac_call, idx1 + 1)
    assert idx2 > 0, "未找到第二处 AAC 调用"
    b4 = (base[:idx2] +
          aac_call.replace("LCAACEncodeADTSFramed(pcm16)", "nil /* 漏改 */") +
          base[idx2 + len(aac_call):])
    mutants.append(("B4 漏改一条路径的 AAC", b4, "AAC"))

    # B5: 去掉 AAC 编码器（kAudioFormatMPEG4AAC）
    mutants.append((
        "B5 去掉 AAC 编码器",
        base.replace("kAudioFormatMPEG4AAC", "kAudioFormatLinearPCM"),
        "AAC 编码器"))

    # B6: 去掉码率设置
    mutants.append((
        "B6 AAC 不设码率",
        base.replace("kAudioConverterEncodeBitRate", "kAudioConverterEncodeQuality"),
        "码率"))

    # B7: VoiceFormat 写死 wav
    mutants.append((
        "B7 VoiceFormat 写死 wav",
        base.replace('@"VoiceFormat": voiceFormat,', '@"VoiceFormat": @"wav",'),
        "VoiceFormat"))

    # B8: 去掉 AAC 失败回退记账
    # v1.0.87：不再是「_aacBroken 永久禁用」，而是「markAacFailure 计数 + 冷却」。
    mutants.append((
        "B8 去掉 AAC 失败回退记账",
        base.replace("markAacFailure", "markAacFailureUnused"),
        "markAacFailure"))

    # B9: 去掉直连失败回退
    # v1.0.87：不再是「_directFailed 永久切代理」，而是「markDirectFailure + 冷却」。
    mutants.append((
        "B9 去掉直连失败回退",
        base.replace("markDirectFailure", "markDirectFailureUnused"),
        "markDirectFailure"))

    # B10: 去掉 connectionProxyDictionary
    # v2.1.0：新增的 LCStreamASR 也有 `c.connectionProxyDictionary = @{};`，
    # 只删 LCSessionDirect 那一处的话新配置会掩盖移除效果 → 必须两处都删。
    mutants.append((
        "B10 去掉代理禁用",
        base.replace("cfg.connectionProxyDictionary = proxy;", "")
            .replace("c.connectionProxyDictionary = @{};", ""),
        "代理"))

    # B11: 去掉 HTTPS 代理禁用
    # 注意：v1.0.86 起 HTTPS/SOCKS 代理开关改用字面量 key
    # （iOS 上 kCFNetworkProxiesHTTPSEnable 不可用），锚点必须跟着改。
    mutants.append((
        "B11 不禁 HTTPS 代理",
        base.replace(
            '    [proxy setObject:@NO forKey:@"HTTPSEnable"];\n',
            ""),
        "代理"))

    # B12: 去掉字幕框宽度上限
    mutants.append((
        "B12 去掉宽度上限",
        base.replace(
            "CGFloat maxW = MIN(hostW - margin * 2, 460.0);",
            "CGFloat maxW = hostW - margin * 2;"),
        "绝对上限"))

    # B13: pcm16 路径写死 5 秒（旧写法）
    OLD13 = """        double secs16 = (double)_pcm16.length / 2.0 / 16000.0;
        if (secs16 >= chunkSecs && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {"""
    NEW13 = """        if (_pcm16.length >= 16000 * 2 * 5 && (_inFlightCount < LC_ASR_MAX_CONCURRENCY)) {"""
    mutants.append((
        "B13 pcm16 写死分片",
        mutate(base, OLD13, NEW13, "b13"),
        "pcm16"))

    for name, mutant, keyword in mutants:
        errs = run_check(mutant, name)
        hit = [e for e in errs if keyword in e]
        if hit:
            print("  [PASS] %-26s → 被拦: %s" % (name, hit[0][:95]))
            results.append((name, True))
        else:
            print("  [FAIL] %-26s → 未被拦（错误列表: %s）"
                  % (name, [e[:80] for e in errs]))
            results.append((name, False))

    # ============ C. 反向：合法写法不误报 ============
    print("\n=== C. 反向：合法写法不得误报 ===")
    # C1: 把并发上限改成 3（合法）
    c1 = base.replace("LC_ASR_MAX_CONCURRENCY = 2;", "LC_ASR_MAX_CONCURRENCY = 3;")
    errs = run_check(c1, "C1")
    if errs:
        print("  [FAIL] 并发上限=3 被误报:", [e[:90] for e in errs])
        results.append(("C1 合法并发上限=3", False))
    else:
        print("  [PASS] 并发上限=3 未误报")
        results.append(("C1 合法并发上限=3", True))

    # C2: 宽度上限改成 380（合法）
    c2 = base.replace("MIN(hostW - margin * 2, 460.0)", "MIN(hostW - margin * 2, 380.0)")
    errs = run_check(c2, "C2")
    if errs:
        print("  [FAIL] 宽度上限=380 被误报:", [e[:90] for e in errs])
        results.append(("C2 合法宽度上限=380", False))
    else:
        print("  [PASS] 宽度上限=380 未误报")
        results.append(("C2 合法宽度上限=380", True))

    # ============ 汇总 ============
    print("\n" + "=" * 60)
    bad = [n for n, ok in results if not ok]
    if bad:
        print("❌ 双向验证失败（%d/%d 项不通过）:" % (len(bad), len(results)))
        for n in bad:
            print("   -", n)
        return 1
    print("✅ v1.0.85 双向验证全部通过（%d 项）" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
