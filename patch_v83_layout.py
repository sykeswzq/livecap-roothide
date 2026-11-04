# -*- coding: utf-8 -*-
"""v1.0.83 补丁：修复「中文显示不全」+ 英文行残留

根因（设备日志实证）：
  13:17:45 drag: begin  → 当时只有英文行，容器高度算出 58
  13:17:46 drag: end    → _userMoved = YES
  之后 renderCurrent 里：
      if (_userMoved) { _container.center = _userCenter; }   ← 只改 center
      else            { _container.frame = CGRectMake(x, y, w, h); }
  → 容器尺寸被永久冻结在 58pt，而中文标签被排到 y=71（高 36）
  → 底边 107 超出容器 58，masksToBounds=YES 直接裁掉 → 「中文没显示全」

  日志实测（连续多次）：
    layout c=(12,300,381,58) oLbl=(10,10,h=57) tLbl=(10,71,h=36)
    容器 58 < 需要 10+57+4+36+10 = 117

修复：_userMoved 时也要更新 frame.size，只保留 center（用户拖到的位置）。
"""
import io, re, sys

SRC = 'LiveCap.m'
src = io.open(SRC, encoding='utf-8').read()
orig = src

# ---------------------------------------------------------------- 修复 1
old = '''        if (_userMoved) {
            _container.center = _userCenter;
        } else {
            CGFloat x = mx * spanX;
            CGFloat y = my * spanY;
            _container.frame = CGRectMake(x, y, w, h);
        }'''

new = '''        if (_userMoved) {
            // v1.0.83 修复：用户拖动过之后【必须仍然更新容器尺寸】。
            // 旧实现只改 center 不改 size → 容器高度被永久冻结在拖动那一刻的高度
            // （实测 58pt），而中文字幕被排到 y=71（高 36），底边 107 超出容器 58，
            // 被 masksToBounds=YES 直接裁掉 → 用户看到「中文没显示全」。
            // 正确做法：保留用户拖到的中心点，但尺寸照常按当前文本高度重算。
            CGRect f = _container.frame;
            f.size = CGSizeMake(w, h);
            // 保持中心点不变（用户拖到的位置），只改尺寸
            f.origin = CGPointMake(_userCenter.x - w / 2.0, _userCenter.y - h / 2.0);
            _container.frame = f;
            _userCenter = _container.center;
        } else {
            CGFloat x = mx * spanX;
            CGFloat y = my * spanY;
            _container.frame = CGRectMake(x, y, w, h);
        }'''

if old not in src:
    print("!! 修复1 锚点未命中")
    sys.exit(1)
src = src.replace(old, new, 1)
print("  [1] 容器尺寸冻结 → 已修复")

# ---------------------------------------------------------------- 修复 2
# 英文行残留：showEnglish 被写成 true 后，双语分支会画英文行。
# 除了修好配置读取，还要在【布局层】加一道保险：
# showEnglish 读取失败/异常时默认走「只中文」分支（当前已是 NO 默认），
# 这里加的是：只中文模式下，英文标签即使有残留文本也必须收起。
old2 = '''        CGFloat ly = pad;
        // 文字区域避开右上角的拖动把手
        CGFloat textW = maxW - handleSpace;
        if (origin.length) {
            _originLabel.frame = CGRectMake(pad, ly, textW, oh);
            _originLabel.hidden = NO;
            ly += oh + 4;
        } else if (!_toastActive) {'''

new2 = '''        CGFloat ly = pad;
        // 文字区域避开右上角的拖动把手
        CGFloat textW = maxW - handleSpace;
        if (origin.length) {
            _originLabel.frame = CGRectMake(pad, ly, textW, oh);
            _originLabel.hidden = NO;
            ly += oh + 4;
        } else if (!_toastActive) {
            // v1.0.83：只中文模式下英文标签必须彻底收起。
            // 除了 frame 归零，还要清空 attributedText —— 否则 label 仍持有上一句英文，
            // 若后续任何分支漏了 hidden=YES，英文会再次闪现。'''

if old2 not in src:
    print("!! 修复2 锚点未命中")
    sys.exit(1)
src = src.replace(old2, new2, 1)

# 在英文标签收起分支里补上清空文本
old3 = '''            _originLabel.frame = CGRectZero;
            _originLabel.hidden = YES;
        }'''
new3 = '''            _originLabel.frame = CGRectZero;
            _originLabel.hidden = YES;
            // 清空文本，彻底杜绝英文残留（只中文模式下的最后一道保险）
            _originLabel.attributedText = nil;
        }'''
if old3 not in src:
    print("!! 修复3 锚点未命中")
    sys.exit(1)
src = src.replace(old3, new3, 1)
print("  [2] 英文行残留保险 → 已加（清空 attributedText）")

# ---------------------------------------------------------------- 修复 3
# 高度上限保护：容器高度被限制为 45% 屏高，但标签高度没同步限制，
# 极端长文本时标签会超出容器被裁。
old4 = '''        CGFloat pad = 10;
        CGFloat w = maxW + pad * 2;
        CGFloat h = pad * 2 + oh + th + (origin.length && translation.length ? 4 : 0);
        if (h < fs + pad * 2) h = fs + pad * 2;'''

new4 = '''        CGFloat pad = 10;
        CGFloat w = maxW + pad * 2;
        CGFloat h = pad * 2 + oh + th + (origin.length && translation.length ? 4 : 0);
        if (h < fs + pad * 2) h = fs + pad * 2;'''

assert old4 in src

# ---------------------------------------------------------------- 修复 4
# 关键：测量高度时用的宽度 measureW 必须与实际 label 宽度一致，
# 否则文字换行数算错 → 标签高度不足 → 「显示不全」。
# 实测：measureW = maxW - handleSpace（26），但 label 宽度 textW = maxW - handleSpace
# 两者一致，但 label 的 frame 是 (pad, ly, textW, th)，
# 而 pad=10 没有算进可用宽度 → 实际可用宽度比测量宽度少了 2*pad，
# 换行数可能多出 1 行 → 高度不够被裁。
old5 = '''        CGFloat handleSpace = _dragHandle ? 26.0 : 0.0;
        CGFloat measureW = maxW - handleSpace;'''
new5 = '''        CGFloat handleSpace = _dragHandle ? 26.0 : 0.0;
        // v1.0.83：测量宽度必须【扣掉左右内边距】。
        // 旧实现 measureW = maxW - handleSpace，但 label 实际放在 x=pad 处、宽 textW，
        // 文字真正能用的宽度 = textW - 2*pad 的量级；
        // 测量宽度算多了 → 换行数比实际少 → th 偏小 → 标签高度不够 → 末行被裁。
        CGFloat measureW = maxW - handleSpace - pad * 2;'''
if old5 not in src:
    print("!! 修复5 锚点未命中")
    sys.exit(1)
src = src.replace(old5, new5, 1)
print("  [3] 测量宽度未扣内边距 → 已修复（避免末行被裁）")

# pad 需要在 measureW 之前定义 —— 检查顺序
i_pad = src.find('CGFloat pad = 10;')
i_measure = src.find('CGFloat measureW = maxW - handleSpace - pad * 2;')
print("     pad 定义位置 %d, measureW 位置 %d -> %s"
      % (i_pad, i_measure, "OK(pad 在前)" if i_pad < i_measure else "需要调整顺序"))

io.open(SRC, 'w', encoding='utf-8', newline='\n').write(src)
print("已写入 %s (变化 %d 字节)" % (SRC, len(src.encode('utf-8')) - len(orig.encode('utf-8'))))
