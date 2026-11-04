# -*- coding: utf-8 -*-
"""v1.0.82: 字幕只显示中文一行（默认），英文行可由设置面板切回。"""
import io, re, sys

P = 'LiveCap.m'
src = io.open(P, encoding='utf-8').read()
orig = src
errors = []

def sub(old, new, tag, count=1):
    global src
    if old not in src:
        errors.append("未找到片段: %s" % tag)
        return False
    if src.count(old) != count:
        errors.append("片段 %s 出现 %d 次（期望 %d）" % (tag, src.count(old), count))
        return False
    src = src.replace(old, new, count)
    return True

# ============================================================
# 1) 新增实例变量
# ============================================================
sub(
"""    NSUInteger _displayedSeq;      // 当前画面对应的 seq
    NSUInteger _pendingSeq;        // 最新一句待翻译的 seq""",
"""    NSUInteger _displayedSeq;      // 双语模式：当前画面对应的 seq
    NSUInteger _pendingSeq;        // 最新一句待翻译的 seq
    // ===== v1.0.82：只显示中文一行 =====
    // _transSeq  = 当前显示的译文对应的 seq（只中文模式的对账基准）
    // _placeholder = 尚无可显示译文时的占位文字（翻译中… / 翻译失败）
    NSUInteger _transSeq;
    NSString *_placeholder;""",
"ivar")

# ============================================================
# 2) showPending：按显示模式分流
# ============================================================
sub(
"""- (NSUInteger)showPending:(NSString *)origin {
    if (!_container || !_installed) {
        LCLogF(@"overlay: show skipped (container=%d installed=%d)", _container != nil, _installed);
        return 0;
    }
    @try {
        if (origin.length == 0) return 0;
        NSUInteger seq = ++_seqCounter;
        _pendingOrigin = origin;
        _pendingSeq = seq;
        // 【关键】立即刷新画面：新英文立刻上屏，字幕框随语音轮动。
        // 译文暂时清空，等 showPair 回来再补上 —— 宁可短暂缺中文，也不能卡住不动。
        _displayedOrigin = origin;
        _displayedTranslation = nil;
        _displayedSeq = seq;
        [self renderCurrent];
        LCLogF(@"overlay: pending seq=%lu origin=[%@]", (unsigned long)seq, origin);
        return seq;
    } @catch (NSException *e) {
        LCLog(@"overlay: pending error");
        return 0;
    }
}""",
"""- (NSUInteger)showPending:(NSString *)origin {
    if (!_container || !_installed) {
        LCLogF(@"overlay: show skipped (container=%d installed=%d)", _container != nil, _installed);
        return 0;
    }
    @try {
        if (origin.length == 0) return 0;
        NSUInteger seq = ++_seqCounter;
        _pendingOrigin = origin;
        _pendingSeq = seq;

        if (![[LCConfig shared] showEnglish]) {
            // ===== 只显示中文一行 =====
            // 【不】清空当前译文、也不重刷画面：保留上一句中文直到新译文到达。
            // 这是标准字幕行为（Netflix / YouTube 都是上一句保持到下一句出现），
            // 若在这里清空，翻译的 1~2s 延迟会让字幕框反复闪「翻译中…」非常刺眼。
            if (_displayedTranslation.length == 0) {
                _placeholder = @"翻译中…";
                [self renderCurrent];
            }
            LCLogF(@"overlay: pending seq=%lu origin=[%@] (zh-only, keeping last)", (unsigned long)seq, origin);
            return seq;
        }

        // ===== 双语模式 =====
        // 立即刷新画面：新英文立刻上屏，字幕框随语音轮动。
        // 译文暂时清空，等 showPair 回来再补上 —— 宁可短暂缺中文，也不能卡住不动。
        _displayedOrigin = origin;
        _displayedTranslation = nil;
        _displayedSeq = seq;
        [self renderCurrent];
        LCLogF(@"overlay: pending seq=%lu origin=[%@]", (unsigned long)seq, origin);
        return seq;
    } @catch (NSException *e) {
        LCLog(@"overlay: pending error");
        return 0;
    }
}""",
"showPending")

# ============================================================
# 3) showPair：只中文模式下推进 _transSeq
# ============================================================
sub(
"""        if (origin.length == 0) return;
        if (translation.length == 0) { [self showFailed:origin seq:seq]; return; }
        if (seq != 0 && seq < _displayedSeq) {
            LCLogF(@"overlay: drop stale pair seq=%lu (displayed=%lu) origin=[%@]",
                   (unsigned long)seq, (unsigned long)_displayedSeq, origin);
            return;
        }
        _displayedOrigin = origin;
        _displayedTranslation = translation;
        _displayedSeq = seq ? seq : _displayedSeq;
        if (seq && seq == _pendingSeq) _pendingOrigin = nil;""",
"""        if (origin.length == 0) return;
        if (translation.length == 0) { [self showFailed:origin seq:seq]; return; }
        if (![[LCConfig shared] showEnglish]) {
            // 只中文模式：对账基准是 _transSeq（当前显示的译文）
            if (seq != 0 && seq < _transSeq) {
                LCLogF(@"overlay: drop stale pair seq=%lu (transSeq=%lu) origin=[%@]",
                       (unsigned long)seq, (unsigned long)_transSeq, origin);
                return;
            }
            _displayedTranslation = translation;
            _displayedOrigin = origin;
            _transSeq = seq ? seq : _transSeq;
            _placeholder = nil;
            if (seq && seq == _pendingSeq) _pendingOrigin = nil;
            LCLogF(@"overlay: showPair seq=%lu origin=[%@] trans=[%@] transLen=%lu (zh-only)",
                   (unsigned long)seq, origin, translation, (unsigned long)translation.length);
            [self renderCurrent];
            return;
        }
        if (seq != 0 && seq < _displayedSeq) {
            LCLogF(@"overlay: drop stale pair seq=%lu (displayed=%lu) origin=[%@]",
                   (unsigned long)seq, (unsigned long)_displayedSeq, origin);
            return;
        }
        _displayedOrigin = origin;
        _displayedTranslation = translation;
        _displayedSeq = seq ? seq : _displayedSeq;
        if (seq && seq == _pendingSeq) _pendingOrigin = nil;""",
"showPair")

