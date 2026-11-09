#!/usr/bin/env python3
"""Extract and compare postinst from v1.0.88 and v1.0.100 debs."""
import os
import struct

base = r"C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\releases"
out_base = r"C:\tmp_extract"

for ver in ['1.0.88', '1.0.100']:
    deb_path = os.path.join(base, f"com.sykes.livecap_{ver}_iphoneos-arm64e.deb")
    out_dir = os.path.join(out_base, ver)
    os.makedirs(out_dir, exist_ok=True)

    with open(deb_path, "rb") as f:
        data = f.read()

    pos = 0
    control_tar_start = None
    control_tar_size = None
    while True:
        name_raw = data[pos:pos+100]
        name_bytes = name_raw.split(b'\x00')[0]
        if not name_bytes:
            break
        name = name_bytes.decode('ascii', errors='replace')
        size = int(data[pos+124:pos+136], 8)
        if name == 'control.tar.gz':
            control_tar_start = pos + 162
            control_tar_size = ((size + 511) // 512) * 512
        next_pos = pos + 512
        if name == 'TRAILER!!':
            break
        pos = next_pos

    if control_tar_start is None:
        print(f"{ver}: control.tar.gz not found!")
        continue

    control_data = data[control_tar_start:control_tar_start+control_tar_size]
    control_path = os.path.join(out_dir, "control.tar.gz")
    with open(control_path, "wb") as f:
        f.write(control_data)
    print(f"{ver}: saved {control_path} ({len(control_data)} bytes)")
