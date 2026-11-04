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
import io
import os
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


def check_v82_fixes(src):
    """v1.0.82 关键修复的回归拦截

    用户实测反馈：「有时候是两行 一行英语 一行中文，我只要一行中文就行了」
    以及二次确认：「不要显示英文原文，只要翻译的就行」

    拦截点：
      1. 默认必须只显示中文（showEnglish 默认 NO）
      2. 只中文模式下英文标签必须彻底收起（frame 归零 + hidden）
      3. 只中文模式下不能清空上一句译文（否则字幕框闪「翻译中…」）
      4. 翻译队列必须是 FIFO（单槽覆盖会让中间句子的中文整句丢失）
      5. 1 秒去重节流不能静默丢弃 completion
    """
    # 1) showEnglish 默认值必须是 NO（只中文）
    m = re.search(r"-\s*\(BOOL\)\s*showEnglish\s*\{", src)
    if not m:
        errors.append("v1.0.82 回归: 缺少 showEnglish 配置读取方法")
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
        # 默认必须是 NO（只显示中文）—— 两处 return 都要检查
        # （实时读盘分支 + 缓存兜底分支），漏一处就会退回双语
        defaults = re.findall(r"return\s+v\s*\?\s*\[v boolValue\]\s*:\s*(NO|YES)", body)
        if not defaults:
            errors.append("v1.0.82 回归: showEnglish 未按「缺省=只显示中文」实现")
        elif "YES" in defaults:
            errors.append("v1.0.82 回归: showEnglish 默认值出现 YES —— "
                          "默认应只显示中文译文一行（用户明确要求）")
        # 必须实时读盘，否则面板切换开关要重启 App 才生效
        if "dictionaryWithContentsOfFile" not in body:
            errors.append("v1.0.82 回归: showEnglish 未实时读盘 —— "
                          "面板切换开关后需重启 App 才生效")

    # 2) renderCurrent：英文标签必须彻底收起
    m = re.search(r"-\s*\(void\)\s*renderCurrent\s*\{", src)
    if not m:
        errors.append("v1.0.82 回归: 找不到 renderCurrent 方法")
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
        if "_originLabel.hidden = YES" not in body:
            errors.append("v1.0.82 回归: renderCurrent 未隐藏英文标签 —— "
                          "只中文模式下仍会显示英文行")
        if "_originLabel.frame = CGRectZero" not in body:
            errors.append("v1.0.82 回归: renderCurrent 未把英文标签 frame 归零 —— "
                          "会残留上一句英文，表现为上下两行")
        # 只中文模式：origin 必须置空（不参与高度计算）
        if 'showEn ? (_displayedOrigin ?: @"") : @""' not in body:
            errors.append("v1.0.82 回归: renderCurrent 未按 showEnglish 置空 origin —— "
                          "英文行仍会占用高度")

    # 3) 只中文模式下 showPending 不能清空上一句译文
    m = re.search(r"-\s*\(NSUInteger\)\s*showPending:\(NSString \*\)\w+\s*\{", src)
    if m:
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
        if "keeping last" not in body and "保留" not in body:
            errors.append("v1.0.82 回归: showPending 未区分只中文模式 —— "
                          "只中文模式下必须保留上一句译文，不能清空后闪「翻译中…」")
        # 双语分支仍要设置 _displayedSeq
        if "_displayedSeq = seq" not in body:
            errors.append("v1.0.82 回归: showPending 双语分支未设置 _displayedSeq")
        # 只中文分支绝不能清空 _displayedTranslation（那会让字幕反复闪占位）
        zh_branch = body.split("showEnglish")[-1] if "showEnglish" in body else body
        if "_displayedTranslation = nil" in zh_branch.split("双语模式")[0]:
            errors.append("v1.0.82 回归: 只中文分支里清空了 _displayedTranslation —— "
                          "字幕框会反复闪「翻译中…」")

    # 4) 翻译队列必须是 FIFO，不能是单槽覆盖
    if "_pendingItems" not in src:
        errors.append("v1.0.82 回归: 翻译队列未改为 FIFO —— "
                      "单槽覆盖会让中间句子的 completion 丢失（中文整句不显示）")
    # 单槽变量必须【彻底消失】—— 只要还有 _pendingText/_pendingCompletion，
    # 就说明某条路径仍在用「新文本覆盖旧文本」，那句话的 completion 会被丢弃
    for legacy in ["_pendingText", "_pendingCompletion"]:
        if legacy in src:
            errors.append("v1.0.82 回归: 仍存在单槽变量 %s —— "
                          "新文本会覆盖旧文本的回调，导致那句话的中文整句消失" % legacy)
    # FIFO 队列必须有长度上限，否则积压时延迟无界增长
    m = re.search(r"kMaxQueue\s*=\s*(\d+)", src)
    if not m:
        errors.append("v1.0.82 回归: FIFO 队列没有长度上限 —— "
                      "翻译积压时字幕会越来越滞后于语音")
    elif int(m.group(1)) > 5:
        errors.append("v1.0.82 回归: FIFO 队列上限 %s 过大 —— "
                      "翻译积压时字幕会越来越滞后于语音（上限应 <= 5）" % m.group(1))

    # 5) 1 秒去重节流不能静默丢弃 completion
    m = re.search(r"-\s*\(void\)\s*translate:\(NSString \*\)\w+\s*\n?[^\n]*\{", src)
    if m:
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
        if "completion(nil)" not in body:
            errors.append("v1.0.82 回归: 1 秒去重节流未回调 nil —— "
                          "静默 return 会让这句的 completion 永不执行（中文整句丢失）")


