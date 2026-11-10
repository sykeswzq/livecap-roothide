"""v2.2.1 一键部署 + 真机诊断（设备上线后执行）。

用法：
  py -3.11 deploy_diag_v211.py deploy [IP]     # 等连、部署 deb、复核 plist
  py -3.11 deploy_diag_v211.py diag   [IP]     # 用户重开 App 后抓日志定位真因

背景：v2.2.1 照 XL-Roothide 重做注入勾选链路 —— 勾选状态改存偏好
selectedApps（不再从 Filter 回读）、写完 Filter 立刻 killall runningboardd、
dylib 运行时不再用 enabledBundles 白名单拦 hook。diag 会顺带打印
Filter 权限 / 内容 / selectedApps，便于确认注入是否真的写进去了。
"""
import base64
import os
import plistlib
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST_DEFAULT = '10.10.201.107'
DEB = os.path.join(HERE, 'releases',
                   'com.sykes.livecap_2.2.1_iphoneos-arm64e.deb')
PLIST = '/var/mobile/Library/Preferences/com.sykes.livecap.plist'


def ssh_opts(host):
    return (['ssh', '-i', KEY, '-o', 'StrictHostKeyChecking=no',
             '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=12',
             'root@' + host])


def ssh(host, cmd, timeout=90):
    p = subprocess.run(ssh_opts(host) + [cmd], capture_output=True, timeout=timeout)
    return p.stdout, p.stderr.decode('utf-8', 'replace')


def wait_online(host, tries=20):
    for i in range(tries):
        try:
            out, err = ssh(host, 'echo OK', timeout=20)
            if b'OK' in out:
                print('设备在线: %s (第 %d 次探测)' % (host, i + 1))
                return True
        except Exception:
            pass
        print('  设备未响应 ... %d/%d' % (i + 1, tries))
        time.sleep(8)
    return False


def read_plist(host):
    out, _ = ssh(host, 'base64 -i ' + PLIST)
    return plistlib.loads(base64.b64decode(re.sub(rb'\s+', b'', out)))


def do_deploy(host):
    if not os.path.exists(DEB):
        print('找不到 deb:', DEB)
        return 1
    print('部署 %s (%d bytes) -> %s' % (os.path.basename(DEB),
                                        os.path.getsize(DEB), host))
    r = subprocess.call([sys.executable, os.path.join(HERE, 'deploy_v87.py'), DEB])
    if r != 0:
        print('部署脚本返回非 0，请检查上面的输出')
        return r
    out, _ = ssh(host, 'dpkg -l com.sykes.livecap | tail -1')
    print('设备版本行:', out.decode('utf-8', 'replace').strip())
    # 复核配置：v2.2.1 新增 selectedApps（勾选状态真相）
    d = read_plist(host)
    print('plist 键数:', len(d))
    for k in ('enabled', 'showBilingual', 'model', 'streamASR',
              'strictSubtitleSync', 'selectedApps', 'enabledBundles',
              'lastFilterWriteOK', 'lastFilterWritePath',
              'asrEngine', 'asrAppId', 'asrChunkSeconds'):
        v = d.get(k, '<未设置→走代码默认>')
        if isinstance(v, list) and len(v) > 6:
            v = '%d 个: %s ...' % (len(v), ', '.join(map(str, v[:4])))
        print('  %-22s = %r' % (k, v))
    print('  apiKey 存在:', bool(d.get('apiKey')),
          ' 腾讯云密钥存在:', bool(d.get('tencentSecretId')),
          ' 注入 App 数:', len(d.get('manualPositions', {})))
    print('\n下一步：完全退出 YouTube 再重开、播放 1~2 分钟有声视频，')
    print('然后执行: py -3.11 deploy_diag_v211.py diag')
    return 0


