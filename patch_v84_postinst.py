#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""postinst 补丁：新增 asrChunkSeconds 默认值

v1.0.84：ASR 分片时长默认 2.5 秒（延迟从 ~6s 降到 ~3s）。
只在键【不存在】时写入，不覆盖用户已改过的值。
"""
import io

P = "postinst"


def main():
    s = io.open(P, encoding="utf-8").read()
    orig = s

    # 1) 默认 plist 里加键
    old = """	<key>showBilingual</key>
	<false/>"""
    new = """	<key>showBilingual</key>
	<false/>
	<key>asrChunkSeconds</key>
	<real>2.5</real>"""
    if old not in s:
        print("  [FAIL] 默认 plist 锚点未找到")
        return 1
    s = s.replace(old, new, 1)
    print("  [OK] 默认 plist 加 asrChunkSeconds=2.5")

    # 2) postinst 里确保已存在的配置也有该键
    old2 = """# ===== v1.0.83：配置键迁移（showEnglish → showBilingual）====="""
    new2 = """# ===== v1.0.84：ASR 分片时长默认值 =====
# 依据：设备日志实测 ASR RTT ≈ 音频时长 × 1.1（5.11s→5.6s，7.2s→10s），
# 分片越长字幕延迟越大。默认 2.5 秒 → RTT 约 2.8 秒。
# 只在键不存在时写入（不覆盖用户已改过的值）。
if [ -f "$CFG" ]; then
  if ! plutil -convert xml1 "$CFG" 2>>"$LOG"; then
    echo "WARNING: plutil convert failed, asrChunkSeconds default skipped" >> "$LOG"
  else
    if ! grep -q "<key>asrChunkSeconds</key>" "$CFG" 2>/dev/null; then
      plutil -type real -value 2.5 -key asrChunkSeconds "$CFG" 2>>"$LOG" \\
        && echo "config: asrChunkSeconds default 2.5" >> "$LOG" \\
        || echo "WARNING: write asrChunkSeconds failed" >> "$LOG"
    fi
    plutil -convert binary1 "$CFG" 2>>"$LOG"
  fi
fi

# ===== v1.0.83：配置键迁移（showEnglish → showBilingual）====="""
    if old2 not in s:
        print("  [FAIL] postinst 迁移段锚点未找到")
        return 1
    s = s.replace(old2, new2, 1)
    print("  [OK] postinst 增加 asrChunkSeconds 默认值写入")

    if s == orig:
        print("无改动")
        return 1
    io.open(P, "w", encoding="utf-8", newline="\n").write(s)
    print("\n已写入 postinst")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
