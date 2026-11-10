#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.0.2 CI 一条龙：轮询 run → 下载 artifact → 解出 deb → 本地校核。

用法: py -3.11 ci_fetch_v202.py [run_id]
不传 run_id 时自动取与本地 HEAD 一致的最新 run。
"""
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASES = os.path.join(HERE, 'releases')
def _target_ver():
    """版本号一律从 build.sh 读，避免每次升级都要改这个脚本。"""
    b = io.open(os.path.join(HERE, 'build.sh'), encoding='utf-8').read()
    m = re.search(r'^VER=(.+)$', b, re.M)
    return m.group(1).strip() if m else '2.1.0'


TARGET_VER = _target_ver()


def creds():
    url = subprocess.check_output(['git', 'remote', 'get-url', 'origin']).decode().strip()
    m = re.match(r'https://([^@]+)@ghproxy\.net/https://github\.com/(.+?)(?:\.git)?$', url)
    if not m:
        raise SystemExit('remote 格式无法解析')
    return m.group(1), m.group(2)


def api(path, token, timeout=40):
    req = urllib.request.Request(
        'https://api.github.com' + path,
        headers={'Authorization': 'Bearer ' + token,
                 'Accept': 'application/vnd.github+json',
                 'User-Agent': 'livecap-ci'})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def wait_run(run_id, token, repo, limit=720):
    deadline = time.time() + limit
    last = ''
    while time.time() < deadline:
        try:
            r = api('/repos/%s/actions/runs/%s' % (repo, run_id), token)
            state = '%s/%s' % (r['status'], r['conclusion'])
            if state != last:
                print('  [%s] run %s %s' % (time.strftime('%H:%M:%S'), run_id, state), flush=True)
                last = state
            if r['status'] == 'completed':
                return r
        except Exception as e:
            print('  [%s] API 暂时不可用: %s' % (time.strftime('%H:%M:%S'), str(e)[:80]), flush=True)
        time.sleep(20)
    raise SystemExit('CI 轮询超时')


def ar_members(data):
    assert data[:8] == b'!<arch>\n', '不是 ar 归档'
    pos, out = 8, {}
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        if hdr[58:60] != b'`\n':
            break
        name = hdr[0:16].decode('ascii', 'replace').strip().rstrip('/')
        size = int(hdr[48:58].decode('ascii').strip())
        out[name] = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size % 2)
    return out


def verify(deb_path):
    print('\n=== 本地校核 %s ===' % os.path.basename(deb_path), flush=True)
    data = open(deb_path, 'rb').read()
    print('  文件大小: %d bytes' % len(data))
    m = ar_members(data)
    for k in ('debian-binary', 'control.tar.xz', 'data.tar.xz'):
        assert k in m, '缺 ar 成员 %s' % k
        print('  ar 成员 %-16s %d bytes' % (k, len(m[k])))

    def find(tar, tail):
        for n in tar.getnames():
            if n.rstrip('/').endswith(tail):
                return n
        return None

    ctl = tarfile.open(fileobj=io.BytesIO(m['control.tar.xz']), mode='r:xz')
    control = ctl.extractfile(find(ctl, '/control')).read().decode('utf-8', 'replace')
    assert ('Version: %s' % TARGET_VER) in control, 'control 版本不是 %s' % TARGET_VER
    assert 'Architecture: iphoneos-arm64e' in control, '架构不对'
    pinst = find(ctl, '/postinst')
    assert pinst and (ctl.getmember(pinst).mode & 0o111), 'postinst 缺失或不可执行'
    print('  control: Version=%s / arm64e / postinst 可执行 OK' % TARGET_VER)

    dat = tarfile.open(fileobj=io.BytesIO(m['data.tar.xz']), mode='r:xz')
    names = dat.getnames()
    def pick(tail):
        n = find(dat, tail)
        assert n, '缺文件 %s' % tail
        return n
    dylib_path = pick('/LiveCap.dylib')
    filter_path = pick('/DynamicLibraries/LiveCap.plist')
    prefs_path = pick('/LiveCapPrefs.bundle/LiveCapPrefs')
    info_path = pick('/LiveCapPrefs.bundle/Info.plist')
    dl = dat.extractfile(dylib_path).read()
    magic = dl[:4].hex()
    assert magic in ('cffaedfe', 'cafebabe', 'feedfacf'), 'Mach-O magic 异常 %s' % magic
    print('  dylib: magic=%s size=%d' % (magic, len(dl)))

    # 新代码必须真的编进 dylib（ASCII 日志串 / 方法名）
    for tag, needle in [('分片配置方法', b'lc_chunkSeconds'),
                        ('短片段跳过日志', b'asr: skip short chunk'),
                        ('agnes 熔断日志', b'agnes rate-limited'),
                        ('inflight 打点', b'translate: inflight rtt='),
                        ('v2.1.0 流式类', b'LCStreamASR'),
                        ('v2.1.0 握手日志', b'asr: ws handshake ok'),
                        ('v2.1.0 稳态句日志', b'asr: ws final sentence'),
                        ('v2.1.1 中间结果兜底', b'asr: ws partial fallback translate'),
                        ('v2.1.1 握手看门狗', b'asr: ws handshake timeout 6s'),
                        ('v2.1.1 零产出看门狗', b'asr: ws no sentence in 10s')]:
        assert needle in dl, '%s 未编进 dylib（%s）' % (tag, needle.decode())
        print('  含新代码: %s OK' % tag)

    plist = dat.extractfile(filter_path).read().decode('utf-8', 'replace')
    assert 'com.google.ios.youtube' in plist and 'mediaserverd' not in plist
    assert '<!--' not in plist
    print('  Filter plist: YouTube 在列 / 无 mediaserverd / 无 XML 注释 OK')

    prefs = dat.extractfile(prefs_path).read()
    assert b'asrChunkSeconds' in prefs, '设置面板未编入分片选项'
    print('  PrefBundle: 含 asrChunkSeconds 设置项 OK')
    info = dat.extractfile(info_path).read().decode('utf-8', 'replace')
    assert info.count('<string>%s</string>' % TARGET_VER) == 2, 'Info.plist 版本未同步'
    print('  Info.plist: 两处版本均为 %s OK' % TARGET_VER)
    print('=== 校核全部通过 ===')
    return True


def main():
    token, repo = creds()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip()
    print('repo=%s HEAD=%s' % (repo, head[:8]), flush=True)
    run_id = sys.argv[1] if len(sys.argv) > 1 else None
    if not run_id:
        runs = api('/repos/%s/actions/runs?per_page=5' % repo, token)['workflow_runs']
        hit = [r for r in runs if r['head_sha'] == head]
        if not hit:
            raise SystemExit('还没查到本次 push 的 run，稍后再试')
        run_id = hit[0]['id']
    print('监控 run %s ...' % run_id, flush=True)
    r = wait_run(run_id, token, repo)
    if r['conclusion'] != 'success':
        print('CI 失败: %s' % r['conclusion'])
        try:
            jobs = api('/repos/%s/actions/runs/%s/jobs?per_page=20' % (repo, run_id), token)
            for j in jobs['jobs']:
                if j['conclusion'] != 'success':
                    for s in j['steps']:
                        if s['conclusion'] != 'success':
                            print('  失败步骤: %s -> %s' % (s['name'], s['conclusion']))
        except Exception as e:
            print('  取 jobs 失败:', e)
        return 1
    print('CI 全绿，开始下载 artifact', flush=True)
    arts = api('/repos/%s/actions/runs/%s/artifacts' % (repo, run_id), token)['artifacts']
    assert arts, '没有 artifact'
    url = arts[0]['archive_download_url']
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token,
                                               'User-Agent': 'livecap-ci'})
    # archive_download_url 会 302 到 Azure blob；若把 GitHub 的 Authorization
    # 头一路带过去，对象存储会回 401 "Server failed to authenticate the request"。
    class StripAuthRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, r, fp, code, msg, headers, newurl):
            new = urllib.request.HTTPRedirectHandler.redirect_request(
                self, r, fp, code, msg, headers, newurl)
            if new is not None:
                for k in list(new.headers.keys()):
                    if k.lower() in ('authorization', 'accept'):
                        del new.headers[k]
                new.add_header('User-Agent', 'livecap-ci')
            return new
    opener = urllib.request.build_opener(StripAuthRedirect)
    blob = opener.open(req, timeout=180).read()
    print('artifact ZIP: %d bytes' % len(blob))
    z = zipfile.ZipFile(io.BytesIO(blob))
    deb_name = [n for n in z.namelist() if n.endswith('.deb')][0]
    os.makedirs(RELEASES, exist_ok=True)
    out = os.path.join(RELEASES, os.path.basename(deb_name))
    open(out, 'wb').write(z.read(deb_name))
    print('已保存: %s' % out)
    verify(out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
