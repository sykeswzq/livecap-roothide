#!/bin/sh
# LiveCap 注入诊断脚本
# 在 iPhone 上执行此脚本，检查注入状态

echo "=== LiveCap 注入诊断 ==="
echo "时间: $(date)"
echo ""

# 1. 检查 dylib 是否存在及权限
echo "--- [1] dylib 文件 ---"
ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib 2>/dev/null || echo "NOT FOUND at /var/jb/..."
ls -la /Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib 2>/dev/null || echo "NOT FOUND at /Library/..."
echo ""

# 2. 检查 plist 过滤器
echo "--- [2] LiveCap.plist ---"
cat /var/jb/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist 2>/dev/null | head -30
echo ""

# 3. 检查 InjectManager 白名单
echo "--- [3] Dopamine InjectManager ---"
cat /var/jb/Library/Preferences/com.dopamine2.InjectManager.plist 2>/dev/null || echo "NOT FOUND"
echo ""

# 4. 检查 LiveCap 配置
echo "--- [4] LiveCap 配置 ---"
cat /var/mobile/Library/Preferences/com.sykes.livecap.plist 2>/dev/null
echo ""

# 5. 检查日志
echo "--- [5] 日志文件 ---"
ls -la /var/mobile/Documents/livecap*.log 2>/dev/null || echo "无日志"
cat /var/mobile/Documents/livecap_ctor.log 2>/dev/null || echo "ctor.log 不存在"
cat /var/mobile/Documents/livecap.log 2>/dev/null | tail -20 || echo "livecap.log 不存在或为空"
echo ""

# 6. 检查 mediaserverd
echo "--- [6] mediaserverd ---"
ps aux | grep mediaserverd | grep -v grep
ls -la /var/log/livecap_media.log 2>/dev/null || echo "mediaserverd 日志不存在"
echo ""

# 7. 检查是否安装了其他正常工作的 tweak（对比）
echo "--- [7] 其他 tweaks ---"
ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/*.dylib 2>/dev/null | head -10
echo ""

# 8. 尝试重启 mediaserverd
echo "--- [8] 诊断结果 ---"
if [ -f /var/mobile/Documents/livecap_ctor.log ]; then
    echo "✓ ctor 已调用（dylib 已注入 mediaserverd）"
else
    echo "✗ ctor 未调用（dylib 未注入任何进程）"
    echo ""
    echo "可能原因："
    echo "1. Dopamine InjectManager 未添加 YouTube 白名单"
    echo "2. dylib 权限错误（应为 mobile:staff，非 root:wheel）"
    echo "3. LiveCap.plist 的 Filter.Bundles 未包含 com.google.ios.youtube"
    echo "4. 设备需要重启"
fi

echo ""
echo "=== 诊断完成 ==="
