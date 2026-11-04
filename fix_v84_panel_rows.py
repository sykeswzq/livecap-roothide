#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正面板行数：新增「识别分片」行后 section 2 需 5→6 行，且索引要错开

问题：补丁把「识别分片」插在 row==4，而 row==4 原本是「显示英文原文」。
      若行数仍是 5，两者冲突 → 「识别分片」永远不显示。
修法：
  - numberOfRowsInSection: section 2 由 5 改为 6
  - 「显示英文原文」改到 row==5（else 分支）
  - 「识别分片」放 row==4
"""
import io

P = "PrefBundle/LiveCapPrefs.m"


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def main():
    src = read(P)
    orig = src

    # 1) 行数 5 → 6
    old_rows = "    if (section == 2) return 5;  // 字号 / 粗体 / 文字颜色 / 背景样式 / 显示英文原文"
    new_rows = ("    if (section == 2) return 6;  // 字号 / 粗体 / 文字颜色 / 背景样式 / "
                "识别分片 / 显示英文原文")
    if old_rows not in src:
        print("  [FAIL] 行数锚点未找到")
        return 1
    src = src.replace(old_rows, new_rows, 1)
    print("  [OK] 行数 5 -> 6")

    # 2) 「显示英文原文」的 else 分支必须改成 row==5 之外的判断
    #    现在结构是：row0/1/2/3 各自处理，row4 = 识别分片，else = 显示英文原文
    #    → 需要把 else 改成显式 row==5
    old_else = """        } else {
            // v1.0.82：默认只显示中文一行；打开后恢复「英文原文 + 中文翻译」两行
            cell.textLabel.text = @"显示英文原文";"""
    new_else = """        } else {
            // row == 5：显示英文原文
            // v1.0.82：默认只显示中文一行；打开后恢复「英文原文 + 中文翻译」两行
            cell.textLabel.text = @"显示英文原文";"""
    if old_else not in src:
        print("  [FAIL] else 分支锚点未找到")
        return 1
    src = src.replace(old_else, new_else, 1)
    print("  [OK] 「显示英文原文」标注 row==5")

    if src == orig:
        print("无改动")
        return 1
    write(P, src)
    print("\n已修正面板行数")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
