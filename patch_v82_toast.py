# -*- coding: utf-8 -*-
"""v1.0.82 第四批补丁（收尾）：
1) renderCurrent 在 toast 期间直接返回 —— 否则 toast 的居中位置会被
   字幕位置覆盖，且中文字幕会叠在 toast 文字上（画面重叠）
2) 完全没有内容时隐藏容器，避免出现一个只有背景的空框
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

# 1) toast 期间直接返回
sub(
"""- (void)renderCurrent {
    @try {
        BOOL showEn = [[LCConfig shared] showEnglish];""",
"""- (void)renderCurrent {
    @try {
        // toast 展示期间不重排画面：toast 自己管布局，
        // 否则容器的居中位置会被字幕位置覆盖、且字幕文字会叠在 toast 上。
        // toast 结束后会再调一次 renderCurrent 恢复正常字幕。
        if (_toastActive) return;

        BOOL showEn = [[LCConfig shared] showEnglish];""",
"toast early return")

# 2) 完全没有内容 → 隐藏容器
sub(
"""        _container.hidden = NO;
        LCLogF(@"overlay: layout c=(%.0f,%.0f,%.0f,%.0f)""",
"""        // 没有任何文字时隐藏容器，避免出现一个只有背景的空框
        BOOL hasContent = (origin.length > 0) || (translation.length > 0);
        _container.hidden = !hasContent;
        LCLogF(@"overlay: layout c=(%.0f,%.0f,%.0f,%.0f)""",
"hide empty container")

if errors:
    print("补丁失败：")
    for e in errors:
        print("  - " + e)
    sys.exit(1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("v1.0.82 第四批补丁应用成功（%d -> %d 字节）" % (orig_len, len(src)))
