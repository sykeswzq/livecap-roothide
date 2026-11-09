#!/usr/bin/env python3
"""Compare postinst between v1.0.88 and v1.0.100 debs."""
import os
import subprocess
import shutil

base = r"C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide"
releases = os.path.join(base, "releases")

for ver in ['1.0.88', '1.0.100']:
    deb = os.path.join(releases, f"com.sykes.livecap_{ver}_iphoneos-arm64e.deb")
    tmpdir = os.path.join(r"C:\tmp", f"livecap_extract_{ver}")
    if os.path.exists(tmpdir):
        shutil.rmtree(tmpdir, ignore_errors=True)
    os.makedirs(tmpdir, exist_ok=True)

    # Use ar via Git Bash
    result = subprocess.run(
        ["bash", "-c", f"cd '{tmpdir}' && ar x '{deb}'"],
        capture_output=True, text=True
    )
    files = os.listdir(tmpdir)
    print(f"\n=== {ver} extracted files: {files}")

    postinst_path = os.path.join(tmpdir, "postinst")
    if os.path.exists(postinst_path):
        with open(postinst_path, 'r', errors='replace') as f:
            content = f.read()
        print(f"--- postinst ({len(content)} bytes) ---")
        print(content[:2000])
    else:
        print("No postinst found!")
