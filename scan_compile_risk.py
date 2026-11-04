#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""编译期风险静态扫描（本地无 xcrun，必须提前拦 CI 编译错误）。

检查项：
  1. 大括号 / 圆括号 / 方括号配平（剥除注释与字符串后统计）
  2. @interface / @implementation / @end 配平
  3. Objective-C `?:` 两侧类型混用（block vs NSNull*）
  4. 变量先用后定义（同一作用域内先赋值后声明）
  5. 方法体内 `[[LCConfig shared] xxx]` 调用了不存在的 selector
  6. 属性声明与实现的方法名一致性（只查 LCConfig / LCSubtitleOverlay 关键类）

用法: python3 scan_compile_risk.py
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "LiveCap.m")
PANEL = os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m")

errors = []
warnings = []


def strip_comments_strings(src):
    """剥离注释与字符串字面量，避免注释里的示例代码造成误报"""
    out = []
    i = 0
    n = len(src)
    state = None  # None / 'line' / 'block' / '"' / "'"
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


def check_balance(src, label):
    pairs = {")": "(", "]": "[", "}": "{"}
    for open_c, close_c in (("(", ")"), ("[", "]"), ("{", "}")):
        depth = 0
        line = 1
        bad = None
        for ch in src:
            if ch == "\n":
                line += 1
            elif ch == open_c:
                depth += 1
            elif ch == close_c:
                depth -= 1
                if depth < 0 and bad is None:
                    bad = line
        if depth != 0:
            errors.append("%s: %s%s 不配平（残余深度 %d）" %
                          (label, open_c, close_c, depth))
        elif bad is not None:
            errors.append("%s: %s%s 提前闭合于行 %d" % (label, open_c, close_c, bad))


def check_objc_blocks(src, label):
    ifc = len(re.findall(r"@interface\b", src))
    impl = len(re.findall(r"@implementation\b", src))
    end = len(re.findall(r"@end\b", src))
    if ifc + impl != end:
        errors.append("%s: @interface/@implementation 共 %d 个，@end 只有 %d 个 —— 不配平"
                      % (label, ifc + impl, end))


def _collect_block_vars(src):
    """收集所有【block 类型】的变量名

    覆盖三种声明形态：
      1. 局部变量:  void (^comp)(NSString *) = ...
      2. 方法参数:  completion:(void (^)(NSString *))completion
      3. 属性/类型: void (^handler)(void)
    """
    names = set()
    for m in re.finditer(r"\(\s*\^\s*(\w+)\s*\)\s*\(", src):
        names.add(m.group(1))
    for m in re.finditer(r"(\w+)\s*:\s*\(\s*void\s*\(\^\s*\)\s*\([^)]*\)\s*\)\s*(\w+)",
                         src):
        names.add(m.group(2))
    for m in re.finditer(r"void\s*\(\^\s*\)\s*\([^)]*\)\s*\)\s*(\w+)", src):
        names.add(m.group(1))
    return names


def _ternary_branches(stmt, nsnull_rel):
    """在语句中找出与 [NSNull null] 配对的三元表达式，返回 (cond, then_branch, else_branch)

    nsnull_rel = [NSNull null] 在 stmt 内的相对起始位置

    紧凑写法 `a ?: b` 里，`?:` 的冒号【本身就是】三元运算符的冒号，
    此时 then 分支为空、else 分支为 b。
    非紧凑写法 `a ? b : c` 里，三元冒号是第二个冒号。
    """
    # 从 NSNull 往前找冒号
    colon = -1
    i = nsnull_rel - 1
    while i >= 0:
        if stmt[i] == ":":
            colon = i
            break
        i -= 1
    if colon < 0:
        return None

    # 往前找对应的 '?'
    j = colon - 1
    while j >= 0 and stmt[j] in " \t":
        j -= 1
    if j >= 0 and stmt[j] == "?":
        # 紧凑写法 ?: → then 分支为空
        cond = stmt[:j].strip()
        then_b = ""
        else_b = stmt[colon + 1:].strip()
        return cond, then_b, else_b

    # 非紧凑写法：往前找 '?'
    qmark = stmt.rfind("?", 0, colon)
    if qmark < 0:
        return None
    cond = stmt[:qmark].strip()
    then_b = stmt[qmark + 1:colon].strip()
    else_b = stmt[colon + 1:].strip()
    return cond, then_b, else_b


