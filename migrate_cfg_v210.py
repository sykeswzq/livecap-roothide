#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.1.0 设备 plist 迁移：model 旧值 + 新增流式配置键。

必做原因（和 v2.0.2 的 asrChunkSeconds 同款坑）：
  postinst 只在【首次安装】写默认配置，升级不会覆盖已有 plist。
  设备 plist 里 model 仍是 agnes-2.5-flash，而 LCConfig.model 优先读 plist，
  会把代码里的新默认值 agnes-3.0-flash 完全盖掉 —— 翻译优化等于白做。
  同时 streamASR / asrEngine / asrAppId 三个新键也不存在（代码有默认值兜底，
  但显式写进 plist 便于以后在面板/SSH 里调整）。

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
BACKUP = os.path.join(HERE, 'releases', 'device_cfg_before_v210.plist')

NEW = {
    'model': 'agnes-3.0-flash',
    'streamASR': True,
    'asrEngine': '16k_en',
    'asrAppId': '1312073434',
}


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
    print('原始键数: %d' % len(d))
    for k, v in NEW.items():
        print('  %-14s %r -> %r' % (k, d.get(k, '<缺失>'), v))

    os.makedirs(os.path.dirname(BACKUP), exist_ok=True)
    open(BACKUP, 'wb').write(raw)
    print('已本地备份 -> %s (%d bytes)' % (BACKUP, len(raw)))

    changed = any(d.get(k) != v for k, v in NEW.items())
    if not changed:
        print('配置已是 v2.1.0 目标值，无需改动')
    else:
        for k, v in NEW.items():
            d[k] = v
        xml = plistlib.dumps(d, fmt=plistlib.FMT_XML, sort_keys=True)
        b64 = base64.b64encode(xml).decode('ascii')
        print('生成 XML %d bytes, 备份设备原文件并上传...' % len(xml))
        ssh('cp %s /tmp/livecap_cfg_before_v210.plist && '
            'chmod 666 /tmp/livecap_cfg_before_v210.plist' % CFG)
        rc, _, err = ssh('cat > /tmp/lc_cfg_v210.xml', data=b64.encode('ascii'))
        if rc != 0:
            print('上传失败:', err[:300])
            return 1
        rc, out, err = ssh(
            'base64 -d /tmp/lc_cfg_v210.xml > /tmp/lc_cfg_v210_body.xml && '
            'plutil -convert binary1 /tmp/lc_cfg_v210_body.xml && '
            'cp /tmp/lc_cfg_v210_body.xml %s && chmod 666 %s && '
            'killall -9 cfprefsd 2>/dev/null; ls -l %s' % (CFG, CFG, CFG))
        print('设备端:', out.decode('utf-8', 'replace').strip() or err[:200])
        if rc != 0:
            print('写入返回 %d: %s' % (rc, err[:300]))
            return 1

    rc, out, _ = ssh('base64 -i %s' % CFG)
    d2 = plistlib.loads(base64.b64decode(re.sub(rb'\s+', b'', out)))
    print('\n复核：键数 %d' % len(d2))
    lost = set(d.keys()) - set(d2.keys())
    print('  丢失的键:', lost or '无')
    for k, v in NEW.items():
        print('  %-14s = %r %s' % (k, d2.get(k), 'OK' if d2.get(k) == v else 'FAIL'))
    print('  showBilingual =', d2.get('showBilingual'))
    print('  apiKey 保留   =', bool(d2.get('apiKey')))
    print('  tencentKey 保留 =', bool(d2.get('tencentSecretId')))
    print('  injectApps 条目 =', len(d2.get('injectApps', [])))
    if lost or any(d2.get(k) != v for k, v in NEW.items()):
        print('迁移复核未通过')
        return 1
    print('迁移完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
