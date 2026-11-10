# Draws the app icon: a ridgeline plot of a cartoon face, on the macOS icon grid.
# Usage: ridgeline.py photo.png person-mask.png landmarks.json out.png
# The photo is levelled by its eye line; the face is rebuilt as a height field from the person
# mask and Vision's landmarks. The glasses, nose and crop are placed by hand for the one photo
# the icon was made from (coordinates are in the levelled 720 px frame).
import sys, json, math, numpy as np
from PIL import Image, ImageDraw, ImageFilter

photo, maskp, landmarks, out = sys.argv[1:5]
LINES, AMP, LW = 28, 3.2, 15   # ridges, lift in row gaps, line width at 2048 px

# ---- level the photo ----
d = json.load(open(landmarks))
img = Image.open(photo).convert('RGB'); mask = Image.open(maskp).convert('L').resize(img.size)
W, H = img.size; C = 720
ox, oy = (C - W) // 2, (C - H) // 2
(lx, ly), (rx, ry) = d['leftPupil'][0], d['rightPupil'][0]
th = math.atan2(ry - ly, rx - lx)
def canvas(im, fill):
    c = Image.new(im.mode, (C, C), fill); c.paste(im, (ox, oy)); return c.rotate(math.degrees(th), resample=Image.BICUBIC)
def T(p):
    x, y = p[0] + ox - C / 2, p[1] + oy - C / 2
    return (C / 2 + x * math.cos(th) + y * math.sin(th), C / 2 - x * math.sin(th) + y * math.cos(th))
P = canvas(img, (0, 0, 0)); M = canvas(mask, 0)
L = {k: [T(p) for p in v] for k, v in d.items() if isinstance(v, list)}

# ---- cartoon height field ----
K = 3  # draw the height field at 3x for smooth shapes
def sc(pts): return [(x * K, y * K) for x, y in pts]
def layer(): 
    im = Image.new('L', (C * K, C * K), 0); return im, ImageDraw.Draw(im)
def arr(im, blur): return np.asarray(im.filter(ImageFilter.GaussianBlur(blur * K)).resize((C, C), Image.LANCZOS), float) / 255

