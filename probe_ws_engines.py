#!/usr/bin/env python3
"""probe_ws_engines.py - 探测腾讯云实时 ASR 各引擎在当前账号下的可用性

只做握手（不推音频），用于区分：
  code=0   引擎可用
  code=4002 签名 / APPID / 密钥不对
  code=4003 实时语音识别服务未开通
  code=4004 该引擎计费项未开通（大模型引擎常见）或资源包耗尽

密钥复用 verify_ws_asr.load_credentials()，不落盘。
用法: py -3.11 probe_ws_engines.py [APPID]
"""
import json
import sys
import time

import websocket

import verify_ws_asr as v

ENGINES = [
    ('16k_en', '通用英文'),
    ('16k_zh', '通用中文'),
    ('16k_multi_lang', '大模型1.0 多语种（当前一句话识别所用）'),
    ('16k_zh_en', '大模型1.0 中英'),
    ('16k_en_large', '大模型1.0 英文'),
    ('Hy-ASR-3.0-preview', '大模型2.0 中英+方言'),
]


def main():
    appid = sys.argv[1] if len(sys.argv) > 1 else '1312073434'
    sid, skey = v.load_credentials()
    print('APPID = %s' % appid)
    print('-' * 74)
    ok = []
    for eng, desc in ENGINES:
        url, _, _ = v.build_ws_url(appid, sid, skey, engine=eng)
        try:
            ws = websocket.create_connection(url, timeout=8)
            d = json.loads(ws.recv())
            ws.close()
            code = d.get('code')
            print('  %-22s code=%-5s %-28s %s'
                  % (eng, code, desc, str(d.get('message'))[:36]))
            if code == 0:
                ok.append(eng)
        except Exception as e:
            print('  %-22s EXC %s %s' % (eng, type(e).__name__, str(e)[:50]))
        time.sleep(0.25)
    print('-' * 74)
    print('可用引擎: %s' % (', '.join(ok) if ok else '无'))
    if any(e in ('16k_multi_lang', '16k_zh_en', '16k_en_large') for e in ok):
        print('大模型引擎可用 -> 可直接追求「准确要高」')
    else:
        print('大模型引擎全部不可用 -> 需在控制台开通大模型 ASR 后付费 / 购买资源包')
        print('参考: https://cloud.tencent.com/document/product/1093/35686')


if __name__ == '__main__':
    main()
