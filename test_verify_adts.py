#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_adts.py 的双向变异测试：证明它【真的能拦住 ADTS 头的回归】。

背景：
  「检查脚本看起来在跑」不等于「真能拦住」。v1.0.86 的 mediaserverd 事故就是这么来的。
  verify_adts.py 从 LiveCap.m 真源码里提取 ADTS 头的位运算并求值，
  再和 FFmpeg 官方 muxer 的输出逐字节对拍。
  这里把每一处关键位运算分别改坏，验证脚本会准确报出不一致。

同时收录一组【等价变异】：它们在数值上与原式完全等价，
脚本【不应该】报错 —— 这类用例反过来锁住「脚本不是瞎报」。

用法: py -3.11 test_verify_adts.py
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "LiveCap.m")
BAK = os.path.join(HERE, "_bk", "LiveCap.m.adts_mutbak")
VERIFIER = os.path.join(HERE, "verify_adts.py")

# (说明, 旧文本, 新文本, 是否应当被抓到)
MUST_CATCH = [
    ("采样率索引 8->9（变 22050Hz）",
     "((8 & 0x0F) << 2)", "((9 & 0x0F) << 2)", True),
    ("profile 1->2（AAC-LC -> AAC-MAIN）",
     "((1 & 0x03) << 6) | ((8 & 0x0F) << 2)", "((2 & 0x03) << 6) | ((8 & 0x0F) << 2)", True),
    ("声道位 bit0 1->0",
     "hdr[3] = (uint8_t)(((1 & 0x03) << 6)", "hdr[3] = (uint8_t)(((0 & 0x03) << 6)", True),
    ("帧长基数 7->6（少算 1 字节 ADTS 头）",
     "uint32_t frameLen = 7 + produced;", "uint32_t frameLen = 6 + produced;", True),
    ("帧长基数 7->8（多算 1 字节 ADTS 头）",
     "uint32_t frameLen = 7 + produced;", "uint32_t frameLen = 8 + produced;", True),
    ("帧长用错变量（恒为 0）",
     "uint32_t frameLen = 7 + produced;", "uint32_t frameLen = 7 + 0;", True),
    ("buffer_fullness 0x1F->0x00",
     "| 0x1F);", "| 0x00);", True),
    ("syncword 低半字节 0xF1->0xF9（变 MPEG-2 ID）",
     "0xFF, 0xF1, 0x60", "0xFF, 0xF9, 0x60", True),
    ("syncword 高字节 0xFF->0xFE",
     "0xFF, 0xF1, 0x60", "0xFE, 0xF1, 0x60", True),
    ("hdr[5] 帧长掩码 0x07->0x06（丢最低位）",
     "(frameLen & 0x07) << 5", "(frameLen & 0x06) << 5", True),
    ("hdr[4] 掩码 0xFF->0xFE",
     "hdr[4] = (uint8_t)((frameLen >> 3) & 0xFF)",
     "hdr[4] = (uint8_t)((frameLen >> 3) & 0xFE)", True),
]

# 等价变异：数值上与原式一致，脚本【不应】报错
EQUIVALENT = [
    ("私有位 (1>>2)&0x01 恒为 0，改成显式 0",
     "((1 >> 2) & 0x01)", "((0 >> 2) & 0x01)"),
    ("hdr[5] 掩码 0x07->0x0F（bit3 落在 uint8_t 溢出位且被 0x1F 覆盖）",
     "(frameLen & 0x07) << 5", "(frameLen & 0x0F) << 5"),
]


def run_verifier():
    p = subprocess.run([sys.executable, VERIFIER], capture_output=True,
                       cwd=HERE)
    out = p.stdout.decode("utf-8", "replace")
    return p.returncode, out


def apply_mut(text, old, new):
    if old not in text:
        return None
    return text.replace(old, new, 1)


def main():
    if not os.path.exists(SRC):
        print("❌ 找不到 LiveCap.m")
        return 1
    orig = open(SRC, "rb").read().decode("utf-8")
    os.makedirs(os.path.dirname(BAK), exist_ok=True)
    shutil.copyfile(SRC, BAK)

    failed = []
    try:
        # 基线：未改动时必须全绿
        rc, out = run_verifier()
        if rc != 0:
            print("❌ 基线就是红的，脚本本身有问题")
            print(out[-1500:])
            return 1
        print("✅ 基线全绿")

        print("\n--- 必须抓到的变异 ---")
        for name, old, new, _ in MUST_CATCH:
            t = apply_mut(orig, old, new)
            if t is None:
                print("  ❌ %s —— 锚点没命中（源码结构变了？）" % name)
                failed.append(name)
                continue
            open(SRC, "wb").write(t.encode("utf-8"))
            rc, out = run_verifier()
            if rc != 0:
                d = next((l.strip() for l in out.splitlines() if "❌" in l), "")
                print("  ✅ %s" % name)
                if d:
                    print("       %s" % d)
            else:
                print("  ❌ %s —— 漏检了！" % name)
                failed.append(name)
            open(SRC, "wb").write(orig.encode("utf-8"))

        print("\n--- 等价变异（不应报错）---")
        for name, old, new in EQUIVALENT:
            t = apply_mut(orig, old, new)
            if t is None:
                print("  ❌ %s —— 锚点没命中" % name)
                failed.append(name)
                continue
            open(SRC, "wb").write(t.encode("utf-8"))
            rc, out = run_verifier()
            if rc == 0:
                print("  ✅ %s（确认等价，脚本未误报）" % name)
            else:
                print("  ❌ %s —— 等价变异被误报！" % name)
                failed.append(name)
            open(SRC, "wb").write(orig.encode("utf-8"))
    finally:
        shutil.copyfile(BAK, SRC)
        if os.path.exists(BAK):
            os.remove(BAK)

    # 还原后再跑一次，确认回到全绿
    rc, out = run_verifier()
    if rc != 0:
        print("\n❌ 还原后仍然红，源码被污染了！")
        print(out[-1200:])
        failed.append("还原后仍然失败")

    print("\n" + "=" * 68)
    if failed:
        print("❌ 失败 %d 项：%s" % (len(failed), failed))
        return 1
    print("✅ ADTS 双向变异测试全部通过（%d 个必抓 + %d 个等价）"
          % (len(MUST_CATCH), len(EQUIVALENT)))
    print("=" * 68)
    return 0


if __name__ == "__main__":
    sys.exit(main())
