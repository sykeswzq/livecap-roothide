import base64
import subprocess
import os

SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
REMOTE_HOST = '10.10.201.107'

def send_file(local_path, remote_path):
    """Send a file via SSH using base64 encoding"""
    with open(local_path, 'rb') as f:
        data = f.read()

    b64 = base64.b64encode(data).decode('ascii')

    # Write to temp file
    tmp_file = local_path + '.b64'
    with open(tmp_file, 'w') as f:
        f.write(b64)

    print(f"Encoded {len(data)} bytes -> {len(b64)} base64 chars")
    return tmp_file

# Files to send
files = [
    (r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\livecap_extracted\Library\MobileSubstrate\DynamicLibraries\LiveCap.dylib', '/usr/lib/TweakInject/LiveCap.dylib'),
    (r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\livecap_extracted\Library\MobileSubstrate\DynamicLibraries\LiveCap.plist', '/usr/lib/TweakInject/LiveCap.plist'),
]

for local, remote in files:
    if os.path.exists(local):
        print(f"Processing: {local}")
        send_file(local, remote)
    else:
        print(f"File not found: {local}")
