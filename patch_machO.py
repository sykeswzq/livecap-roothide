#!/usr/bin/env python3
"""patch_machO_install_name.py - 直接修改 Mach-O 64-bit 的 install_name
用法: python3 patch_machO_install_name.py <dylib> <new_id>
"""
import struct
import sys

def patch_machO(dylib_path, new_id):
    with open(dylib_path, "rb") as f:
        data = bytearray(f.read())

    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError(f"Not 64-bit Mach-O: {data[:4].hex()}")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    off = 32

    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x1D:  # LC_ID_DYLIB
            # name 是相对于 Mach-O header 的偏移
            name_offset = struct.unpack_from("<I", data, off + 8)[0]
            # 找到现有字符串结束
            end = data.find(b"\x00", name_offset)
            old_len = end - name_offset

            new_id_bytes = new_id.encode("utf-8") + b"\x00"
            new_len = len(new_id_bytes)

            if new_len <= old_len:
                # 直接替换（原地）
                data[name_offset:end] = new_id_bytes + b"\x00" * (old_len - new_len)
                print(f"OK: patched install_name at offset {name_offset} ({old_len} -> {new_len})")
                with open(dylib_path, "wb") as f:
                    f.write(data)
                return True
            else:
                # 需要扩展：找 __LINKEDIT segment 是否有空间
                print(f"WARNING: new name too long ({new_len} > {old_len})")
                # 尝试在 __LINKEDIT 中找足够空间
                for i in range(ncmds):
                    if off + 8 > len(data):
                        break
                    c, cs = struct.unpack_from("<II", data, off)
                    if c == 0x19:  # LC_SEGMENT_64
                        segname = data[off+16:off+24].decode("ascii", errors="replace")
                        if segname == "__LINKEDIT":
                            # 检查 segment 末尾是否有空间
                            vmsize, fileoff, filesize = struct.unpack_from("<QQQ", data, off+72)
                            end_of_linkedit = fileoff + filesize
                            print(f"  __LINKEDIT ends at offset {end_of_linkedit}, file size {len(data)}")
                            if end_of_linkedit + new_len <= len(data):
                                # 写入新字符串到 segment 末尾
                                new_offset = end_of_linkedit
                                data[new_offset:new_offset + new_len] = new_id_bytes
                                # 更新 LC_ID_DYLIB 的 name 字段
                                struct.pack_into("<I", data, off + 8, new_offset)
                                print(f"  OK: wrote install_name at new offset {new_offset}")
                                with open(dylib_path, "wb") as f:
                                    f.write(data)
                                return True
                            else:
                                print(f"  ERROR: not enough space in __LINKEDIT")
                                return False
                    off += cs
                print("ERROR: __LINKEDIT not found or no space")
                return False
        off += cmdsize

    print("ERROR: LC_ID_DYLIB not found")
    return False

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <dylib> <new_id>")
        sys.exit(1)
    if not patch_machO(sys.argv[1], sys.argv[2]):
        sys.exit(1)
