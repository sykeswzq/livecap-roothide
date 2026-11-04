#!/bin/bash
# LiveCap v1.0.77 installation script for Dopamine 2.x rootless
set -e

echo "=== LiveCap v1.0.77 Installation ==="

# Paths
DEB_PATH="/tmp/LiveCap_v1.0.77.deb"
INSTALL_DIR="/usr/lib/TweakInject"
JB_DIR="/var/jb/usr/lib/TweakInject"

# Extract DEB
echo "[1/5] Extracting DEB..."
cd /tmp
mkdir -p livecap_extract
cd livecap_extract
python3 -c "
import tarfile, io, lzma, os

with open('$DEB_PATH', 'rb') as f:
    data = f.read()

# Parse ar format
pos = 8  # Skip !<arch>\n
if data[pos:pos+1] == b'/':
    end = data.find(b'\n', pos)
    ext_header_size = int(data[pos+1:end].decode())
    pos = end + 1 + ext_header_size
    if pos % 2 != 0:
        pos += 1

files = {}
while pos < len(data):
    if pos + 60 > len(data):
        break
    header = data[pos:pos+60]
    magic = header[58:60]
    if magic != b'\x60\n':
        break
    name = header[0:16].decode('ascii', errors='replace').strip()
    size = int(header[48:58].decode('ascii').strip())
    if size % 2 != 0:
        size += 1
    content_start = pos + 60
    files[name] = data[content_start:content_start+size]
    pos = content_start + size

# Extract data.tar.xz
if 'data.tar.xz' in files:
    import tarfile
    data_data = lzma.decompress(files['data.tar.xz'])
    with tarfile.open(fileobj=io.BytesIO(data_data), mode='r') as tar:
        tar.extractall('.')
    print('Extracted data.tar.xz')

# Extract control.tar.xz
if 'control.tar.xz' in files:
    import tarfile
    control_data = lzma.decompress(files['control.tar.xz'])
    with tarfile.open(fileobj=io.BytesIO(control_data), mode='r') as tar:
        tar.extractall('.')
    print('Extracted control.tar.xz')
"

# Install files
echo "[2/5] Installing files..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$JB_DIR"

# Copy dylib
cp livecap_extract/Library/MobileSubstrate/DynamicLibraries/LiveCap.dylib "$INSTALL_DIR/"
chmod 755 "$INSTALL_DIR/LiveCap.dylib"

# Create roothidepatch symlink
ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib "$INSTALL_DIR/LiveCap.dylib.roothidepatch"

# Copy plist (fix it during install)
cat > "$INSTALL_DIR/LiveCap.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Filter</key>
	<dict>
		<key>Bundles</key>
		<array>
			<string>com.google.ios.youtube</string>
			<string>com.bilibili.app.blue</string>
			<string>com.bilibili.app.in</string>
			<string>com.ss.android.ugc.aweme</string>
			<string>com.ss.android.ugc.aweme.lite</string>
			<string>com.netflix.Netflix</string>
			<string>com.hulu.plus</string>
			<string>com.hbo.hbonow</string>
			<string>com.amazon.avod.thirdpartyclient</string>
			<string>com.disney.disneyplus</string>
			<string>com.apple.tv</string>
			<string>tv.twitch.android.app</string>
			<string>com.google.android.youtube.music</string>
			<string>com.baidu.iapp.video</string>
			<string>com.iqiyi.i18n</string>
			<string>com.iqiyi.video</string>
			<string>com.youku.youku</string>
			<string>com.tencent.qqlive</string>
			<string>com.sohu.svplayer</string>
			<string>cn.wanshizheng.pinshipin</string>
			<string>com.apple.mobilepodcasts</string>
			<string>com.vimeo.vimeo</string>
			<string>com.dailymotion.dailymotion-app</string>
			<string>com.pandora.android</string>
			<string>com.spotify.client</string>
			<string>com.soundcloud.android</string>
			<string>com.tencent.tmgp.sgame</string>
			<string>com.miHoYo.Yuushen</string>
		</array>
		<key>Executables</key>
		<array>
			<string>YouTube</string>
			<string>TikTok</string>
			<string>WeChat</string>
			<string>BillBill</string>
		</array>
	</dict>
</dict>
</plist>
PLISTEOF
chmod 666 "$INSTALL_DIR/LiveCap.plist"

# Sign dylib
echo "[3/5] Signing dylib..."
ldid -s "$INSTALL_DIR/LiveCap.dylib"

# Add to trustcache
echo "[4/5] Adding to trustcache..."
jbctl trustcache add "$INSTALL_DIR/LiveCap.dylib" 2>&1 || echo "trustcache add failed (may already exist)"

# Update InjectManager whitelist
echo "[5/5] Updating InjectManager whitelist..."
cat > /Library/Preferences/com.dopamine2.InjectManager.plist << 'WLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Whitelist</key>
	<array>
		<string>com.google.ios.youtube</string>
		<string>com.bilibili.app.blue</string>
		<string>com.bilibili.app.in</string>
		<string>com.ss.android.ugc.aweme</string>
		<string>com.ss.android.ugc.aweme.lite</string>
		<string>com.netflix.Netflix</string>
		<string>com.hulu.plus</string>
		<string>com.hbo.hbonow</string>
		<string>com.amazon.avod.thirdpartyclient</string>
		<string>com.disney.disneyplus</string>
		<string>com.apple.tv</string>
		<string>tv.twitch.android.app</string>
		<string>com.google.android.youtube.music</string>
		<string>com.baidu.iapp.video</string>
		<string>com.iqiyi.i18n</string>
		<string>com.iqiyi.video</string>
		<string>com.youku.youku</string>
		<string>com.tencent.qqlive</string>
		<string>com.sohu.svplayer</string>
		<string>cn.wanshizheng.pinshipin</string>
		<string>com.apple.mobilepodcasts</string>
		<string>com.vimeo.vimeo</string>
		<string>com.dailymotion.dailymotion-app</string>
		<string>com.pandora.android</string>
		<string>com.spotify.client</string>
		<string>com.soundcloud.android</string>
		<string>com.tencent.tmgp.sgame</string>
		<string>com.miHoYo.Yuushen</string>
	</array>
</dict>
</plist>
WLEOF

# Cleanup
rm -rf /tmp/livecap_extract

echo ""
echo "=== Installation Complete ==="
echo "Files installed:"
ls -la "$INSTALL_DIR/LiveCap*"
echo ""
echo "Next steps:"
echo "1. Open Dopamine app and click 'Jailbreak' or 'Jailbreak Again'"
echo "2. Open YouTube"
echo "3. Check constructor log: cat /var/mobile/Documents/livecap_ctor.log"
