#!/usr/bin/env python3
"""patch_machO_install_name.py - 直接修改 Mach-O 64-bit 的 install_name
用法: python3 patch_machO_install_name.py <dylib> <new_id>
Mach-O LC_SEGMENT_64 结构 (arm64):
  - cmd: 4 bytes
  - cmdsize: 4 bytes
  - segname: 16 bytes (offset 8)
  - vmaddr: 8 bytes (offset 24)
  - vmsize: 8 bytes (offset 32)
  - fileoff: 8 bytes (offset 40)
  - filesize: 8 bytes (offset 48)  <- 我之前写错了，应该是 48 不是 56
  - maxprot: 4 bytes (offset 56)
  - initprot: 4 bytes (offset 60)
  - nsects: 4 bytes (offset 64)
  - flags: 4 bytes (offset 68)
  总计: 72 bytes
"""
import struct
import sys

def patch_machO(dylib_path, new_id):
    with open(dylib_path, "rb") as f:
        data = bytearray(f.read())

    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError(f"Not 64-bit Mach-O: {data[:4].hex()}")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)

    # 找到 LC_ID_DYLIB 和 __LINKEDIT segment
    linkedit_off = None
    linkedit_fileoff = None
    linkedit_filesize = None
    id_dylib_off = None

    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[off+8:off+24].decode("ascii", errors="replace").strip('\x00')
            fileoff = struct.unpack_from("<Q", data, off+40)[0]
            filesize = struct.unpack_from("<Q", data, off+48)[0]  # 修正偏移
            if segname == '__LINKEDIT':
                linkedit_off = off
                linkedit_fileoff = fileoff
                linkedit_filesize = filesize
        elif cmd == 0x0D:  # LC_ID_DYLIB  (注意: 0x1D 是 LC_CODE_SIGNATURE，别搞混)
            id_dylib_off = off
        off += cmdsize

    if id_dylib_off is None:
        print("ERROR: LC_ID_DYLIB not found")
        return False

    if linkedit_off is None:
        print("ERROR: __LINKEDIT not found")
        return False

    print(f"__LINKEDIT: fileoff={linkedit_fileoff}, filesize={linkedit_filesize}")
    print(f"__LINKEDIT 范围: {linkedit_fileoff}-{linkedit_fileoff + linkedit_filesize}")
    print(f"File size: {len(data)}")

    # 计算新字符串位置：放在 __LINKEDIT 末尾
    new_id_bytes = new_id.encode("utf-8") + b"\x00"
    new_name_offset = linkedit_fileoff + linkedit_filesize

    # 检查是否需要扩展文件
    if new_name_offset + len(new_id_bytes) > len(data):
        padding = new_name_offset + len(new_id_bytes) - len(data) + 4096
        data.extend(b"\x00" * padding)
        print(f"Expanded file by {padding} bytes")

    # 写入新字符串
    data[new_name_offset:new_name_offset + len(new_id_bytes)] = new_id_bytes
    print(f"Wrote install_name at offset {new_name_offset}")

    # 更新 LC_ID_DYLIB 的 name 字段（相对于 Mach-O header 的偏移）
    struct.pack_into("<I", data, id_dylib_off + 8, new_name_offset)
    print(f"Updated LC_ID_DYLIB name offset to {new_name_offset}")

    # 更新 __LINKEDIT 的 filesize
    struct.pack_into("<Q", data, linkedit_off + 48, linkedit_filesize + len(new_id_bytes))
    print(f"Updated __LINKEDIT filesize to {linkedit_filesize + len(new_id_bytes)}")

    with open(dylib_path, "wb") as f:
        f.write(data)

    # 验证
    end = data.find(b"\x00", new_name_offset)
    iname = data[new_name_offset:end].decode("utf-8", errors="replace")
    print(f"Verified: {iname!r}")
    if iname == new_id:
        print("SUCCESS!")
        return True
    else:
        print("FAILED!")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <dylib> <new_id>")
        sys.exit(1)
    if not patch_machO(sys.argv[1], sys.argv[2]):
        sys.exit(1)
