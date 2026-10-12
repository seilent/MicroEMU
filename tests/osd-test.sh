#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
osd="${repo}/sysext/usr/libexec/microemu/microemu-osd"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"

cat > "${T}/bin/xprop" <<'EOF'
#!/usr/bin/bash
echo "xprop $*" >> "${OSD_TEST_STATE}/xprop"
EOF
chmod 0755 "${T}/bin/xprop"

cat > "${T}/glyph.svg" <<'EOF'
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M 1 2 L 3.5 4 C 5 6 7 8 9 10 Z"/></svg>
EOF
cat > "${T}/arc.svg" <<'EOF'
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M 1 2 A 3 3 0 0 1 5 5 Z"/></svg>
EOF

dist="${repo}/dist"
theme="${MICROEMU_OSD_TEST_THEME:-${dist}/usr/share/microemu/es-de/themes/art-book-next-es-de}"
speaker="${MICROEMU_OSD_TEST_SPEAKER:-${dist}/usr/share/microemu/osd/speaker.svg}"

PYTHONDONTWRITEBYTECODE=1 PATH="${T}/bin:${PATH}" OSD_TEST_STATE="${T}" MICROEMU_RUNTIME_DIR="${T}/run" python3 - "${osd}" "${T}" "${theme}" "${speaker}" <<'EOF'
import importlib.machinery
import importlib.util
import os
import stat
import sys

path, tmp, theme, speaker = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("microemu_osd", path)
spec = importlib.util.spec_from_loader("microemu_osd", loader)
osd = importlib.util.module_from_spec(spec)
loader.exec_module(osd)

failures = []


def check(cond, message):
    if not cond:
        failures.append(message)


for line, want in [("0", 0), ("7", 7), ("42", 42), ("100", 100), ("101", None), ("1000", None), ("", None),
                   ("4 2", None), ("-1", None), ("x", None), ("42 ", None)]:
    check(osd.parse_level(line) == want, f"parse_level({line!r}) is {osd.parse_level(line)!r}, expected {want!r}")
check(osd.label(0) == "X" and osd.label(7) == "7%" and osd.label(100) == "100%", "label")

lines = osd.Lines()
check(lines.feed(b"42\n7") == [42], "lines: first complete line")
check(lines.feed(b"0\n") == [70], "lines: partial line joined")
check(lines.feed(b"junk\n100\n") == [100], "lines: garbage dropped")
check(lines.feed(b"9" * 100) == [] and lines.feed(b"\n5\n") == [5], "lines: an over long partial line dropped")

fade = osd.Fade()
check(fade.alpha(0) is None, "fade: hidden before a press")
fade.press(1000)
check(fade.alpha(1500) == 1.0 and fade.alpha(1999) == 1.0, "fade: full during the 1000 ms hold")
check(abs(fade.alpha(2125) - 0.5) < 1e-9, f"fade: {fade.alpha(2125)} half way through the 250 ms fade")
fade.press(2125)
check(fade.alpha(3000) == 1.0, "fade: a press during the fade restarts the hold")
check(fade.alpha(3375) is None and fade.alpha(3000) is None, "fade: hidden after hold and fade")

g = osd.geometry(960, 640, 52.5)
for key, want in [("icon", 27), ("font", 18.9), ("left", 9.3333312), ("vpad", 6.6666688), ("radius", 9.6),
                  ("w", 9.3333312 + 27 + 52.5 + 10.5), ("h", 27 + 2 * 6.6666688)]:
    check(abs(g[key] - want) < 0.01, f"geometry {key} {g[key]}, expected {want}")
status_left = 0.97222222 * 960 - (4 * 27 + 3 * 4.8 + 52.5) - 9.3333312
check(abs(g["x"] + g["w"] - (status_left - 4.8)) < 0.01, f"geometry right edge {g['x'] + g['w']}, expected {status_left - 4.8}")
check(abs(g["y"] + g["vpad"] + g["icon"] / 2 - 40) < 0.01, f"geometry content centre y {g['y'] + g['vpad'] + g['icon'] / 2}")

box, ops = osd.load_glyph(os.path.join(tmp, "glyph.svg"))
check(box == [0, 0, 24, 24], f"glyph box {box}")
check(ops == [("M", [1, 2]), ("L", [3.5, 4]), ("C", [5, 6, 7, 8, 9, 10]), ("Z", [])], f"glyph ops {ops}")
try:
    osd.load_glyph(os.path.join(tmp, "arc.svg"))
    failures.append("glyph: an arc command accepted")
except ValueError:
    pass

fifo = os.path.join(tmp, "run", "osd")
os.makedirs(os.path.dirname(fifo), exist_ok=True)
with open(fifo, "w") as f:
    f.write("stale\n")
