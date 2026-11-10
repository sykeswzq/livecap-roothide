"""v2.1.1 一键部署 + 真机诊断（设备上线后执行）。

用法：
  py -3.11 deploy_diag_v211.py deploy [IP]     # 等连、部署 deb、复核 plist
  py -3.11 deploy_diag_v211.py diag   [IP]     # 用户重开 App 后抓日志定位真因

背景：用户反馈 v2.1.0「右上有点、没翻译框」。右上点 = overlay 的 26x26
拖动圆点；没有 showPending 时 hasContent=NO，字幕框不出现。
本地实测已证伪「持续推流无稳态句」和「URL 编码导致 4002」，
真因最可能在连接层，必须靠设备日志里的 asr: ws / code= / showPending 定案。
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
                   'com.sykes.livecap_2.1.1_iphoneos-arm64e.deb')
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
    # 复核配置：v2.1.1 不新增必填键，升级包也不覆盖已有 plist
    d = read_plist(host)
    print('plist 键数:', len(d))
    for k in ('enabled', 'showBilingual', 'model', 'streamASR',
              'asrEngine', 'asrAppId', 'asrChunkSeconds'):
        print('  %-18s = %r' % (k, d.get(k, '<未设置→走代码默认>')))
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
                  '"showPending" "overlay: pending" "overlay: showPair" '
                  '"asr: sending" "showFailed"; do '
                  'printf "%-34s %s\\n" "$k" "$(grep -a -c "$k" "$f")"; done')
    print(out2.decode('utf-8', 'replace'))
    print('=== 判读 ===')
    print('  ws code= 非 0        -> 签名/计费/服务问题，看 message 原文')
    print('  handshake timeout 6s -> WebSocket 连接层不通，已按设计回落 HTTP')
    print('  有 partial 无 final  -> 断句异常，兜底翻译应已上屏')
    print('  有 showPending       -> 字幕框应出现；若仍无框查 overlay/window 层')
    print('  asr: sending 有值    -> 已回落 HTTP 分片链路，字幕正常')
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