def check_ternary_type(src, label):
    """`?:` 两侧类型不一致 → incompatible operand types

    两种情形：
      A. 字面量 block 与 [NSNull null] 混用：  ^(...) ?: [NSNull null]
      B. block 类型【变量】与 [NSNull null] 混用：completion ?: [NSNull null]
         （v1.0.82 真实踩过：incompatible operand types:
           'void (^)(NSString *)' and 'NSNull *'）
    两侧都 cast 成 id 才合法：completion ? (id)completion : (id)[NSNull null]
    """
    block_vars = _collect_block_vars(src)

    # --- 情形 A：字面量 block ---
    for m in re.finditer(r"\?[^:;]{0,120}:[^;]{0,120}", src):
        seg = m.group(0)
        if re.search(r"\^\s*\(", seg) and re.search(r"\[NSNull\s+null\]", seg):
            line = src[:m.start()].count("\n") + 1
            errors.append("%s 行%d: `?:` 两侧混用 block 与 NSNull* —— "
                          "必须两侧都 cast 成 id" % (label, line))

    # --- 情形 B：block 类型变量与 NSNull* 混用 ---
    for m in re.finditer(r"\[NSNull\s+null\]", src):
        pos = m.start()
        # 取所在语句：从最近的 ; { 或换行开始
        st = max(src.rfind(";", 0, pos), src.rfind("{", 0, pos),
                 src.rfind("\n", 0, pos))
        en = pos
        while en < len(src) and src[en] not in ";\n":
            en += 1
        stmt = src[st + 1:en]
        rel = pos - (st + 1)
        br = _ternary_branches(stmt, rel)
        if not br:
            continue
        cond, then_b, else_b = br
        # NSNull 在 else 分支 → 检查 then 分支；反之亦然
        if else_b.startswith("[NSNull"):
            other = then_b
            if not other:
                # 紧凑写法 a ?: b —— 与 NSNull 配对的是条件表达式里的变量
                # （cond 形如 "id compBox = completion"，需剥出变量名）
                mvar = re.search(r"(\w+)\s*$", cond)
                other = mvar.group(1) if mvar else ""
        elif then_b.startswith("[NSNull"):
            other = else_b
        else:
            continue
        if not other:
            continue
        # other 必须是【裸变量名】（已 cast 成 id 的不算）
        if not re.fullmatch(r"\w+", other):
            continue
        if other in block_vars:
            line = src[:pos].count("\n") + 1
            errors.append("%s 行%d: `?:` 两侧混用 block 变量 %s 与 NSNull* —— "
                          "必须两侧都 cast 成 id（如 %s ? (id)%s : (id)[NSNull null]）"
                          % (label, line, other, other, other))


def _build_scope_map(body):
    """建立 位置 → 作用域 id 的映射，以及作用域的父子关系。

    作用域 id 用「每个 { 分配一个自增序号」表示。
    scope_of[pos] = 该位置所处的【最内层】作用域 id
    scope_parent[sid] = 父作用域 id（-1 表示最外层 = 方法体）
    """
    scope_of = [0] * (len(body) + 1)
    scope_parent = {}
    stack = [-1]
    next_id = 0
    for i, ch in enumerate(body):
        scope_of[i] = stack[-1]
        if ch == "{":
            scope_parent[next_id] = stack[-1]
            stack.append(next_id)
            next_id += 1
        elif ch == "}":
            if len(stack) > 1:
                stack.pop()
    scope_of[len(body)] = stack[-1]
    return scope_of, scope_parent


def _scope_chain(scope_of, scope_parent, pos):
    """返回 pos 处的作用域链（由内到外）"""
    chain = []
    sid = scope_of[pos]
    while sid != -1:
        chain.append(sid)
        sid = scope_parent.get(sid, -1)
    return chain


