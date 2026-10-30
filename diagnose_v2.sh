#!/bin/bash
# LiveCap 注入诊断脚本 v2
# 在 iPhone 上执行（SSH 或 Filza 终端）

echo "=========================================="
echo "  LiveCap 注入诊断 v1.0.49"
echo "=========================================="
echo ""

# 1. 检查安装日志
echo "【1】安装日志"
if [ -f /var/mobile/Documents/livecap_install.log ]; then
    echo "✓ install.log 存在"
    cat /var/mobile/Documents/livecap_install.log
else
    echo "✗ install.log 不存在 → postinst 未执行"
fi
echo ""

# 2. 检查 ctor 日志
echo "【2】构造函数日志"
if [ -f /var/mobile/Documents/livecap_ctor.log ]; then
    echo "✓ ctor.log 存在 → dylib 已注入!"
    cat /var/mobile/Documents/livecap_ctor.log
else
    echo "✗ ctor.log 不存在 → dylib 未注入任何进程"
fi
echo ""

# 3. 检查 dylib 文件和权限
echo "【3】dylib 文件检查"
DYLIB="/var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib"
if [ -f "$DYLIB" ]; then
    echo "✓ 文件存在"
    ls -la "$DYLIB"
    OWNER=$(ls -l "$DYLIB" | awk '{print $3":"$4}')
    if [ "$OWNER" = "mobile:staff" ]; then
        echo "✓ 权限正确: mobile:staff"
    else
        echo "✗ 权限错误: $OWNER (应该是 mobile:staff)"
        echo "  修复: sudo chown mobile:staff $DYLIB"
    fi
else
    echo "✗ 文件不存在!"
fi
echo ""

# 4. 检查 plist 过滤器
echo "【4】Filter 配置"
PLIST="/var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist"
if [ -f "$PLIST" ]; then
    echo "✓ LiveCap.plist 存在"
    grep -A1 "com.google.ios.youtube" "$PLIST" && echo "✓ YouTube 在 Filter 中" || echo "✗ YouTube 不在 Filter 中"
else
    echo "✗ LiveCap.plist 不存在"
fi
echo ""

# 5. 检查 Dopamine InjectManager 白名单
echo "【5】InjectManager 白名单"
INJECTMgr="/var/jb/Library/Preferences/com.dopamine2.InjectManager.plist"
if [ -f "$INJECTMgr" ]; then
    echo "✓ InjectManager 存在"
    echo "当前白名单:"
    plutil -p "$INJECTMgr" 2>/dev/null | grep -E "com\.(google|bilibili|ss)" | head -10
    # 检查 YouTube
    if plutil -p "$INJECTMgr" 2>/dev/null | grep -q "com.google.ios.youtube"; then
        echo "✓ YouTube 在白名单中"
    else
        echo "✗ YouTube 不在白名单中!"
        echo "  修复: 在 Dopamine 设置中手动添加 com.google.ios.youtube"
    fi
else
    echo "✗ InjectManager.plist 不存在"
fi
echo ""

# 6. 检查 mediaserverd 状态
echo "【6】mediaserverd 状态"
if pgrep -x mediaserverd > /dev/null; then
    echo "✓ mediaserverd 正在运行 (PID: $(pgrep -x mediaserverd))"
else
    echo "✗ mediaserverd 未运行"
fi

if [ -f /var/log/livecap_media.log ]; then
    echo "✓ mediaserverd 日志存在"
    tail -5 /var/log/livecap_media.log
else
    echo "✗ mediaserverd 日志不存在"
fi
echo ""

# 7. 列出所有已安装的 tweaks
echo "【7】已安装的 tweaks"
ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/*.dylib 2>/dev/null | head -20
echo ""

# 8. 检查 App 列表
echo "【8】目标 App 白名单"
echo "Filter 包含的 App:"
plutil -extract Filter.Bundles raw "$PLIST" 2>/dev/null | tr ',' '\n' | grep -o '"[^"]*"' | tr -d '"' | head -10
echo ""

echo "=========================================="
echo "诊断完成"
echo "=========================================="
