#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 真机部署（SSH 分块上传 → dpkg 安装 → 校验）。

用法:
  py -3.11 deploy_v87.py <本地deb路径>

注意:
  · 走 SSH 分块 base64 上传（Windows 没有 dpkg/ar 也能装）
  · 安装前会先确认设备上旧版本，避免版本号不升导致 Sileo 判「已最新」跳过
"""
import base64
import os
import subprocess
import sys

SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST = 'root@10.10.201.107'
SSH_OPTS = ['-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=20']


def sh(cmd, timeout=120):
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    out = p.stdout.decode('utf-8', 'replace')
    err = p.stderr.decode('utf-8', 'replace')
    return p.returncode, out, err


def ssh(cmd, timeout=120):
    return sh(['ssh'] + SSH_OPTS + [HOST, cmd], timeout=timeout)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    deb = sys.argv[1]
    if not os.path.exists(deb):
        print("找不到 deb: %s" % deb)
        return 1

    with open(deb, 'rb') as f:
        data = f.read()
    print("[1/5] 本地 deb: %s (%d bytes)" % (deb, len(data)))

    ver = os.path.basename(deb)
    remote = '/tmp/LiveCap_%s.deb' % ver

    # 设备端现有版本
    rc, out, _ = ssh('dpkg -l 2>/dev/null | grep -i livecap | awk \'{print $3}\'')
    print("      设备现有版本: %s" % (out.strip() or "(未安装)"))

    # 分块上传
    chunk_size = 4000
    chunks = [base64.b64encode(data[i:i + chunk_size]).decode('ascii')
              for i in range(0, len(data), chunk_size)]
    print("[2/5] 分 %d 块上传到设备..." % len(chunks))
    ssh('rm -rf /tmp/lc_up && mkdir -p /tmp/lc_up')
    for i, c in enumerate(chunks):
        p = subprocess.run(['ssh'] + SSH_OPTS + [HOST, 'cat > /tmp/lc_up/c%03d.b64' % i],
                           input=c.encode('ascii'), capture_output=True, timeout=60)
        if p.returncode != 0:
            print("上传块 %d 失败: %s" % (i, p.stderr.decode('utf-8', 'replace')[:300]))
            return 1
        if i % 10 == 0:
            print("      %d/%d" % (i, len(chunks)))
    rc, out, err = ssh('cd /tmp/lc_up && cat c*.b64 | base64 -d > %s && ls -la %s'
                        % (remote, remote))
    print("      %s" % out.strip())
    if rc != 0:
        print("合并失败: %s" % err[:300])
        return 1

    # 安装
    print("[3/5] dpkg -i 安装 ...")
    rc, out, err = ssh('dpkg -i %s 2>&1 | tail -20' % remote)
    print(out)
    if rc != 0:
        print("安装返回码 %d: %s" % (rc, err[:500]))

    # 校验
    print("[4/5] 校验安装结果 ...")
    rc, out, _ = ssh(
        'dpkg -l 2>/dev/null | grep -i livecap; '
        'echo "--- dylib ---"; ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib; '
        'echo "--- prefs bundle ---"; ls -la /var/jb/Library/PreferenceBundles/LiveCapPrefs.bundle/ 2>/dev/null; '
        'echo "--- install log ---"; tail -12 /var/mobile/Documents/livecap_install.log 2>/dev/null')
    print(out)

    # 清理
    ssh('rm -rf /tmp/lc_up %s' % remote)

    # 签名校验（设备端重算页哈希）
    print("[5/5] 设备端 dylib 签名自检 ...")
    rc, out, _ = ssh('cd /var/jb/Library/MobileSubstrate/DynamicLibraries && '
                     'codesign -dv LiveCap.dylib 2>&1 | head -5; '
                     'echo "--- trustcache ---"; '
                     'ls -la /var/containers/Bundle/Application/.jbroot-*/usr/lib/TweakInject/LiveCap.dylib 2>/dev/null | head -3')
    print(out)
    print("\n部署完成。请完全退出 YouTube 后重开，再看字幕延迟与字号。")
    return 0


if __name__ == '__main__':
    sys.exit(main())
