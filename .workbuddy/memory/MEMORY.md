# LiveCap roothide tweak - 项目记忆

## 关键构建教训

### CoreFoundation framework 必须显式链接
- **踩坑记录**: v2.0.0 使用 CFPreferences API（SetAppValue/AppSynchronize/__bridge CFStringRef）但 build.sh 未加 `-framework CoreFoundation`
- **症状**: CI Build 步骤在 ~6 秒内快速失败（链接器错误）
- **修复**: 第 52 行追加 `-framework CoreFoundation`
- **规则**: 只要代码中出现 `CF*`、`__bridge`、`NSTimer` 等 API，必须在 clang 命令中链接对应 framework

### 验证脚本局限
- `verify_source_safety.py`, `scan_compile_risk.py`, `test_v*.py` 仅检查源码语法/逻辑
- **无法检测**框架链接缺失、符号未定义等链接期错误
- 必须依赖 CI 环境真实编译才能发现此类问题

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

## 部署目标
- 设备 IP: `10.10.201.107`
- iOS: Dopamine Rootless + Sileo
- 架构: iphoneos-arm64e

## 待办事项
- [ ] GitHub Actions CI 构建成功后下载 `.deb` 并部署到设备
- [ ] 重启 SpringBoard 测试字幕翻译功能
- [ ] 验证字号调节 UI 是否正常工作
