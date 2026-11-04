# -*- coding: utf-8 -*-
"""生成设备配置修正后的 plist：
1. model: agnes-3.0-flash -> agnes-2.5-flash（慢模型 29-40s，必然超时）
2. showEnglish: 新增 false（只显示中文译文一行）
3. 删除误加的 replace 键（设备上老版 plutil 把 -replace 的参数当键名写进去了）
4. 保留其余全部配置（apiKey / injectApps / 腾讯云密钥 / 位置等）
"""
import io, re, sys

SRC = sys.argv[1] if len(sys.argv) > 1 else '/tmp/lc_cfg.xml'
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/lc_cfg_fixed.xml'

s = io.open(SRC, encoding='utf-8').read()

# 1) model 修正
s2 = s.replace('<key>model</key>\n\t<string>agnes-3.0-flash</string>',
               '<key>model</key>\n\t<string>agnes-2.5-flash</string>')
if s2 == s:
    print("  model: 已是 agnes-2.5-flash 或格式不符，跳过")
else:
    s = s2
    print("  model -> agnes-2.5-flash")

# 2) 删除误加的 replace 键
s2 = re.sub(r'\t<key>replace</key>\n\t<string>[^<]*</string>\n', '', s)
if s2 != s:
    s = s2
    print("  删除误加的 replace 键")

# 3) showEnglish -> false（若不存在则插入）
if '<key>showEnglish</key>' in s:
    s = re.sub(r'<key>showEnglish</key>\s*\n\s*<(true|false)\s*/>',
               '<key>showEnglish</key>\n\t<false/>', s)
    print("  showEnglish -> false (已存在)")
else:
    s = s.replace('\t<key>sourceLang</key>',
                  '\t<key>showEnglish</key>\n\t<false/>\n\t<key>sourceLang</key>')
    print("  showEnglish -> false (新增)")

io.open(OUT, 'w', encoding='utf-8', newline='\n').write(s)
print("已写入 %s" % OUT)

# 校验
for k in ['model', 'showEnglish', 'apiKey', 'targetLang']:
    m = re.search(r'<key>' + k + r'</key>\s*\n\s*(<[^>]+>)', s)
    print("  校验 %-12s -> %s" % (k, m.group(1) if m else '缺失'))