def check_objc_type_hazards(src):
    """拦截 Objective-C 编译期类型错误（本机无 xcrun，无法本地编译，
    只能靠静态扫描 + CI 兜底；CI 一次往返 3~5 分钟，反复试错代价太高）。

    已踩过的坑：
      LiveCap.m:435  error: incompatible operand types
        ('void (^)(NSString *__strong)' and 'NSNull * _Nonnull')
      根因：?: 运算符要求两侧类型一致，block 与 NSNull* 混用直接编译报错。
    """
    # 0) 先剥掉注释行 —— 注释里的示例代码（如「不能写成 completion ?: [NSNull null]」）
    #    会造成误报
    code_lines = []
    for ln in src.split("\n"):
        st = ln.lstrip()
        if st.startswith("//"):
            code_lines.append("")
        else:
            code_lines.append(ln)
    code = "\n".join(code_lines)

    # 1) ?: 两侧出现 block 字面量
    #    正确匹配 ?: 表达式：cond ? A : B
    #    （注意 A 允许为空 —— `completion ?: [NSNull null]` 是最危险的那种）
    TERNARY = re.compile(r"([A-Za-z_][\w\.\[\]]*)\s*\?\s*([^:;\n]*?)\s*:\s*([^;\n]+)")
    for m in TERNARY.finditer(code):
        a, b = m.group(2).strip(), m.group(3).strip()
        if "^(NSString" in a or "^(NSString" in b:
            line = code[:m.start()].count("\n") + 1
            errors.append(
                "编译错误风险 行%d: ?: 两侧混用 block 字面量 —— "
                "?: 要求两侧类型一致（block vs NSNull* 会报 incompatible operand types）"
                % line)

    # 2) ?: 一侧是 NSNull、另一侧不是 —— 但两侧都显式 cast 成 id 的写法是合法的
    #    （id compBox = completion ? (id)completion : (id)[NSNull null];）
    #    只有【未 cast】时才是编译错误。
    for m in TERNARY.finditer(code):
        a, b = m.group(2).strip(), m.group(3).strip()
        if ("NSNull" in a) == ("NSNull" in b):
            continue
        # 两侧都显式 cast 成 id → 合法
        if a.startswith("(id)") and b.startswith("(id)"):
            continue
        line = code[:m.start()].count("\n") + 1
        errors.append(
            "编译错误风险 行%d: ?: 一侧是 NSNull 另一侧不是 —— "
            "block 与 NSNull* 类型不兼容（两侧都要 cast 成 id）" % line)

    # 3) block 变量从容器取出后未显式 cast（id -> block 需要 cast）
    for m in re.finditer(r"void \(\^(\w+)\)\([^)]*\)\s*=\s*\([^)]*\)\s*(\w+)\[", code):
        line = code[:m.start()].count("\n") + 1
        if "(void (^)" not in m.group(0):
            errors.append("编译错误风险 行%d: %s 从容器取出后未显式 cast 成 block"
                          % (line, m.group(1)))

    # 4) 从 id 直接赋值给 block 变量（缺 cast 会报 incompatible pointer types）
    for m in re.finditer(r"void \(\^(\w+)\)\([^)]*\)\s*=\s*(\w+)\[", code):
        name, srcvar = m.group(1), m.group(2)
        line = code[:m.start()].count("\n") + 1
        errors.append("编译错误风险 行%d: %s 直接由 %s[...] 赋值 —— "
                      "必须显式 cast 成 block 类型" % (line, name, srcvar))



