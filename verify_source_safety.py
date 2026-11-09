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
        # v1.0.87：面板改用 LCGetBool(@"showBilingual", ...) 读取（类型安全版），
        # 旧的 LCGet(@"showBilingual") 形式同样接受。
        if ('LCGet(@"showBilingual")' not in panel_src and
                'LCGetBool(@"showBilingual"' not in panel_src):
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
    # v1.0.87：函数名从 LCAACEncode16kMono 改为 LCAACEncodeADTSFramed
    #（v1.0.85 编的是裸 AAC，腾讯云拒收 → 压缩白做 → 延迟反弹）
    aac_calls = len(re.findall(r"LCAACEncodeADTSFramed\s*\(", code))
    if aac_calls < 3:   # 1 处定义 + 2 处调用
        errors.append("v1.0.85 回归: LCAACEncodeADTSFramed 调用只有 %d 处（需 ≥2 处调用）—— "
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

    # ---- 3) 回退机制（v1.0.87 改为可恢复，不再永久拉黑）----
    # v1.0.85 原本要求 _aacBroken / _directFailed 两个「永久禁用」标记。
    # v1.0.87 查明这两个标记正是延迟反弹的放大器：
    #   · AAC 被拒一次 → 永久退回 82KB WAV（压缩白做）
    #   · 直连失败一次 → 永久走慢代理（网络恢复也回不去）
    # 现在要求「计数 + 冷却」的可恢复机制存在。
    for token, why in (
            ("markAacFailure", "AAC 被拒后必须能记账并冷却，而不是永久禁用"),
            ("markAacSuccess", "AAC 成功后必须清零失败计数"),
            ("aacUsable", "必须能判断当前是否允许使用 AAC（冷却期判断）"),
            ("markDirectFailure", "直连失败后必须能进入代理冷却，而不是永久回退"),
            ("currentSession", "必须按冷却状态动态选择直连/代理 session")):
        # 用词边界 \b：否则 markAacFailureUnused 这类改名能骗过子串检查
        if not re.search(r"\b%s\b" % token, code):
            errors.append("v1.0.87 回归: 缺少 %s —— %s" % (token, why))

    # ---- 4) 直连 session ----
    if "connectionProxyDictionary" not in code:
        errors.append("v1.0.85 回归: 缺少 connectionProxyDictionary —— "
                      "ASR 请求仍会走系统代理，多出 2 个跨洋 RTT（约 1.5s 固定开销）")
    # v1.0.86 修正：kCFNetworkProxiesHTTPSEnable / kCFNetworkProxiesSOCKSEnable
    # 在 iOS SDK 里标记为 "unavailable: not available on iOS"，用了会编译失败。
    # iOS 上唯一可用的代理开关是 kCFNetworkProxiesHTTPEnable。
    if "kCFNetworkProxiesHTTPEnable" not in code:
        errors.append("v1.0.85 回归: 缺少 kCFNetworkProxiesHTTPEnable —— "
                      "HTTP 代理没被禁用，ASR 仍走代理")
    # 禁用 HTTPS/SOCKS 代理改用字面量 key（"HTTPSEnable" / "SOCKSEnable"），
    # 运行时效果等价于 CF 常量，但不受 iOS 可用性标注限制。
    # 注意：必须在【原始源码 src】里匹配 —— _strip_comments_strings 会把
    # 字符串字面量一起剥掉，在 code 里查永远查不到（会误报）。
    for lit in ('"HTTPSEnable"', '"SOCKSEnable"'):
        if lit not in src:
            errors.append("v1.0.85 回归: 缺少代理开关字面量 %s —— "
                          "iOS 上 kCFNetworkProxiesHTTPSEnable 不可用，"
                          "必须用字面量 key 关闭 HTTPS/SOCKS 代理" % lit)

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


def check_v86_fixes(src, panel_src=None):
    """v1.0.86：防止 mediaserverd 注入复发 + 防 C++ 语法残留。

    背景（真实事故）：
    LiveCap.plist 的 Filter 里带 <key>Executables</key><string>mediaserverd</string>，
    把 tweak 注入进了 iOS 系统媒体服务守护进程 → mediaserverd 崩溃循环
    （launchctl 状态 -11 = SIGSEGV）→ 微信语音 / 通话全部无声。
    这个坑 v1.0.30 修过一次（commit 7431db0），v1.0.74 改 plist 时又加了回来
    （commit ba3ac6d）→ 复发。
    所以必须在 CI 里硬性拦截，不能靠人记得。
    """
    # ---- 1) plist 里不得出现 mediaserverd ----
    plist_path = os.path.join(os.path.dirname(SRC), "LiveCap.plist")
    try:
        with io.open(plist_path, "r", encoding="utf-8") as pf:
            plist_txt = pf.read()
    except Exception as e:
        errors.append("v1.0.86 回归: 读不到 LiveCap.plist: %s" % e)
        plist_txt = None

    if plist_txt is not None:
        # plist 里【不能有 XML 注释】（ElleKit 用 CFPropertyList 解析，
        # 遇到 <!-- --> 整个 Filter 解析失败 → tweak 静默不注入）。
        # 所以这里不剥离注释，直接全文查。
        if "<!--" in plist_txt:
            errors.append(
                "v1.0.86 回归: LiveCap.plist 含 XML 注释 —— "
                "ElleKit 解析 Filter 会失败，tweak 静默不注入且无任何日志。")
        if "mediaserverd" in plist_txt:
            errors.append(
                "v1.0.86 回归: LiveCap.plist 里出现了 mediaserverd —— "
                "注入系统媒体服务会导致 mediaserverd 崩溃（-11），"
                "微信语音/通话会无声。v1.0.30 修过一次，v1.0.74 又挖回来了。")
        # Executables 节点整体都不该有（mediaserverd 之外也一样危险）
        if "<key>Executables</key>" in plist_txt:
            errors.append(
                "v1.0.86 回归: LiveCap.plist 出现了 Executables 过滤节点 —— "
                "只允许用 Bundles 白名单限定目标 App。")

    # ---- 2) postinst 不得再杀 mediaserverd ----
    postinst_path = os.path.join(os.path.dirname(SRC), "postinst")
    try:
        with io.open(postinst_path, "r", encoding="utf-8") as pf:
            post_txt = pf.read()
    except Exception:
        post_txt = None

    if post_txt is not None:
        post_code = re.sub(r"^\s*#.*$", "", post_txt, flags=re.MULTILINE)
        if re.search(r"killall[^\n]*mediaserverd", post_code):
            errors.append(
                "v1.0.86 回归: postinst 里还在 killall mediaserverd —— "
                "杀系统音频服务会中断所有 App 的音频会话（微信语音瞬断）。")

    # ---- 3) Objective-C 不支持 C++ 引用声明 ----
    # AudioBuffer &b = ... 是 C++ 语法，CI 会报
    # "expected identifier or '('" + "use of undeclared identifier 'b'"。
    code = _strip_comments_strings(src)
    cpp_ref = re.findall(r"(?<![\w&])[A-Za-z_][A-Za-z0-9_]*\s*&\s*[a-zA-Z_]\w*\s*=", code)
    if cpp_ref:
        errors.append(
            "v1.0.86 回归: 检测到 C++ 引用声明 %s —— "
            "Objective-C 不支持，必须改成指针（const AudioBuffer *b = ...）。"
            % cpp_ref[:3])

    # ---- 4) 已删除/不存在的常量不得复活 ----
    dead_symbols = [
        "kAudioFormatFlagIsEncoded",
        "kAudioConverterEncodeQuality",
        "AudioConverterInputStatus",
        "kCFNetworkProxiesHTTPSEnable",
        "kCFNetworkProxiesSOCKSEnable",
    ]
    # 在原始源码里找（字符串/注释剥离会把符号删掉，但这里要连注释一起检查，
    # 因为注释里提到的名字说明作者还想着这个 API，容易顺手写回去）
    for sym in dead_symbols:
        # 允许出现在【注释】里作为「不要用」的说明，但不允许出现在代码里
        for line in src.splitlines():
            code_only = line.split("//", 1)[0]
            if sym in code_only:
                errors.append(
                    "v1.0.86 回归: 代码中使用了不存在的符号 %s —— "
                    "该常量在 iOS SDK 里不存在，CI 会编译失败。" % sym)
                break

    # ---- 5) AudioConverter 回调签名必须与 SDK 一致 ----
    # SDK 权威原型（AudioConverter.h）：
    #   typedef OSStatus (*AudioConverterComplexInputDataProc)(
    #       AudioConverterRef               inAudioConverter,
    #       UInt32 *                        ioNumberDataPackets,
    #       AudioBufferList *               ioData,
    #       AudioStreamPacketDescription ** outDataPacketDescription,
    #       void *                          inUserData);
    # 必须【5 个参数】。写成 3 参数版本会连续两轮 CI 报
    # "incompatible function pointer types"。
    if "LCAACInputProc" in code:
        m = re.search(r"static\s+OSStatus\s+LCAACInputProc\s*\(([^)]*)\)",
                      code, re.DOTALL)
        if not m:
            errors.append(
                "v1.0.86 回归: LCAACInputProc 签名不匹配 —— "
                "必须是 OSStatus (*)(AudioConverterRef, UInt32*, "
                "AudioBufferList*, AudioStreamPacketDescription**, void*)。")
        else:
            params = m.group(1)
            nparams = params.count(",") + 1
            if nparams != 5:
                errors.append(
                    "v1.0.86 回归: LCAACInputProc 有 %d 个参数（应为 5）—— "
                    "SDK 的 AudioConverterComplexInputDataProc 是 5 参数，"
                    "少写会报 incompatible function pointer types。" % nparams)
            for need in ("AudioBufferList *", "AudioStreamPacketDescription **"):
                if need.replace(" ", "") not in params.replace(" ", ""):
                    errors.append(
                        "v1.0.86 回归: LCAACInputProc 缺少参数类型 %s —— "
                        "必须与 AudioConverterComplexInputDataProc 严格一致。" % need)

    # ---- 5b) 输出必须是 AudioBufferList*，不能是输出回调 ----
    # AudioConverterFillComplexBuffer 的【输出不是回调】，
    # 而是调用者提供的 AudioBufferList*。用输出回调会编译失败。
    if "AudioConverterFillComplexBuffer" in code:
        for m in re.finditer(
                r"AudioConverterFillComplexBuffer\s*\(([^;]*?)\);",
                code, re.DOTALL):
            args = m.group(1)
            if "outList" not in args and "outABL" not in args:
                errors.append(
                    "v1.0.86 回归: AudioConverterFillComplexBuffer 的输出参数"
                    "不是 AudioBufferList 缓冲区 —— "
                    "该 API 的输出是调用者提供的缓冲区（outList），"
                    "不是输出回调，传回调会编译失败。")


def _method_body(src, sig_pattern):
    """按签名正则提取方法体文本。

    只认以 { 开头的【实现】，自动跳过 @interface 里以 ; 结尾的声明行。
    返回 None 表示没找到该方法。
    """
    m = re.search(sig_pattern + r"\s*\{", src)
    if not m:
        return None
    start = m.end() - 1
    depth = 0
    for i in range(start, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i]
    return None


def check_v87_fixes(src, panel_src=None):
    """v1.0.87：ADTS 封装 + 可恢复失败 + 分片不丢音 + 字号 UI 可调。

    用户反馈：「好像还是有延迟，然后字体要在UI里面可以设置大小」

    延迟根因链（全部有设备日志/真实接口实测支撑）：
      v1.0.85 编出【裸 AAC】（无 ADTS 头）
        → 腾讯云拒收 ErrorInvalidVoicedata
        → _aacBroken 永久置位，全程退回 82KB WAV
        → 手机上行约 25KB/s，光上传就 3.2s
        → ASR RTT 中位 4875ms、21% 触发 10s 硬超时
        → 用户感知「还是慢」

    本次拦截点（全部为【反向断言】：发现旧写法即失败）：
      1. 不得再出现裸 AAC 编码器 LCAACEncode16kMono
      2. 必须有 ADTS 头（0xFF 0xF1 syncword + frame_length 计算）
      3. 不得再出现「一次失败即永久禁用」的 _aacBroken / _directFailed
      4. 并发槽位满时不得整段丢弃音频（setLength:0）
      5. 字号必须实时读盘（面板改完立即生效）
      6. 面板必须有真正的字号 UI（滑块），且不得再用强转 NSNumber 读值
    """
    code = _strip_comments_strings(src)

    # ---- 1) 裸 AAC 编码器不得复活 ----
    if re.search(r"LCAACEncode16kMono", src):
        errors.append(
            "v1.0.87 回归: 源码里又出现了 LCAACEncode16kMono（裸 AAC）—— "
            "腾讯云拒收无 ADTS 头的 AAC（ErrorInvalidVoicedata），"
            "压缩会完全失效并退回 82KB WAV，延迟反弹。必须用 LCAACEncodeADTSFramed。")

    # ---- 2) ADTS 头必须真的写进字节流 ----
    if "LCAACEncodeADTSFramed" not in code:
        errors.append(
            "v1.0.87 回归: 缺少 LCAACEncodeADTSFramed —— "
            "必须逐帧加 7 字节 ADTS 头，否则腾讯云拒收。")
    else:
        # ADTS syncword：0xFF 0xF1（MPEG-4, 无 CRC）
        if not re.search(r"0xFF\s*,\s*0xF1", src):
            errors.append(
                "v1.0.87 回归: ADTS 头缺少 syncword 0xFF 0xF1 —— "
                "腾讯云按 ADTS 解析，无 syncword 直接判定为非法音频。")
        # frame_length 必须按「7 + payload」算
        if not re.search(r"frameLen\s*=\s*7\s*\+\s*produced", code):
            errors.append(
                "v1.0.87 回归: ADTS 头没有按 frame_length = 7 + payload 计算 —— "
                "长度算错会导致解码器读错帧边界。")
        # 采样率索引 8 = 16kHz
        if not re.search(r"\(8\s*&\s*0x0F\)", code):
            errors.append(
                "v1.0.87 回归: ADTS 头缺少 sampling_frequency_index = 8（16kHz）—— "
                "与实际编码采样率不一致会让解码器错位。")

    # ---- 3) 一次性永久禁用不得复活 ----
    for dead in ("_aacBroken", "_directFailed"):
        # 只在【代码】里查（注释里作为历史说明可以出现）
        if re.search(r"\b%s\b" % dead, code):
            errors.append(
                "v1.0.87 回归: 代码里又出现了 %s —— "
                "「一次失败即永久禁用」正是延迟反弹的放大器："
                "AAC 被拒一次就永久退回 WAV，直连失败一次就永久走慢代理。"
                "必须改成「连续失败计数 + 冷却窗口」。" % dead)

    # ---- 4) 并发槽位满时不得整段丢音频 ----
    for fn in ("trimPCMKeepingSeconds", "trimPCM16KeepingSeconds"):
        # 至少要有【定义 + 1 处调用】；两条音频入口都要改
        # 注意：ObjC 方法名后面跟的是 : 而不是 (，所以不能用 \bNAME\s*\( 来数
        n = len(re.findall(r"\b%s\b" % fn, code))
        if n < 2:
            errors.append(
                "v1.0.87 回归: %s 只有 %d 处（需 ≥2：定义 + 调用）—— "
                "并发槽位满时必须【裁掉最旧的音频、保留最新的一段】，"
                "整段清空会让分片越来越长（实测出现 4.41s 长尾）。" % (fn, n))
    # 旧写法：并发分支里直接 setLength:0
    for m in re.finditer(r"else\s+if\s*\([^)]*\)\s*\{\s*\[_pcm(?:16)?\s+setLength:\s*0\]",
                         code, re.DOTALL):
        errors.append(
            "v1.0.87 回归: 并发分支里出现整段清空音频 —— "
            "必须改为裁剪保留最新音频，否则分片越滚越长、延迟持续恶化。")

    # ---- 5) 字号必须实时读盘 + 面板改完立刻重绘 ----
    body = _method_body(src, r"-\s*\(id\)\s*freshValueForKey\s*:\s*\(\s*NSString\s*\*\s*\)\s*key")
    if body is None:
        errors.append(
            "v1.0.87 回归: 缺少 freshValueForKey（实时读盘）—— "
            "字号读的是启动时缓存的 _d，面板改完必须重启 App 才生效。")
    elif "dictionaryWithContentsOfFile" not in body:
        errors.append(
            "v1.0.87 回归: freshValueForKey 没有真的读文件 —— "
            "字号必须每次从 plist 现读，否则改了不生效。")

    body = _method_body(src, r"-\s*\(void\)\s*startConfigWatcher")
    if body is None:
        errors.append(
            "v1.0.87 回归: 缺少配置监听 startConfigWatcher —— "
            "改完字号后若没有新句子就没有重绘时机，字幕大小不会当场变化。")
    elif "dispatch_source_set_timer" not in body:
        errors.append(
            "v1.0.87 回归: startConfigWatcher 没有起定时器 —— "
            "字号变化无法被感知。")

    body = _method_body(src, r"-\s*\(void\)\s*checkConfigChange")
    if body is None:
        errors.append(
            "v1.0.87 回归: 缺少 checkConfigChange —— "
            "字号变化后必须触发重排重绘。")
    elif "renderCurrent" not in body:
        errors.append(
            "v1.0.87 回归: checkConfigChange 没有调用 renderCurrent —— "
            "字号变了但画面不重绘，等于没生效。")

    # ---- 7) C 函数不得在定义之前被调用（v1.0.87 首次 CI 失败就是这个）----
    # CI 实证：
    #   LiveCap.m:274: error: call to undeclared function 'LCLogF'
    #   LiveCap.m:377: error: static declaration of 'LCLogF' follows non-static declaration
    # 根因：新的 AAC 编码器（位于文件靠前）里调了 LCLogF，
    #       而 LCLogF 的定义在文件更靠后 —— C 语言没有前向查找。
    m_def = re.search(r"static\s+void\s+LCLogF\s*\(", code)
    m_use = re.search(r"\bLCLogF\s*\(", code)
    if m_def and m_use and m_use.start() < m_def.start():
        errors.append(
            "v1.0.87 回归: LCLogF 在其定义之前就被调用 —— "
            "CI 会报 call to undeclared function 'LCLogF'。"
            "要么把调用挪到定义之后，要么在文件靠前加前向声明。")

    # ---- 8) 面板必须提供真正的字号 UI ----
    if panel_src is None:
        warnings.append("v1.0.87: 未读取面板源码，跳过字号 UI 检查")
    else:
        if "UISlider" not in panel_src:
            errors.append(
                "v1.0.87 回归: 面板没有字号滑块 —— "
                "用户要求「字体要在 UI 里面可以设置大小」，"
                "数字键盘输入框不算合格的 UI。")
        elif not re.search(r"addTarget\s*:\s*self[\s\S]{0,120}?@selector\(lc_sliderChanged:\)",
                           panel_src):
            errors.append(
                "v1.0.87 回归: 字号滑块没有绑定 lc_sliderChanged: 回调 —— "
                "拖动滑块必须能实时写入 fontSize 配置。")
        if "LCFontSizeController" not in panel_src:
            errors.append(
                "v1.0.87 回归: 面板缺少 LCFontSizeController（字号选择页）—— "
                "字号必须是一个可视化的调节界面。")
        else:
            # 类的完整 @interface 必须出现在【使用点之前】。
            # CI 实证（v1.0.87 第二次构建失败）：
            #   error: receiver 'LCFontSizeController' for class message is a forward declaration
            # 原因：只有 @class 前向声明时不能发 alloc/init 这类【类消息】。
            m_if = panel_src.find("@interface LCFontSizeController")
            m_use = panel_src.find("[[LCFontSizeController alloc]")
            if m_use >= 0 and (m_if < 0 or m_use < m_if):
                errors.append(
                    "v1.0.87 回归: LCFontSizeController 只有前向声明却被 alloc —— "
                    "CI 会报 'receiver for class message is a forward declaration'。"
                    "必须把完整的 @interface/@implementation 放在使用点之前。")
        # 旧写法：把可能是 NSString 的值强转成 NSNumber
        # （必须先剥掉 // 注释，否则注释里举的反例会误判）
        panel_code = re.sub(r"//[^\n]*", "", panel_src)
        if re.search(r"\[\s*\(NSNumber\s*\*\)\s*LCGet\(", panel_code):
            errors.append(
                "v1.0.87 回归: 面板仍在用 [(NSNumber *)LCGet(...)] 强转读配置 —— "
                "postinst 写入的是 <string>16</string>，强转后取值行为未定义，"
                "必须改用 LCGetNum / LCGetBool（兼容 NSNumber 与 NSString）。")
        # 面板默认值必须与 tweak 一致（16，不是 28）
        if re.search(r"fontSize\"?\s*,\s*28", panel_src):
            errors.append(
                "v1.0.87 回归: 面板字号默认值仍是 28 —— "
                "tweak 侧默认是 16，两边对不上会让用户以为「改了没生效」。")
        if 'LCSet(@((NSInteger)v), @"fontSize")' not in panel_src:
            errors.append(
                "v1.0.87 回归: 面板字号滑块没有写回 fontSize 键 —— "
                "拖动必须真正写入配置才能生效。")


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
    check_v86_fixes(src, panel_src)
    check_v87_fixes(src, panel_src)
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
    print("  OK: v1.0.87 修复在位（ADTS 封装/失败可恢复/分片不丢音/字号滑块+实时生效）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
