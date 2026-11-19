#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate RouterFinder app icon (radar / network discovery theme)."""
from PIL import Image, ImageDraw, ImageFilter
import os, json, math

BASE = 1024
S = 4
W = BASE * S

def lerp(a, b, t): return a + (b - a) * t

# ---- background: diagonal gradient ----
gsmall = 512
g = Image.new('RGB', (gsmall, gsmall))
gp = g.load()
c0 = (16, 20, 66)     # deep indigo
c1 = (62, 36, 152)    # violet
c2 = (26, 108, 220)   # vivid blue
for y in range(gsmall):
    for x in range(gsmall):
        t = 0.55 * (y / gsmall) + 0.45 * (x / gsmall)
        if t < 0.5:
            u = t * 2; a, b = c0, c1
        else:
            u = (t - 0.5) * 2; a, b = c1, c2
        gp[x, y] = (int(lerp(a[0],b[0],u)), int(lerp(a[1],b[1],u)), int(lerp(a[2],b[2],u)))
bg = g.resize((W, W), Image.LANCZOS).convert('RGBA')

cx = cy = W / 2
R = W * 0.405

# ---- radar sweep glow ----
sweep = Image.new('RGBA', (W, W), (0,0,0,0))
ImageDraw.Draw(sweep).pieslice([cx-R, cy-R, cx+R, cy+R], start=202, end=248, fill=(120, 232, 255, 85))
bg = Image.alpha_composite(bg, sweep.filter(ImageFilter.GaussianBlur(W*0.018)))

# ---- rings + dots layer ----
rings = Image.new('RGBA', (W, W), (0,0,0,0))
dr = ImageDraw.Draw(rings)
for rad, alpha, wmul in [(R, 62, 0.005), (R*0.745, 82, 0.006), (R*0.49, 108, 0.0075)]:
    dr.ellipse([cx-rad, cy-rad, cx+rad, cy+rad], outline=(255,255,255,alpha), width=int(W*wmul))
for rr, ang in [(0.745,-38),(0.49,140),(0.745,205),(1.0,298)]:
    a = math.radians(ang)
    dx = cx + R*rr*math.cos(a); dy = cy + R*rr*math.sin(a)
    s = W*0.017
    dr.ellipse([dx-s,dy-s,dx+s,dy+s], fill=(150,242,255,235))
bg = Image.alpha_composite(bg, rings)

# ---- center signal ----
base_y = cy + W*0.10
glow = Image.new('RGBA', (W, W), (0,0,0,0))
gr = W*0.10
ImageDraw.Draw(glow).ellipse([cx-gr, base_y-gr, cx+gr, base_y+gr], fill=(120,230,255,135))
bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(W*0.032)))

sig = Image.new('RGBA', (W, W), (0,0,0,0))
ds = ImageDraw.Draw(sig)
for rad in (W*0.095, W*0.168, W*0.241):
    ds.arc([cx-rad, base_y-rad, cx+rad, base_y+rad], start=202, end=338,
           fill=(255,255,255,255), width=int(W*0.023))
s = W*0.037
ds.ellipse([cx-s, base_y-s, cx+s, base_y+s], fill=(255,255,255,255))
bg = Image.alpha_composite(bg, sig)

icon = bg.convert('RGB').resize((BASE, BASE), Image.LANCZOS)
icon.save(r'E:/RouterFinder/output/icon-preview.png')

# ---- write appiconset ----
appicon = r'E:/RouterFinder/RouterFinder/Assets.xcassets/AppIcon.appiconset'
os.makedirs(appicon, exist_ok=True)
sizes = {
    'Icon-20@2x.png':40, 'Icon-20@3x.png':60,
    'Icon-29@2x.png':58, 'Icon-29@3x.png':87,
    'Icon-40@2x.png':80, 'Icon-40@3x.png':120,
    'Icon-60@2x.png':120, 'Icon-60@3x.png':180,
    'Icon-1024.png':1024,
}
for fn, px in sizes.items():
    icon.resize((px, px), Image.LANCZOS).save(os.path.join(appicon, fn))

contents = {
  "images": [
    {"size":"20x20","idiom":"iphone","scale":"2x","filename":"Icon-20@2x.png"},
    {"size":"20x20","idiom":"iphone","scale":"3x","filename":"Icon-20@3x.png"},
    {"size":"29x29","idiom":"iphone","scale":"2x","filename":"Icon-29@2x.png"},
    {"size":"29x29","idiom":"iphone","scale":"3x","filename":"Icon-29@3x.png"},
    {"size":"40x40","idiom":"iphone","scale":"2x","filename":"Icon-40@2x.png"},
    {"size":"40x40","idiom":"iphone","scale":"3x","filename":"Icon-40@3x.png"},
    {"size":"60x60","idiom":"iphone","scale":"2x","filename":"Icon-60@2x.png"},
    {"size":"60x60","idiom":"iphone","scale":"3x","filename":"Icon-60@3x.png"},
    {"size":"1024x1024","idiom":"universal","platform":"ios","scale":"1x","filename":"Icon-1024.png"}
  ],
  "info": {"author":"xcode","version":1}
}
with open(os.path.join(appicon, 'Contents.json'), 'w', encoding='utf-8') as f:
    json.dump(contents, f, indent=2)
print('icon preview + appiconset generated')
