# -*- coding: utf-8 -*-
"""v1.0.82 第二批补丁：
1) 翻译队列改为 FIFO + 有限长，任何句子的 completion 都不会被永久丢弃
   （中文单行模式下 completion 丢失 = 整句中文不显示）
2) 1 秒去重节流不再静默 return，改为回调 nil，保持状态一致
3) toast 期间不被新字幕冲掉
4) _transSeq 不在 hide 时重置（保持单调，避免 hide 前发出的译文又画回来）
"""
import io, sys

P = 'LiveCap.m'
src = io.open(P, encoding='utf-8').read()
orig_len = len(src)
errors = []

def sub(old, new, tag, count=1):
    global src
    if old not in src:
        errors.append("未找到片段: %s" % tag); return False
    if src.count(old) != count:
        errors.append("片段 %s 出现 %d 次（期望 %d）" % (tag, src.count(old), count)); return False
    src = src.replace(old, new, count)
    return True

# ============================================================
# 1) 实例变量：FIFO 队列 + toast 标记
# ============================================================
sub(
"""    NSString *_pendingText;
    void (^_pendingCompletion)(NSString *);
    BOOL _inflight;""",
"""    // v1.0.82：单槽「只保留最新」会丢 completion
    //   —— 双语模式无感（画面靠 showPending 刷英文），
    //   —— 但中文单行模式下 completion 丢失 = 那句话的中文整句不显示。
    // 改为 FIFO 队列（有限长，超长时丢【最旧】的，因为它已经过时）。
    NSMutableArray *_pendingItems;   // 每项 = @{@"text": NSString, @"comp": block}
    BOOL _inflight;""",
"queue ivar")

sub(
"""        s->_cache = [NSMutableDictionary dictionary];
        s->_lastSentText = [NSMutableDictionary dictionary];
        s->_lastSentTime = [NSMutableDictionary dictionary];""",
"""        s->_cache = [NSMutableDictionary dictionary];
        s->_lastSentText = [NSMutableDictionary dictionary];
        s->_lastSentTime = [NSMutableDictionary dictionary];
        s->_pendingItems = [NSMutableArray array];""",
"queue init")

# ============================================================
# 2) translate:：入队改 FIFO
# ============================================================
sub(
"""    // ===== 入队（串行化 + 只保留最新）=====
    // 翻译是异步的，比 ASR 慢。若允许多条请求并发：
    //   ① 互相抢带宽，单条延迟从 <1s 恶化到 10s，译文永远追不上字幕；
    //   ② 回调乱序，英文与中文错配。
    // 现在同一时刻只有一条请求在飞，新文本覆盖排队中的旧文本（字幕只关心最新一句）。
    dispatch_async(_queue, ^{
        self->_pendingText = trimmed;
        self->_pendingCompletion = completion;
        [self pumpQueue];
    });""",
"""    // ===== 入队（串行化 FIFO）=====
    // 翻译是异步的，比 ASR 慢。若允许多条请求并发：
    //   ① 互相抢带宽，单条延迟从 <1s 恶化到 10s，译文永远追不上字幕；
    //   ② 回调乱序，英文与中文错配。
    // 因此同一时刻只允许一条在飞，其余排队。
    //
    // v1.0.82 修正：原来排队是「单槽 + 新文本覆盖旧文本」，
    // 被覆盖那条的 completion 永远不会执行 →
    // 双语模式看不出（画面已由 showPending 刷了英文），
    // 中文单行模式下那句话的中文会整句消失。
    // 现在改为 FIFO 队列，每句都保证有回调；队列过长时丢【最旧】的
    // （它已经落后于语音太多，显示出来反而是错的）。
    dispatch_async(_queue, ^{
        [self->_pendingItems addObject:@{@"text": trimmed, @"comp": completion ?: [NSNull null]}];
        const NSUInteger kMaxQueue = 3;
        while (self->_pendingItems.count > kMaxQueue) {
            NSDictionary *dropped = self->_pendingItems.firstObject;
            [self->_pendingItems removeObjectAtIndex:0];
            id dc = dropped[@"comp"];
            LCLogF(@"translate: queue overflow, drop oldest text=[%@]", dropped[@"text"]);
            if (dc != [NSNull null]) {
                void (^dcomp)(NSString *) = dc;
                dispatch_async(dispatch_get_main_queue(), ^{ dcomp(nil); });
            }
        }
        [self pumpQueue];
    });""",
"translate enqueue")

