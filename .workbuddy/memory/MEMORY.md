# LiveCap roothide tweak - 项目记忆

## 关键构建教训

### ⚠️ 更正（2026-11-10）：v2.0.0 CI 连续失败的真实根因
- 早先记的「缺 CoreFoundation framework」「LCJBRootPath 拼写」「CRLF」「M_PI_2」**均为误判**。
- 真实原因全是 v2.0.0 重构遗留的**编译错误**（详见 `2026-11-10.md`）：
  1. 调用点删了 `target:`/`cacheKey:` 参数，但 `raceTranslate:`/`mymemoryTranslate:` 实现签名漏改
  2. 两处 `@"auto-detected"` 误写成裸 C 字符串
  3. 新增字号页 `[_valueLabel centerXAnchor constraint...]` 缺点语法 + 数组类型声明错误
  4. `test_v83_verify.py` 用例3 依赖旧缩进导致假失败
- 修复提交 `7c11084` + `08c9b2d` → Run #42741950126 全绿，已出 v2.0.0 deb 并部署。

### 拿真实 CI 日志（最重要）
- git remote URL 里内嵌有效 PAT；用 `GET /repos/{o}/{r}/actions/runs/{id}/logs` + `-L`
  下载完整日志 ZIP，直接看 `build/6_Build.txt` 的 `error:` 行。
- 旧 PAT 失效时 403/401；`/actions/runs/{id}/jobs` 可能返回陈旧缓存数据，别信。
- **CI 失败第一步就拉日志**，别用源码隔离测试反推（这次为此白跑十余轮）。
- Windows Python 读不到 Git Bash 的 `/tmp`，ZIP 要落到仓库相对路径。

### 验证脚本局限
- `verify_source_safety.py` / `scan_compile_risk.py` / `test_v*.py` 只查已知历史 bug 模式，
  **挡不住 selector 签名不一致、裸 C 字符串、点语法笔误**这类编译期错误
- 本地无 xcrun → 这类错误仍需 CI 真实编译兜底，但必须配合日志 ZIP 快速定位
- 改调用点参数时，必须同步核对方法实现签名与 `@interface` 声明

### iOS Tweak 开发通用要点
1. Windows 本地无法编译 iOS dylib（无 xcrun），CI 往返 3~5 分钟 → 编译期错误靠静态检查提前拦
2. Objective-C `?:` 两侧类型必须一致：`completion ?: [NSNull null]` 直接报错 → 统一用 `id` 承载 + 显式 cast
3. 写静态检查脚本的坑：
   - 正则要匹配方法体第一个 `{`，跨行签名需用 `[^;{]*\{`
   - 扫代码前必须剥离注释行，否则注释里的示例代码造成误报
   - 双向验证：修复版须通过 + 重新注入原始 bug 须被准确拦在正确行号
4. CRLF 换行符在 macOS CI 上可能导致编译失败 → 统一用 LF
5. LCJBRootPath vs LCJbRootPath 大小写敏感 → 必须与 LCPrivate.h 定义完全一致

## 版本历史
- **v1.0.100** (commit 1f65c4b): 移除 XL 依赖，LiveCap 完全独立 ✅
- **v2.0.0** (commits f46ade3→0f7bcac): 
  - 重构：移除 sourceLang/targetLang/asrChunkSeconds，ASR chunk 硬编码为常量 LC_ASR_CHUNK_SECONDS
  - 新增 UI：LCFontSizeController 独立字号调节页（UISlider + 实时预览）
  - 精简：UI 改为 4 组面板（基本/接口/外观/显示选项）
  - 修复：CRLF 转换、LCJBRootPath 拼写错误、CoreFoundation framework 链接
  - **✅ 2026-11-10 修完编译错误后构建成功（Run #42741950126）并部署到设备 v2.0.0**
    - 产物 `releases/com.sykes.livecap_2.0.0_iphoneos-arm64e.deb`（103096 bytes）
    - SSH key：`E:/SynologyDrive/单位/F/wangziqing/00000/ucs_ssh_key`
    - 部署脚本：`python3 deploy_v87.py <deb路径>`（分块上传 + dpkg -i + 校验）

## 部署目标
- 设备 IP: `10.10.201.107`
- iOS: Dopamine Rootless + Sileo
- 架构: iphoneos-arm64e

