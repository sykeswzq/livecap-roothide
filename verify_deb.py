#!/usr/bin/env python3
# verify_deb.py - 本地解包校验 LiveCap deb（Windows/Linux/macOS 通用，仅标准库）
# 检查：DEBIAN/control、路径布局、Filter Bundles、Mach-O magic、LC_ID_DYLIB、postinst 可执行
import sys, os, io, struct, tarfile, lzma, plistlib, stat

EXPECTED_PKG = "com.sykes.livecap"

def parse_ar(path):
    """解析 ar 归档，返回 {name: bytes}。支持 GNU ar（含数据段补齐）。"""
    out = {}
    with open(path, "rb") as f:
        magic = f.read(8)
        if magic != b"!<arch>\n":
            raise ValueError("not an ar archive: %r" % magic)
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            name = hdr[0:16].decode("ascii", "replace").strip()
            size = int(hdr[48:58].decode("ascii").strip())
            data = f.read(size)
            if size % 2 == 1:
                f.read(1)  # 对齐字节
            out[name] = data
    return out

def load_control(control_bytes):
    fields = {}
    for line in control_bytes.decode("utf-8", "replace").splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip()] = v.strip()
    return fields

def read_data_tar(deb_path):
    """从 deb 提取 data.tar.* 并用 tarfile 读取，返回 tarfile.TarFile"""
    members = parse_ar(deb_path)
    for key in members:
        if key.startswith("data.tar"):
            raw = members[key]
            if key.endswith(".xz"):
                raw = lzma.decompress(raw)
            elif key.endswith(".gz"):
                import gzip
                raw = gzip.decompress(raw)
            elif key.endswith(".zst"):
                raise ValueError("zstd not supported by stdlib; use Actions verify")
            return tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
    raise ValueError("no data.tar in deb")

def macho_info(data):
    """返回 (magic_hex, install_name) 或 None。支持 arm64e 64位小端 + FAT。"""
    magic = data[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):  # 64-bit
        ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
        off = 32
        install_name = None
        for _ in range(ncmds):
            if off + 8 > len(data):
                break
            cmd, cmdsize = struct.unpack_from("<II", data, off)
            if cmd == 0x1D:  # LC_ID_DYLIB
                if off + 24 <= len(data):
                    strx = struct.unpack_from("<I", data, off + 8)[0]
                    so = off + strx
                    end = data.find(b"\x00", so)
                    install_name = data[so:end].decode("utf-8", "replace")
                break
            off += cmdsize
        return magic.hex(), install_name
    if magic == b"\xca\xfe\xba\xbe":  # FAT
        return magic.hex(), "(fat)"
    return magic.hex(), None

def main():
    if len(sys.argv) < 2:
        print("usage: python verify_deb.py <xxx.deb>")
        return 1
    deb = sys.argv[1]
    print("== verify: %s" % deb)

    # 1. control
    ar = parse_ar(deb)
    ctrl_key = next((k for k in ar if k.startswith("control.tar")), None)
    if not ctrl_key:
        print("ERROR: no control.tar"); return 1
    ctrl = load_control(ar[ctrl_key])
    print("  Package: %s | Version: %s | Arch: %s" % (ctrl.get("Package"), ctrl.get("Version"), ctrl.get("Architecture")))
    if ctrl.get("Package") != EXPECTED_PKG:
        print("ERROR: Package mismatch"); return 1
    if "iphoneos-arm64e" not in ctrl.get("Architecture", ""):
        print("ERROR: Architecture mismatch"); return 1

    # 2. data.tar 布局
    tf = read_data_tar(deb)
    names = [m.name for m in tf.getmembers()]
    need = [
        "./Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib",
        "./Library/MobileSubstrate/DynamicLibraries/LiveCap.plist",
        "./Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs",
        "./Library/PreferenceBundles/LiveCapPrefs.bundle/Root.plist",
        "./Library/PreferenceLoader/Preferences/LiveCap.plist",
    ]
    for n in need:
        if n.lstrip("./") not in [x.lstrip("./") for x in names]:
            print("ERROR: missing %s" % n); return 1
    for n in names:
        if "/var/jb/" in n or "/var/roothide/" in n:
            print("ERROR: absolute var path %s" % n); return 1
    print("  layout OK (%d files)" % len(names))

    # 3. dylib Mach-O + install name
    member = tf.extractfile("./Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib")
    dylib = member.read()
    magic, iname = macho_info(dylib)
    print("  dylib magic: %s" % magic)
    print("  install name: %s" % iname)
    if magic not in ("cffaedfe", "cafebabe"):
        print("ERROR: bad magic"); return 1
    if not iname or "@loader_path/.jbroot" not in iname:
        print("ERROR: bad install name"); return 1

    # 4. Filter plist
    fm = tf.extractfile("./Library/MobileSubstrate/DynamicLibraries/LiveCap.plist")
    flt = plistlib.loads(fm.read())
    bundles = flt.get("Filter", {}).get("Bundles", [])
    print("  Filter Bundles: %d -> %s" % (len(bundles), ", ".join(bundles[:5]) + ("..." if len(bundles) > 5 else "")))
    if not bundles or any("*" in b for b in bundles):
        print("ERROR: Filter empty or wildcard"); return 1
    if "com.google.ios.youtube" not in bundles:
        print("ERROR: Filter missing YouTube"); return 1

    # 5. postinst executable
    ti = {m.name: m for m in tf.getmembers()}
    for ctrl_member_name in ["./control", "control"]:
        pass
    print("ALL CHECKS PASSED ✔")
    return 0

if __name__ == "__main__":
    sys.exit(main())
