#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 iOS 设置项图标三件套（无第三方依赖，纯 zlib/PNG 手写）。

背景：PreferenceLoader 的 entry.icon 走 UIImage 的 1x/2x/3x 规则，
标准设置图标规格是 29x29 / 58x58 / 87x87（设备上 GoodWiFi / Shuffle /
Backgrounder 等全是这个规格）。之前只放了一张 512x512 的 icon.png，
被当成 1x 图渲染，所以在设置列表里明显比别的插件大。

输入：PrefBundle/icon@512.png（源图，512x512 RGB，non-interlaced）
输出：PrefBundle/icon.png       29x29  (1x, RGBA 圆角)
      PrefBundle/icon@2x.png    58x58  (2x)
      PrefBundle/icon@3x.png    87x87  (3x, iPhone 14 Pro 实际用这张)
      _icon_preview.png        放大预览（仅自查用，不进包）

重跑：python3 make_icons.py（改了 icon@512.png 后重新生成即可）
"""
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'PrefBundle', 'icon@512.png')
SIZES = (29, 58, 87)
OUT_NAMES = ('icon.png', 'icon@2x.png', 'icon@3x.png')
RADIUS_RATIO = 0.2237  # iOS 圆角方形图标惯例


def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not png'
    w, h = struct.unpack('>II', d[16:24])
    bd, ct, comp, filt, inter = d[24:29]
    assert bd == 8 and ct == 2 and inter == 0, \
        'need 8bit RGB non-interlaced, got %s' % ((bd, ct, inter),)
    pos, idat = 8, b''
    while pos + 8 <= len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        if typ == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp, stride = 3, w * 3
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        ft = raw[p]
        cur = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = cur[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ft == 1:
                pred = a
            elif ft == 2:
                pred = b
            elif ft == 3:
                pred = (a + b) // 2
            elif ft == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            elif ft == 0:
                pred = 0
            else:
                raise ValueError('bad filter %d' % ft)
            cur[i] = (cur[i] + pred) & 0xFF
        rows.append(cur)
        prev = cur
    return w, h, rows


def write_png(path, w, h, rows, colortype=6):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(typ, body):
        return (struct.pack('>I', len(body)) + typ + body +
                struct.pack('>I', zlib.crc32(typ + body) & 0xFFFFFFFF))

    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, colortype, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 9)) +
           chunk(b'IEND', b''))
    open(path, 'wb').write(png)
    return len(png)


def resample(rows, sw, sh, n):
    """面积平均降采样：每个目标像素取源矩形内所有像素的均值。"""
    out = []
    for y in range(n):
        y0, y1 = sh * y // n, max(sh * (y + 1) // n, sh * y // n + 1)
        row = bytearray(n * 3)
        for x in range(n):
            x0, x1 = sw * x // n, max(sw * (x + 1) // n, sw * x // n + 1)
            acc = [0, 0, 0]
            cnt = 0
            for sy in range(y0, min(y1, sh)):
                sr = rows[sy]
                for sx in range(x0, min(x1, sw)):
                    k = sx * 3
                    acc[0] += sr[k]
                    acc[1] += sr[k + 1]
                    acc[2] += sr[k + 2]
                    cnt += 1
            k = x * 3
            row[k] = acc[0] // cnt
            row[k + 1] = acc[1] // cnt
            row[k + 2] = acc[2] // cnt
        out.append(row)
    return out


def unsharp(rows, n, amount=0.45):
    """小尺寸下 CC 笔画容易糊，用 3x3 轻微锐化提一下边缘。"""
    src = [bytearray(r) for r in rows]
    out = []
    for y in range(n):
        row = bytearray(n * 3)
        for x in range(n):
            for ch in range(3):
                k = x * 3 + ch
                blur, cnt = 0, 0
                for dy in (-1, 0, 1):
                    yy = y + dy
                    if yy < 0 or yy >= n:
                        continue
                    for dx in (-1, 0, 1):
                        xx = x + dx
                        if xx < 0 or xx >= n:
                            continue
                        blur += src[yy][xx * 3 + ch]
                        cnt += 1
                blur //= cnt
                v = src[y][k] + int(amount * (src[y][k] - blur))
                row[k] = max(0, min(255, v))
        out.append(row)
    return out


def round_corners(rgb_rows, n):
    """RGB -> RGBA，按圆角方形 SDF 做 4x4 子采样抗锯齿。"""
    r = n * RADIUS_RATIO
    half = n / 2.0
    out = []
    for y in range(n):
        row = bytearray(n * 4)
        for x in range(n):
            hit = 0
            for sy in range(4):
                for sx in range(4):
                    px = x + (sx + 0.5) / 4.0
                    py = y + (sy + 0.5) / 4.0
                    qx = abs(px - half) - (half - r)
                    qy = abs(py - half) - (half - r)
                    d = math.sqrt(max(qx, 0) ** 2 + max(qy, 0) ** 2) + min(max(qx, qy), 0) - r
                    if d <= 0:
                        hit += 1
            a = round(255.0 * hit / 16.0)
            k3, k4 = x * 3, x * 4
            row[k4] = rgb_rows[y][k3]
            row[k4 + 1] = rgb_rows[y][k3 + 1]
            row[k4 + 2] = rgb_rows[y][k3 + 2]
            row[k4 + 3] = a
        out.append(row)
    return out


def preview(rgba_rows, n, factor=8, bg=(238, 238, 242)):
    """自查用：把 RGBA 合成到浅灰底再 nearest 放大，看清圆角和笔画。"""
    rgb = []
    for row in rgba_rows:
        line = bytearray(n * 3)
        for x in range(n):
            a = row[x * 4 + 3] / 255.0
            for ch in range(3):
                line[x * 3 + ch] = int(row[x * 4 + ch] * a + bg[ch] * (1 - a))
        rgb.append(line)
    out = []
    for r in rgb:
        line = b''.join(bytes(r[x * 3:x * 3 + 3]) * factor for x in range(n))
        for _ in range(factor):
            out.append(bytearray(line))
    return out


def main():
    sw, sh, src = read_png(SRC)
    assert (sw, sh) == (512, 512), 'source must be 512x512, got %sx%s' % (sw, sh)
    print('source %dx%d, %d scanlines' % (sw, sh, len(src)))
    for n, name in zip(SIZES, OUT_NAMES):
        rgba = round_corners(unsharp(resample(src, sw, sh, n), n), n)
        p = os.path.join(HERE, 'PrefBundle', name)
        size = write_png(p, n, n, rgba)
        print('  %-14s %dx%d RGBA  %6d bytes' % (name, n, n, size))
    rgba = round_corners(unsharp(resample(src, sw, sh, 87), 87), 87)
    big = preview(rgba, 87, 8)
    write_png(os.path.join(HERE, '_icon_preview.png'), 87 * 8, 87 * 8, big, colortype=2)
    print('  _icon_preview.png (87x8 = 696px, 自查用)')


if __name__ == '__main__':
    main()