def check_v83_fixes(src, panel_src=None):
    """v1.0.83 关键修复的回归拦截

    用户实测反馈：「82翻译还是有英文，然后中文没显示全」

    拦截点：
      1. 配置键必须是 showBilingual，且 showEnglish 不得再作为配置键被读取
      2. tweak 侧必须有统一写回通道 writeConfig:（含 CFPreferencesAppSynchronize）
      3. _userMoved 分支必须更新 frame.size（否则容器高度冻结 → 中文被裁）
      4. measureW 必须扣掉左右内边距 pad*2（否则测量高度偏小 → 末行被裁）
      5. 只中文模式收起英文标签时必须清空 attributedText（杜绝英文残留）
      6. 面板侧必须用文件直读直写（不能纯 CFPreferences，否则又跟 tweak 竞争）
    """
    # ---- 1) 配置键语义 ----
    m = re.search(r"-\s*\(BOOL\)\s*showEnglish\s*\{", src)
    if not m:
        errors.append("v1.0.83 回归: 缺少 showEnglish 配置读取方法")
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
        if "showBilingual" not in body:
            errors.append("v1.0.83 回归: showEnglish 方法未读取 showBilingual 键 —— "
                          "必须语义反转为 showBilingual（默认 NO=只显示中文）")
        # 老键 showEnglish 一律不能作为配置键被读取
        if re.search(r"[@\[]\"?showEnglish\"?\s*\]", body):
            errors.append("v1.0.83 回归: showEnglish 方法仍在读取 showEnglish 配置键 —— "
                          "该键会被两套写入机制覆写，必须彻底只认 showBilingual")
        # 默认值必须是 NO
        defaults = re.findall(r"return\s+v\s*\?\s*\[v boolValue\]\s*:\s*(NO|YES)", body)
        if not defaults:
            errors.append("v1.0.83 回归: showEnglish 未按「缺省=只显示中文」实现")
        elif "YES" in defaults:
            errors.append("v1.0.83 回归: showEnglish 默认值出现 YES —— "
                          "默认应只显示中文译文一行（用户明确要求）")

    # 全局扫描：tweak 源码里不得再有 showEnglish 作为配置键
    for mm in re.finditer(r"[@\[]\"showEnglish\"\]", src):
        line = src[:mm.start()].count("\n") + 1
        errors.append("v1.0.83 回归 行%d: 仍在用 showEnglish 作为配置键 —— "
                      "该键会被覆写，必须改为 showBilingual" % line)

    # ---- 2) 统一写回通道 ----
    # 注意：@interface 里也有 `- (void)writeConfig:(NSMutableDictionary *)d;` 声明行，
    #       提取方法体必须跳过以 `;` 结尾的声明，只认以 `{` 开头的实现。
    m = None
    for cand in re.finditer(r"-\s*\(void\)\s*writeConfig\s*:\s*\([^)]*\)\s*(\w+)\s*(\{|;)",
                            src):
        if cand.group(2) == "{":
            m = cand
            break
    if not m:
        errors.append("v1.0.83 回归: 缺少 writeConfig: 统一配置写回通道 —— "
                      "面板与 tweak 会互相覆写同一个 plist")
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
        if "writeToFile" not in body:
            errors.append("v1.0.83 回归: writeConfig: 没有 writeToFile —— "
                          "必须走文件直写通道")
        if "CFPreferencesAppSynchronize" not in body:
            errors.append("v1.0.83 回归: writeConfig: 没有 CFPreferencesAppSynchronize —— "
                          "cfprefsd 内存里的旧值会把文件覆盖回去")

    # ---- 3) _userMoved 必须更新 size ----
    m = re.search(r"-\s*\(void\)\s*renderCurrent\s*\{", src)
    if not m:
        errors.append("v1.0.83 回归: 缺少 renderCurrent 方法")
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
        # 定位 _userMoved 分支
        um = re.search(r"if\s*\(\s*_userMoved\s*\)\s*\{", body)
        if not um:
            errors.append("v1.0.83 回归: renderCurrent 中找不到 _userMoved 分支")
        else:
            ustart = um.end() - 1
            udepth = 0
            uend = ustart
            for i in range(ustart, len(body)):
                if body[i] == "{":
                    udepth += 1
                elif body[i] == "}":
                    udepth -= 1
                    if udepth == 0:
                        uend = i
                        break
            ubody = body[ustart:uend]
            if "f.size" not in ubody and "size =" not in ubody:
                errors.append("v1.0.83 回归: _userMoved 分支没有更新容器尺寸 —— "
                              "容器高度会被永久冻结，中文标签超出部分被 masksToBounds 裁掉"
                              "（用户反馈「中文没显示全」的根因）")
            if "_container.center" not in ubody and "_userCenter" not in ubody:
                errors.append("v1.0.83 回归: _userMoved 分支没有保持用户拖动的中心点")

        # ---- 4) measureW 必须扣内边距 ----
        mm = re.search(r"CGFloat\s+measureW\s*=\s*([^;]+);", body)
        if not mm:
            errors.append("v1.0.83 回归: renderCurrent 中找不到 measureW 定义")
        else:
            expr = mm.group(1)
            if "pad" not in expr:
                errors.append("v1.0.83 回归: measureW 未扣掉左右内边距 pad —— "
                              "测量高度会偏小导致末行被裁（用户反馈「中文没显示全」）")

        # ---- 5) 英文标签收起时清空文本 ----
        if re.search(r"_originLabel\.hidden\s*=\s*YES", body):
            seg_m = re.search(r"_originLabel\.hidden\s*=\s*YES([^}]*)", body)
            seg = seg_m.group(1) if seg_m else ""
            if "attributedText = nil" not in seg:
                errors.append("v1.0.83 回归: 收起英文标签时未清空 attributedText —— "
                              "label 会持有上一句英文，任何分支漏 hidden 就会闪现英文")

    # ---- 6) 面板必须文件直读直写 ----
    if panel_src is None:
        warnings.append("v1.0.83: 未读取面板源码，跳过面板通道检查")
    else:
        if "dictionaryWithContentsOfFile" not in panel_src:
            errors.append("v1.0.83 回归: 面板未使用文件直读 —— "
                          "面板用 CFPreferences、tweak 用文件直写会互相覆写")
        if 'LCGet(@"showBilingual")' not in panel_src:
            errors.append("v1.0.83 回归: 面板开关未读写 showBilingual —— "
                          "必须与 tweak 用同一个键")
        if 'LCSet(@(sw.on), @"showBilingual")' not in panel_src:
            errors.append("v1.0.83 回归: 面板开关写入的键不是 showBilingual")
        if "CFPreferencesAppSynchronize" not in panel_src:
            errors.append("v1.0.83 回归: 面板写入后没有 CFPreferencesAppSynchronize —— "
                          "cfprefsd 内存旧值会覆盖文件")
        # 面板不得再用 CFPreferencesSetAppValue 写这个开关
        for mm in re.finditer(r"CFPreferencesSetAppValue\s*\([^)]*showBilingual[^)]*\)",
                              panel_src):
            line = panel_src[:mm.start()].count("\n") + 1
            errors.append("v1.0.83 回归 面板行%d: showBilingual 仍用 CFPreferencesSetAppValue 写 —— "
                          "必须改用文件直写" % line)

PANEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "PrefBundle", "LiveCapPrefs.m")



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
            if c == "\n":
                state = None; out.append("\n")
            else:
                out.append(" ")
            i += 1; continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = None; out.append("  "); i += 2; continue
            out.append("\n" if c == "\n" else " "); i += 1; continue
        if state == '"':
            if c == "\\":
                out.append("  "); i += 2; continue
            if c == '"':
                state = None; out.append(" ")
            else:
                out.append("\n" if c == "\n" else " ")
            i += 1; continue
        if state == "'":
            if c == "\\":
                out.append("  "); i += 2; continue
            if c == "'":
                state = None; out.append(" ")
            else:
                out.append("\n" if c == "\n" else " ")
            i += 1; continue
    return "".join(out)

# 不存在的 UIKit 通知名 —— 用了会直接编译失败
# （v1.0.84 就在这上面栽了一轮：CI 报 undeclared identifier）
INVALID_UIKIT_NOTIFICATIONS = [
    "UIWindowDidChangeFrameNotification",
    "UIWindowDidChangeBoundsNotification",
    "UIWindowWillChangeFrameNotification",
]


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
    # 关键：必须在【剥离注释与字符串】后的代码里做关键词检查，
    # 否则注释里的关键词会让检查项形同虚设（双向验证已实测过这个坑）。
    code = _strip_comments_strings(src)

    # ---- 1) 分片时长可配置 ----
    if "asrChunkSeconds" not in code:
        errors.append("v1.0.84 回归: 缺少 asrChunkSeconds 配置 —— "
                      "ASR 分片时长必须可配置（设备实测 RTT ≈ 音频时长 × 1.1）")
    else:
        m = re.search(r"double\s+chunkSecs\s*=\s*([^;]+);", code)
        if not m:
            errors.append("v1.0.84 回归: 未找到 chunkSecs 赋值 —— "
                          "ASR 分片必须走可配置时长")
        elif "asrChunkSeconds" not in m.group(1):
            errors.append("v1.0.84 回归: chunkSecs 被写死为 %s —— "
                          "必须使用 [[LCConfig shared] asrChunkSeconds]" % m.group(1).strip())
        # 所有分片阈值判断都必须引用 chunkSecs，不能再写死 5.0 / 10.0
        for mm in re.finditer(r"secs\s*>=\s*([0-9]+\.?[0-9]*)", code):
            errors.append("v1.0.84 回归 行%d: 分片阈值仍写死 %s 秒 —— "
                          "必须改用 chunkSecs（延迟与分片长度成正比）"
                          % (code[:mm.start()].count("\n") + 1, mm.group(1)))
        # 两条音频入口路径（appendBufferList / appendMonoFloat）都必须改
        if len(re.findall(r"secs\s*>=\s*chunkSecs", code)) < 2:
            errors.append("v1.0.84 回归: 只有部分音频入口改用了 chunkSecs —— "
                          "appendBufferList: 与 appendMonoFloat: 两条路径都要改")

    # ---- 2) 毫秒级 RTT 打点 ----
    # 注意：RTT 打点写在日志格式串里，_strip_comments_strings 会连字符串字面量一起剥掉，
    #       所以这里必须在【原始源码】里找（格式串不会出现在注释里）。
    if not re.search(r"asr:\s*rtt=", src):
        errors.append("v1.0.84 回归: 缺少毫秒级 RTT 打点 —— "
                      "设备日志只有秒级精度，无法定位延迟在网络还是服务端")

    # ---- 3) bringSubviewToFront（必须是真实调用语句，不是注释）----
    if not re.search(r"\[\s*parent\s+bringSubviewToFront\s*:\s*_container\s*\]", code):
        errors.append("v1.0.84 回归: 缺少 [parent bringSubviewToFront:_container] 调用 —— "
                      "YouTube 全屏 VC 的 view 在 subviews 末尾，会盖住字幕框")

    # ---- 4) ensureInBestWindow ----
    # 要求【所有】调用点都在：源码有 2 处（渲染前提到最上层 + key window 变化回调），
    # 只保留一处不足以覆盖「全屏新建 window」的两种触发路径。
    ensure_calls = len(re.findall(r"\[\s*self\s+ensureInBestWindow\s*\]", code))
    if ensure_calls < 2:
        errors.append("v1.0.84 回归: [self ensureInBestWindow] 调用点只有 %d 处（需 ≥2）—— "
                      "渲染时与 key window 变化时都要重新挂载，否则全屏新建 window "
                      "后字幕留在旧 window 里看不见" % ensure_calls)
    if "UIWindowDidBecomeKeyNotification" not in code:
        errors.append("v1.0.84 回归: 缺少 UIWindowDidBecomeKeyNotification 监听 —— "
                      "全屏新建 window 时需要及时把字幕搬过去")

    # ---- 5) 位置钳制 ----
    if not re.search(r"f\.origin\.y\s*=\s*MIN\(\s*MAX\(", code):
        errors.append("v1.0.84 回归: 缺少位置钳制 —— "
                      "竖屏拖动位置转横屏后字幕会跑出屏幕外（全屏时看不见）")

    # ---- 6) 不得使用不存在的 UIKit 通知名 ----
    for bad in INVALID_UIKIT_NOTIFICATIONS:
        if bad in src:
            line = src[:src.index(bad)].count("\n") + 1
            errors.append("v1.0.84 回归 行%d: 用了不存在的通知名 %s —— "
                          "UIKit 没有这个通知，编译会报 undeclared identifier"
                          % (line, bad))


