# LiveCap 事故档案

本文件记录 LiveCap 已发生过的真实事故与根因，供后续排查时快速对照。

---

## 事故 1：微信语音 / 通话无声（v1.0.74 ~ v1.0.85）

**症状**
- 安装 LiveCap 后，微信语音消息点开无声、通话无声
- `launchctl list | grep mediaserverd` 显示退出状态 `-11`（SIGSEGV）
- mediaserverd 处于崩溃循环

**根因**
`LiveCap.plist` 的 `Filter` 里带了 `Executables = mediaserverd`，
把 tweak 注入进了 **iOS 系统媒体服务守护进程**。

`mediaserverd` 负责所有 App 的音频输出与格式协商。在它内部 hook 音频管线
（AVAudioEngine tap / MTAudioProcessingTap）会破坏系统音频路径，
导致 mediaserverd 反复崩溃，所有 App 的音频输出都受影响。

**历史（同一个坑修过又复发）**

| 版本 | 动作 | 结果 |
|---|---|---|
| v1.0.29 | plist 含 `Executables=mediaserverd` | 微信/电话音频崩溃（`runs=21, -11`） |
| v1.0.30 | 移除 mediaserverd（commit `7431db0`） | ✅ 恢复稳定 |
| v1.0.74 | 改 plist 加 `Mode:Any` 时**顺手又加回来**（commit `ba3ac6d`） | 🔴 复发 |
| v1.0.86 | 再次移除 + CI 加反向断言（commit `b1af919`） | ✅ 根治 |

**为什么复发**
CI 的 `Verify deb` 步骤里当时有两条**正向断言在保护这个 bug**：

```bash
[ "$MODE" = "Any" ] || exit 1   # 强制 Mode=Any
... | grep -q "mediaserverd" || exit 1   # 强制包含 mediaserverd
```

任何人想「优化」这段 plist，都会被 CI 要求必须保留 mediaserverd 注入。

**修复要点**
1. `LiveCap.plist`：删除整个 `Executables` 节点，只保留 `Bundles` 白名单
2. `postinst`：不再 `killall mediaserverd`（杀它会中断所有 App 的音频会话）
3. CI `Verify deb`：把正向断言**反转**为反向断言（出现 mediaserverd 就报错）
4. CI 新增独立步骤 `Verify no mediaserverd injection`
5. `verify_source_safety.py` 新增 `check_v86_fixes()` 硬拦
6. `test_v86_verify.py` 双向验证：把 bug 放回去必须被抓到

**注意**
`LiveCap.plist` 里**不能有 XML 注释** —— ElleKit 用 CFPropertyList 解析，
遇到 `<!-- -->` 会导致整个 Filter 解析失败 → tweak 静默不注入、无任何日志。
所以本文档才是记录事故经过的地方。

---

## 事故 2：v1.0.84 编译失败 —— `UIWindowDidChangeFrameNotification` 不存在

**症状**
CI Build 步骤失败：
```
LiveCap.m:1796:28: error: use of undeclared identifier
'UIWindowDidChangeFrameNotification'
```

**根因**
UIKit 根本没有「window frame 变化」这种通知。

**暴露的检查盲区**
此前的静态检查只能查：
- 语法 / 括号配平
- `?:` 两侧类型混用

**查不出「符号不存在」**。这是最危险的一类 —— 写错一个常量名，
本地全绿，CI 才炸。

**修复**
- 改用 `UIDeviceOrientationDidChangeNotification` +
  `UIApplicationDidChangeStatusBarOrientationNotification`
- 新增 `scan_uikit_symbols.py`（UIKit 符号全量白名单）
- 新增 `scan_new_symbols.py`（以已成功编译的版本为基线做差集，
  只看本次新增的符号 —— 「已成功编译过的版本」是最好的符号白名单）
- `verify_source_safety.py` 增加 `INVALID_UIKIT_NOTIFICATIONS` 黑名单

---

## 事故 3：v1.0.85~86 连续 3 轮 CI 失败 —— AudioConverter API 签名

**症状**
```
error: incompatible function pointer types passing
'UInt32 (void *, UInt32 *, void **)' to parameter of type
'AudioConverterComplexInputDataProc'
```

改了返回类型（`size_t` → `UInt32` → `OSStatus`）后仍然失败。

**根因**
`AudioConverterComplexInputDataProc` 的真实原型是 **5 参数**：

```c
typedef OSStatus (*AudioConverterComplexInputDataProc)(
    AudioConverterRef               inAudioConverter,
    UInt32 *                        ioNumberDataPackets,
    AudioBufferList *               ioData,
    AudioStreamPacketDescription ** outDataPacketDescription,
    void *                          inUserData);
```

关键点：
- 第 3 参是 `AudioBufferList *`（要填充成员指向 PCM 数据），**不是 `void **`**
- `AudioConverterFillComplexBuffer` 的**输出不是回调**，
  而是调用者提供的 `AudioBufferList *` 缓冲区，
  写完用 `mBuffers[0].mDataByteSize` 取回实际字节数

**教训**
本仓库 `LiveCap.m` 里**已有一份编译通过、CI 验证过的 AAC 解码实现**
（`LCInputProc` + `LCConvert`）。写新代码前应先在同文件里找现成范式照抄，
而不是照着记忆猜 API 签名。

**防复发**
`check_v86_fixes()` 现在会校验：
- `LCAACInputProc` 的参数个数必须是 5
- 必须含 `AudioBufferList *` 与 `AudioStreamPacketDescription **` 类型
- `AudioConverterFillComplexBuffer` 的输出参数必须是 `outList`/`outABL` 缓冲区

---

## 事故 4：GitHub Push Protection 拦截 —— 仓库内硬编码腾讯云密钥

**症状**
`git push` 被拒：
```
remote: error: The push was rejected because it contains a secret
```

**根因**
`git add -A` 把含真实 SecretID 的本地配置文件（`dev_cfg.xml`）带进了提交。

**修复**
- 密钥改为从环境变量 `TC3_SECRET_ID` / `TC3_SECRET_KEY` 读取
- `dev_cfg*.xml` 加入 `.gitignore`
- `git rm --cached` 从索引移除

**建议**
提交前先跑 `git diff --cached | grep -cE "AKID[0-9A-Za-z]{20,}"` 复查。