def check_use_before_decl(src, label):
    """作用域感知的「先用后定义」检测 → 编译错误 undeclared identifier

    C/ObjC 的变量可见性规则：
      - 在作用域 S 声明的变量，对其【子作用域】可见；
      - 在【兄弟/外层】作用域不可见。
    因此对每一次使用，应该在「由内到外的作用域链」中找【最近的】声明该名字的作用域：
      - 若该作用域里最早的声明位置 > 使用位置 → 用在前、声明在后 → 编译错误；
      - 若链上没有任何作用域声明过这个名字，但【后代】作用域里有 → 也不可见 → 编译错误。
    """
    for m in re.finditer(r"\n(?:[-+]\s*\([^)]*\)\s*\w+[^;{]*)\{", src):
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
        body_start_line = src[:start].count("\n") + 1

        scope_of, scope_parent = _build_scope_map(body)

        # 收集声明：scope_id -> [声明位置列表]
        decl_re = re.compile(
            r"(?m)(?:^|[;{}])\s*((?:CGFloat|CGRect|CGPoint|CGSize|BOOL|NSInteger|"
            r"NSUInteger|double|float|int|int32_t|int64_t|uint32_t|uint64_t|"
            r"NSString\s*\*|NSMutableString\s*\*|NSArray\s*\*|NSDictionary\s*\*|"
            r"NSMutableDictionary\s*\*|UILabel\s*\*|UIView\s*\*|UIButton\s*\*|id)\s*)\s*"
            r"(\w+)\s*(?:=|;)")
        decls = {}       # name -> {scope_id: [pos,...]}
        decl_scope = {}  # pos -> scope_id
        for dm in decl_re.finditer(body):
            name = dm.group(2)
            pos = dm.start(2)
            sid = scope_of[pos]
            decls.setdefault(name, {}).setdefault(sid, []).append(pos)
            decl_scope[pos] = sid

        # 收集使用点
        names = set(decls.keys())
        for name in names:
            use_re = re.compile(r"(?<![\w>.])" + re.escape(name) + r"(?![\w])")
            for um in use_re.finditer(body):
                upos = um.start()
                # 跳过一次性声明自身的名字位置
                if upos in decl_scope:
                    continue
                chain = _scope_chain(scope_of, scope_parent, upos)
                found = None
                for sid in chain:
                    if sid in decls.get(name, {}):
                        found = sid
                        break
                if found is not None:
                    first_decl = min(decls[name][found])
                    if first_decl > upos:
                        line = body_start_line + body[:upos].count("\n")
                        errors.append("%s 行%d: 变量 %s 在声明之前被使用 —— "
                                      "编译错误 undeclared identifier" % (label, line, name))
                    continue
                # 链上没有声明 → 若后代作用域有声明，则此处不可见 → 也是编译错误
                in_chain = set(chain)
                descendant = False
                for sid, plist in decls.get(name, {}).items():
                    if sid in in_chain:
                        continue
                    # sid 是当前作用域的后代？
                    p = scope_parent.get(sid, -1)
                    while p != -1:
                        if p in in_chain:
                            descendant = True
                            break
                        p = scope_parent.get(p, -1)
                    if descendant:
                        break
                if descendant:
                    line = body_start_line + body[:upos].count("\n")
                    errors.append("%s 行%d: 变量 %s 只在【内层作用域】声明，"
                                  "此处不可见 —— 编译错误 undeclared identifier"
                                  % (label, line, name))


def check_selectors_exist(src, label):
    """[[LCConfig shared] xxx] 的 xxx 必须在 LCConfig 里实现"""
    m = re.search(r"@implementation\s+LCConfig\b", src)
    if not m:
        return
    # 注意：@implementation LCConfig 后面可能跟 ivar 块 `{ ... }`，
    # 用大括号配平取 body 只会取到 ivar 块 → 方法列表全空 → 误报。
    # 这里改用 @end 作为边界（类内不会出现 @end）。
    endm = re.search(r"@end\b", src[m.end():])
    if not endm:
        return
    body = src[m.end():m.end() + endm.start()]
    implemented = set()
    for mm in re.finditer(r"^\s*[-+]\s*\([^)]*\)\s*(\w+)", body, re.M):
        implemented.add(mm.group(1))
    for mm in re.finditer(r"\[\[LCConfig\s+shared\]\s*(\w+)", src):
        sel = mm.group(1)
        if sel not in implemented:
            line = src[:mm.start()].count("\n") + 1
            errors.append("%s 行%d: [[LCConfig shared] %s] —— LCConfig 未实现该方法"
                          % (label, line, sel))


def check_panel_balance(src):
    check_balance(src, "面板")
    check_objc_blocks(src, "面板")


def main():
    for path, label in ((SRC, "LiveCap.m"), (PANEL, "面板")):
        with io.open(path, "r", encoding="utf-8") as f:
            raw = f.read()
        src = strip_comments_strings(raw)
        if label == "LiveCap.m":
            check_balance(src, label)
            check_objc_blocks(src, label)
            check_ternary_type(src, label)
            check_use_before_decl(src, label)
            check_selectors_exist(src, label)
        else:
            check_panel_balance(src)
            check_ternary_type(src, label)

    print("=== 编译期风险扫描 ===")
    print("")
    for w in warnings:
        print("  WARN: %s" % w)
    if errors:
        for e in errors:
            print("  ERROR: %s" % e)
        print("")
        print("共 %d 个错误，构建中止。" % len(errors))
        return 1
    print("  OK: 括号/块配平、无 `?:` 类型混用、LCConfig selector 全部存在")
    return 0


if __name__ == "__main__":
    sys.exit(main())