def check_v85_fixes(src, panel_src=None):
    """v1.0.85 关键修复的回归拦截

    用户实测反馈：「还是翻译速度有点慢 然后全屏的时候字幕框太宽了」

    设备实测（2026-11-04）：
      ASR RTT ≈ 1.1 × 音频秒数（5.11s→5.5s，2.56s→4.2~5.3s）
      翻译 RTT ≈ 0.82s（mymemory 赢竞速）→ 翻译只占 20%，ASR 占 80%

    拦截点：
      1. ASR 必须允许并发（BOOL _inFlight 串行 → 计数器）
      2. ASR 两条路径都必须走 AAC 压缩（漏改任一条 = 没修）
      3. AAC 编码失败 / 被腾讯云拒绝 → 必须能回退 WAV
      4. ASR 必须用直连 session（禁用系统代理）+ 失败回退代理
      5. 字幕框宽度必须有绝对上限（否则全屏时铺满整屏）
      6. pcm16 路径不得写死 5 秒分片（v1.0.84 漏改过）
    """
    code = _strip_comments_strings(src)

    # ---- 1) 并发控制 ----
    if re.search(r"BOOL\s+_inFlight\b", code):
        errors.append("v1.0.85 回归: 仍用 BOOL _inFlight 串行锁 —— "
                      "串行时 ASR 吞吐只有 0.91 实时率，字幕永远追不上语音，"
                      "必须改成计数器 + 并发上限")
    if "LC_ASR_MAX_CONCURRENCY" not in code:
        errors.append("v1.0.85 回归: 缺少 LC_ASR_MAX_CONCURRENCY 并发上限常量")
    elif "LC_ASR_MAX_CONCURRENCY" in code:
        m = re.search(r"LC_ASR_MAX_CONCURRENCY\s*=\s*(\d+)", code)
        if not m:
            errors.append("v1.0.85 回归: LC_ASR_MAX_CONCURRENCY 未赋常量值")
        elif int(m.group(1)) < 2:
            errors.append("v1.0.85 回归: 并发上限为 %s —— 必须 ≥2，"
                          "否则串行排队问题依旧" % m.group(1))
    # 并发判定必须真的用上计数
    conc = len(re.findall(r"_inFlightCount\s*<\s*LC_ASR_MAX_CONCURRENCY", code))
    if conc < 2:
        errors.append("v1.0.85 回归: 并发判定只出现 %d 处（需 ≥2）—— "
                      "appendBufferList: / appendMonoFloat: 两条音频入口都要改" % conc)
    # 释放槽位必须防负数
    if not re.search(r"if\s*\(\s*_inFlightCount\s*>\s*0\s*\)\s*_inFlightCount--", code):
        errors.append("v1.0.85 回归: 并发计数释放未防负数 —— "
                      "多次 DONE 会让计数变负，之后所有请求都会被判定为「槽位满」")

    # ---- 2) AAC 压缩（两条路径都要有）----
    aac_calls = len(re.findall(r"LCAACEncode16kMono\s*\(", code))
    if aac_calls < 3:   # 1 处定义 + 2 处调用
        errors.append("v1.0.85 回归: LCAACEncode16kMono 调用只有 %d 处（需 ≥2 处调用）—— "
                      "processChunk: 与 processChunk16: 两条路径都要压缩，"
                      "漏一条等于没修（v1.0.84 分片时长就漏过一条）" % aac_calls)
    # AAC 编码器本身必须存在且设置码率
    if "kAudioFormatMPEG4AAC" not in code:
        errors.append("v1.0.85 回归: 缺少 AAC 编码器实现 —— "
                      "PCM16@16k 需要 256kbps，设备上行只有约 255kbps，"
                      "必须压缩上传才能降延迟")
    if not re.search(r"kAudioConverterEncodeBitRate", code):
        errors.append("v1.0.85 回归: AAC 未设置码率 —— 会用系统默认码率，体积压不下去")
    # 两条路径都要把 VoiceFormat 动态化
    # 注意：@"VoiceFormat" 是字符串字面量，_strip_comments_strings 会把它剥掉，
    #       所以必须在【原始源码】里匹配（注释里写的是 VoiceFormat = "aac"，不会误判）。
    if len(re.findall(r'@"VoiceFormat"\s*:\s*voiceFormat', src)) < 2:
        errors.append("v1.0.85 回归: VoiceFormat 未在两条路径都动态化 —— "
                      "必须按实际编码格式填 wav/aac")

    # ---- 3) 回退机制 ----
    # 注意用词边界 \b：否则 _aacBrokenUnused 这类改名能骗过子串检查
    if not re.search(r"\b_aacBroken\b", code):
        errors.append("v1.0.85 回归: 缺少 _aacBroken 标记 —— "
                      "AAC 被腾讯云拒绝时必须能永久回退 WAV，不能整条链路挂掉")
    if not re.search(r"\b_directFailed\b", code):
        errors.append("v1.0.85 回归: 缺少 _directFailed 标记 —— "
                      "直连失败时必须能永久回退走代理（用户设备开了境外代理工具）")

    # ---- 4) 直连 session ----
    if "connectionProxyDictionary" not in code:
        errors.append("v1.0.85 回归: 缺少 connectionProxyDictionary —— "
                      "ASR 请求仍会走系统代理，多出 2 个跨洋 RTT（约 1.5s 固定开销）")
    if "kCFNetworkProxiesHTTPSEnable" not in code:
        errors.append("v1.0.85 回归: 缺少 kCFNetworkProxiesHTTPSEnable —— "
                      "HTTPS 代理没被禁用，ASR 仍走代理")

    # ---- 5) 字幕框宽度上限 ----
    if not re.search(r"MIN\(\s*hostW\s*-\s*margin\s*\*\s*2\s*,\s*[0-9.]+\s*\)", code):
        errors.append("v1.0.85 回归: 字幕框宽度缺少绝对上限 —— "
                      "全屏横屏时 hostW=852 会让容器宽 840 铺满整屏，"
                      "必须加 MIN(hostW - margin*2, 460) 之类的上限")

    # ---- 6) pcm16 路径不得写死分片 ----
    if re.search(r"_pcm16\.length\s*>=\s*16000\s*\*\s*2\s*\*\s*[0-9]+", code):
        errors.append("v1.0.85 回归: pcm16 路径仍写死分片秒数 —— "
                      "必须改用 asrChunkSeconds 配置（v1.0.84 漏改过这一处）")
    # secs16 必须由实际字节数算出，不能写死常量
    m = re.search(r"double\s+secs16\s*=\s*([^;]+);", code)
    if not m:
        errors.append("v1.0.85 回归: 未找到 secs16 计算 —— "
                      "pcm16 路径的分片判定必须按实际字节数算秒数")
    elif "_pcm16.length" not in m.group(1):
        errors.append("v1.0.85 回归: secs16 被写死为 %s —— "
                      "必须由 _pcm16.length 实际算出秒数" % m.group(1).strip())


def main():
    try:
        src = read_src()
    except Exception as e:
        print("ERROR: 无法读取 %s: %s" % (SRC, e))
        sys.exit(1)

    panel_src = None
    try:
        with io.open(PANEL, "r", encoding="utf-8") as pf:
            panel_src = pf.read()
    except Exception:
        pass

    check_no_io_in_hit_test(src)
    check_macho_bounds_guards(src)
    check_output_capacity(src)
    check_required_features(src)
    check_v81_fixes(src)
    check_v82_fixes(src)
    check_objc_type_hazards(src)
    check_v83_fixes(src, panel_src)

    check_v84_fixes(src, panel_src)
    check_v85_fixes(src, panel_src)
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
    print("  OK: v1.0.82 修复在位（默认只显示中文/英文标签收起/保留上一句/FIFO 队列）")
    print("  OK: v1.0.83 修复在位（showBilingual 语义/统一配置通道/容器尺寸不再冻结/测量扣内边距）")
    print("  OK: v1.0.84 修复在位（分片时长可配置/毫秒RTT打点/提到最上层/跟随新window/位置钳制）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
