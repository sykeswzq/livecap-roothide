import base64
import subprocess
import os

SSH_CMD = ['ssh', '-i', 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key',
           '-o', 'StrictHostKeyChecking=no', 'root@10.10.201.107']

def upload_file(local_path, remote_path):
    """Upload a file via SSH using base64 encoding"""
    with open(local_path, 'rb') as f:
        data = f.read()

    b64 = base64.b64encode(data).decode('ascii')

    # Write to temp file
    tmp_b64 = local_path + '.b64'
    with open(tmp_b64, 'w') as f:
        f.write(b64)

    print(f"Prepared {local_path} -> {len(b64)} base64 chars")

    # Use ssh with stdin redirect
    # Build the remote command
    remote_cmd = f"base64 -d > {remote_path}"

    # Read the b64 file and pipe to ssh
    with open(tmp_b64, 'r') as f:
        result = subprocess.run(SSH_CMD + [remote_cmd], input=f.read(),
                              capture_output=True, text=True)
        if result.returncode == 0:
            print(f"  Uploaded to {remote_path}")
            # Verify
            check = subprocess.run(SSH_CMD + ['ls', '-la', remote_path],
                                 capture_output=True, text=True)
            print(f"  {check.stdout.strip()}")
        else:
            print(f"  Error: {result.stderr}")

    # Cleanup
    os.remove(tmp_b64)

# Upload files
upload_file(
    r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\livecap_extracted\Library\MobileSubstrate\DynamicLibraries\LiveCap.plist',
    '/usr/lib/TweakInject/LiveCap.plist'
)

upload_file(
    r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\livecap_extracted\Library\MobileSubstrate\DynamicLibraries\LiveCap.dylib',
    '/usr/lib/TweakInject/LiveCap.dylib'
)

print("\nDone!")
