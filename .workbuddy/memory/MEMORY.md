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
- [ ] 可选：清理设备旧配置 plist 里 v1 遗留键（v2.0.0 不读取，无害）
