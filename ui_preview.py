#!/usr/bin/env python3
# ui_preview.py - 将 Root.plist 的设置面板渲染为 iOS 设置风格的预览图
import plistlib
from PIL import Image, ImageDraw, ImageFont

FONT_PATH = r"C:\Windows\Fonts\msyh.ttc"

def font(size_pt):
    return ImageFont.truetype(FONT_PATH, int(size_pt * 2))  # 2x 渲染

# 配色（iOS）
BG      = (242, 242, 247)
CARD    = (255, 255, 255)
LABEL   = (0, 0, 0)
VALUE   = (142, 142, 147)
GROUP   = (109, 109, 114)
LINE    = (229, 229, 234)
SW_ON   = (52, 199, 89)
CHEV    = (199, 199, 204)
SLIDER_TRACK = (216, 216, 220)
SLIDER_FILL  = (52, 120, 246)

W = 780          # 2x of 390pt
M = 30           # 卡片外边距（px）
CARD_R = 20      # 圆角
ROW_H = 88       # 行高（2x 44pt）
PAD = 30

def chevron(d, x, y):
    d.line([(x, y-12), (x+12, y), (x, y+12)], fill=CHEV, width=5)

def draw_switch(d, x, y, on=True):
    w, h = 102, 62
    r = h // 2
    if on:
        d.rounded_rectangle([x, y, x+w, y+h], radius=r, fill=SW_ON)
        d.ellipse([x+w-h+4, y+4, x+w-4, y+h-4], fill=(255,255,255))
    else:
        d.rounded_rectangle([x, y, x+w, y+h], radius=r, outline=CHEV, width=4)
        d.ellipse([x+4, y+4, x+h-4, y+h-4], fill=(255,255,255))

def draw_slider(d, x, y, pct):
    track_w, track_h = 480, 8
    d.rounded_rectangle([x, y, x+track_w, y+track_h], radius=4, fill=SLIDER_TRACK)
    fill_w = track_w * pct
    d.rounded_rectangle([x, y, x+fill_w, y+track_h], radius=4, fill=SLIDER_FILL)
    cx = x + fill_w
    d.ellipse([cx-28, y-24, cx+28, y+track_h+24], fill=(255,255,255), outline=SLIDER_TRACK, width=4)

def main():
    with open(r"PrefBundle\Root.plist", "rb") as f:
        root = plistlib.load(f)

    rows = []  # (type, label, value)
    groups = []
    current = []
    current_title = ""
    current_footer = ""
    for item in root["items"]:
        cell = item.get("cell", "")
        if cell == "PSGroupCell":
            if current:
                groups.append((current_title, current, current_footer))
            current_title = item.get("label", "")
            current_footer = item.get("footerText", "")
            current = []
        else:
            label = item.get("label", item.get("key", ""))
            key = item.get("key", "")
            if cell == "PSToggleSwitchSpecifier":
                current.append(("switch", label, key))
            elif cell == "PSSliderSpecifier":
                current.append(("slider", label, str(item.get("default", 16))))
            elif cell == "PSMultiValueSpecifier":
                # 多选项显示当前值对应的中文 title（模拟 iOS 面板真实显示）
                titles = item.get("titles", [])
                values = item.get("values", [])
                cur = item.get("default", values[0] if values else "")
                title = cur
                if cur in values:
                    idx = values.index(cur)
                    if idx < len(titles):
                        title = titles[idx]
                current.append(("row", label, title))
            else:
                default = item.get("default", "")
                value = str(default) if default else item.get("placeholder", "")
                current.append(("row", label, value))
    if current:
        groups.append((current_title, current, current_footer))

    # 估算高度
    h = 180
    for title, items, footer in groups:
        if title:
            h += 70
        h += 20 + len(items) * ROW_H
        if footer:
            h += 70
    h += 120
    img = Image.new("RGB", (W, h), BG)
    d = ImageDraw.Draw(img)

    # 状态栏 + 导航栏
    f_nav = font(17)
    d.text((W//2, 110), "实时字幕翻译", font=f_nav, fill=LABEL, anchor="mm")
    d.line([(0, 160), (W, 160)], fill=LINE, width=2)
    f_group = font(13)

    y = 200
    f_footer = font(11)
    for title, items, footer in groups:
        if title:
            d.text((M+2, y), title, font=f_group, fill=GROUP)
            y += 56
        card_x = M
        card_y = y
        card_h = len(items) * ROW_H
        d.rounded_rectangle([card_x, card_y, W-M, card_y+card_h], radius=CARD_R, fill=CARD)
        for i, (typ, label, value) in enumerate(items):
            ry = card_y + i * ROW_H
            f_lbl = font(16)
            f_val = font(16)
            if typ == "switch":
                d.text((card_x+40, ry+ROW_H//2), label, font=f_lbl, fill=LABEL, anchor="lm")
                draw_switch(d, W-M-102-40, ry + (ROW_H-62)//2, on=True)
            elif typ == "slider":
                d.text((card_x+40, ry+ROW_H//2), label, font=f_lbl, fill=LABEL, anchor="lm")
                draw_slider(d, card_x+40+260, ry + ROW_H//2 - 4, 0.22)
                d.text((W-M-40, ry+ROW_H//2), value, font=f_val, fill=VALUE, anchor="rm")
            else:
                d.text((card_x+40, ry+ROW_H//2), label, font=f_lbl, fill=LABEL, anchor="lm")
                # 值文字（太长截断）
                val = value
                if len(val) > 34:
                    val = val[:33] + "…"
                d.text((card_x+40, ry+ROW_H//2), "", font=f_lbl, fill=LABEL)
                tw = d.textlength(val, font=f_val)
                d.text((W-M-40-38, ry+ROW_H//2), val, font=f_val, fill=VALUE, anchor="rm")
                chevron(d, W-M-40, ry+ROW_H//2)
            if i < len(items) - 1:
                d.line([(card_x+40, ry+ROW_H-1), (W-M-40, ry+ROW_H-1)], fill=LINE, width=2)
        y += card_h + 24
        if footer:
            # 分组 footer 灰字（可换行）
            lines = []
            cur = ""
            for ch in footer:
                cur += ch
                if d.textlength(cur, font=f_footer) > W - 2*M - 8:
                    lines.append(cur.rstrip())
                    cur = ""
            if cur:
                lines.append(cur)
            for j, ln in enumerate(lines[:3]):
                d.text((M+4, y), ln, font=f_footer, fill=VALUE)
                y += 26
            y += 10

    # 底部提示
    f_tip = font(11)
    tip = "目标 App 需在 Dopamine Inject Manager 白名单勾选；识别语言/API 可随时改"
    d.text((W//2, y + 10), tip, font=f_tip, fill=VALUE, anchor="mm")

    out = r"ui_preview.png"
    img.save(out)
    print("saved", out, img.size)

if __name__ == "__main__":
    main()
