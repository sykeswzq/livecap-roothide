# LiveCap-Roothide — 任意App实时视频字幕翻译 tweak

抓取 **AVPlayer 系 App** 的音频 → iOS 原生 `SFSpeechRecognizer` 实时转写 → **OpenAI 兼容接口**翻译 → 悬浮双语字幕。

- 兼容：Dopamine2 / Roothide（iOS 15.0–16.x，arm64e）
- 无根 deb，`Pre-Depends: rootless-compat`
- **v1.0.32 新增：输出静音/禁音时也显示字幕**

## 安装

1. `dpkg -i com.sykes.livecap_*.deb`（或 Sileo/Zebra 安装）
2. **必须在 Dopamine → Inject Manager 里勾选目标 App**（白名单注入）
3. 完全杀掉目标 App 再打开（不要只切换后台）

## 配置

设置 → 实时字幕翻译：

- 总开关 / 翻译开关
- 识别语言：en-US / zh-CN / ja-JP / ko-KR（默认英语）
- 翻译目标语言（默认简体中文）
- **自定义翻译 API**：地址（OpenAI 兼容 `/v1`）、Key、模型
- 字号 / 字幕位置（底部 / 顶部）

默认配置在 `/var/mobile/Library/Preferences/com.sykes.livecap.plist`（安装时预写，改面板即覆盖）。

## 支持范围与限制（重要）

| 项 | 说明 |
|---|---|
| 音频源 | 只对使用 **AVPlayer** 播放的 App 生效（YouTube、B站、TikTok、Netflix、Disney+、Hulu、Twitch 等）；自研播放器（IJK/ExoPlayer 系）抓不到 |
| **静音/禁音字幕** | **v1.0.32 新增**：tap 改为 PreEffects（音量斜坡之前取音频），App 静音时 ASR 仍能拿到全幅音频，字幕不消失 |
| 语音识别 | 用 iOS `SFSpeechRecognizer`。授权是**跨App共享**的：目标 App 自己带语音识别权限（如 YouTube）即可用；若目标 App 无此权限，先去 **系统设置 → 隐私 → 语音识别** 确认已授权过任意 App |
| 翻译 | 需要网络，走配置的 API；partial 结果 1s 节流防抖，相同文本走缓存 |
| Filter 白名单 | 内置主流视频 App 包名；要加 App：编辑 `/var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist` 的 Filter.Bundles 加包名，然后 `killall runningboardd` |

## 日志

`/tmp/livecap.log`（Filza 可见 `/tmp`）：注入、tap 挂载、识别、翻译请求都打点，排障先看它。

## 构建

GitHub Actions（macos-latest）自动构建并校验，本地也可：

```bash
bash build.sh
python verify_deb.py com.sykes.livecap_*_iphoneos-arm64e.deb
```

## 提示

- 换配置（语言/API/字号）后**完全退出目标 App 再打开**生效
- SFSpeech 为在线识别，弱网下延迟会变高
- **静音字幕**：App 内部静音（volume=0/muted=YES）时字幕仍会出现；但如果 App 完全不输出音频（无声轨），ASR 无法识别，这是物理限制
