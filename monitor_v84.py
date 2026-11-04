#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""后台轮询设备日志，一旦产生新内容就自动跑 check_v84.py 分析。

用法: python3 monitor_v84.py [最少等待秒数] [超时秒数]
默认: 等 20 秒起，最长 600 秒。
"""
import base64
import os
import subprocess
import sys
import time

HOST = "root@10.10.201.107"
LOG = ("/var/mobile/Containers/Data/Application/"
       "C7E7F401-7808-465F-8787-F05AE203D242/Documents/livecap.log")
HERE = os.path.dirname(os.path.abspath(__file__))


def log_size():
    cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o",
           "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
           HOST, "wc -c < '%s' 2>/dev/null || echo 0" % LOG]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=30)
        txt = p.stdout.decode("utf-8", "replace").strip()
        return int(txt.split()[0]) if txt and txt.split()[0].isdigit() else 0
    except Exception:
        return -1


def main():
    start_wait = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 600
    print("[monitor] 基线日志大小: %d bytes" % log_size())
    print("[monitor] 等待 %ds 后开始轮询，最长 %ds" % (start_wait, timeout))
    time.sleep(start_wait)

    deadline = time.time() + timeout
    last = -1
    stable = 0
    while time.time() < deadline:
        sz = log_size()
        if sz > 0 and sz == last:
            stable += 1
            if stable >= 2:      # 连续 3 次大小不变 → 认为写入结束
                break
        else:
            stable = 0
        last = sz
        print("[monitor] 日志 %d bytes" % sz)
        time.sleep(5)

    print("[monitor] 最终 %d bytes，开始分析" % last)
    r = subprocess.run([sys.executable, os.path.join(HERE, "check_v84.py")],
                       cwd=HERE, capture_output=True)
    out = r.stdout.decode("utf-8", "replace")
    print(out)
    if r.stderr:
        print("[stderr]", r.stderr.decode("utf-8", "replace")[:2000])
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
