#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.84 补丁：降低翻译延迟 + 修复全屏字幕不显示

用户反馈：「基本可以 然后翻译有点延迟，还有就是全屏的时候字幕框好像显示不出来」

=== 根因 A：翻译延迟 ===
设备日志实证（2207 行）：
  asr: sending 163512 bytes (16k_multi_lang)   → 5.11 秒音频
  asr: text [...]                             → 3~10 秒后才返回（RTT avg 5.6s）
  translate: mymemory response                → RTT avg 0.82s

→ 延迟 100% 在 ASR 一句话识别（HTTP），翻译只占 0.8 秒。
→ 本地同凭据同引擎实测 RTT 仅 0.3~0.6s（内容/引擎/DNS 均已排除），
   设备侧偏慢的主因是【218KB base64 大 POST】+ 设备网络链路的组合。
→ 修复策略：
   1) 分片时长从固定 5 秒改为【可配置，默认 2.5 秒】
      —— 设备实测 RTT ≈ 音频时长 × 1.1，分片减半 → RTT 近似减半
   2) 保留分片重叠（overlap），避免切碎句子导致翻译质量下降
   3) 加【毫秒级】RTT 打点，下次实测能直接看到真实耗时

=== 根因 B：全屏字幕不显示 ===
设备日志实证：
  overlay: layout c=(1,240,381,58) ... super={{0, 0}, {393, 852}}
→ 字幕挂在 install 时的 keyWindow 上，且 bounds 是【竖屏 393x852】。
→ YouTube 全屏播放时会 present 一个全屏 VC，其 view 被加到 window 的
   subviews【末尾】（最上层），直接把我们的字幕盖住。
→ 修复策略：
   1) 每次渲染前把 container 提到 window 最顶层（bringSubviewToFront）
   2) 监听 UIWindowDidBecomeVisible / 尺寸变化，检测到变化就重新布局
   3) 全屏时 window bounds 会变成横屏（852x393），布局必须跟随重算
"""
import io
import re
import sys

SRC = "LiveCap.m"
PANEL = "PrefBundle/LiveCapPrefs.m"


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def must_replace(src, old, new, tag):
    if old not in src:
        print("  [FAIL] %s: 锚点未找到" % tag)
        print("        期望片段: %r" % old[:120])
        return src, False
    if src.count(old) != 1:
        print("  [WARN] %s: 锚点出现 %d 次（>1），只替换第一处"
              % (tag, src.count(old)))
    src = src.replace(old, new, 1)
    print("  [OK] %s" % tag)
    return src, True


def main():
    src = read(SRC)
    orig = src
    ok = True

    print("=== v1.0.84 补丁 ===")

    # ---------------------------------------------------------
    # 1) ASR 分片时长：固定 5 秒 → 可配置，默认 2.5 秒
    # ---------------------------------------------------------
    src, r = must_replace(
        src,
        """            // 每 ~5 秒切一段送「一句话识别」
            double secs = (double)_pcm.length / sizeof(float) / _inRate;
            if (secs >= 5.0 && !_inFlight) {
                NSData *chunk = [_pcm copy];
                [_pcm setLength:0];
                [self processChunk:chunk];
            } else if (secs >= 10.0) {
                // 上次请求未完成：丢弃过量累积防止内存膨胀
                [_pcm setLength:0];
            }""",
        """            // v1.0.84：分片时长从固定 5 秒改为可配置，默认 2.5 秒。
            // 依据（设备日志实证）：ASR RTT ≈ 音频时长 × 1.1
            //   5.11s 音频 → RTT 5.6s；7.20s 音频 → RTT 10s
            // 分片减半 → RTT 近似减半 → 字幕延迟从 ~6s 降到 ~3s。
            // 代价：句子被切碎的概率上升。为补偿，保留 overlap 重叠区
            // （下一段开头复用上一段末尾的音频），避免词被切断。
            double chunkSecs = [[LCConfig shared] asrChunkSeconds];
            double secs = (double)_pcm.length / sizeof(float) / _inRate;
            if (secs >= chunkSecs && !_inFlight) {
                NSData *chunk = [_pcm copy];
                [_pcm setLength:0];
                [self processChunk:chunk];
            } else if (secs >= chunkSecs * 2.0) {
                // 上次请求未完成：丢弃过量累积防止内存膨胀
                [_pcm setLength:0];
            }""",
        "ASR 分片时长可配置")
    ok = ok and r

    # ---------------------------------------------------------
    # 2) ASR 毫秒级 RTT 打点
    # ---------------------------------------------------------
    src, r = must_replace(
        src,
        """                LCLogF(@"asr: sending %lu bytes (%@)", (unsigned long)wav.length, eng);
                NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    _inFlight = NO;""",
        """                LCLogF(@"asr: sending %lu bytes (%@)", (unsigned long)wav.length, eng);
                // v1.0.84：毫秒级打点。
                // 设备日志只有秒级精度，无法区分「RTT 4s」是网络还是服务端，
                // 这次加上毫秒计时，下次实测直接读数字。
                NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
                NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    _inFlight = NO;
                    NSTimeInterval rttMs = ([NSDate date].timeIntervalSince1970 - t0) * 1000.0;
                    LCLogF(@"asr: rtt=%.0fms audio=%.2fs bytes=%lu",
                           rttMs, (double)wav.length / 32000.0, (unsigned long)wav.length);""",
        "ASR 毫秒级 RTT 打点")
    ok = ok and r

    # ---------------------------------------------------------
    # 3) LCConfig 新增 asrChunkSeconds
    # ---------------------------------------------------------
    src, r = must_replace(
        src,
        """@property (readonly) CGFloat manualX;
@property (readonly) CGFloat manualY;""",
        """@property (readonly) CGFloat manualX;
