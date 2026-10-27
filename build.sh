#!/bin/bash
# build.sh - LiveCap roothide 实时字幕翻译 tweak 单 DEB 构建
# 范式对齐 XL-Roothide / UCS-roothide：
#   1) dylib 单 arm64e，install_name=@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib
#   2) -undefined dynamic_lookup（符号运行时解析）
#   3) ldid -M -S 签名
#   4) PreferenceBundle 双 slice(arm64+arm64e) + PreferenceLoader 入口
#   5) dpkg-deb -b -Zxz
set -euo pipefail
cd "$(dirname "$0")"

PKG=com.sykes.livecap
NAME="实时字幕翻译"
VER=1.0.3
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
  -dynamiclib -fobjc-arc \
  -undefined dynamic_lookup \
  -install_name "$NEWID" \
  -framework UIKit -framework Foundation -framework AVFoundation \
  -framework Speech -framework MediaToolbox -framework AudioToolbox -framework CoreGraphics \
  -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib" \
  LiveCap.m
chmod 755 "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib"
cp LiveCap.plist "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist"
chmod 666 "$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.plist"

echo "[2/4] compile preference bundle (arm64 + arm64e)"
xcrun --sdk iphoneos clang \
  -bundle -fobjc-arc -undefined dynamic_lookup \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs" \
  PrefBundle/LiveCapPrefs.m PrefBundle/LiveCapAppListController.m PrefBundle/LiveCapColorController.m
chmod 755 "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs"
cp PrefBundle/Info.plist "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/Info.plist"
cp PrefBundle/Root.plist "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/Root.plist"
cp PrefLoader.plist "$STAGE/Library/PreferenceLoader/Preferences/LiveCap.plist"

echo "[3/4] verify install name + ldid + Mach-O header"
DL="$STAGE/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib"
IDS="$(otool -D "$DL" | grep -v 'architecture' | grep -v '^$' | sort -u)"
echo "  install name: $IDS"
echo "$IDS" | grep -q "@loader_path/.jbroot" \
  || { echo "ERROR: LC_ID_DYLIB bad: $IDS"; exit 1; }

ldid -M -S "$DL"
ldid -M -S "$STAGE/Library/PreferenceBundles/LiveCapPrefs.bundle/LiveCapPrefs"
PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
[ -n "$PY" ] || { echo "ERROR: python not found"; exit 1; }
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
Description: 任意App实时视频字幕翻译。抓取 AVPlayer 系 App 的音频，SFSpeech 实时转写 + OpenAI 兼容接口翻译，悬浮双语字幕。兼容 Dopamine2-roothide 白名单注入。目标App需在 Dopamine Inject Manager 白名单勾选。
EOF
cp postinst pkg/DEBIAN/postinst
cp postrm pkg/DEBIAN/postrm
chmod 755 pkg/DEBIAN/postinst pkg/DEBIAN/postrm

cp -a "$STAGE/." pkg/
dpkg-deb -b -Zxz pkg "$OUT"
echo "  -> $(wc -c < "$OUT") bytes"
echo "BUILD_OK $OUT"
