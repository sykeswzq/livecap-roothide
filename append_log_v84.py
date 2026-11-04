#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 v1.0.84 的工作日志追加到 .workbuddy/memory/2026-11-04.md"""
import io

P = r"C:\Users\Administrator\WorkBuddy\ZDFY\.workbuddy\memory\2026-11-04.md"

TEXT = """

---

## v1.0.84 —— 降低翻译延迟 + 修复全屏字幕不显示

用户反馈：「基本可以 然后翻译有点延迟，还有就是全屏的时候字幕框好像显示不出来」

### 根因 A：翻译延迟（100% 在 ASR，不在翻译）
设备日志实证（2207 行）：
```
asr: sending 163512 bytes (16k_multi_lang)   → 5.11 秒音频
asr: text [...]                              → 3~10 秒后返回（RTT avg 5.6s）
translate: mymemory response                 → RTT avg 0.82s
```
翻译只占 0.8 秒，**延迟全在腾讯云 HTTP「一句话识别」**。

**排查过程（全部实测，非猜测）**：

| 实验 | 结论 |
|---|---|
| 本地同凭据同引擎实测 | RTT 仅 0.3~0.6s（设备 4~7s，差 10 倍）|
| 真实语音 vs 合成音对照 | 内容**不是**主因（差异 <0.1s）|
| 人声+背景音乐+降采样失真 | 噪声失真**不是**主因 |
| 16k_multi_lang / 16k_en / 16k_zh | 引擎**不是**主因 |
| 设备 DNS 冷启动 | 3.175s（热缓存 0.1s）|

→ 设备实测 **RTT ≈ 音频时长 × 1.1**（5.11s→5.6s，7.20s→10s）

**修复**：
- ASR 分片时长写死 5 秒 → **可配置，默认 2.5 秒**（RTT 近似减半，延迟 ~6s→~3s）
- **两条音频入口路径都要改**：`appendBufferList:` 和 `appendMonoFloat:`
  —— 检查项实测抓出 `appendMonoFloat:` 漏改（YouTube 自研播放器走这条！）
- 新增**毫秒级 RTT 打点**（设备日志只有秒级精度，无法区分网络/服务端）

### 根因 B：全屏字幕不显示
日志证据：`overlay: layout c=(1,240,381,58) ... super={{0, 0}, {393, 852}}`
→ 字幕挂在 install 时的 keyWindow，bounds 是**竖屏** 393x852。

三种情况全部覆盖：
1. **同 window present 全屏 VC** → VC 的 view 加到 `window.subviews` 末尾（最上层）盖住字幕
   → 修复：每次渲染前 `[parent bringSubviewToFront:_container]`
2. **全屏新建 window** → 字幕留在旧 window 被完全盖住
   → 修复：`bestHostWindow` / `ensureInBestWindow` + 监听 `UIWindowDidBecomeKeyNotification`
3. **旋转后跑出屏幕** → `_userCenter` 是绝对坐标，竖屏 (189,320) 转横屏后 y 超界
   → 修复：把 container **钳制**在宿主 bounds 内

### 面板
新增「识别分片」选项（1.5/2.5/3.5/5.0 秒），用户自行权衡延迟 vs 句子完整度。
注意：新增行必须同步 `numberOfRowsInSection`（section 2 由 5 改 6），否则 cell 不显示。

### ⚠️ 静态检查的严重教训（本次最重要收获）
v1.0.84 检查项初版用**全文件字符串搜索**关键词 → 注释里提到关键词就误判通过。

**双向验证实测**：移除 `bringSubviewToFront` / 位置钳制 / `ensureInBestWindow`
三个回归，检查脚本**全部没拦住** → 检查形同虚设。

**修正要点**：
- 必须在**剥离注释后的代码**里匹配（复用 `scan_compile_risk.py` 的 `strip_comments_strings`）
- `ensureInBestWindow` 要求 **≥2 处**调用（渲染时 + key window 变化时）
- `chunkSecs` 要求**两条音频入口路径**都改（实测抓出 `appendMonoFloat:` 漏改）
- RTT 打点在**日志格式串**里，字符串字面量会被剥离 → 该项要在原始源码中匹配

**铁律**：写静态检查脚本必须双向验证（修复版通过 + 注入 bug 须被准确拦截），
否则检查脚本可能形同虚设 —— 本次差点又白跑一轮 CI。

### 工具（新增）
- `test_asr_rtt.py` —— 腾讯云 ASR「音频长度 vs RTT」实测（用真实凭据）
- `test_asr_content_effect.py` —— 真实语音 vs 合成音对照
- `test_asr_noise_effect.py` —— 噪声/失真/多引擎对照
- `test_v84_verify.py` —— v1.0.84 双向验证（5 个回归全部被拦截）

### 环境事实补充
- 设备老 plutil **支持 `-type real -value 2.5 -key K <file>`** ✅（真机验证，写出 `<real>2.5</real>`）
- 设备无 curl/ping/python/nslookup，只有 `getent`（可测 DNS，冷启动 3.175s）
- Windows 无 TTS 权限（PowerShell `Add-Type` 与 COM 均被安全策略拦），
  改用 `https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0010_8k.wav` 拿真实语音样本
"""


def main():
    s = io.open(P, encoding="utf-8").read()
    if "## v1.0.84" in s:
        print("已存在 v1.0.84 段落，跳过")
        return 0
    if not s.endswith("\n"):
        s += "\n"
    io.open(P, "w", encoding="utf-8", newline="\n").write(s + TEXT)
    print("已追加 v1.0.84 工作日志")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