## 待办事项
- [x] ~~GitHub Actions CI 构建成功后下载 `.deb` 并部署到设备~~（2026-11-10 已完成，v2.0.0）
- [ ] 完全退出 YouTube 后重开，实测中文字幕叠加与翻译延迟
- [ ] 验证 v2.0.0 新增的字号调节页（UISlider 10–40 + 实时预览）
- [x] ~~清理设备旧配置 plist 里 v1 遗留键~~ —— **「v2.0.0 不读取、无害」已证伪**：
  v2.0.2 重新从 plist 读 `asrChunkSeconds`，设备残留的 2.5 会让新的 1.5s 默认分片完全不生效。
  2026-11-10 已用 `fix_chunk_cfg_v202.py` 迁移为 1.5（16 键无丢失、apiKey 保留）。
  **以后任何「重新启用某个旧配置键」的改动，都必须先查设备 plist 是否残留旧值。**
- [ ] 完全退出 YouTube 重开后跑 `verify_v202_latency.py`，确认 v2.0.2 分片 <2.0s、
  端到端从 4.4s 降到约 3.0s（截至 2026-11-10 15:40 尚未重开）

## 当前设备版本
- 设备 `10.10.201.107` 已装 **v2.0.2**（CI Run #42775919469 全绿，commit 41de7bd）。
- 延迟基线（v2.0.1 实测）：端到端 4.4s = 攒音 1.3s + ASR 2.0s + 翻译 1.2s；
  翻译/队列已不是瓶颈，瓶颈在 2.5s 分片与腾讯云 ASR 长尾（p90 4.8s）。
- v2.0.2 改动：分片默认 1.5s 且面板可调、agnes 限流熔断 90s、短片段跳过。

## 架构方向（2026-11-10 已验证，待用户拍板）
- 用户验收标准：**速度要快 + 准确要高**。
- 唯一同时满足的是腾讯云实时 ASR WebSocket（不攒音频、服务端 VAD 语义断句、
  大模型引擎抗噪），**不碰 iOS 授权**。本地 SFSpeech 因 TCC/Info.plist 授权不可用，
  且识别质量更差，不要再往这个方向试。
- 实时 ASR 技术侧已全链路实测通过（握手 210ms / 首字 ~0.7s / final 正常）；
  密钥复用现有 `tencentSecretId`/`tencentSecretKey`，APPID 由 `cam:GetUserAppId` 查得。
- **唯一外部阻塞**：大模型引擎（含 `16k_multi_lang`）在实时接口返回 4004，
  是独立计费项未开通；通用引擎 `16k_en`/`16k_zh` 可用。
- 翻译侧改用免费 `agnes-3.0-flash`（无思维链、不返回空内容），
  但必须保留 ~3s 超时熔断 + 429 退避 + 兜底（3.0 有 17s 级长尾）。
  `agnes-2.5-flash` 是推理模型，256 token 常被思维链吃光导致空译文，应弃用为主力。
- **注意**：一旦切换流式架构，v2.0.2 分片复测即失去意义，不必再等用户重开 App。

## 当前状态（2026-11-10 16:30 更新）
- 用户已选「零成本组合」并已实施交付：设备 `10.10.201.107` 装 **v2.1.0**
  （CI Run #42782771675 全绿，HEAD `ac78d98`）。
- v2.1.0 = 流式 ASR WebSocket（`16k_en` + needvad 语义断句，不攒音频）
  + `agnes-3.0-flash` 主力翻译（2.5s 优先窗口 / 3.5s 超时 / 碎片纠错 prompt）
  + 旧 HTTP 分片链路完整保留作兜底（`streamASR=false` 可一键回退）。
- 配置文件已迁移到 19 键；备份 `releases/device_cfg_before_v210.plist`。
- **唯一待办**：用户完全退出 YouTube 重开后跑 `verify_v210_latency.py`，
  确认 agnes 胜出率 >80% 与端到端延迟。若嫌识别不准，
  去腾讯云控制台开通「实时 ASR 大模型版」后付费，把 `asrEngine` 改成
  `16k_multi_lang` 即可（代码已支持，无需重新编译）。
- 新增通用经验：`NSURLSessionWebSocketTask` 用 `cancelWithCloseCode:reason:`；
  Windows 下脚本改源码必须防 LF→CRLF；新增等效代码要同步收紧防回归断言。