# ============================================================
# 4) showFailed：只中文模式下保留上一句中文
# ============================================================
sub(
"""        if (origin.length == 0) return;
        if (seq != 0 && seq < _displayedSeq) {
            LCLogF(@"overlay: drop stale fail seq=%lu (displayed=%lu)",
                   (unsigned long)seq, (unsigned long)_displayedSeq);
            return;
        }
        _displayedOrigin = origin;
        _displayedTranslation = nil;
        _displayedSeq = seq ? seq : _displayedSeq;
        if (seq && seq == _pendingSeq) _pendingOrigin = nil;""",
"""        if (origin.length == 0) return;
        if (![[LCConfig shared] showEnglish]) {
            // 只中文模式：翻译失败时【保留】上一句中文（不要清空字幕框）。
            // 若从来没成功译过一句，则显示「翻译失败」占位，而不是留一个空框。
            if (_displayedTranslation.length == 0) {
                _placeholder = @"翻译失败";
                [self renderCurrent];
            }
            if (seq && seq == _pendingSeq) _pendingOrigin = nil;
            LCLogF(@"overlay: showFailed seq=%lu origin=[%@] (zh-only)", (unsigned long)seq, origin);
            return;
        }
        if (seq != 0 && seq < _displayedSeq) {
            LCLogF(@"overlay: drop stale fail seq=%lu (displayed=%lu)",
                   (unsigned long)seq, (unsigned long)_displayedSeq);
            return;
        }
        _displayedOrigin = origin;
        _displayedTranslation = nil;
        _displayedSeq = seq ? seq : _displayedSeq;
        if (seq && seq == _pendingSeq) _pendingOrigin = nil;""",
"showFailed")

# ============================================================
# 5) renderCurrent：占位文字 + 英文标签收起
# ============================================================
sub(
"""        // 只显示中文且译文还没回来 → 显示占位提示，不要空框
        if (!showEn && translation.length == 0 && _pendingOrigin.length > 0) {
            translation = @"翻译中…";
        }""",
"""        // 只显示中文且还没有任何译文 → 显示占位提示，不要空框
        if (!showEn && translation.length == 0) {
            translation = _placeholder ?: @"";
        }""",
"render placeholder")

sub(
"""        CGFloat ly = pad;
        // 文字区域避开右上角的拖动把手
        CGFloat textW = maxW - handleSpace;
        if (origin.length) {
            _originLabel.frame = CGRectMake(pad, ly, textW, oh);
            ly += oh + 4;
        }""",
"""        CGFloat ly = pad;
        // 文字区域避开右上角的拖动把手
        CGFloat textW = maxW - handleSpace;
        if (origin.length) {
            _originLabel.frame = CGRectMake(pad, ly, textW, oh);
            _originLabel.hidden = NO;
            ly += oh + 4;
        } else {
            // 只显示中文时英文行必须彻底收起（frame 归零 + hidden），
            // 否则会残留上一句英文，表现为「两行：上面英文下面中文」
            _originLabel.frame = CGRectZero;
            _originLabel.hidden = YES;
        }""",
"render origin layout")

# ============================================================
# 6) hide：重置新增状态
# ============================================================
sub(
"""- (void)hide {
    _container.hidden = YES;
    _pendingOrigin = nil;
    _displayedOrigin = nil;
    _displayedTranslation = nil;""",
"""- (void)hide {
    _container.hidden = YES;
    _pendingOrigin = nil;
    _displayedOrigin = nil;
    _displayedTranslation = nil;
    _placeholder = nil;
    _transSeq = 0;""",
"hide reset")

# ============================================================
# 7) showToast：结束后恢复字幕，而不是清空文字
# ============================================================
sub(
"""        _container.frame = CGRectMake((sw - w) / 2, sh - insets.bottom - h - 120, w, h);
        _originLabel.frame = CGRectMake(pad, pad, maxW, oh);
        _container.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            _container.hidden = YES;
            _originLabel.attributedText = nil;
            _transLabel.attributedText = nil;
        });""",
"""        _container.frame = CGRectMake((sw - w) / 2, sh - insets.bottom - h - 120, w, h);
        _originLabel.frame = CGRectMake(pad, pad, maxW, oh);
        // toast 用英文标签承载（内容是中文提示语，字号/描边逻辑一致）
        _originLabel.hidden = NO;
        _transLabel.hidden = YES;
        _transLabel.frame = CGRectZero;
        _container.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 不能直接清空 attributedText：那会把 toast 期间新到字幕的文字也抹掉。
            // 正确做法是重新渲染当前成对内容。
            _originLabel.attributedText = nil;
            _transLabel.attributedText = nil;
            _originLabel.hidden = YES;
            [self renderCurrent];
        });""",
"showToast restore")

# ============================================================
# 8) 版本号
# ============================================================
src = src.replace("LiveCap mediaserverd tap (1.0.81)", "LiveCap mediaserverd tap (1.0.82)")

if errors:
    print("补丁失败：")
    for e in errors:
        print("  - " + e)
    sys.exit(1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("v1.0.82 显示层补丁应用成功（%d -> %d 字节）" % (len(orig), len(src)))