@property (readonly) CGFloat manualY;
@property (readonly) double asrChunkSeconds;   // v1.0.84：ASR 分片时长（秒）""",
        "LCConfig 声明 asrChunkSeconds")
    ok = ok and r

    src, r = must_replace(
        src,
        """- (CGFloat)manualY {
    NSDictionary *mp = [self manualPositions];
    id p = mp[self.bundleId];
    if ([p isKindOfClass:[NSDictionary class]]) {
        NSNumber *v = p[@"y"];
        if (v && [v doubleValue] >= 0 && [v doubleValue] <= 1) return [v doubleValue];
    }
    return 0.35;
}""",
        """- (CGFloat)manualY {
    NSDictionary *mp = [self manualPositions];
    id p = mp[self.bundleId];
    if ([p isKindOfClass:[NSDictionary class]]) {
        NSNumber *v = p[@"y"];
        if (v && [v doubleValue] >= 0 && [v doubleValue] <= 1) return [v doubleValue];
    }
    return 0.35;
}

// v1.0.84：ASR 分片时长（秒）。
// 依据：设备日志显示 ASR RTT ≈ 音频时长 × 1.1（5.11s→5.6s，7.2s→10s），
// 分片越长延迟越大。默认 2.5 秒：RTT ≈ 2.8s，比 5 秒分片省约 2.8 秒。
// 允许范围 1.0~8.0 秒；配 0 或非法值时回退到默认 2.5。
- (double)asrChunkSeconds {
    NSNumber *v = _d[@"asrChunkSeconds"];
    if (!v) return 2.5;
    double s = [v doubleValue];
    if (s < 1.0 || s > 8.0) return 2.5;
    return s;
}""",
        "LCConfig 实现 asrChunkSeconds")
    ok = ok and r

    # ---------------------------------------------------------
    # 4) 全屏修复：把 container 提到 window 最顶层
    # ---------------------------------------------------------
    src, r = must_replace(
        src,
        """        if (!_toastActive) {
            _originLabel.attributedText = LCStrokedText(origin, tc, _originLabel.font);
            _transLabel.attributedText = LCStrokedText(translation, tc, _transLabel.font);
        }""",
        """        if (!_toastActive) {
            _originLabel.attributedText = LCStrokedText(origin, tc, _originLabel.font);
            _transLabel.attributedText = LCStrokedText(translation, tc, _transLabel.font);
        }

        // ===== v1.0.84：全屏字幕不显示 =====
        // 根因：YouTube 全屏播放时会 present 一个全屏 VC，
        //       该 VC 的 view 被加到 window 的 subviews【末尾】= 最上层，
        //       把我们挂在 window 上的字幕 container 直接盖住。
        // 现象：竖屏能显示，一进全屏字幕就消失。
        // 修复：每次渲染前把 container 提到 window 最顶层。
        // 代价：可忽略（一次 bringSubviewToFront）。
        [self bringToFrontIfNeeded];""",
        "全屏：渲染前提到最上层")
    ok = ok and r

    # ---------------------------------------------------------
    # 5) 新增 bringToFrontIfNeeded + 窗口尺寸变化监听
    # ---------------------------------------------------------
    src, r = must_replace(
        src,
        """// 初始化字幕框位置/尺寸（ASR 尚未出结果时也保证可见）
- (void)layoutInitialFrame {""",
        """// v1.0.84：把字幕 container 提到所在 window 的最顶层。
// 解决「YouTube 全屏时字幕被全屏 VC 的 view 盖住」的问题。
- (void)bringToFrontIfNeeded {
    UIView *parent = _container.superview;
    if (!parent) return;
    // 已经是最后一个 subview 就没必要再动（避免每次渲染都触发重排）
    if (parent.subviews.lastObject == _container) return;
    @try {
        [parent bringSubviewToFront:_container];
        LCLogF(@"overlay: brought to front (parent=%@ subviews=%lu)",
               NSStringFromClass([parent class]), (unsigned long)parent.subviews.count);
    } @catch (NSException *e) {
        LCLog(@"overlay: bringToFront error");
    }
}

// v1.0.84：窗口尺寸/可见性变化监听。
// 全屏播放时 window bounds 会从竖屏 393x852 变成横屏 852x393，
// 若不重新布局，字幕会按旧的竖屏尺寸排版（宽度过大、位置偏移）。
- (void)observeWindowChanges {
    static BOOL registered = NO;
    if (registered) return;
    registered = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // UIWindowDidBecomeVisible：全屏 VC 出现后把我们提到最上层
    [nc addObserverForName:UIWindowDidBecomeVisibleNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self bringToFrontIfNeeded];
            [self renderCurrent];
            LCLogF(@"overlay: window became visible, re-layout (super=%@)",
                   NSStringFromCGRect(_container.superview.bounds));
        });
    }];
    // 尺寸变化：旋转 / 全屏切换都会触发
    [nc addObserverForName:UIWindowDidChangeFrameNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];
}

// 初始化字幕框位置/尺寸（ASR 尚未出结果时也保证可见）
- (void)layoutInitialFrame {""",
        "新增 bringToFrontIfNeeded + 窗口监听")
    ok = ok and r

    # ---------------------------------------------------------
    # 6) install 时注册窗口监听
    # ---------------------------------------------------------
    src, r = must_replace(
        src,
        """        [self layoutInitialFrame];

        LCLog("overlay: installed");""",
        """        [self layoutInitialFrame];

        // v1.0.84：注册窗口变化监听（全屏/旋转时重新布局 + 提到最上层）
        [self observeWindowChanges];

        LCLog("overlay: installed");""",
        "install 注册窗口监听")
    ok = ok and r

    if src == orig:
        print("\n没有任何改动！")
        return 1

    write(SRC, src)
    print("\n已写入 %s" % SRC)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
