#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
osd="${repo}/data/usr/libexec/microemu/microemu-osd"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"

cat > "${T}/bin/xprop" <<'EOF'
#!/usr/bin/bash
echo "xprop $*" >> "${OSD_TEST_STATE}/xprop"
EOF
cat > "${T}/bin/wpctl" <<'EOF'
#!/usr/bin/bash
echo "wpctl $*" >> "${OSD_TEST_STATE}/wpctl"
cat "${OSD_TEST_STATE}/volume"
exit "$(cat "${OSD_TEST_STATE}/wpctl_rc" 2>/dev/null || echo 0)"
EOF
chmod 0755 "${T}/bin/xprop" "${T}/bin/wpctl"

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


for text, want in [("Volume: 0.40\n", 40), ("Volume: 1.00\n", 100), ("Volume: 0.00\n", 0), ("Volume: 0.40 [MUTED]\n", 0),
                   ("Volume: 1.50\n", 100), ("Volume: 0.055\n", 6), ("", None), ("Volume: x\n", None), ("junk", None)]:
    check(osd.parse_volume(text) == want, f"parse_volume({text!r}) is {osd.parse_volume(text)!r}, expected {want!r}")
check(osd.label(0) == "X" and osd.label(7) == "7%" and osd.label(100) == "100%", "label")

for line, want in [("Event 'change' on sink #56", True), ("Event 'change' on server #4294967295", True),
                   ("Event 'new' on sink-input #12", False), ("Event 'change' on sink-input #12", False),
                   ("Event 'change' on source #3", False), ("Event 'remove' on sink #56", False), ("", False)]:
    check(osd.volume_event(line) == want, f"volume_event({line!r}) is {osd.volume_event(line)!r}, expected {want!r}")

lines = osd.Lines()
check(lines.feed(b"Event 'new' on sink-input #1\nEvent 'change' on si") is False, "lines: a partial event counted")
check(lines.feed(b"nk #5\n") is True, "lines: partial event not joined")
check(lines.feed(b"Event 'change' on source #3\n") is False, "lines: a source change counted")
check(lines.feed(b"9" * 5000) is False and lines.feed(b"\nEvent 'change' on sink #1\n") is True, "lines: an over long partial line kept")

for last, level, want in [(None, 40, (False, 40)), (40, 40, (False, 40)), (40, 45, (True, 45)), (45, None, (False, 45)),
                          (45, 0, (True, 0)), (None, None, (False, None))]:
    check(osd.step(last, level) == want, f"step({last}, {level}) is {osd.step(last, level)}, expected {want}")

with open(os.path.join(tmp, "volume"), "w") as f:
    f.write("Volume: 0.65\n")
check(osd.read_level() == 65, "read_level from wpctl")
with open(os.path.join(tmp, "wpctl")) as f:
    check(f.read().strip() == "wpctl get-volume @DEFAULT_AUDIO_SINK@", "read_level: wpctl call")
with open(os.path.join(tmp, "wpctl_rc"), "w") as f:
    f.write("1")
check(osd.read_level() is None, "read_level: a failed wpctl gave a level")
os.unlink(os.path.join(tmp, "wpctl_rc"))

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
