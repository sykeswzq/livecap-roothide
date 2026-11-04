#!/usr/bin/env python3
import base64
import subprocess
import sys
import os

DEB_PATH = r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\com.sykes.livecap_1.0.77_iphoneos-arm64e.deb'
SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
REMOTE_HOST = 'root@10.10.201.107'

# Read DEB and encode
with open(DEB_PATH, 'rb') as f:
    data = f.read()

b64 = base64.b64encode(data).decode('ascii')

# Write to temp file for splitting
tmp_file = r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\livecap_b64_chunk.txt'
chunk_size = 4000  # Safe chunk size for SSH

# Split into chunks and send
print(f"Total base64 length: {len(b64)}")
print(f"Sending in chunks of {chunk_size}...")

for i in range(0, len(b64), chunk_size):
    chunk = b64[i:i+chunk_size]
    chunk_file = f'{tmp_file}_{i//chunk_size}'
    with open(chunk_file, 'w') as f:
        f.write(chunk)

# Create assembly script on remote
assemble_script = '''#!/bin/sh
cd /tmp
rm -f LiveCap_v1.0.77.deb livecap_part_*
for i in $(seq 0 99); do
    f="/tmp/livecap_part_$i.txt"
    if [ -f "$f" ]; then
        cat "$f" >> livecap_part_$i.b64
        rm "$f"
    fi
done
# Now concatenate all parts and decode
cat /tmp/livecap_part_*.b64 | base64 -d > /tmp/LiveCap_v1.0.77.deb
ls -la /tmp/LiveCap_v1.0.77.deb
'''

# Write assembly script
script_file = r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\assemble_livecap.sh'
with open(script_file, 'w') as f:
    f.write(assemble_script)

print(f"Created {len(b64)//chunk_size + 1} chunk files")
print("Next: upload chunks to device and assemble")
