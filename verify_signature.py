#!/usr/bin/env python3
"""verify_signature.py - 校验 Mach-O 的 ad-hoc 代码签名是否真实有效

为什么需要它：
  codesign -v 只在 macOS 上有，且对 ldid 生成的 ad-hoc 签名行为不完全可靠。
  真正的判据是：CodeDirectory 里记录的每页 SHA-256 哈希，是否等于
  文件对应页内容的 SHA-256。只要签名后任何字节被改动（哪怕改的是
  Mach-O header 里的 LC_ID_DYLIB offset），哈希就对不上 →
  设备端内核会拒绝加载，报 "code signature invalid (errno=85)"。

用法: python3 verify_signature.py <macho> [more.macho ...]
退出码 0 = 全部有效；1 = 有文件签名无效或结构异常
"""
import hashlib
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF  # little-endian read of 0xCFFAEDFE
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D


def sha256(data):
    return hashlib.sha256(data).digest()


def parse_macho(data):
    """解析（可能 fat 的）Mach-O，返回各 slice 的 (offset, size) 列表

    fat_arch     (20 字节): cputype(4) cpusubtype(4) offset(4) size(4) align(4)
    fat_arch_64  (32 字节): cputype(4) cpusubtype(4) offset(8) size(8) align(4) reserved(4)
    """
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == FAT_MAGIC:
        nfat = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for i in range(nfat):
            off = 8 + i * 20
            _, _, slice_off, slice_size, _ = struct.unpack_from(
                ">IIIII", data, off)
            slices.append((slice_off, slice_size))
        return slices
    if magic == FAT_MAGIC_64:
        nfat = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for i in range(nfat):
            off = 8 + i * 32
            _, _, slice_off, slice_size = struct.unpack_from(
                ">IIQQ", data, off)
            slices.append((slice_off, slice_size))
        return slices
    # thin: 64-bit
    m = struct.unpack_from("<I", data, 0)[0]
    if m != 0xFEEDFACF:
        raise ValueError("not a 64-bit Mach-O (magic=%08x)" % m)
    return [(0, len(data))]


def verify_slice(data, base, size, label):
    """校验单个 slice 的签名，返回 (ok, cdhash_hex)"""
    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    off = base + 32
    sig_dataoff = None
    sig_datasize = None

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_CODE_SIGNATURE:
            sig_dataoff, sig_datasize = struct.unpack_from(
                "<II", data, off + 8)
        off += cmdsize
        if off > base + size:
            break

    if sig_dataoff is None or sig_datasize == 0:
        return False, None, "无 LC_CODE_SIGNATURE（未签名）"

    cs = base + sig_dataoff
    if cs + sig_datasize > len(data):
        return False, None, "签名数据越界 (dataoff=%d size=%d)" % (
            sig_dataoff, sig_datasize)

    # SuperBlob: magic(4) length(4) count(4) then count*(type(4) offset(4))
    magic = struct.unpack_from(">I", data, cs)[0]
    if magic != 0xFADE0CC0:
        return False, None, "签名不是 SuperBlob (magic=%08x)" % magic
    length = struct.unpack_from(">I", data, cs + 4)[0]
    count = struct.unpack_from(">I", data, cs + 8)[0]

    code_dir_off = None
    for i in range(count):
        t, o = struct.unpack_from(">II", data, cs + 12 + i * 8)
        # ldid 生成的 ad-hoc 签名用 type=0 表示 CodeDirectory；
        # 标准 Apple 签名用 CSSLOT_CODEDIRECTORY (0x00010000)。
        # 两种都接受，靠 blob magic (0xFADE0C02) 二次确认。
        blob_magic = struct.unpack_from(">I", data, cs + o)[0]
        if blob_magic == 0xFADE0C02:
            code_dir_off = cs + o
            break
    if code_dir_off is None:
        return False, None, "签名中无 CodeDirectory"

    # CodeDirectory 布局 (big-endian):
    #   +0  magic(4) +4 length(4) +8 version(4) +12 flags(4)
    #   +16 hashOffset(4) +20 identOffset(4) +24 nSpecialSlots(4)
    #   +28 nCodeSlots(4) +32 codeLimit(4)
    #   +36 hashSize(1) +37 hashType(1) +38 platform(1) +39 pageSize(1)
    cd_magic = struct.unpack_from(">I", data, code_dir_off)[0]
    if cd_magic != 0xFADE0C02:
        return False, None, "CodeDirectory magic 异常 (%08x)" % cd_magic
    hash_off = struct.unpack_from(">I", data, code_dir_off + 16)[0]
    ident_off = struct.unpack_from(">I", data, code_dir_off + 20)[0]
    n_code_slots = struct.unpack_from(">I", data, code_dir_off + 28)[0]
    code_limit = struct.unpack_from(">I", data, code_dir_off + 32)[0]
    hash_size = data[code_dir_off + 36]
    hash_type = data[code_dir_off + 37]
    page_size = data[code_dir_off + 39]

    if hash_type != 2:  # SHA256
        return False, None, "仅支持 SHA256 hash (type=%d)" % hash_type
    if hash_size != 32:
        return False, None, "hash size 非 32 (%d)" % hash_size

    ident_end = data.index(b"\x00", code_dir_off + ident_off)
    identifier = data[code_dir_off + ident_off:ident_end].decode(
        "utf-8", errors="replace")

    # 逐页重算并比对
    # codeLimit 是被签名覆盖的字节数，页大小为 page_size (log2)
    page = 1 << page_size
    for slot in range(n_code_slots):
        start = slot * page
        if start >= code_limit:
            break
        end = min(start + page, code_limit)
        actual = sha256(data[base + start:base + end])
        stored = data[code_dir_off + hash_off + slot * hash_size:
                       code_dir_off + hash_off + (slot + 1) * hash_size]
        if actual != stored:
            return False, identifier, (
                "页 %d 哈希不匹配 (offset=%d len=%d) → 签名已被破坏"
                % (slot, start, end - start))

    cdhash = data[code_dir_off + hash_off + (n_code_slots - 1) * hash_size:
                  code_dir_off + hash_off + n_code_slots * hash_size].hex()
    return True, identifier, cdhash


def main():
    if len(sys.argv) < 2:
        print("Usage: verify_signature.py <macho> [...]", file=sys.stderr)
        return 1

    rc = 0
    for path in sys.argv[1:]:
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            print("  [FAIL] %s: 无法读取 (%s)" % (path, e))
            rc = 1
            continue

        try:
            slices = parse_macho(data)
        except ValueError as e:
            print("  [FAIL] %s: %s" % (path, e))
            rc = 1
            continue

        all_ok = True
        for idx, (base, size) in enumerate(slices):
            tag = path if len(slices) == 1 else "%s[slice%d]" % (path, idx)
            ok, identifier, info = verify_slice(data, base, size, tag)
            if ok:
                print("  [OK]   %s: 签名有效 (%s) CDHash=%s"
                      % (tag, identifier, info))
            else:
                print("  [FAIL] %s: %s" % (tag, info))
                all_ok = False
        if not all_ok:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
