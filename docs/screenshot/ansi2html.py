"""Turn the statusline's ANSI SGR output into HTML spans (256-colour and truecolor)."""
import html
import re
import sys

BASE16 = [
    (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
    (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
]


def xterm(n):
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return steps[n // 36], steps[(n // 6) % 6], steps[n % 6]
    v = 8 + (n - 232) * 10
    return v, v, v


def convert(text):
    out, fg, bg, bold = [], None, None, False
    for part in re.split(r"(\x1b\[[0-9;]*m)", text):
        m = re.fullmatch(r"\x1b\[([0-9;]*)m", part)
        if m:
            codes = [int(c) for c in m.group(1).split(";") if c] or [0]
            i = 0
            while i < len(codes):
                c = codes[i]
                if c == 0:
                    fg, bg, bold = None, None, False
                elif c == 1:
                    bold = True
                elif c in (38, 48) and codes[i + 1] == 5:
                    rgb = xterm(codes[i + 2])
                    i += 2
                    fg, bg = (rgb, bg) if c == 38 else (fg, rgb)
                elif c in (38, 48) and codes[i + 1] == 2:
                    rgb = tuple(codes[i + 2:i + 5])
                    i += 4
                    fg, bg = (rgb, bg) if c == 38 else (fg, rgb)
                i += 1
            continue
        if not part:
            continue
        style = []
        if fg:
            style.append("color:rgb(%d,%d,%d)" % fg)
        if bg:
            style.append("background:rgb(%d,%d,%d)" % bg)
        if bold:
            style.append("font-weight:bold")
        out.append('<span style="%s">%s</span>' % (";".join(style), html.escape(part)))
    return "".join(out)


print(convert(sys.stdin.read()))
