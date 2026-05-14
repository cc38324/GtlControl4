"""Generate Control4-style amplifier icons for GTL2750 driver.

Outputs two PNGs in the same directory:
  device_sm.png  (32x32)  — Composer device list icon
  device_lg.png  (300x300) — Composer detail icon
"""

from PIL import Image, ImageDraw, ImageFont
import os, math

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

C4_BG_TOP    = (38, 42, 50)        # dark steel top
C4_BG_BOT    = (18, 22, 28)        # dark steel bottom
C4_PANEL     = (28, 32, 38)
C4_ACCENT    = (0, 180, 220)       # C4 cyan accent
C4_ACCENT_DK = (0, 110, 150)
C4_KNOB      = (54, 60, 70)
C4_KNOB_HI   = (90, 96, 108)
C4_LED       = (90, 230, 120)
C4_TEXT      = (220, 226, 232)
C4_SHADOW    = (0, 0, 0, 90)


def vgradient(size, top, bot):
    img = Image.new("RGB", size, top)
    px = img.load()
    w, h = size
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(top[0] + (bot[0] - top[0]) * t)
        g = int(top[1] + (bot[1] - top[1]) * t)
        b = int(top[2] + (bot[2] - top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def rounded_rect_mask(size, radius):
    mask = Image.new("L", size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1],
                        radius=radius, fill=255)
    return mask


def draw_amplifier(size):
    """Render a Control4-style 1U amplifier face."""
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")

    w, h = size
    pad = max(2, int(min(w, h) * 0.06))
    body = vgradient((w - 2 * pad, h - 2 * pad), C4_BG_TOP, C4_BG_BOT)
    radius = max(2, int(min(w, h) * 0.10))
    mask = rounded_rect_mask(body.size, radius)
    img.paste(body, (pad, pad), mask)

    # Inner panel (matte)
    inset = max(2, int(min(w, h) * 0.12))
    panel_box = [inset, inset, w - inset, h - inset]
    d.rounded_rectangle(panel_box, radius=max(1, radius - 2),
                        fill=C4_PANEL, outline=(60, 66, 76), width=1)

    # Display strip on the left
    disp_w = int((w - 2 * inset) * 0.36)
    disp_h = int((h - 2 * inset) * 0.55)
    disp_x = inset + int((w - 2 * inset) * 0.06)
    disp_y = inset + int(((h - 2 * inset) - disp_h) / 2)
    d.rounded_rectangle([disp_x, disp_y, disp_x + disp_w, disp_y + disp_h],
                        radius=max(1, int(radius * 0.5)),
                        fill=(8, 12, 16),
                        outline=C4_ACCENT_DK, width=max(1, w // 100))

    # VU bars in display
    bar_count = 4
    bar_pad = max(1, disp_w // 30)
    bar_w = (disp_w - bar_pad * (bar_count + 1)) // bar_count
    for i in range(bar_count):
        bx = disp_x + bar_pad + i * (bar_w + bar_pad)
        # ascending heights
        bh = int(disp_h * (0.25 + 0.18 * i))
        by = disp_y + disp_h - bar_pad - bh
        # gradient color: green -> cyan
        col = (
            int(60 + 0 * (i / 3)),
            int(220 - 40 * (i / 3)),
            int(120 + 100 * (i / 3)),
        )
        d.rounded_rectangle([bx, by, bx + bar_w, disp_y + disp_h - bar_pad],
                            radius=max(1, bar_w // 4), fill=col)

    # Volume knob on the right
    knob_area_x = disp_x + disp_w + int((w - 2 * inset) * 0.08)
    knob_area_w = (w - inset) - knob_area_x - int((w - 2 * inset) * 0.04)
    knob_r = min(knob_area_w, disp_h) // 2
    cx = knob_area_x + knob_area_w // 2
    cy = disp_y + disp_h // 2

    # knob outer ring
    d.ellipse([cx - knob_r, cy - knob_r, cx + knob_r, cy + knob_r],
              fill=C4_KNOB, outline=C4_KNOB_HI, width=max(1, w // 120))
    # inner indent
    ir = int(knob_r * 0.72)
    d.ellipse([cx - ir, cy - ir, cx + ir, cy + ir],
              fill=(24, 28, 34), outline=(60, 66, 76),
              width=max(1, w // 160))
    # tick at ~ -30 degrees (top-right)
    angle = math.radians(-30)
    tx1 = cx + int(math.cos(angle) * ir * 0.55)
    ty1 = cy + int(math.sin(angle) * ir * 0.55)
    tx2 = cx + int(math.cos(angle) * ir * 0.95)
    ty2 = cy + int(math.sin(angle) * ir * 0.95)
    d.line([(tx1, ty1), (tx2, ty2)],
           fill=C4_ACCENT, width=max(2, w // 80))

    # Power LED bottom right
    led_r = max(1, w // 40)
    led_x = w - inset - led_r * 3
    led_y = h - inset - led_r * 3
    d.ellipse([led_x - led_r, led_y - led_r,
               led_x + led_r, led_y + led_r],
              fill=C4_LED)
    # LED glow
    glow_r = led_r * 2
    glow = Image.new("RGBA",
                     (glow_r * 4, glow_r * 4), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for rr in range(glow_r * 2, 0, -1):
        a = int(60 * (1 - rr / (glow_r * 2)))
        gd.ellipse([glow_r * 2 - rr, glow_r * 2 - rr,
                    glow_r * 2 + rr, glow_r * 2 + rr],
                   fill=(C4_LED[0], C4_LED[1], C4_LED[2], a))
    img.alpha_composite(glow, (led_x - glow_r * 2, led_y - glow_r * 2))

    # Brand text bottom left (only on large icon)
    if w >= 96:
        try:
            font = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                max(8, w // 16))
        except OSError:
            font = ImageFont.load_default()
        d.text((inset + max(2, w // 60), h - inset - max(8, w // 12)),
               "GTL2750", fill=C4_TEXT, font=font)

    return img


def main():
    small = draw_amplifier((32, 32))
    large = draw_amplifier((300, 300))

    small.save(os.path.join(OUT_DIR, "device_sm.png"), "PNG")
    large.save(os.path.join(OUT_DIR, "device_lg.png"), "PNG")
    print("Wrote:",
          os.path.join(OUT_DIR, "device_sm.png"),
          os.path.join(OUT_DIR, "device_lg.png"))


if __name__ == "__main__":
    main()
