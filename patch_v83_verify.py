#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 verify_source_safety.py 追加 v1.0.83 回归拦截检查。

v1.0.83 针对用户实测反馈：「82翻译还是有英文，然后中文没显示全」
  A. 「还有英文」根因：showEnglish 键被面板(CFPreferences写) 与 tweak(文件直写)
     两套机制互相覆写 → 明明写了 false 却变成 true。
     修复：语义反转为 showBilingual（默认 NO=只中文），老键彻底忽略；
           面板与 tweak 统一走「文件直读直写」通道 + CFPreferencesAppSynchronize。
  B. 「中文没显示全」根因：_userMoved 分支只设 _container.center，
     从不更新 frame.size → 容器高度被永久冻结在拖动那一刻的高度(实测58pt)，
     而中文标签被排到 y=71(高36)，底边107 超出容器58，
     被 masksToBounds=YES 直接裁掉。
     修复：_userMoved 时也更新 size，只保留 center。
"""
import io
import os
import re
import sys

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "verify_source_safety.py")
PANEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "PrefBundle", "LiveCapPrefs.m")

CHECK_FUNC = r'''

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
    m = re.search(r"-\s*\(void\)\s*writeConfig\s*:\s*\(", src)
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
'''

ANCHOR = "\ndef main():"


def main():
    with io.open(SCRIPT, "r", encoding="utf-8") as f:
        content = f.read()

    if "def check_v83_fixes" in content:
        print("skip: check_v83_fixes 已存在")
    else:
        if ANCHOR not in content:
            print("ERROR: 找不到 main() 锚点")
            return 1
        content = content.replace(ANCHOR, CHECK_FUNC + ANCHOR, 1)

        # 注册调用
        content = content.replace(
            "    check_objc_type_hazards(src)",
            "    check_objc_type_hazards(src)\n    check_v83_fixes(src, panel_src)", 1)

        # main() 里读取面板源码
        content = content.replace(
            '    check_no_io_in_hit_test(src)',
            '    panel_src = None\n'
            '    try:\n'
            '        with io.open(PANEL, "r", encoding="utf-8") as pf:\n'
            '            panel_src = pf.read()\n'
            '    except Exception:\n'
            '        pass\n\n'
            '    check_no_io_in_hit_test(src)', 1)

        # 输出提示
        content = content.replace(
            '    print("  OK: v1.0.82 修复在位（默认只显示中文/英文标签收起/保留上一句/FIFO 队列）")',
            '    print("  OK: v1.0.82 修复在位（默认只显示中文/英文标签收起/保留上一句/FIFO 队列）")\n'
            '    print("  OK: v1.0.83 修复在位（showBilingual 语义/统一配置通道/容器尺寸不再冻结/测量扣内边距）")',
            1)

        # 需要 io 模块
        if "\nimport io\n" not in content:
            content = content.replace("\nimport re\n", "\nimport io\nimport re\n", 1)

        with io.open(SCRIPT, "w", encoding="utf-8") as f:
            f.write(content)
        print("patched: verify_source_safety.py")

    return 0


if __name__ == "__main__":
    sys.exit(main())