# ============================================================
# 3) pumpQueue：改成从 FIFO 取
# ============================================================
sub(
"""- (void)pumpQueue {
    if (_inflight) return;
    NSString *text = _pendingText;
    if (!text.length) return;
    void (^comp)(NSString *) = _pendingCompletion;
    _pendingText = nil;
    _pendingCompletion = nil;""",
"""- (void)pumpQueue {
    if (_inflight) return;
    if (_pendingItems.count == 0) return;
    NSDictionary *item = _pendingItems.firstObject;
    [_pendingItems removeObjectAtIndex:0];
    NSString *text = item[@"text"];
    if (!text.length) { [self pumpQueue]; return; }
    id rawComp = item[@"comp"];
    void (^comp)(NSString *) = (rawComp != [NSNull null]) ? rawComp : nil;""",
"pumpQueue dequeue")

# ============================================================
# 4) 1 秒去重节流：不再静默丢弃 completion
# ============================================================
sub(
"""    if (lastText && [lastText isEqualToString:trimmed] && lastTime &&
        ([nowN doubleValue] - [lastTime doubleValue]) < 1.0) {
        return;
    }""",
"""    if (lastText && [lastText isEqualToString:trimmed] && lastTime &&
        ([nowN doubleValue] - [lastTime doubleValue]) < 1.0) {
        // 1 秒内的重复句：命中缓存就回缓存，否则回调 nil（保持状态一致，
        // 不能静默 return —— 否则这句的 completion 永远不执行，中文会整句丢失）
        NSString *dupCached = nil;
        @synchronized(self) { dupCached = _cache[cacheKey]; }
        if (dupCached.length > 0) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(dupCached); });
        } else if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        }
        return;
    }""",
"dup throttle")

# ============================================================
# 5) toast 期间保护（不被新字幕冲掉）
# ============================================================
sub(
"""    NSString *_placeholder;""",
"""    NSString *_placeholder;
    BOOL _toastActive;         // toast 展示中：不要覆盖/隐藏 origin 标签""",
"toast flag ivar")

sub(
"""        _originLabel.attributedText = LCStrokedText(origin, tc, _originLabel.font);
        _transLabel.attributedText = LCStrokedText(translation, tc, _transLabel.font);""",
"""        if (!_toastActive) {
            _originLabel.attributedText = LCStrokedText(origin, tc, _originLabel.font);
            _transLabel.attributedText = LCStrokedText(translation, tc, _transLabel.font);
        }""",
"render toast guard")

sub(
"""        } else {
            // 只显示中文时英文行必须彻底收起（frame 归零 + hidden），
            // 否则会残留上一句英文，表现为「两行：上面英文下面中文」
            _originLabel.frame = CGRectZero;
            _originLabel.hidden = YES;
        }""",
"""        } else if (!_toastActive) {
            // 只显示中文时英文行必须彻底收起（frame 归零 + hidden），
            // 否则会残留上一句英文，表现为「两行：上面英文下面中文」
            _originLabel.frame = CGRectZero;
            _originLabel.hidden = YES;
        }""",
"render toast guard 2")

sub(
"""        // toast 用英文标签承载（内容是中文提示语，字号/描边逻辑一致）
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
"""        // toast 用英文标签承载（内容是中文提示语，字号/描边逻辑一致）
        _originLabel.hidden = NO;
        _transLabel.hidden = YES;
        _transLabel.frame = CGRectZero;
        _container.hidden = NO;
        _toastActive = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 不能直接清空 attributedText：那会把 toast 期间新到字幕的文字也抹掉。
            // 正确做法是重新渲染当前成对内容。
            _toastActive = NO;
            _originLabel.attributedText = nil;
            _transLabel.attributedText = nil;
            _originLabel.hidden = YES;
            [self renderCurrent];
        });""",
"toast active set")

# ============================================================
# 6) _transSeq 不在 hide 时重置
# ============================================================
sub(
"""    _placeholder = nil;
    _transSeq = 0;""",
"""    _placeholder = nil;
    // _transSeq 【不】重置：保持单调递增，这样 hide 之前发出的译文回来时
    // 会因 seq < _transSeq 被丢弃，不会把已隐藏的字幕又画回来。""",
"transSeq monotonic")

if errors:
    print("补丁失败：")
    for e in errors:
        print("  - " + e)
    sys.exit(1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("v1.0.82 第二批补丁应用成功（%d -> %d 字节）" % (orig_len, len(src)))
