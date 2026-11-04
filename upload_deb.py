#!/usr/bin/env python3
"""Upload DEB file to iOS device via SSH in chunks"""
import base64
import subprocess
import sys
import os

DEB_PATH = r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\com.sykes.livecap_1.0.82_iphoneos-arm64e.deb'
SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
REMOTE_HOST = '10.10.201.107'
REMOTE_PATH = '/tmp/LiveCap_v1.0.82.deb'

# Read DEB
with open(DEB_PATH, 'rb') as f:
    data = f.read()

print(f"Reading DEB: {len(data)} bytes")

# Split into chunks of 4000 chars each
chunk_size = 4000
chunks = []
for i in range(0, len(data), chunk_size):
    chunks.append(base64.b64encode(data[i:i+chunk_size]).decode('ascii'))

print(f"Split into {len(chunks)} chunks")

# Create temp directory on remote
result = subprocess.run(
    ['ssh', '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
     f'root@{REMOTE_HOST}', 'mkdir -p /tmp/livecap_upload && cd /tmp/livecap_upload'],
    capture_output=True, text=True
)
if result.returncode != 0:
    print(f"Failed to create dir: {result.stderr}")
    sys.exit(1)

# Upload each chunk
for idx, chunk in enumerate(chunks):
    chunk_file = f'/tmp/livecap_upload/chunk_{idx:03d}.b64'
    # Write chunk to temp file locally, then cat it and pipe to ssh
    local_tmp = f'chunk_{idx:03d}.txt'
    with open(local_tmp, 'w') as f:
        f.write(chunk)

    # Use ssh with stdin
    cmd = ['ssh', '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
           f'root@{REMOTE_HOST}', f'cat > {chunk_file}']
    with open(local_tmp, 'r') as fin:
        result = subprocess.run(cmd, input=fin.read(), capture_output=True, text=True)

    if result.returncode != 0:
        print(f"Failed to upload chunk {idx}: {result.stderr}")
        os.remove(local_tmp)
        sys.exit(1)

    os.remove(local_tmp)
    print(f"Uploaded chunk {idx+1}/{len(chunks)}")

# Assemble chunks on remote
print("Assembling chunks on device...")
result = subprocess.run(
    ['ssh', '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
     f'root@{REMOTE_HOST}',
     f'cd /tmp/livecap_upload && cat chunk_*.b64 | base64 -d > {REMOTE_PATH} && ls -la {REMOTE_PATH}'],
    capture_output=True, text=True
)
print(result.stdout)
if result.returncode != 0:
    print(f"Failed to assemble: {result.stderr}")
    sys.exit(1)

# Cleanup
subprocess.run(
    ['ssh', '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
     f'root@{REMOTE_HOST}',
     'rm -rf /tmp/livecap_upload'],
    capture_output=True
)

print(f"\nSuccess! DEB uploaded to {REMOTE_PATH}")
