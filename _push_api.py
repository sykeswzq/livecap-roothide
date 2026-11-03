import base64
import json
import os
import sys
import urllib.request

REPO = 'sykeswzq/livecap-roothide'
BASE = 'https://api.github.com/repos/' + REPO
TOKEN = os.environ['GH_TOKEN']

MSG = """v1.0.72: 修复 AAC 解码的两个 -50 根因（离线模拟验证）

## 根因 A: 输出请求帧数 > 输入能提供的帧数 -> 转换器二次回调输入 -> -50
离线模拟(10 个 AAC 包, 每包 1024 帧):
  outCapacity = totalSamples*8 + maxOut*8 = 114688 字节  (多留了 32768 余量)
  outNumPackets = outCapacity/8 = 14336 帧
  实际可产出 = 10 * 1024 = 10240 帧
  -> 缺口 4096 帧 -> 转换器再次回调输入 -> 输入已耗尽(返回0包)
  -> AudioConverter 判定输入不完整 -> -50 InvalidInputSize

修复:
1. outCapacity 去掉 maxOut*8 余量，严格按 totalSamples*bytesPerFrame
2. outNumPackets 取 min(容量帧数, totalSamples)，绝不超出实际可解出的帧数
3. 新增日志 audio: dec req pkts=%u realFrames=%u cap=%u 便于对拍

## 根因 B: 输入回调里 packet 描述的偏移基准错误
AudioConverterFillComplexBuffer 的输入回调中，
packet description 的 mStartOffset 是【相对于 mData 指针】的偏移；
我们把 mData 指向 in->data + startOff(已跳过前面的包)，
却交出 mStartOffset 为【绝对偏移】的描述数组
-> 转换器按 (in->data+startOff)+mStartOffset 取数据 -> 偏移重复累加 -> 读到垃圾
-> 第一次调用 startOff=0 恰好正确，之后全错
-> 这正是历史上「只解出 2048 帧(20%)」的确切原因

修复: 每次只交 1 个包，mData 指向该包真实起点，
      同时把该包的 mStartOffset 归零 —— 两者基准一致。
      并加越界保护(absOff+absLen > dataLen 时停止喂数据)。

## 保留 v1.0.71 的修复
- install 时立即 layoutInitialFrame，字幕框与拖动把手不再依赖 ASR 才可见
- 把手尺寸统一 26pt

## 三个问题实为同一根因
「没翻译」「字幕框显示英文」「右上没白点/不能移动」全是 AAC 解码失败的下游表现。

版本 1.0.71 -> 1.0.72
"""





FILES = {
    'LiveCap.m': 'LiveCap.m',
    'LiveCap.plist': 'LiveCap.plist',
    'build.sh': 'build.sh',
    'postinst': 'postinst',
    'patch_machO.py': 'patch_machO.py',
    'verify_signature.py': 'verify_signature.py',
    'verify_tc3_signature.py': 'verify_tc3_signature.py',
    'verify_asr_params.py': 'verify_asr_params.py',
    'verify_source_safety.py': 'verify_source_safety.py',
    '.github/workflows/build.yml': '.github/workflows/build.yml',
    'PrefBundle/Info.plist': 'PrefBundle/Info.plist',
}

EXEC_FILES = ('build.sh', 'postinst', 'patch_machO.py',
              'verify_signature.py', 'verify_tc3_signature.py',
              'verify_asr_params.py')


def api(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header('Authorization', 'token ' + TOKEN)
    req.add_header('Content-Type', 'application/json')
    req.add_header('User-Agent', 'workbuddy')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        print('HTTP', e.code, e.read().decode()[:500])
        sys.exit(1)


def main():
    ref = api('GET', '/git/ref/heads/main')
    base_sha = ref['object']['sha']
    base = api('GET', '/git/commits/' + base_sha)
    base_tree = base['tree']['sha']
    print('base:', base_sha[:7])

    entries = []
    for remote_path, local_path in FILES.items():
        with open(local_path, 'rb') as f:
            content = f.read()
        b = api('POST', '/git/blobs', {
            'content': base64.b64encode(content).decode(),
            'encoding': 'base64',
        })
        mode = '100755' if remote_path in EXEC_FILES else '100644'
        entries.append({'path': remote_path, 'mode': mode,
                        'type': 'blob', 'sha': b['sha']})
        print('blob', remote_path, b['sha'][:7])

    tree = api('POST', '/git/trees', {'base_tree': base_tree, 'tree': entries})
    print('tree:', tree['sha'][:7])

    commit = api('POST', '/git/commits', {
        'message': MSG, 'tree': tree['sha'], 'parents': [base_sha],
    })
    api('PATCH', '/git/refs/heads/main', {'sha': commit['sha'], 'force': False})
    print('PUSHED ->', commit['sha'][:7])


if __name__ == '__main__':
    main()