def do_diag(host):
    out, _ = ssh(host,
                 'f=$(ls -1t /var/mobile/Containers/Data/Application/*/Documents/livecap.log '
                 '2>/dev/null | head -1); echo "LOG=$f"; wc -l "$f"; '
                 'tail -60 "$f"')
    txt = out.decode('utf-8', 'replace')
    print('=== 最新日志尾部 ===')
    print(txt[-5000:])
    print('\n=== 关键事件计数 ===')
    out2, _ = ssh(host,
                  'f=$(ls -1t /var/mobile/Containers/Data/Application/*/Documents/livecap.log '
                  '2>/dev/null | head -1); '
                  'for k in "asr: ws" "handshake ok" "ws code=" "handshake timeout" '
                  '"no sentence in 10s" "partial fallback translate" "final sentence" '
                  '"asr: ws commit" "queue overflow" "drop lagging pair" "inflight rtt" '
                  '"showPending" "overlay: pending" "overlay: showPair" '
                  '"asr: sending" "showFailed"; do '
                  'printf "%-34s %s\\n" "$k" "$(grep -a -c "$k" "$f")"; done')
    print(out2.decode('utf-8', 'replace'))
    print('\n=== 注入状态（v2.2.1）===')
    inj_cmd = (
        'echo "--- Filter 文件（权限必须是 -rw-rw-rw-）---"; '
        'for p in /var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist '
        '/var/containers/Bundle/Application/.jbroot-*/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist; do '
        '[ -f "$p" ] || continue; ls -la "$p"; plutil -p "$p" 2>/dev/null | head -40; done; '
        'echo "--- 偏好 selectedApps / Filter 写入诊断 ---"; '
        'plutil -p /var/mobile/Library/Preferences/com.sykes.livecap.plist 2>/dev/null | '
        'grep -i -A3 -e selectedApps -e lastFilterWrite | head -40; '
        'echo "--- 版本 ---"; dpkg -l com.sykes.livecap | tail -1'
    )
    inj, _ = ssh(host, inj_cmd)
    print(inj.decode('utf-8', 'replace')[:5000])
    print('=== 判读 ===')
    print('  ws code= 非 0        -> 签名/计费/服务问题，看 message 原文')
    print('  handshake timeout 6s -> WebSocket 连接层不通，已按设计回落 HTTP')
    print('  有 partial 无 final  -> 断句异常，兜底翻译应已上屏')
    print('  有 showPending       -> 字幕框应出现；若仍无框查 overlay/window 层')
    print('  asr: sending 有值    -> 已回落 HTTP 分片链路，字幕正常')
    print('=== v2.2.0 判读 ===')
    print('  asr: ws commit 有值  -> 整句断句生效；commit 数应 ≈ 送译句数')
    print('  partial fallback=0   -> 严格同步已开（若非 0 说明开关被关掉了）')
    print('  queue overflow 多    -> 翻译仍跟不上，看 inflight rtt 是否 >3s')
    print('  drop lagging pair 多 -> 译文滞后严重，字幕会主动丢弃旧句')
    print('=== v2.2.1 注入判读 ===')
    print('  Filter 权限非 666    -> 面板写不进 Bundles，勾选会静默失败')
    print('  Filter 里没目标 App  -> 勾选没写进去，看 lastFilterWritePath/OK')
    print('  selectedApps 缺失    -> 面板还没打开过，首次打开会做一次性迁移')
    print('  selectedApps 只有 1 个 -> 迁移兜底没生效，原有 App 被抹掉了')
    print('  仍不生效             -> 还要 Dopamine → Inject Manager 勾选 + 彻底重开 App')
    return 0


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'deploy'
    host = sys.argv[2] if len(sys.argv) > 2 else HOST_DEFAULT
    if mode not in ('deploy', 'diag'):
        print(__doc__)
        return 2
    if not wait_online(host):
        print('设备 %s 仍不可达。请点亮屏幕、确认与电脑同一 WiFi；'
              '若 IP 已变，把新 IP 作为第二个参数传入。' % host)
        return 1
    return do_deploy(host) if mode == 'deploy' else do_diag(host)


if __name__ == '__main__':
    sys.exit(main())
