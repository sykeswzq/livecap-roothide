#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 verify_source_safety.py 追加 v1.0.84 回归拦截项"""
import io
import re
import sys

P = "verify_source_safety.py"


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


NEW_FUNC = '''

def check_v84_fixes(src, panel_src=None):
    """v1.0.84 关键修复的回归拦截

    用户实测反馈：「基本可以 然后翻译有点延迟，还有就是全屏的时候字幕框好像显示不出来」

    拦截点：
      1. ASR 分片时长必须可配置（不得退回固定 5 秒 —— 设备实测 RTT ≈ 音频时长）
      2. 必须有毫秒级 RTT 打点（否则无法定位延迟究竟在网络还是服务端）
      3. 必须调用 bringSubviewToFront（全屏 VC 的 view 在 subviews 末尾，会盖住字幕）
      4. 必须调用 ensureInBestWindow（全屏新建 window 时字幕要跟着搬过去）
      5. 必须有位置钳制（竖屏拖动位置转横屏后会跑出屏幕）
    """
    # ---- 1) 分片时长可配置 ----
    if "asrChunkSeconds" not in src:
        errors.append("v1.0.84 回归: 缺少 asrChunkSeconds 配置 —— "
                      "ASR 分片时长必须可配置（设备实测 RTT ≈ 音频时长 × 1.1）")
    else:
        m = re.search(r"double\\s+chunkSecs\\s*=\\s*([^;]+);", src)
        if not m:
            errors.append("v1.0.84 回归: 未找到 chunkSecs 赋值 —— "
                          "ASR 分片必须走可配置时长")
        elif "asrChunkSeconds" not in m.group(1):
            errors.append("v1.0.84 回归: chunkSecs 被写死为 %s —— "
                          "必须使用 [[LCConfig shared] asrChunkSeconds]" % m.group(1).strip())
        # 分片阈值判断必须引用 chunkSecs，不能再写死 5.0
        for mm in re.finditer(r"secs\\s*>=\\s*([0-9]+\\.?[0-9]*)", src):
            if mm.group(1) == "5.0":
                errors.append("v1.0.84 回归 行%d: 分片阈值仍写死 5.0 秒 —— "
                              "必须改用 chunkSecs（延迟与分片长度成正比）"
                              % (src[:mm.start()].count("\\n") + 1))

    # ---- 2) 毫秒级 RTT 打点 ----
    if not re.search(r"asr:\\s*rtt=[^\\"]*ms", src):
        errors.append("v1.0.84 回归: 缺少毫秒级 RTT 打点 —— "
                      "设备日志只有秒级精度，无法定位延迟在网络还是服务端")

    # ---- 3) bringSubviewToFront ----
    if "bringSubviewToFront" not in src:
        errors.append("v1.0.84 回归: 缺少 bringSubviewToFront —— "
                      "YouTube 全屏 VC 的 view 在 subviews 末尾，会盖住字幕框")

    # ---- 4) ensureInBestWindow ----
    if "ensureInBestWindow" not in src:
        errors.append("v1.0.84 回归: 缺少 ensureInBestWindow —— "
                      "全屏若新建 window，字幕必须跟着搬到新的 key window")
    if "UIWindowDidBecomeKeyNotification" not in src:
        errors.append("v1.0.84 回归: 缺少 UIWindowDidBecomeKeyNotification 监听 —— "
                      "全屏新建 window 时需要及时把字幕搬过去")

    # ---- 5) 位置钳制 ----
    if not re.search(r"f\\.origin\\.y\\s*=\\s*MIN\\(MAX\\(", src):
        errors.append("v1.0.84 回归: 缺少位置钳制 —— "
                      "竖屏拖动位置转横屏后字幕会跑出屏幕外（全屏时看不见）")
'''


def main():
    src = read(P)
    if "def check_v84_fixes" in src:
        print("已存在 v1.0.84 检查项，跳过")
        return 0

    # 1) 插入新函数（放在 check_v83_fixes 之后、main 之前）
    m = re.search(r"\ndef main\(\)", src)
    if not m:
        print("FAIL: 找不到 main()")
        return 1
    src = src[:m.start()] + NEW_FUNC + src[m.start():]

    # 2) 在调用点插入
    m2 = re.search(r"^(\s*)check_v83_fixes\(src, panel_src\)\s*$", src, re.M)
    if not m2:
        print("FAIL: 找不到 check_v83_fixes 调用点")
        return 1
    indent = m2.group(1)
    src = src[:m2.end()] + "\n%scheck_v84_fixes(src, panel_src)" % indent + src[m2.end():]

    # 3) 在输出区插入 OK 行
    m3 = re.search(r'^(.*print\("  OK: v1\.0\.83 修复在位.*\)\s*)$', src, re.M)
    if not m3:
        print("FAIL: 找不到 v1.0.83 OK 输出行")
        return 1
    src = src[:m3.end()] + '\n%s    print("  OK: v1.0.84 修复在位（分片时长可配置/毫秒RTT打点/提到最上层/跟随新window/位置钳制）")' % m3.group(1) + src[m3.end():]

    write(P, src)
    print("已插入 v1.0.84 检查项")
    return 0


if __name__ == "__main__":
    sys.exit(main())
