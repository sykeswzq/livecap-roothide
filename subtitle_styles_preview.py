# -*- coding: utf-8 -*-
# 生成字幕背景样式对比预览图（模拟视频画面 + 各种字幕样式）
from PIL import Image, ImageDraw, ImageFont

W, CARD_H = 900, 240
FONT_PATH = r"C:\Windows\Fonts\msyh.ttc"

def font(sz):
    return ImageFont.truetype(FONT_PATH, sz)

def draw_video_bg(d, x, y, w, h):
    # 模拟一段视频画面：深色渐变 + 色块
    for i in range(h):
        v = int(30 + 60 * i / h)
        d.line([(x, y + i), (x + w, y + i)], fill=(v, v, v + 12))
    # 一个亮色区域（比如球赛草地/夜景灯光），测试可读性
    d.rounded_rectangle([x + w*0.55, y + h*0.15, x + w*0.95, y + h*0.65], radius=12, fill=(18, 120, 60))
    d.ellipse([x + w*0.1, y + h*0.5, x + w*0.28, y + h*0.75], fill=(255, 215, 60))
    d.line([(x, y + h*0.85), (x + w, y + h*0.85)], fill=(200, 200, 210), width=2)

def stroke_text(d, cx, cy, text, f, fill, stroke_col, stroke_w):
    d.text((cx, cy), text, font=f, fill=fill,
           stroke_width=stroke_w, stroke_fill=stroke_col, anchor="mm")

def render_style(idx, name, draw_fn, out_y):
    y = out_y
    draw_video_bg(d, 0, y, W, CARD_H)
    d.text((18, y + 16), f"样式 {idx}：{name}", font=font(24), fill=(255, 255, 255))
    draw_fn(y + CARD_H // 2)
    d.line([(0, y + CARD_H), (W, y + CARD_H)], fill=(255, 255, 255), width=2)

img = Image.new("RGB", (W, CARD_H * 5), (20, 20, 24))
d = ImageDraw.Draw(img)

# 样式1：无背景 + 白字黑描边（当前默认）
def s1(cy):
    txt = "Hello, this is a live subtitle demo"
    f = font(26)
    tw = d.textlength(txt, font=f)
    stroke_text(d, W/2, cy, txt, f, (255,255,255), (0,0,0), 4)

# 样式2：半透明黑圆角背景条（经典字幕，Netflix/大多数播放器）
def s2(cy):
    txt = "Hello, this is a live subtitle demo"
    f = font(26)
    tw = d.textlength(txt, font=f)
    pad = 14
    x0, x1 = W/2 - tw/2 - pad, W/2 + tw/2 + pad
    d.rounded_rectangle([x0, cy-26, x1, cy+26], radius=10, fill=(0,0,0,170))
    d.text((W/2, cy), txt, font=f, fill=(255,255,255), anchor="mm")

# 样式3：实黑圆角背景条（强可读性）
def s3(cy):
    txt = "Hello, this is a live subtitle demo"
    f = font(26)
    tw = d.textlength(txt, font=f)
    pad = 14
    x0, x1 = W/2 - tw/2 - pad, W/2 + tw/2 + pad
    d.rounded_rectangle([x0, cy-26, x1, cy+26], radius=10, fill=(0,0,0))
    d.text((W/2, cy), txt, font=f, fill=(255,255,255), anchor="mm")

# 样式4：半透明白圆角背景条 + 黑字（浅色风格）
def s4(cy):
    txt = "Hello, this is a live subtitle demo"
    f = font(26)
    tw = d.textlength(txt, font=f)
    pad = 14
    x0, x1 = W/2 - tw/2 - pad, W/2 + tw/2 + pad
    d.rounded_rectangle([x0, cy-26, x1, cy+26], radius=10, fill=(255,255,255,190))
    d.text((W/2, cy), txt, font=f, fill=(10,10,10), anchor="mm")

# 样式5：毛玻璃近似（浅色半透明 + 轻微亮度渐变边）
def s5(cy):
    txt = "Hello, this is a live subtitle demo"
    f = font(26)
    tw = d.textlength(txt, font=f)
    pad = 16
    x0, x1 = W/2 - tw/2 - pad, W/2 + tw/2 + pad
    # 多层半透明白叠加模拟模糊
    for alpha in (60, 90, 120, 150, 120, 90, 60):
        d.rounded_rectangle([x0, cy-26, x1, cy+26], radius=12, fill=(255,255,255,alpha))
    d.text((W/2, cy), txt, font=f, fill=(20,20,20), anchor="mm")

for idx, (name, fn) in enumerate([
    ("无背景 + 描边（当前默认）", s1),
    ("半透明黑圆角条", s2),
    ("实黑圆角条", s3),
    ("半透明白圆角条", s4),
    ("毛玻璃效果", s5),
], 1):
    render_style(idx, name, fn, (idx-1) * CARD_H)

out = r"subtitle_styles_preview.png"
img.save(out)
print("saved", out, img.size)
