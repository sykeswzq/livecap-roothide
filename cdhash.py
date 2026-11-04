#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""计算 Mach-O 的 cdhash，用于核对越狱 trustcache 是否包含该 dylib。

cdhash 的定义（Apple 官方）：
    cdhash = SHA256( 整个 CodeDirectory blob ) 的前 20 字节

要点：
  - 不是 code slot 的摘要，也不是整个文件的摘要
  - CodeDirectory 里 hashSize/hashType/platform/pageSize 是 4 个 uint8_t
    （off36/37/38/39）
  - SuperBlob 的 slot type 0 才是 CSSLOT_CODEDIRECTORY

用法: python3 cdhash.py <macho路径>
"""
import hashlib
import struct
import sys

CD_MAGIC = struct.pack(">I", 0xfade0c02)
SB_MAGIC = struct.pack(">I", 0xfade0cc0)
CSSLOT_CODEDIRECTORY = 0


def find_code_directories(data):
    """返回 [(cd_offset, cd_length), ...]"""
    out = []
    pos = 0
    while True:
        idx = data.find(CD_MAGIC, pos)
        if idx < 0:
            break
        pos = idx + 4
        sb = data.rfind(SB_MAGIC, max(0, idx - 0x10000), idx)
        if sb < 0:
            continue
        try:
            _m, _l, count = struct.unpack(">III", data[sb:sb + 12])
        except struct.error:
            continue
        if count > 32:
            continue
        for i in range(count):
            off = sb + 12 + i * 8
            if off + 8 > len(data):
                break
            ctype, cmoff = struct.unpack(">II", data[off:off + 8])
            if ctype != CSSLOT_CODEDIRECTORY:
                continue
            cd_abs = sb + cmoff
            if cd_abs != idx:
                continue
            cd_len = struct.unpack(">I", data[cd_abs + 4:cd_abs + 8])[0]
            if 44 <= cd_len <= len(data) - cd_abs:
                out.append((cd_abs, cd_len))
    return out


def calc_cdhash(data):
    res = []
    for off, length in find_code_directories(data):
        blob = data[off:off + length]
        cdhash = hashlib.sha256(blob).digest()[:20]
        res.append((off, length, cdhash.hex().upper()))
    return res


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    data = open(sys.argv[1], "rb").read()
    res = calc_cdhash(data)
    if not res:
        print("未找到 CodeDirectory（可能未签名）")
        return 3
    for off, length, cdhash in res:
        print("CodeDirectory @%d len=%d" % (off, length))
        print("cdhash: %s" % cdhash)
    return 0


if __name__ == "__main__":
    sys.exit(main())
