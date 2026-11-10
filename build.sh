#!/bin/bash
# build.sh - LiveCap roothide 实时字幕翻译 tweak 单 DEB 构建
# 范式对齐 XL-Roothide / UCS-roothide：
#   1) dylib 单 arm64e，install_name=@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib
#   2) -undefined dynamic_lookup（符号运行时解析）
#   3) ldid -M -S 签名
#   4) PreferenceBundle 双 slice(arm64+arm64e) + PreferenceLoader 入口
#   5) dpkg-deb -b -Zxz
set -eu
cd "$(dirname "$0")"

PKG=com.sykes.livecap
NAME="实时字幕翻译"
VER=2.2.1
ARCH="iphoneos-arm64e"
OUT="${PKG}_${VER}_${ARCH}.deb"
NEWID="@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib"
rm -f "$OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "iPhoneOS SDK: $SDK"
command -v ldid >/dev/null 2>&1 || { echo "ERROR: ldid not installed"; exit 1; }

STAGE=build
rm -rf "$STAGE" pkg
mkdir -p "$STAGE/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle"
mkdir -p "$STAGE/Library/PreferenceLoader/Preferences"

echo "[1/4] compile tweak dylib (arm64e)"
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc -finput-charset=UTF-8 -fexec-charset=UTF-8 \
  -undefined dynamic_lookup \
  -install_name "$NEWID" \
  -framework UIKit -framework Foundation -framework AVFoundation \
  -framework Speech -framework MediaToolbox -framework AudioToolbox -framework CoreGraphics \
  -framework CFNetwork \
  -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib" \
  LiveCap.m fishhook.c
chmod 755 "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib"
ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib.roothidepatch"
cp LiveCap.plist "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist"
chmod 666 "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist"

echo "[2/4] compile preference bundle (arm64 + arm64e)"
xcrun --sdk iphoneos clang \
  -bundle -fobjc-arc -finput-charset=UTF-8 -fexec-charset=UTF-8 \
  -undefined dynamic_lookup \
  -framework CoreFoundation -framework Foundation -framework UIKit -framework CoreGraphics \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs" \
  PrefBundle/LiveCapPrefs.m PrefBundle/LiveCapAppListController.m
chmod 755 "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs"
cp PrefBundle/Info.plist "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/Info.plist"
cp PrefLoader.plist "$STAGE/Library/PreferenceLoader/Preferences/LiveCap.plist"

echo "[3/4] verify install name + ldid + Mach-O header"
DL="$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib"
PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
[ -n "$PY" ] || { echo "ERROR: python not found"; exit 1; }

# ===== 关键：install_name 必须在 ldid 签名【之前】确定 =====
# 原因：ldid -S 会重写 Mach-O 的 LC_CODE_SIGNATURE / __LINKEDIT 布局。
# 如果签名后再改 header（LC_ID_DYLIB.name offset / __LINKEDIT.filesize），
# 这些字节落在 CodeDirectory 哈希覆盖范围内 → 签名失效，
# 设备端加载报 "code signature invalid (errno=85)"，tweak 静默不注入、无日志。
#
# 顺序：install_name_tool（原生工具，未签名状态下改 header 安全）→ ldid 签名 → 校验
echo "  set install_name (BEFORE signing)"
install_name_tool -id "$NEWID" "$DL" 2>/dev/null || true
IDS="$(otool -D "$DL" | grep -v 'architecture' | grep -v '^$' | sort -u)"
echo "  install name after install_name_tool: $IDS"
echo "$IDS" | grep -q "@loader_path/.jbroot" \
  || { echo "ERROR: LC_ID_DYLIB bad: $IDS"; exit 1; }

echo "  ldid sign"
ldid -M -S "$DL"
# 签名后复核 install_name：若 ldid 破坏了它，用 patch_machO.py 修复后【重新签名】
IDS="$(otool -D "$DL" | grep -v 'architecture' | grep -v '^$' | sort -u)"
echo "  install name after ldid: $IDS"
if ! echo "$IDS" | grep -q "@loader_path/.jbroot"; then
  echo "  ldid altered install_name -> patch + RE-SIGN"
  $PY "$PWD/patch_machO.py" "$DL" "$NEWID" \
    || { echo "ERROR: patch_machO.py failed"; exit 1; }
  ldid -M -S "$DL"
  IDS="$(otool -D "$DL" | grep -v 'architecture' | grep -v '^$' | sort -u)"
  echo "  install name after re-sign: $IDS"
  echo "$IDS" | grep -q "@loader_path/.jbroot" \
    || { echo "ERROR: LC_ID_DYLIB bad after re-sign: $IDS"; exit 1; }
fi

# 签名有效性硬校验：重算 CodeDirectory 页哈希，与文件实际内容比对
echo "  verify code signature (recompute CodeDirectory page hashes)"
$PY "$PWD/verify_signature.py" "$DL" \
  || { echo "ERROR: dylib code signature invalid"; exit 1; }

ldid -M -S "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs"
$PY "$PWD/verify_signature.py" "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs" \
  || { echo "ERROR: PrefBundle code signature invalid"; exit 1; }
for f in "$DL" "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs"; do
  m="$($PY -c 'import sys;d=open(sys.argv[1],"rb").read(4);print(d.hex())' "$f")"
  [ "$m" = "cafebabe" ] || [ "$m" = "cffaedfe" ] || { echo "ERROR: Mach-O bad magic=$m"; exit 1; }
done

echo "[4/4] control + postinst/postrm + build deb"
mkdir -p pkg/DEBIAN
cat > pkg/DEBIAN/control <<EOF
Package: $PKG
Name: $NAME
Version: $VER
Architecture: $ARCH
Depends: mobilesubstrate, preferenceloader, firmware (>= 13.0)
Pre-Depends: rootless-compat (>= 0.9)
Maintainer: sykes
Author: sykes
Section: Tweaks
Priority: optional
Description: 任意App实时视频字幕翻译。抓取 AVPlayer 系 App 的音频，腾讯云一句话识别（在线 ASR，无需iOS授权）转写 + OpenAI 兼容接口翻译，悬浮双语字幕。兼容 Dopamine2-roothide 白名单注入。目标App需在 Dopamine Inject Manager 白名单勾选。
EOF
cp postinst pkg/DEBIAN/postinst
cp postrm pkg/DEBIAN/postrm
chmod 755 pkg/DEBIAN/postinst pkg/DEBIAN/postrm

cp -a "$STAGE/." pkg/
dpkg-deb -b -Zxz pkg "$OUT"
echo "  -> $(wc -c < "$OUT") bytes"
echo "BUILD_OK $OUT"
