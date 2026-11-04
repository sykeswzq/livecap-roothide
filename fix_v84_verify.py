#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正 verify_source_safety.py 的 v1.0.84 检查项

问题：原检查项用全文件字符串搜索关键词 → 注释里提到关键词就误判通过。
      双向验证实测：移除 bringSubviewToFront / 位置钳制 / ensureInBestWindow
      三个回归，检查脚本全部【没拦住】→ 检查形同虚设。

修法：复用 scan_compile_risk.py 的 strip_comments_strings，
      只在【剥离注释后的代码】里匹配。
"""
import io
import re
import sys

P = "verify_source_safety.py"

STRIP_FUNC = '''

def _strip_comments_strings(src):
    """剥离注释与字符串字面量（与 scan_compile_risk.py 同源实现）

    必须剥离后再做关键词检查 —— 否则注释里写一句
    「// 用了 bringSubviewToFront」就会让检查项误判通过，
    双向验证已实测过这个坑。
    """
    out = []
    i = 0
    n = len(src)
    state = None
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "/" and nxt == "/":
                state = "line"; out.append("  "); i += 2; continue
            if c == "/" and nxt == "*":
                state = "block"; out.append("  "); i += 2; continue
            if c == '"':
                state = '"'; out.append(" "); i += 1; continue
            if c == "'":
                state = "'"; out.append(" "); i += 1; continue
            out.append(c); i += 1; continue
        if state == "line":
            if c == "\\n":
                state = None; out.append("\\n")
            else:
                out.append(" ")
            i += 1; continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = None; out.append("  "); i += 2; continue
            out.append("\\n" if c == "\\n" else " "); i += 1; continue
        if state == '"':
            if c == "\\\\":
                out.append("  "); i += 2; continue
            if c == '"':
                state = None; out.append(" ")
            else:
                out.append("\\n" if c == "\\n" else " ")
            i += 1; continue
        if state == "'":
            if c == "\\\\":
                out.append("  "); i += 2; continue
            if c == "'":
                state = None; out.append(" ")
            else:
                out.append("\\n" if c == "\\n" else " ")
            i += 1; continue
    return "".join(out)
'''

NEW_BODY = '''    # 关键：必须在【剥离注释与字符串】后的代码里做关键词检查，
    # 否则注释里的关键词会让检查项形同虚设（双向验证已实测过这个坑）。
    code = _strip_comments_strings(src)

    # ---- 1) 分片时长可配置 ----
    if "asrChunkSeconds" not in code:
        errors.append("v1.0.84 回归: 缺少 asrChunkSeconds 配置 —— "
                      "ASR 分片时长必须可配置（设备实测 RTT ≈ 音频时长 × 1.1）")
    else:
        m = re.search(r"double\\s+chunkSecs\\s*=\\s*([^;]+);", code)
        if not m:
            errors.append("v1.0.84 回归: 未找到 chunkSecs 赋值 —— "
                          "ASR 分片必须走可配置时长")
        elif "asrChunkSeconds" not in m.group(1):
            errors.append("v1.0.84 回归: chunkSecs 被写死为 %s —— "
                          "必须使用 [[LCConfig shared] asrChunkSeconds]" % m.group(1).strip())
        # 所有分片阈值判断都必须引用 chunkSecs，不能再写死 5.0 / 10.0
        for mm in re.finditer(r"secs\\s*>=\\s*([0-9]+\\.?[0-9]*)", code):
            errors.append("v1.0.84 回归 行%d: 分片阈值仍写死 %s 秒 —— "
                          "必须改用 chunkSecs（延迟与分片长度成正比）"
                          % (code[:mm.start()].count("\\n") + 1, mm.group(1)))
        # 两条音频入口路径（appendBufferList / appendMonoFloat）都必须改
        if len(re.findall(r"secs\\s*>=\\s*chunkSecs", code)) < 2:
            errors.append("v1.0.84 回归: 只有部分音频入口改用了 chunkSecs —— "
                          "appendBufferList: 与 appendMonoFloat: 两条路径都要改")

    # ---- 2) 毫秒级 RTT 打点 ----
    if not re.search(r"asr:\\s*rtt=", code):
        errors.append("v1.0.84 回归: 缺少毫秒级 RTT 打点 —— "
                      "设备日志只有秒级精度，无法定位延迟在网络还是服务端")

    # ---- 3) bringSubviewToFront（必须是真实调用语句，不是注释）----
    if not re.search(r"\\[\\s*parent\\s+bringSubviewToFront\\s*:\\s*_container\\s*\\]", code):
        errors.append("v1.0.84 回归: 缺少 [parent bringSubviewToFront:_container] 调用 —— "
                      "YouTube 全屏 VC 的 view 在 subviews 末尾，会盖住字幕框")

    # ---- 4) ensureInBestWindow ----
    if not re.search(r"\\[\\s*self\\s+ensureInBestWindow\\s*\\]", code):
        errors.append("v1.0.84 回归: 缺少 [self ensureInBestWindow] 调用 —— "
                      "全屏若新建 window，字幕必须跟着搬到新的 key window")
    if "UIWindowDidBecomeKeyNotification" not in code:
        errors.append("v1.0.84 回归: 缺少 UIWindowDidBecomeKeyNotification 监听 —— "
                      "全屏新建 window 时需要及时把字幕搬过去")

    # ---- 5) 位置钳制 ----
    if not re.search(r"f\\.origin\\.y\\s*=\\s*MIN\\(\\s*MAX\\(", code):
        errors.append("v1.0.84 回归: 缺少位置钳制 —— "
                      "竖屏拖动位置转横屏后字幕会跑出屏幕外（全屏时看不见）")
'''


def main():
    src = io.open(P, encoding="utf-8").read()
    orig = src

    # 1) 插入 strip 工具函数
    if "_strip_comments_strings" not in src:
        m = re.search(r"\ndef check_v84_fixes\(", src)
        if not m:
            print("FAIL: 找不到 check_v84_fixes")
            return 1
        src = src[:m.start()] + STRIP_FUNC + src[m.start():]

    # 2) 替换 check_v84_fixes 的检查体
    m = re.search(r"\ndef check_v84_fixes\(.*?\n(?=\ndef |\Z)", src, re.S)
    if not m:
        print("FAIL: 找不到 check_v84_fixes 函数体")
        return 1
    old_func = m.group(0)
    # 保留函数签名与 docstring
    dm = re.match(r"\ndef check_v84_fixes\(src, panel_src=None\):\n(\s*\"\"\".*?\"\"\")\n",
                  old_func, re.S)
    if not dm:
        print("FAIL: 无法解析 check_v84_fixes 头部")
        return 1
    new_func = dm.group(0) + NEW_BODY + "\n"
    src = src[:m.start()] + new_func + src[m.end():]

    if src == orig:
        print("无改动")
        return 1
    io.open(P, "w", encoding="utf-8", newline="\n").write(src)
    print("已修正 v1.0.84 检查项（改为剥离注释后匹配）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