fd = osd.open_fifo(fifo)
check(stat.S_ISFIFO(os.stat(fifo).st_mode), "fifo: a regular file at the path not replaced")
writer = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
os.write(writer, b"57\n")
check(osd.Lines().feed(os.read(fd, 64)) == [57], "fifo: line not read back")
os.close(writer)
try:
    os.read(fd, 64)
    failures.append("fifo: read returned with no writer instead of blocking")
except BlockingIOError:
    pass
os.close(fd)
fd = osd.open_fifo(fifo)
check(stat.S_ISFIFO(os.stat(fifo).st_mode), "fifo: a stale fifo not recreated")
os.close(fd)

osd.set_overlay(0x400007)
with open(os.path.join(tmp, "xprop")) as f:
    got = f.read().strip()
check(got == "xprop -id 4194311 -f STEAM_OVERLAY 32c -set STEAM_OVERLAY 1", f"xprop call {got!r}")

try:
    import gi
    import signal
    import warnings
    have_gi = True
except ImportError:
    have_gi = False
    print("osd-test: signal check skipped, no gi")
if have_gi:
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        add = osd.unix_signal_add()
        from gi.repository import GLib
        source = add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, lambda *args: False)
        GLib.source_remove(source)
    deprecated = [str(w.message) for w in caught if issubclass(w.category, gi.PyGIDeprecationWarning)]
    check(not deprecated, f"signal handler: {deprecated}")

if os.path.isdir(os.path.join(theme, "_inc", "fonts")) and os.path.isfile(speaker):
    import cairo
    osd.THEME = theme
    osd.SPEAKER = speaker
    osd.setup_fonts()
    osd.gi_init()
    family, weight = osd.resolved_family()
    check((family, weight) == ("Mulish", 300), f"font resolved to {family} {weight}")
    with open(osd.FONTS_CONF) as f:
        conf = f.read()
    check("<include ignore_missing=\"yes\">/etc/fonts/fonts.conf</include>" in conf, "fonts.conf: system config not included")

    def pixels(level, alpha):
        out = os.path.join(tmp, f"osd-{level}-{alpha}.png")
        osd.render(out, 960, 640, level, alpha)
        surface = cairo.ImageSurface.create_from_png(out)
        data = surface.get_data()
        stride = surface.get_stride()
        return lambda x, y: tuple(data[y * stride + x * 4:y * stride + x * 4 + 4])

    def bbox(px):
        xs, ys = [], []
        for y in range(0, 100):
            for x in range(560, 760):
                if px(x, y)[3]:
                    xs.append(x)
                    ys.append(y)
        return min(xs), min(ys), max(xs), max(ys)

    probe = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1))
    g = osd.geometry(960, 640, osd.text_width(probe, 18.9, "100%"))
    bx = int(g["x"] + g["w"] - 5)
    gx = int(g["x"] + g["left"] + 5)
    boxes = {}
    for level in (0, 7, 42, 100):
        px = pixels(level, 1.0)
        boxes[level] = bbox(px)
        check(px(0, 0)[3] == 0 and px(959, 639)[3] == 0 and px(480, 40)[3] == 0 and px(int(g["x"] + g["w"]) + 3, 40)[3] == 0,
              f"render {level}: pixels outside the pill not transparent")
        bg = px(bx, 40)
        check(bg[3] == 0xEE and bg[0] == bg[1] == bg[2] and abs(bg[0] - 0x11 * 0xEE / 255) <= 1,
              f"render {level}: background {bg}, expected 111111ee premultiplied")
    check(len(set(boxes.values())) == 1, f"render: pill size changes with the level {boxes}")
    x0, y0, x1, y1 = boxes[42]
    check(abs(x0 - g["x"]) <= 1 and abs(x1 + 1 - (g["x"] + g["w"])) <= 1 and abs(y0 - g["y"]) <= 1
          and abs(y1 + 1 - (g["y"] + g["h"])) <= 1, f"render: pill bounds {boxes[42]}, geometry {g}")
    print(f"osd-test: pill {g['x']:.2f},{g['y']:.2f} {g['w']:.2f}x{g['h']:.2f}, text cell {g['text']:.2f}, pixels {boxes[42]}")
    glyph = pixels(42, 1.0)(gx, 40)
    check(glyph[3] == 255 and glyph[0] == 255, f"render: glyph pixel {glyph}, expected ffffff")
    half = pixels(42, 0.5)(bx, 40)
    check(abs(half[3] - 0xEE / 2) <= 1, f"render: background alpha {half[3]} at alpha 0.5")
    check(pixels(42, 0.0)(bx, 40)[3] == 0, "render: drawn at alpha 0")
else:
    print(f"osd-test: render skipped, no theme fonts at {theme} or no {speaker}")

if failures:
    for message in failures:
        print(f"FAIL {message}", file=sys.stderr)
    print(f"osd-test: {len(failures)} failure(s)", file=sys.stderr)
    sys.exit(1)
print("osd-test: ok")
EOF
