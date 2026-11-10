#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正设备 plist 里旧版残留的 asrChunkSeconds=2.5 → 1.5。

背景：v1.x 曾把分片时长写进 plist；v2.0.0 改成代码常量后没清理这个键。
v2.0.2 重新支持从 plist 读取，于是旧值 2.5 会被当成有效配置，
导致「默认 1.5 秒」完全不生效。升级不会覆盖已有 plist，必须显式迁移。

做法（设备端 plutil 是老版本，不支持 -replace）：
  拉回 binary plist -> plistlib 改键 -> 生成 XML -> 上传 ->
  plutil -convert binary1 -> cp 覆盖 -> chmod 666 -> killall cfprefsd -> 复核
"""
import base64
import os
import plistlib
import re
import subprocess
import sys

KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST = 'root@10.10.201.107'
OPTS = ['-i', KEY, '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=20']
CFG = '/var/mobile/Library/Preferences/com.sykes.livecap.plist'
HERE = os.path.dirname(os.path.abspath(__file__))
BACKUP = os.path.join(HERE, 'releases', 'device_cfg_before_v202.plist')
TARGET = 1.5


def ssh(cmd, data=None, timeout=90):
    p = subprocess.run(['ssh'] + OPTS + [HOST, cmd], input=data,
                       capture_output=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr.decode('utf-8', 'replace')


def main():
    rc, out, err = ssh('base64 -i %s' % CFG)
    if rc != 0:
        print('读取设备 plist 失败:', err[:300])
        return 1
    raw = base64.b64decode(re.sub(rb'\s+', b'', out))
    d = plistlib.loads(raw)
    print('原始键数: %d, asrChunkSeconds=%r' % (len(d), d.get('asrChunkSeconds')))

    os.makedirs(os.path.dirname(BACKUP), exist_ok=True)
    open(BACKUP, 'wb').write(raw)
    print('已本地备份 -> %s (%d bytes)' % (BACKUP, len(raw)))

    old = d.get('asrChunkSeconds')
    if old == TARGET:
        print('已是 1.5，无需改动')
    else:
        d['asrChunkSeconds'] = TARGET
        xml = plistlib.dumps(d, fmt=plistlib.FMT_XML, sort_keys=True)
        b64 = base64.b64encode(xml).decode('ascii')
        print('生成 XML %d bytes, 备份设备原文件并上传...' % len(xml))
        ssh('cp %s /tmp/livecap_cfg_before_v202.plist && chmod 666 /tmp/livecap_cfg_before_v202.plist' % CFG)
        rc, _, err = ssh('cat > /tmp/lc_cfg_v202.xml', data=b64.encode('ascii'))
        if rc != 0:
            print('上传失败:', err[:300])
            return 1
        rc, out, err = ssh(
            'base64 -d /tmp/lc_cfg_v202.xml > /tmp/lc_cfg_v202_body.xml && '
            'plutil -convert binary1 /tmp/lc_cfg_v202_body.xml && '
            'cp /tmp/lc_cfg_v202_body.xml %s && chmod 666 %s && '
            'killall -9 cfprefsd 2>/dev/null; '
            'ls -l %s' % (CFG, CFG, CFG))
        print('设备端:', out.decode('utf-8', 'replace').strip() or err[:200])
        if rc != 0:
            print('写入返回 %d: %s' % (rc, err[:300]))
            return 1

    # 复核：重新读回，确认所有键都还在
    rc, out, _ = ssh('base64 -i %s' % CFG)
    d2 = plistlib.loads(base64.b64decode(re.sub(rb'\s+', b'', out)))
    print('\n复核：键数 %d, asrChunkSeconds=%r' % (len(d2), d2.get('asrChunkSeconds')))
    lost = set(d.keys()) - set(d2.keys())
    print('  丢失的键:', lost or '无')
    print('  showBilingual =', d2.get('showBilingual'))
    print('  apiKey 保留 =', bool(d2.get('apiKey')))
    print('  enabled =', d2.get('enabled'))
    if lost or d2.get('asrChunkSeconds') != TARGET:
        print('  ❌ 复核失败')
        return 1
    print('  ✅ 配置迁移完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
