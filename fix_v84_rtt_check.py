#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正 RTT 检查项：格式串在字符串字面量里，需在原始源码中匹配"""
import io

P = "verify_source_safety.py"

OLD = '''    # ---- 2) 毫秒级 RTT 打点 ----
    if not re.search(r"asr:\\s*rtt=", code):'''

NEW = '''    # ---- 2) 毫秒级 RTT 打点 ----
    # 注意：RTT 打点写在日志格式串里，_strip_comments_strings 会连字符串字面量一起剥掉，
    #       所以这里必须在【原始源码】里找（格式串不会出现在注释里）。
    if not re.search(r"asr:\\s*rtt=", src):'''


def main():
    s = io.open(P, encoding="utf-8").read()
    if OLD not in s:
        print("FAIL: 锚点未找到")
        return 1
    s = s.replace(OLD, NEW, 1)
    io.open(P, "w", encoding="utf-8", newline="\n").write(s)
    print("已修正")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
