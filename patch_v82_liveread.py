# -*- coding: utf-8 -*-
"""v1.0.82 第三批补丁：
showEnglish 实时读盘 —— 面板切换开关后无需重启 App 即可生效。

背景：LCConfig 在启动时把 plist 读进 _d 缓存，之后只 reload 一次。
      新增的「显示英文原文」是运行期可切换的展示选项，
      如果继续读缓存，用户在面板拨了开关却要重启 App 才变，体验很差。
      showEnglish 每次访问都直接读盘（renderCurrent 每句调用一次，
      开销可忽略）。
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

sub(
"""// v1.0.82：字幕只显示中文一行。
// 用户实测反馈「有时候是两行 一行英文 一行中文，我只要一行中文就行了」。
// 默认 NO（只中文）；用户可在设置面板切回「同时显示英文原文」。
- (BOOL)showEnglish {
    NSNumber *v = _d[@"showEnglish"];
    return v ? [v boolValue] : NO;
}""",
"""// v1.0.82：字幕只显示中文一行。
// 用户实测反馈「有时候是两行 一行英文 一行中文，我只要一行中文就行了」。
// 默认 NO（只中文）；用户可在设置面板切回「同时显示英文原文」。
//
// 【实时读盘】面板拨动开关后无需重启 App 立即生效：
// LCConfig 启动时把 plist 读进 _d 缓存，若继续读缓存则要重启才变。
// 这里每次直接读文件（renderCurrent 每句调用一次，开销可忽略）。
// 文件读不到时回退到缓存值。
- (BOOL)showEnglish {
    NSString *p = LCJBRootPath(@"/var/mobile/Library/Preferences/com.sykes.livecap.plist");
    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:p];
    if (fresh) {
        NSNumber *v = fresh[@"showEnglish"];
        return v ? [v boolValue] : NO;
    }
    NSNumber *v = _d[@"showEnglish"];
    return v ? [v boolValue] : NO;
}""",
"showEnglish live read")

if errors:
    print("补丁失败：")
    for e in errors:
        print("  - " + e)
    sys.exit(1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("v1.0.82 第三批补丁应用成功（%d -> %d 字节）" % (orig_len, len(src)))