# Head: the person mask, cut off at the jawline and the ears.
jaw = L['contour']
im, d = layer(); d.polygon(sc(jaw + [(252, 330), (228, 140), (522, 140), (498, 330)]), fill=255)
head = np.minimum(arr(im, 1), np.asarray(M, float) / 255)
head = np.asarray(Image.fromarray((head * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2)), float) / 255
head = np.clip((head - 0.35) / 0.3, 0, 1)
dome = np.asarray(Image.fromarray((head * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(26)), float) / 255
dome = head * np.clip((dome - 0.45) / 0.5, 0, 1) ** 0.6

# Hair: the dark part of the head above the eyes.
lum = np.asarray(P.convert('L').filter(ImageFilter.GaussianBlur(4)), float) / 255
yy, xx = np.mgrid[0:C, 0:C]
hair = head * (lum < 0.5) * (yy < 345) * ~((yy > 290) & (xx > 280) & (xx < 480))
hair = np.asarray(Image.fromarray((hair * 255).astype(np.uint8)).filter(ImageFilter.MedianFilter(9)).filter(ImageFilter.GaussianBlur(3)), float) / 255

# Glasses: two rounded lenses, a bridge and the temples.
rim, d = layer(); lens, d2 = layer()
for cx in (328, 436):
    box = [(cx - 46) * K, 308 * K, (cx + 46) * K, 372 * K]
    d.rounded_rectangle(box, radius=24 * K, outline=255, width=11 * K)
    d2.rounded_rectangle(box, radius=24 * K, fill=255)
d.line(sc([(372, 328), (392, 328)]), fill=255, width=10 * K)
d.line(sc([(284, 328), (262, 322)]), fill=255, width=9 * K); d.line(sc([(480, 328), (494, 322)]), fill=255, width=9 * K)
rim = arr(rim, 2.5); lens = arr(lens, 2)

eyes, d = layer()
for k in ('leftPupil', 'rightPupil'):
    x, y = L[k][0]; d.ellipse([(x - 13) * K, (y + 3 - 9) * K, (x + 13) * K, (y + 3 + 9) * K], fill=255)
eyes = arr(eyes, 3)

nose, d = layer(); d.polygon(sc([(380, 345), (390, 345), (408, 388), (385, 400), (362, 388)]), fill=255); nose = arr(nose, 6)
# A grin: the lip outline with its corners pulled up, a little wider than life.
mx = sum(p[0] for p in L['outerLips']) / len(L['outerLips']); top_y = min(p[1] for p in L['outerLips']); bot_y = max(p[1] for p in L['outerLips'])
mw = (max(p[0] for p in L['outerLips']) - min(p[0] for p in L['outerLips'])) / 2 * 1.18; mh = bot_y - top_y
grin = [(mx - mw, top_y - 4), (mx - mw * .5, top_y + mh * .16), (mx, top_y + mh * .22), (mx + mw * .5, top_y + mh * .16), (mx + mw, top_y - 4),
        (mx + mw * .78, top_y + mh * .55), (mx + mw * .42, top_y + mh * .92), (mx, bot_y + 3), (mx - mw * .42, top_y + mh * .92), (mx - mw * .78, top_y + mh * .55)]
teeth, d = layer(); d.polygon(sc(grin), fill=255); teeth = arr(teeth, 2.5)

rng = np.random.default_rng(3)
h = head * (0.22 + 0.5 * dome) + 0.38 * hair + 0.42 * rim * head - 0.10 * lens * (1 - rim) + 0.34 * eyes \
    + 0.26 * nose + 0.5 * teeth
h = np.clip(h, 0, None)

# ---- icon ----
S = 2048; body = 1648; m0 = (S - body) // 2
pad = 0.12 * body
x0, x1 = m0 + pad, m0 + body - pad
y0, y1 = m0 + pad * 1.45, m0 + body - pad * 1.0
cxh, top, bot = 375, 150, 535        # head crop in the levelled photo
half = (bot - top) / 2 * (x1 - x0) / (y1 - y0)
n = 900; xs = np.linspace(x0, x1, n); u = np.linspace(cxh - half, cxh + half, n)
def sample(a, uu, v):
    v = min(max(v, 0), C - 1.001); uu = np.clip(uu, 0, C - 1.001)
    i = uu.astype(int); f = uu - i; j = int(v); g = v - j
    return (a[j, i] * (1 - f) + a[j, i + 1] * f) * (1 - g) + (a[j + 1, i] * (1 - f) + a[j + 1, i + 1] * f) * g
hairA = hair
# Background: a quiet top-to-bottom gradient.
g = np.linspace(0, 1, S)[:, None] * np.ones((1, S))
bgc = (np.array([34, 34, 38])[None, None, :] * (1 - g[..., None]) + np.array([6, 6, 8])[None, None, :] * g[..., None])
canvas = Image.fromarray(bgc.astype(np.uint8), 'RGB'); bgim = canvas.copy()
gap = (y1 - y0) / (LINES - 1)
for k in range(LINES):
    v = top + (bot - top) * k / (LINES - 1)
    hh = sample(h, u, v); ha = sample(hairA, u, v)
    noise = np.convolve(rng.standard_normal(n), np.hanning(15) / np.hanning(15).sum(), 'same')
    y = y0 + k * gap - (hh + 0.28 * noise * ha * hh) * gap * AMP
    pts = list(zip(xs.tolist(), y.tolist()))
    # Each ridge hides the ones behind it: fill below the line with the background.
    fill = Image.new('L', (S, S), 0)
    ImageDraw.Draw(fill).polygon(pts + [(x1, y0 + k * gap + gap), (x0, y0 + k * gap + gap)], fill=255)
    canvas.paste(bgim, (0, 0), fill)
    dr = ImageDraw.Draw(canvas); dr.line(pts, fill=(245, 245, 240), width=LW, joint='curve')
    r = LW / 2
    for px, py in (pts[0], pts[-1]): dr.ellipse([px - r, py - r, px + r, py + r], fill=(245, 245, 240))

# macOS icon grid: 824 body on a 1024 canvas, continuous corners, the template's drop shadow.
t = np.linspace(-1, 1, body)
X, Y = np.meshgrid(t, t)
sq = (np.abs(X) ** 5 + np.abs(Y) ** 5 <= 1).astype(np.uint8) * 255
shape = Image.new('L', (S, S), 0); shape.paste(Image.fromarray(sq), (m0, m0))
shadow = Image.new('L', (S, S), 0); shadow.paste(Image.fromarray(sq), (m0, m0 + 24))
shadow = shadow.filter(ImageFilter.GaussianBlur(28)).point(lambda p: p * 0.3)
icon = Image.new('RGBA', (S, S), (0, 0, 0, 0)); icon.putalpha(shadow)
icon.paste(canvas, (0, 0), shape)
icon.resize((1024, 1024), Image.LANCZOS).save(out)
