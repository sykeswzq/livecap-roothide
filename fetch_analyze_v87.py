#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.87 真机日志采集 + 分析（一条命令跑完）。

用法:
  py -3.11 fetch_analyze_v87.py [等待秒数] [超时秒数]
默认: 等 25 秒起，最长 600 秒，日志稳定 3 次后自动分析。

前提: 设备上 YouTube 已完全退出并重新打开、正在播放有声音的视频。
"""
import os
import subprocess
import sys
import time

SSH_KEY = 'E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key'
HOST = 'root@10.10.201.107'
SSH_OPTS = ['-i', SSH_KEY, '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=20']
LOG_CANDIDATES = ("/var/mobile/Containers/Data/Application/*/Documents/livecap.log",)
LOG = None  # 运行时动态解析


def find_log():
    """YouTube 容器 UUID 重装后会变，动态找最新的 livecap.log。"""
    global LOG
    pat = LOG_CANDIDATES[0]
    rc, out, _ = ssh("ls -1t %s 2>/dev/null | head -1" % pat)
    p = out.strip().splitlines()[0].strip() if out.strip() else ""
    if p and "/" in p:
        LOG = p
    return LOG
HERE = os.path.dirname(os.path.abspath(__file__))


def ssh(cmd, timeout=60):
    p = subprocess.run(['ssh'] + SSH_OPTS + [HOST, cmd],
                       capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')


def log_size():
    if not LOG:
        find_log()
    if not LOG:
        return 0
    rc, out, _ = ssh("wc -c < '%s' 2>/dev/null || echo 0" % LOG)
    try:
        return int(out.strip().split()[0])
    except Exception:
        return 0


def main():
    start_wait = int(sys.argv[1]) if len(sys.argv) > 1 else 25
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 600
    print("[1] 日志路径: %s" % (find_log() or "未找到（YouTube 可能还没启动过）"))
    print("[2] 基线日志大小: %d bytes" % log_size())
    print("[2] 等待 %ds 让设备产生新日志（最长 %ds）" % (start_wait, timeout))
    print("    提示：请完全退出 YouTube 后重新打开并播放视频")
    time.sleep(start_wait)

    deadline = time.time() + timeout
    last, stable = -1, 0
    while time.time() < deadline:
        sz = log_size()
        if sz > 0 and sz == last:
            stable += 1
            if stable >= 2:
                break
        else:
            stable = 0
        last = sz
        print("    日志 %d bytes" % sz)
        time.sleep(5)

    print("[3] 拉取日志并分析 ...")
    if not find_log():
        print("找不到 livecap.log —— 请完全退出 YouTube 后重新打开并播放视频")
        return 1
    local = os.path.join(HERE, "livecap_v87.log")
    rc, out, err = ssh("cat '%s' > /tmp/lc87.log && base64 /tmp/lc87.log" % LOG)
    if rc != 0 or not out.strip():
        print("拉取失败: %s" % err[:400])
        return 1
    import base64
    try:
        data = base64.b64decode(out.strip())
    except Exception as e:
        print("base64 解码失败: %s" % e)
        return 1
    with open(local, 'wb') as f:
        f.write(data)
    print("    已保存 %s (%d bytes)" % (local, len(data)))

    r = subprocess.run([sys.executable, os.path.join(HERE, "analyze_v87.py"), local])
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
