#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LiveCap 源码静态安全检查（CI 每次构建自动跑）

背景：v1.0.69 引入 YouTube 闪退，根因有二：
  1. 在 UIView.hitTest 里同步写日志文件 —— hitTest 被 UIKit 高频调用，
     主线程文件 I/O 触发 iOS watchdog 杀进程。
  2. AAC 包描述越界：官方包描述是【码流级】的（实测恒为 frames×16），
     指向 buffer 之外的数据，AudioConverter 越界读。

本脚本对这两类问题做静态拦截，避免坏包流到设备。
用法: python3 verify_source_safety.py
"""
import re
import sys

SRC = "LiveCap.m"

errors = []
warnings = []


def read_src():
    with open(SRC, "r", encoding="utf-8") as f:
        return f.read()


def check_no_io_in_hit_test(src):
    """禁止在 hitTest / touchesXxx 等 UI 热路径里做文件 I/O 或日志写盘"""
    hot = ["hitTest", "touchesBegan", "touchesMoved", "touchesEnded",
           "touchesCancelled", "layoutSubviews", "drawRect"]
    for fn in hot:
        # 找到该方法体（花括号配平）
        m = re.search(r"-\s*\([^)]*\)\s*" + fn + r"[^\n]*\{", src)
        if not m:
            continue
        start = m.end() - 1
        depth = 0
        end = start
        for i in range(start, len(src)):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        body = src[start:end]
        for bad in ["LCLogF(", "LCLog(", "writeToFile", "NSFileHandle",
                    "stringByAppendingPathComponent"]:
            if bad in body:
                errors.append(
                    "闪退风险: %s() 内出现 %s —— UI 热路径禁止文件 I/O/日志写盘"
                    % (fn, bad))
                break


def check_macho_bounds_guards(src):
    """AAC 包描述必须做边界校验"""
    # 官方包描述使用处必须有 dataLen 校验
    if "CMSampleBufferGetAudioStreamPacketDescriptions" in src:
        if "end > (SInt64)dataLen" not in src and "end > (SInt64)dataLen" not in src.replace(" ", ""):
            errors.append("AAC 越界风险: 官方包描述未校验 offset+size <= dataLen")
        # 逐包校验
        if "mDataByteSize == 0" not in src:
            errors.append("AAC 越界风险: 包描述未过滤 mDataByteSize == 0 的空包")
    # 重建路径必须检查累计偏移
    if "off + sz > (size_t)dataLen" not in src:
        errors.append("AAC 越界风险: 重建包描述时未检查 off+sz <= dataLen")
    # 输出缓冲容量必须与 outNumPackets 对齐
    # 新逻辑: outNumPackets = min(容量帧数, totalSamples)，且容量按 totalSamples 严格算
    if "outNumPackets > realFrames" not in src:
        errors.append("输出越界风险: outNumPackets 未限制在 realFrames(实际可解出帧数)之内")
    if "totalSamples * outASBD.mBytesPerFrame" not in src:
        errors.append("输出越界风险: outCapacity 未按 totalSamples*bytesPerFrame 严格计算")
    # 输入回调的偏移基准必须正确：mData 指向该包真实起点 + mStartOffset 归零
    if "sOne.mStartOffset = 0;" not in src:
        errors.append("AAC 越界风险: 输入回调未把 mStartOffset 归零（基准不一致会导致 -50）")
    if "absOff + absLen > (UInt64)in->dataLen" not in src:
        errors.append("AAC 越界风险: 输入回调缺少包越界保护")


def check_output_capacity(src):
    """输出帧数必须有上限，防止超大分配"""
    if "totalSamples > 16000 * 30" not in src:
        warnings.append("建议: 输出帧数加上限保护（如 30 秒音频），防止超大分配")
    if "mDataByteSize > outCapacity" not in src:
        errors.append("输出越界风险: 未校验转换器写入字节数 <= outCapacity")


def check_required_features(src):
    """必须保留的关键修复"""
    required = [
        ("shouldRecognizeSimultaneouslyWithGestureRecognizer",
         "手势同时识别（修 YouTube 手势竞争导致拖不动）"),
        ("16k_multi_lang", "多语言大模型 ASR 引擎"),
        ("%@/%@/tc3_request", "TC3 三段 credential scope"),
        ('forHTTPHeaderField:@"User-Agent"', "显式 User-Agent"),
    ]
    for token, desc in required:
        if token not in src:
            errors.append("缺少关键修复: %s (%s)" % (desc, token))


def check_v81_fixes(src):
    """v1.0.81 关键修复的回归拦截

    这几条对应用户实测反馈的三个问题，漏掉任何一条都会退回到旧行为：
      1. 字幕框不轮动  → showPending 必须立刻刷屏（不能只在首次显示时刷）
      2. 一直显示英文  → 必须用快模型 agnes-2.5-flash + 短 prompt + 并行竞速
      3. 日志刷屏      → 高频路径必须节流
    """
    # 1) 轮动：showPending 里必须有 renderCurrent 调用
    # 注意正则必须精确锚定到方法体的第一个 '{'，否则贪婪匹配会落到内层 if 的 '{' 上
    m = re.search(r"-\s*\(NSUInteger\)\s*showPending:\(NSString \*\)\w+\s*\{", src)
    if not m:
        errors.append("v1.0.81 回归: showPending 签名必须返回 NSUInteger seq")
    else:
        start = m.end() - 1
        depth = 0
        end = start
        for i in range(start, len(src)):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        body = src[start:end]
        if "renderCurrent" not in body:
            errors.append("v1.0.81 回归: showPending 内没有 renderCurrent —— "
                          "字幕框会不轮动（画面冻结在第一句）")
        if "_displayedSeq = seq" not in body:
            errors.append("v1.0.81 回归: showPending 内没有设置 _displayedSeq —— "
                          "译文无法与画面配对")

    # 2) 翻译：快模型 + 竞速 + 合理超时
    if "agnes-2.5-flash" not in src:
        errors.append("v1.0.81 回归: 默认模型必须是 agnes-2.5-flash "
                      "（agnes-3.0-flash 实测 29~40s，必然超时）")
    if "raceTranslate" not in src:
        errors.append("v1.0.81 回归: 缺少 raceTranslate —— "
                      "串行 fallback 会被最慢的厂商拖死（实测 45s+）")
    if "req.timeoutInterval = 15.0" in src:
        errors.append("v1.0.81 回归: openai 超时仍是 15s，"
                      "慢模型必然超时（应 >= 30s）")
    # prompt 长度：长 prompt 会把延迟从 1s 抬到 35s
    m = re.search(r'@"You are a professional subtitle translator', src)
    if m:
        errors.append("v1.0.81 回归: 仍在使用 1401 字节长 prompt —— "
                      "网关排队时间会暴涨到 30s+")

    # 3) 日志节流：高频路径必须走 LCLogThrottled
    for tag, desc in [("asbr", "音频 buffer"), ("decin", "解码入口"),
                      ("decpkts", "包数"), ("decframes", "解码帧数")]:
        if 'LCLogThrottled(@"%s"' % tag not in src:
            errors.append("v1.0.81 回归: %s 日志未节流（缺 LCLogThrottled(@\"%s\")）"
                          % (desc, tag))

    # 4) provider 内部不得写缓存（竞速下会覆盖胜出结果 / 污染出英文回显）
    # 注意这几个方法的签名是跨多行的，正则必须允许换行
    for fn in ["mymemoryTranslate", "openaiTranslate", "tencentTranslate"]:
        m = re.search(r"-\s*\(void\)\s*" + fn + r"\s*:[^;{]*\{", src)
        if not m:
            errors.append("v1.0.81 回归: 找不到 %s 方法定义，无法校验缓存归属" % fn)
            continue
        start = m.end() - 1
        depth = 0
        end = start
        for i in range(start, len(src)):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        body = src[start:end]
        if "_cache[cacheKey] =" in body:
            errors.append("v1.0.81 回归: %s 内部写缓存 —— "
                          "竞速下会覆盖胜出译文/写入英文回显" % fn)


def main():
    try:
        src = read_src()
    except Exception as e:
        print("ERROR: 无法读取 %s: %s" % (SRC, e))
        sys.exit(1)

    check_no_io_in_hit_test(src)
    check_macho_bounds_guards(src)
    check_output_capacity(src)
    check_required_features(src)
    check_v81_fixes(src)

    print("=== LiveCap 源码安全检查 ===")
    print("  文件: %s (%d 字节)" % (SRC, len(src.encode("utf-8"))))
    print("")

    if warnings:
        for w in warnings:
            print("  WARN: %s" % w)
    if errors:
        for e in errors:
            print("  ERROR: %s" % e)
        print("")
        print("共 %d 个错误，构建中止。" % len(errors))
        sys.exit(1)

    print("  OK: 未发现 UI 热路径 I/O、无界内存访问等已知闪退风险")
    print("  OK: 关键修复均在位（手势同时识别/大模型引擎/TC3 scope/User-Agent）")
    print("  OK: v1.0.81 修复在位（轮动刷新/快模型+竞速/日志节流/缓存归属）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
