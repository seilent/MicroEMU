# MicroEMU

The ES-DE emulation session of [MicroOS](https://github.com/seilent/MicroOS) on the AYANEO Pocket MICRO 2, packaged as
the `microemu` RPM.

## Layout

| Path | Content |
|---|---|
| `data/` | Files installed as is, `/usr` only. |
| `build/` | `install.sh`, `shaders.sh` with `shaders-audit`, `theme.sh`, `osd.sh`, and `stub.sh` for Android. |
| `android/` | Android games through Lepton: `data/` (not installed) and the `restrictions` stub source. |
| `tests/` | Bash tests, binaries stubbed through `PATH`, paths through `MICROEMU_*` variables. |

## Install

`build/install.sh <destdir>` copies `data/` into `<destdir>` without `__pycache__` or `*.pyc`, then adds the pinned
assets: the slang shaders and Retro Crisis presets (`shaders.sh`), the Art Book Next theme (`theme.sh`) and the volume
glyph (`osd.sh`), and sets every dir under `<destdir>` to 0755 whatever the umask. Each download is checked against its sha256 and cached in `MICROEMU_CACHE` (default
`build/cache/`); with a full cache it makes no network call. It writes `/usr/share/microemu/version`
(`MICROEMU_VERSION`) and `build-manifest` (the asset revisions). `just install` installs into `dist/`.

ES-DE comes from MicroOS's own `es-de` package, RetroArch and the 13 cores from Fedora (`/usr/bin/retroarch`,
`/usr/lib64/libretro/`, `/usr/share/libretro/{info,autoconfig}`).

## Session

| Path | Does |
|---|---|
| `/usr/lib/microos/sessions.d/microemu.conf` | `LABEL=MicroEMU`, `STOP=unit`, `DEFAULT=yes`, `GAME_SCOPE=microemu-game.scope` (a switch out of MicroEMU with a core running asks for the confirm) |
| `/usr/share/wayland-sessions/microemu.desktop` | `gamescope-session-plus microemu` |
| `/usr/share/gamescope-session-plus/sessions.d/microemu` | `CLIENTCMD=microemu-client`, `GAMESCOPE_BIN=microemu-gamescope`; `ORIENTATION=left` when `microemu.orientation` is `landscape-flipped` (`microset get`, 5 s), else no `ORIENTATION` and gamescope takes landscape from the panel's DT `rotation`. The launcher sources this file after `device-quirks`, so the value wins |
| `microemu-gamescope` | Drops `--steam` and execs `/usr/bin/gamescope`. Without `--steam`, gamescope focuses ES-DE and the windows it starts with no `STEAM_GAME` atoms. |
| `microemu-client` | Runs `microemu-game-stop`, waits for the card and picks the storage (Storage below), writes `~/.local/share/microemu/ES-DE/custom_systems/es_systems.xml` from the shipped file (the `microos` path filled in, system paths mapped for the layout) and removes `es_find_rules.xml` there, links the shipped themes, reconciles the ES-DE settings, writes the BOOT INTO entries, starts `microemu-osd` and runs `/usr/bin/es-de` in the background with `ESDE_APPDATA_DIR=~/.local/share/microemu/ES-DE`, picking again every 2 s. When `/var/lib/microos/openh264/libopenh264.so.8` exists at that moment, ES-DE alone gets that dir prepended to `LD_LIBRARY_PATH` (H.264 video previews; MicroOS downloads Cisco's openh264 on the device). When ES-DE exits while a game runs (`microemu-game-running`), it waits for the game to end, checking every second. Then, with the unit `deactivating`, it blocks in `sleep infinity`; otherwise (Quit, crash, missing) it runs `microos-session back`, retries once after 2 s, then blocks; after a second failure it exits 1. |
| `microemu-stop` | `ExecStop` of the session, bounded at 15 s: `microemu-game-stop`, then SIGTERM to the `/usr/bin/es-de` process in the session's cgroup every 500 ms, up to 6 times or until it exits. |
| `microemu-game-stop` | Runs every executable in `/usr/libexec/microemu/game-stop.d/` within 5 s of boottime in total, then `reset-failed`, `stop`, `reset-failed` of `microemu-game.scope`. |
| `microemu-pad xb360` | Sets every InputPlumber composite device to `xb360` plus `keyboard` when InputPlumber takes its bus name, and each composite device InputPlumber adds after that (`InterfacesAdded`). Runs as long as the session (`microemu-pad.service`, bound to it, `After=` steamos-manager, restarted on failure). `deck-uhid` has no evdev pad while the Steam client is not running, so RetroArch reads the Xbox 360 pad. |
| `30-microemu-stop.conf` | `ExecStop=-microemu-stop`, `ExecStopPost=-microemu-game-stop`, `TimeoutStopSec=25`, `TimeoutStopFailureMode=terminate`. |

ES-DE loads only these systems: the shipped `es_systems.xml` has `<loadExclusive/>` before `<systemList>`, and every
game command is the RetroArch wrapper.

### BOOT INTO

The `microos` system ("Boot Into") lists `$XDG_RUNTIME_DIR/microemu/microos/<name>.session`, one per session with
`DEFAULT` yes in `microos-session list`, rewritten at every client start, with the session labels in
`gamelists/microos/gamelist.xml`. Its command is `microos-session set-default %BASENAME%`.

## Keys

hotkeyd tables, read by MicroOS's `microos-hotkeyd`:

| File | Rows |
|---|---|
| `hotkeys.d/microemu.conf` | `lc hold unit microemu-lc.service`, `volup press volume up`, `voldown press volume down` |
| `hotkeys.d/steam.conf.d/50-microemu.conf` | `lc hold switch microemu confirm-in-game` |
| `hotkeys.d/microdap.conf.d/50-microemu.conf` | `lc hold switch microemu` |

`microemu-lc` stops the game when `microemu-game-running` reports one, else runs `microos-session back`.
`microemu-game-running` counts `microemu-game.scope` active, activating, reloading or deactivating, and the launch
window: `$XDG_RUNTIME_DIR/microemu/launching` names the live RetroArch wrapper. In the launch window the LC hold also
sends the wrapper SIGTERM, so the game never starts. The power key is hotkeyd's built in suspend. RetroArch's menu is on L3 + R3, so RC stays free.

## Settings

`/usr/share/microset/schema.d/50-microemu.json` (owner `microemu`, group `emulation`):

| Key | Type, default | Written to |
|---|---|---|
| `microemu.orientation` | s, `landscape` `landscape-flipped`, `landscape` | read at session start |
| `microemu.esde.theme`, `theme_color_scheme`, `theme_variant`, `theme_font_size`, `theme_aspect_ratio` | s, enum of the values Art Book Next and ES-DE's bundled `linear-es-de`, `modern-es-de`, `slate-es-de` declare in `capabilities.xml`; `art-book-next-es-de`, `dark-screenshots`, `gamelist-list-metadata-cover`, `medium`, `3:2` | `es_settings.xml` `Theme`, `ThemeColorScheme`, `ThemeVariant`, `ThemeFontSize`, `ThemeAspectRatio` |
| `microemu.retroarch.<key>` | below | `retroarch.cfg` `<key>` |
| `microemu.core.bsnes_mercury.video_threaded`, `nestopia.`, `pcsx_rearmed.` | b, false | `config/<core>/<core>.cfg` `video_threaded` |

| RetroArch key | Type | Default |
|---|---|---|
| `video_driver` | s, `vulkan` `glcore` `gl` `gl1` `sdl2` `x11` `xvideo` `drm` | `vulkan` |
| `video_scale_integer` | b | false |
| `audio_block_frames` | u, 0 to 65536 | 192 |
| `fps_show`, `video_shader_enable` | b | true |
| `sort_savefiles_enable`, `sort_savestates_enable` | b | true |
| `savestate_auto_index`, `savestate_auto_load`, `savestate_auto_save` | b | true |
| `savestate_max_keep` | u, 0 to 999 | 10 |
| `quit_on_close_content` | u, 0 to 2 | 1 |
| `quit_press_twice` | b | false |
| `menu_shader_pipeline` | u, 0 to 6 | 1 |
| `input_player1_analog_dpad_mode` | u, 0 to 4 | 1 (left stick as the d-pad) |

The values are BruhMeh's [Ayaneo-Handheld-Scripts](https://github.com/BruhMeh/Ayaneo-Handheld-Scripts) at `168d1c9`
(`retro_arch_common_auto_config.sh`), with RGUI, per core run ahead and rewind, per core save folders and
`video_scale_integer` false (games fill the 640 px height).

`microemu-reconcile esde <settings dir>` (client) and `microemu-reconcile retroarch <config dir>` (wrapper, after the
scope wait) run at every launch. For each key with a `file` and `setting` in the schema file, the values compare as the
schema type (RetroArch's `"3.000000"` is 3), against the value last written, kept in
`~/.local/state/microemu/written.json`:

- The file differs from the last written value: the app's menu changed it. It is `Set` into MicroSET and kept. When
  MicroSET changed too, the file still wins and the conflict is logged. A value MicroSET refuses stays in the file, the
  old `written.json` entry stays and the refusal is logged.
- Otherwise the MicroSET value goes into the file (a missing key is added).
- No `written.json`, or no entry for the key: MicroSET wins.
- `microsetd` down: nothing changes, one log line.
- A value holding `"`, a CR or a LF, read from the file or from MicroSET: the key is skipped and logged, nothing
  written. Every string key is an enum, so MicroSET never serves one.

`written.json` is updated after each key. Files are replaced through a temp file in the same dir, written through when
they are symlinks. App menu edits stay; MicroSET changes land at the next launch.

## Storage

`microemu-client` picks where ROMs, BIOS, saves, states, screenshots and scraped media live, before ES-DE starts and
every 2 s while it runs. The card is `/run/microos/content`, MicroOS's link to the content card's mount. A missing or
dangling link, a mount `findmnt` does not list, or a read only mount is no card (one log line).

A layout counts when its ROMs folder is on the card, matched by exact name in a listing of the card root (a FAT card's
`roms` is never `ROMs`), each part a real directory, not a symlink, inside the card:

| | MicroOS | EmuDeck | ROCKNIX |
|---|---|---|---|
| ROMs, ES-DE `ROMDirectory` | `ROMs/` | `Emulation/roms/` | `roms/` |
| RetroArch `system_directory` | `BIOS/retroarch/` | `Emulation/bios/` | `roms/bios/` |
| Saves | `Saves/<core>/` | `Emulation/saves/microemu/saves/<core>/` | next to the ROM |
| States | `States/<core>/` | `Emulation/saves/microemu/states/<core>/` | `roms/savestates/<system>/` |
| Screenshots | `Screenshots/` | `Emulation/storage/retroarch/screenshots/` | `roms/screenshots/` |
| Scraped media, ES-DE `MediaDirectory` | `Media/` | `Emulation/tools/downloaded_media/` | `roms/downloaded_media/` |
| Gamelists | ES-DE appdata | ES-DE appdata | `roms/<system>/gamelist.xml` |

- Several layouts on one card: MicroOS wins, then EmuDeck, then ROCKNIX; the others are logged.
- No card, or no layout on it: the MicroOS layout under `~` (`~/ROMs`, `~/BIOS/retroarch`, `~/Saves`, `~/States`,
  `~/Screenshots`, `~/Media`, made by MicroOS).
- Everything follows the ROMs side. With ROMs on the card, saves go to the card; internal ROMs and their saves are hidden
  while that card is in.
- On the card, a missing or symlinked BIOS folder falls back to `~/BIOS/retroarch`, a media folder that exists but is not
  a real folder to `~/Media`, both logged.
- `ROMs/` is matched as written. System folders are the lowercase ES-DE names (`ROMs/gba`, `roms/psx`).
- `<core>` is RetroArch's core name (`mGBA`, `PCSX-ReARMed`). `<system>` is the ROM's first folder under `roms/`, so
  `roms/psx/<game>/<game>.m3u` keeps `roms/savestates/psx/`.
- EmuDeck's own `Emulation/saves/retroarch` links are not read or touched.

The pick creates no folder. It goes to `$XDG_RUNTIME_DIR/microemu/paths` (`layout`, `root`, `roms`, `bios`, `saves`,
`states`, `screenshots`, `media`, `saves_in_content`) and through `microemu-reconcile paths <settings dir>` into
`es_settings.xml`: `ROMDirectory`, `MediaDirectory` and `LegacyGamelistFileLocation` (`true` on a ROCKNIX card), written at
every ES-DE start, so an edit in ES-DE's menu does not stay. A value holding `"`, a CR or LF, or not valid UTF-8 is
refused and logged, nothing written. `custom_systems/es_systems.xml` maps the `<path>` of a system a layout names
differently (no shipped system needs it).

Before the first pick the client waits up to 10 s, 20 polls of 0.5 s, while `systemctl list-jobs --no-legend
'microos-automount@*'` lists a job or such a unit is activating (a card in fsck). While ES-DE runs, a changed pick (card in
or out, layout, rw to ro) stops ES-DE when `microemu-game-running` reports no game, or once the game ended (SIGKILL when
it is still running 10 s after SIGTERM), writes the new pick and starts ES-DE again. That restart never runs `microos-session back`.

ROCKNIX cards go back to ROCKNIX as they are. ES-DE reads and writes `roms/<system>/gamelist.xml` and shows ROCKNIX's
scraped art where ES-DE has none (MicroOS's `es-de` patches); ES-DE's own scrapes go to `roms/downloaded_media/`.

- "Saves per core" and "States per core" have no effect on a ROCKNIX card.
- ROCKNIX keeps numbered, compressed state slots. The slot picked in RetroArch's menu loads, the newest is not picked by
  itself.
- ROCKNIX states do not load for `atari2600` (Stella 2014 here, Stella on ROCKNIX) and `snes` (bsnes-mercury here,
  Snes9x on ROCKNIX).
- ES-DE's orphaned data cleanup moves out ROCKNIX entries whose extension the shipped systems lack, backed up in
  `roms/CLEANUP/<date>/<system>`.

## RetroArch

`/usr/libexec/microemu/bin/retroarch -L /usr/lib64/libretro/<core>_libretro.so <rom>` is the only way ES-DE starts
RetroArch. It exits 1 with a log line unless `gamescope-session-plus@microemu.service` is active, and unless the
arguments are exactly `-L`, a core directly under `/usr/lib64/libretro/` and an absolute ROM path, which is what ES-DE
passes. It also exits 1 without `$XDG_RUNTIME_DIR/microemu/paths` (the pick ES-DE started with), and for a ROM whose
`realpath` is not under the pick's `roms`. It writes its PID to
`$XDG_RUNTIME_DIR/microemu/launching` and removes the file when it exits. It drops `/var/lib/microos/openh264` from
`LD_LIBRARY_PATH` (unset when nothing else is left). Then it creates `~/.config/microemu/retroarch/retroarch.cfg` (when
absent) and the data dirs, and the pick's save, state and screenshot folders, the only place a folder is made on a card:
each existing part a real directory, not a symlink, the result inside the side's root (the card or `~`), nothing for
ROCKNIX saves. A failed check or `mkdir` exits 1, with no fallback to internal storage. It writes
`$XDG_RUNTIME_DIR/microemu/retroarch-paths.cfg`:

| Key | MicroOS, EmuDeck | ROCKNIX |
|---|---|---|
| `savefile_directory` | the pick's saves | the card's `roms` |
| `savestate_directory` | the pick's states | `roms/savestates/<system>` |
| `system_directory`, `screenshot_directory` | the pick's BIOS and screenshots | same |
| `savefiles_in_content_dir` | `false` | `true` |
| `savestates_in_content_dir`, `systemfiles_in_content_dir`, `screenshots_in_content_dir` | `false` | `false` |
| `sort_savefiles_by_content_enable`, `sort_savestates_by_content_enable`, `sort_screenshots_by_content_enable` | `false` | `false` |
| `sort_savefiles_enable`, `sort_savestates_enable` | not written (MicroSET) | `false` |

It copies the core files and remaps (below) when missing, runs `microemu-game-free` (waits up to 8 s of boottime while
`microemu-game.scope` is still stopping), the reconcile, and runs, waiting for it,

```
systemd-run --user --scope --collect --expand-environment=no --unit=microemu-game \
    --property=BindsTo=gamescope-session-plus@microemu.service --property=After=gamescope-session-plus@microemu.service \
    --property=TimeoutStopSec=5 -- /usr/bin/retroarch -c ~/.config/microemu/retroarch/retroarch.cfg \
    --appendconfig "/usr/share/microemu/retroarch/microemu.cfg|$XDG_RUNTIME_DIR/microemu/retroarch-paths.cfg" -L <core> <rom>
```

After the game it runs `microemu-game-free` and the reconcile again. ES-DE waits for it; its exit code is the game's.

RetroArch saves its whole config on exit, SIGTERM included, so the ROCKNIX `false` of the two sort keys lands in
`retroarch.cfg`. Before a ROCKNIX launch the wrapper records their values in `~/.local/state/microemu/pinned-keys`
(`<key>=<value>`, or `<key>` alone when absent). Every `microemu-reconcile retroarch` first puts a recorded value back (an
absent key is removed again), and drops the record when `microemu-game.scope` is `inactive` or `failed`, so a killed
wrapper is covered at the next launch. A change of those two rows in RetroArch's menu during a ROCKNIX game is not kept.

`microemu.cfg` is applied over `retroarch.cfg` at every launch, `retroarch-paths.cfg` over both:
`menu_driver = "rgui"`, `video_fullscreen = "true"`, `desktop_menu_enable = "false"` (Fedora's build crashed about 1 in
3 starts with the Qt companion on), `input_menu_toggle = "nul"` and `input_menu_toggle_gamepad_combo = "2"` (L3 + R3),
`autosave_interval = "10"`, online and core updaters hidden, Fedora's cores, info and pad profiles, the `udev` input and
joypad drivers, remaps, playlists, logs, thumbnails, core assets and cache under `~/.local/share/microemu/retroarch/`, the config dir `~/.config/microemu/retroarch/config` and the shader dir
`/usr/share/microemu/retroarch/shaders`.

The pad is InputPlumber's Xbox 360 pad, which RetroArch maps by position (the bottom button is RetroPad B). Core
remaps under `/usr/share/microemu/retroarch/remaps/<core>/` are copied to `~/.local/share/microemu/retroarch/remaps/<core>/`
when missing and swap A and B for mGBA, Gambatte, Nestopia, Beetle VB and Game & Watch, and A, B, X and Y for
bsnes-mercury, so the pad's labels match the console's.

Core files under `/usr/share/microemu/retroarch/config/<core>/` are copied to `~/.config/microemu/retroarch/config/<core>/`
when missing: `Gambatte.opt` (accurate GBC color correction, LCD ghosting, `GBC - Pastel Mix` palette, boot ROM when
`gb_bios.bin` or `gbc_bios.bin` is in the BIOS folder), `mGBA.opt` (`mgba_interframe_blending = "mix_smart"`), and
`<core>.cfg` with one frame of run ahead and rewind (granularity 15, muted) for Gambatte, mGBA, Nestopia, Stella 2014,
ProSystem, Handy, Beetle NeoPop, Beetle PCE Fast, Beetle VB, Beetle WonderSwan and Game & Watch, rewind only for
bsnes-mercury (its save states are not deterministic). Core presets in the shader dir's `presets/<core>/`: Nestopia
Retro Crisis GDV-NTSC `1080p Flat/RC GDV-NTSC - NES - Clean`, bsnes-mercury `1080p Flat/RC GDV-NTSC - SNES - Clean`.
`crt-guest-advanced-fast`, `crt-guest-advanced-fastest` and the 4K Flat Clean presets ship for Quick Menu > Shaders.

`shaders.sh` installs 37 files of libretro's [slang-shaders](https://github.com/libretro/slang-shaders) at
`e1d75632a205c70f14a4cc947c46d5abb7b3f7f1` and four presets of [Retro Crisis
GDV-NTSC](https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC) `20260321`, each against its sha256; the install fails
when a shipped preset or shader references a missing file. `shaders-audit` lists the license each file states. The LCD
grid and pixel transparency shaders state no license, so they and the Gambatte and mGBA LCD presets are not shipped.

A game resumes from its last auto state, so an in game save made after that state can be lost when RetroArch is killed
instead of quit.

ES-DE systems, each with the bundled 3.5.0 system's name, path (`%ROMPATH%/<name>`, `<ROMDirectory>/<name>` from the
pick), extensions, platform and theme:

| System | Core |
|---|---|
| `atari2600` | `stella2014` |
| `atari7800` | `prosystem` |
| `atarilynx` | `handy` |
| `fds`, `nes` | `nestopia` |
| `gameandwatch` | `gw` |
| `gb`, `gbc` | `gambatte`, `mgba` as a second command |
| `gba` | `mgba` |
| `ngp`, `ngpc` | `mednafen_ngp` |
| `pcengine`, `pcenginecd` | `mednafen_pce_fast` |
| `psx` | `pcsx_rearmed` |
| `snes` | `bsnes_mercury_performance` |
| `virtualboy` | `mednafen_vb` |
| `wonderswan`, `wonderswancolor` | `mednafen_wswan` |

## Theme

[Art Book Next (ES-DE Edition)](https://github.com/anthonycaccese/art-book-next-es-de) by Anthony Caccese, at
`d772d07109701d9bd7c9fda305bfef6601105ab8`, unmodified. `theme.sh` fetches the GitHub archive (sha256 pinned) and
unpacks it to `/usr/share/microemu/es-de/themes/art-book-next-es-de/`, dirs 0755 and files 0644. The README's Credits and License sections go to
`/usr/share/licenses/microemu/art-book-next.txt`.

`microemu-client` links every theme there into `~/.local/share/microemu/ES-DE/themes/`, replacing a link or file of the
same name; a real directory of that name is kept and logged.

## Volume Pill

`/usr/libexec/microemu/microemu-osd`, started by `microemu-client` with `GDK_BACKEND=x11` (python3, GTK 3, cairo,
Pango, `NO_AT_BRIDGE=1`). It runs `pactl subscribe` and on each `change` event of a sink or the server reads `wpctl
get-volume @DEFAULT_AUDIO_SINK@` (0 to 100, 0 when muted); a level that differs from the last shows the pill. When
`pactl subscribe` ends it starts again 2 s later. The pill is the top row style of Art Book Next (`systemstatus`, 3:2,
medium font size): `111111ee`, radius 0.01 W, the speaker glyph and `N%` (`X` at 0) in `ffffff` Mulish Light, 0.7 of a
0.0417 H row, padding 0.0097 W left, 0.0109 W right and 0.0104 H top and bottom, the text cell as wide as `100%`. It sits
on the system status row, 0.005 W left of where ES-DE's status pill starts with every entry shown. It stays 1000 ms after
the last change, then fades out in 250 ms.

The window is the root's size, transparent outside the pill, with an empty input shape, `STEAM_OVERLAY=1` and no
focus, so gamescope draws it over ES-DE and games and input stays with the app. It is mapped only while the pill shows.
The font comes from the theme's `_inc/fonts` through `$XDG_RUNTIME_DIR/microemu/osd-fonts.conf`. The glyph is
`/usr/share/microemu/osd/speaker.svg`, Art Book Next (Batocera Edition)'s `menu-icon-sound.svg`, fetched by `osd.sh`
at a pinned revision and sha256. `microemu-osd --render <png> <width> <height> <level> [<alpha>]` draws one frame.

## Tests

`just test` runs the session, client, storage layout, reconcile, RetroArch, OSD and asset tests; `just test-android` the
Android ones. `layout-test.sh` builds a stat shim with `cc`. `retroarch-run-test.sh` runs Fedora's RetroArch with the mGBA
and PCSX ReARMed cores on generated ROMs per layout, and is skipped without them or `xorriso`.
`osd-test.sh` renders the pill when `dist/` holds the theme fonts and `speaker.svg` (`just install` first;
`MICROEMU_OSD_TEST_THEME` and `MICROEMU_OSD_TEST_SPEAKER` override). The test pin overrides of `shaders.sh`, `osd.sh`,
`stub.sh` and `microemu-gapps-install`, and `microemu-client`'s `MICROEMU_TEST_FOLDERS` rows, apply only with
`MICROEMU_TEST=1`.

## Android

Not installed. The pieces stay under `android/data/` with the paths they would install at; `game-stop.d/50-android` and the `androidgames` system are left out of `data/`. They still use `~/ROMs/androidgames`; they move to the storage pick with the Android work.

The `androidgames` system lists `.apk`, `.play` and `.update` files under `~/ROMs/androidgames/` and runs `/usr/libexec/microemu/microemu-apk
<apk>`. Every Android game runs in one persistent Lepton context, `microemu-play`
(`~/.local/share/lepton/contexts/microemu-play`), through Steam's Lepton and Armada's `lepton-armada`. The container lives
for one game: only a stopped container gives ES-DE focus back.

`microemu-apk` exits 1 with a journal line outside the microemu session, when `lepton-armada` is missing, for a file that
is not an `.apk`, or for one outside `$HOME` and `/run/media/$USER` (the only host paths `lepton-armada` mounts into the
container). An `.update` entry runs `microemu-play-update --no-block` and returns. Otherwise it stops
`microemu-play-update.service`, removes a `lepton-headless-microemu-play` container left with that unit `inactive` or
`failed` (`removed a leftover lepton-headless-microemu-play`), runs `microemu-game-free`, and runs itself in the
`microemu-game` scope (`systemd-run --expand-environment=no`, as the RetroArch wrapper). There, with an EXIT trap that stops `microemu-play.service` (`--no-block` on a signal):

1. `microemu-sideload prepare`: the package name, and OBB files (`obb/*.obb` beside the APK or `*.obb` in its directory)
   copied to the context's `external/Android/obb/<pkg>/` when missing or changed.
2. The session check again, then `systemctl --user start microemu-play.service`, which blocks until Android booted. A failed start whose `Result` is
   `success` logs `android start canceled` (a stop during the boot, an LC hold); any other result logs `android failed
   to start (<result>), see ~/.local/share/microemu/android/boot.log and journalctl --user -u microemu-play.service`, or
   `android failed to start: <reason>` when `microemu-play-run` refused with a reason (it writes it to
   `$XDG_RUNTIME_DIR/microemu/play-start-failed`); the unit is then `reset-failed`. Canceled means `Result` `success` and the marker
   `$XDG_RUNTIME_DIR/microemu/play-stop-requested`, which the `50-android` hook, `microemu-stop` and `microemu-apk`'s trap
   write before they stop the unit and `microemu-apk` clears before the start; `Result` `success` without it is a start
   job refused before the unit ran: `android failed to start (start job failed: <ActiveState>/<SubState>)`.
3. Fuzz 512 on `ABS_X`, `ABS_Y`, `ABS_RX`, `ABS_RY` of each InputPlumber `xb360` node (`Microsoft X-Box 360 pad`,
   `045e:028e`; `microemu-pad-nodes`, `microemu-pad-fuzz`): the PM2's right stick jitters at rest and Android dispatches
   every change. No node: `no InputPlumber xb360 pad node, starting without a pad`, touch only.
4. `microemu-sideload install` (below).
5. `microemu-apk-watch <pkg>` in the background, then `cmd package resolve-activity` for the launcher component and
   `am start -n`. The watcher reads `logcat -b events` for `wm_set_resumed_activity` and `am_proc_died` from the
   guest's current time, arms once `<pkg>` is resumed, and ends the game on the launcher resuming once armed (B on the
   game's root activity, after waiting up to 1 s for its `wm_on_stop_called` so it can save), the process dying, or the stream
   ending: `<pkg> launcher|died|eof, ending the game`, `am force-stop`.
6. The trap's blocking stop of `microemu-play.service`; ES-DE has focus again.

`microemu-play.service` (`BindsTo=` the session, no `After=`, `Type=notify`, `TimeoutStartSec=60`, `TimeoutStopSec=10`)
runs `microemu-play-run`, which writes `$XDG_RUNTIME_DIR/microemu/lepton/containers.conf` (passed as
`CONTAINERS_CONF_OVERRIDE`) and runs `lepton-armada start microemu-play` as a child:

| Setting | Value |
|---|---|
| annotation | `run.oci.systemd.subgroup=app-steam-app1-1.scope`: gamescope takes the Android window's appid from the container's cgroup name, so it can take focus over ES-DE |
| mounts | each `xb360` node at the same path, `rw`; `$XDG_RUNTIME_DIR/microemu/lepton/odm-build.prop` over `/vendor/odm/etc/build.prop`, `ro` |
| odm build.prop | Lepton's own (`images/rootfs/vendor/odm/etc/build.prop`) plus `ro.sf.lcd_density` from `/usr/share/microemu/android/display` (`density=213`: a portrait app's 426 px column is 320 dp), `qemu.hw.mainkeys=1` (no navigation bar, B is Back), `debug.mesa.tu.debug=noubwc` (Turnip's UBWC off) and `pm.dexopt.install=speed` (installs and updates compile with `speed`) |
| environment | `TERM=dumb`, `APP_WANTS_FLATSCREEN=true`, `GAMESCOPE_WAYLAND_DISPLAY=gamescope-0`, `STEAM_COMPAT_DATA_PATH` the context (shared storage kept in `external/`), `LEPTON_NO_CLEANUP=true`, `LEPTON_KEEP_CONTEXT=1`, no `SteamAppId` or `LD_LIBRARY_PATH`; `internal/` created first |

Lepton's output before the boot goes to the journal, after it to `~/.local/share/microemu/android/lepton.log`. A
`logcat -b main -b system -b crash` stream from the moment `logd` runs goes to `boot.log`, emptied at each start.
While no `steam` process runs, a reader on `~/.steam/steam.pipe` logs each line Android writes there (`android asked to
open <uri>`), so a writer never blocks. It opens the path only while it is a FIFO and without creating it, and stops
when the FIFO is replaced or removed; with no such FIFO it is skipped. `lepton start exited with <rc>` goes to the
journal and `lepton.log`; a stop request makes `microemu-play-run` wait for Lepton instead of dying first, and the read
loop ends once Lepton is gone even when a descendant still holds its output open. Ready is Lepton's `Boot
complete!` line with the container running and `sys.boot_completed` 1 (Lepton prints the line also when the container
died); Lepton exiting before that is `android exited during boot, see .../boot.log` and exit 1. A missing or
changed `microemu-stamp` (Lepton and image versions) extends the start timeout to 120 s. A
`privapp-permissions whitelist` line in the boot log writes `privapp-log`; while that file exists the odm build.prop gets
`ro.control_privapp_permissions=log` and the journal says `privapp log mode`. `microemu-play-stop` runs `podman stop -t 1
lepton-microemu-play` (the container ignores SIGTERM and is killed after 1 s; ES-DE has focus about 1.7 s after the
stop, the context intact); `SuccessExitStatus=137` keeps a container killed from outside (an OOM kill included) from failing the unit; `--post`, after every stop, also `podman rm -fi` and removes Lepton's leftover
`/tmp/lepton-context.*` prefix.

Before it reports ready, `microemu-play-run` applies the guest settings in `/usr/share/microemu/android/opts` that the
context has not had yet, in one `podman exec` (at most 30 s, `guest settings timed out`, the rest retried at the next
start), through `cmd_real`. They come from BruhMeh's
[Ayaneo-Handheld-Scripts](https://github.com/BruhMeh/Ayaneo-Handheld-Scripts) `First_Run_Optimizations.sh` at `168d1c9`:
`wifi_scan_always_enabled` and `ble_scan_always_enabled` 0, `send_action_app_error` 0, `ota_disable_automatic_update`
1, `alarm_manager_constants` `allow_while_idle_short_time=10000,allow_while_idle_long_time=20000`,
`captive_portal_mode` 0 (the script has 2), and `disable-user` for `com.android.printspooler`, `com.android.bips`,
`com.android.dreams.phototable`, `com.android.managedprovisioning` and `com.android.stk` when the package exists
(Lepton's image has none of them, so they are recorded absent). Each
line has an id; `microemu-opts` in the context holds the ids done (or absent), a failed one is logged and retried at the
next start, and an `unset <id>` line runs its undo command once for an id that was applied. Left out of the script:
the background restrictions on GMS and Play (`RUN_IN_BACKGROUND`, the restricted standby bucket, the GMS appops), so
Play Services keep updating; Gboard, `com.ayaneo.update`, the Google apps and `com.qti.pasrservice`, which are not
installed; `sm fstrim` (`/data` is a host directory); `pm trim-caches` (game caches); `use_freezer` (the
guest's cgroup2 is mounted read only, so nothing can be frozen) and `sys.use_fifo_ui` (the guest's realtime priority
limit is 0). These have no
effect on Android 11 and are left out: `sensor_privacy`, `send_security_reports`,
`master_sync_allow_background_in_battery_saver`, `job_scheduler_quota_controller_max_job_count_bg` and
`dalvik.vm.dex2oat-filter`.

Sideloads (`microemu-sideload install`), with per package state in `~/.local/share/microemu/android/sideload/<pkg>`:

- Package name and version code from Lepton's `apk-info-extractor`, cached by path, size and mtime.
- Installed with `cmd_real package install -r -g` (a split set, `base.apk` with `.armada-apks`, as an install session),
  then `appops set <pkg> MANAGE_EXTERNAL_STORAGE allow` and a `speed` compile. Reinstalled when the sha256 of
  its files changes, data kept.
- Refused: an older version code than installed, a package installed from Play (`installer` in `packages.xml`, or
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE`), a bad split list.
- A package whose file is gone is marked `stale`, never uninstalled; a file moved with the same content only updates
  the path. Nothing is marked when `~/ROMs/androidgames` is missing, empty or a link to an absent target.
  `microemu-android-prune [<pkg>...]` queues stale packages; the next `.apk` launch uninstalls the ones still stale, and
  keeps a failed uninstall queued with its state.

`microemu-play-reset` removes the context and the sideload state (refused while `microemu-play.service` or
`microemu-play-update.service` runs, `lepton-microemu-play` or `lepton-headless-microemu-play` exists, or `podman container
exists` fails); the next
launch boots a fresh context and installs every `.apk` again. Play games are gone with the context, so the sync after
that launch deletes their `.play` entries.

An LC hold while `microemu-play.service` is active, booting or stopping runs `microemu-game-stop`. Its `50-android` hook,
while the unit is active, starts the home activity (`am start -W -a android.intent.action.MAIN -c
android.intent.category.HOME`; `input keyevent KEYCODE_HOME` does nothing in Lepton's guest), waits up to 1 s for
the game's `wm_on_stop_called` event so it can save (the line names the activity class: it must equal the game's launcher activity from
`$XDG_RUNTIME_DIR/microemu/play-activity`, else, with no activity known, a class in the game's package; Launcher3's
own stop never counts), then force-stops the launched package (`$XDG_RUNTIME_DIR/microemu/play-pkg`, written by `microemu-apk` once it knows it: the
`.apk`'s or `.play`'s package, or Play Store's for a `.play` not installed), then starts a
`--no-block` stop of the unit; during the boot it only stops the unit. Each guest command is bounded at 1 s.
`microemu-stop` stops the game, then ES-DE, then waits for the unit with what is left of its 15 s. B on the game's root
activity reaches ES-DE about 2.6 to 3 s after the press (the watcher about 0.9 s plus up to 1 s waiting for the
game's onStop, measured 0.3 s; the container stop about 1.7 s).

### Google Play

Optional, and off until `microemu-gapps-install` runs. Google's APKs are not part of microemu: that command downloads them
on the device.

`microemu-gapps-install` (refused while `microemu-play.service` or `microemu-play-update.service` runs, or either container
exists):

1. Downloads MindTheGapps 11.0.0 arm64 `20230922_081122` and 14.0.0 arm64 `20250203_200051` from GitHub with `curl
   --proto =https --proto-redir =https` into `~/.cache/microemu/gapps/`, checked by size and sha256.
2. Extracts GSF, GmsCore 20.45.16, the permission and sysconfig XMLs from MTG 11 and Play Store 36.6.25 from MTG 14
   (MTG 11's Play Store has no arm64 libraries) into `~/.local/share/microemu/gapps/mtg11-20230922.vending-36.6.25.tmp/`,
   and writes `privapp-permissions-google-p.xml` with MTG 14's `com.android.vending` block. Every file is checked
   against its pinned sha256.
3. Writes `STAMP` last (`set=<name>`, then `<sha256> <size> <path>` per file), makes the set read only, renames it,
   points `current` at it (`ln -sfn` then `mv -T`), deletes the zips, and writes `~/ROMs/androidgames/Google Play.play`
   when missing (a reinstall restores it), and `Update Google Play.update` plus the marker
   `~/.local/share/microemu/gapps/update-entry` unless the marker exists. A complete set is left alone; a `.tmp` from an
   interrupted run is removed first.
4. Runs `microemu-play-update --setup` in the foreground and exits 1 with `Play services not updated, run microemu-gapps-install
   again` when it fails.

With the layer on (`current` exists, or the context's `microemu-stamp` names a set), every `microemu-play-run` start checks
that `current`, its `STAMP`, every listed file with its size, and the restrictions stub exist, and refuses with
`gapps tree incomplete, run microemu-gapps-install` otherwise: booting the context once without them makes Android drop
the GMS and GSF data (the account and the registration). It then mounts each tree file at its path and the stub, `ro`:

| Host | Container |
|---|---|
| `/usr/share/microemu/android/microemu-restrictions-stub.jar` | `/system/framework/microemu-restrictions-stub.jar` |
| `/usr/share/microemu/android/microemu-restrictions-stub.rc` | `/system/etc/init/microemu-restrictions-stub.rc` |

Lepton's SystemServer does not start `RestrictionsManagerService`, and Play crashes at start without a `restrictions`
service. The stub (`android/restrictions-stub/`) is a `Binder` registered as `restrictions` from a root `app_process`,
answering `IRestrictionsManager` with an empty `Bundle` and no provider. `build/stub.sh` builds it from source with
`platform-30_r03.zip`'s `android.jar` and R8 8.5.35 (both sha256 pinned, Armada's `BASE.env` pins) through `javac
--release 11` and D8, and checks the jar holds one `classes.dex` naming `RestrictionsStub`.

The first boot with a new set grants GMS location and contacts permissions, then records the set in `microemu-stamp`,
only when every grant succeeded (otherwise the next start retries).

`.play` entries in `~/ROMs/androidgames/` hold one package name. `microemu-apk` refuses them while the layer is off;
otherwise it starts the container, then the package's launcher activity, or Play Store's when the package is not
installed (`<pkg> not installed, opening Google Play`, the watcher on `com.android.vending`). `Google Play.play` opens
the store.

After every container stop, `microemu-android-sync` reads the context's `packages.xml` and Launcher3's `app_icons.db` on
the host and writes `<label>.play` for each package installed from Play (`installer="com.android.vending"`) that is not
a system or updated system package, not Play, GMS or GSF, and has a launcher label; a package already held by a
`.play` file anywhere under `~/ROMs/androidgames/` is skipped, so renamed or moved entries stay. Names drop control,
path and FAT illegal characters (`: ? * " < > |`) and are cut to 200 UTF-8 bytes; a failed write is logged and the
next package goes on. Before that it deletes every `.play` file under `~/ROMs/androidgames/` whose package was in
`packages.xml` at the previous sync and is not now (`removed <name>, <pkg> not installed`), except `Google Play.play`
and `com.android.vending`; the previous set is kept in `~/.local/share/microemu/android/play-installed`, so a `.play`
for a package that was never installed stays and opens Google Play. With `packages.xml` missing, unreadable or
without packages it deletes nothing and keeps the previous set. When it wrote or removed at least one
entry it creates `$XDG_RUNTIME_DIR/microemu/esde-reload`: ES-DE reads gamelists only at start (v3.5.0 has no reload
signal, file watch or IPC), so `microemu-client` restarts it after the game. ES-DE restarts on Android Games when Play
entries appear or go.
It reads the GSF ID first, from `gservices.db` into
`~/.local/share/microemu/gapps/gsf-id` and logs `GSF ID <id>, register it at https://www.google.com/android/uncertified`
when it changes. Sign in works once the ID is registered.

#### Updates

Play updates itself and GMS from a job that runs 10 min after boot, with or without an account. Updates run by hand: `microemu-play-update`, or `Update Google Play` in ES-DE's Android Games.

`microemu-play-update [--no-block] [--clear-play] [--setup]` refuses (journal line, exit 1) while `microemu-play.service`
runs, while `lepton-microemu-play` exists, with the layer off, or with `microemu-play-update.service already running`
(active or activating; no option is recorded then). Otherwise it starts `microemu-play-update.service` and
follows its journal; `--no-block` (the ES-DE entry) starts it and returns. The unit (`Type=oneshot`, `KillMode=mixed`,
`TimeoutStartSec=31min`, `Conflicts=` and `Before=microemu-play.service`, `SyslogIdentifier=microemu-play-update`, no
dependency on the session) checks again that `microemu-play.service` is inactive, then starts a private gamescope:
`$XDG_RUNTIME_DIR/microemu/headless/` emptied and made 0700, gamescope run as `--backend headless -W <width>
-H <height> --expose-wayland -R <dir>/ready -- sleep infinity` with `XDG_RUNTIME_DIR` set to that dir, width and height
from `/usr/share/microemu/android/display`, output in `~/.local/share/microemu/android/headless-gamescope.log`. It waits
up to 10 s for the `<X display> <wayland socket>` line gamescope writes to `ready` (`headless gamescope did not start`,
exit 1, otherwise), then runs `microemu-play-run --headless` with `GAMESCOPE_WAYLAND_DISPLAY=microemu/headless/<socket>`:
the same context and mounts minus microemu's pad nodes, Lepton context name `headless-microemu-play` (container
`lepton-headless-microemu-play`, `lepton.headless=true`, no window), `ARMADA_EXT_WAYLAND_DISPLAY=` (no second display),
no `systemd-notify`. The guest composer is on that gamescope, not the session's.
`microemu-play-run --headless` refuses without a socket at `$XDG_RUNTIME_DIR/<dir>/<socket>`; either mode refuses while
the other mode's container exists. The gamescope is stopped and the dir removed on every exit, and again by
`ExecStopPost=`. After `sys.boot_completed` is `1`, every 10 s the unit reads the versionCodes of
`com.google.android.gms` and `com.android.vending` from the context's `packages.xml` on the
host and logs each change, with a progress line every minute; Play's install status is not read. In maintenance runs it
also counts the `Session <id>:` lines under `Active install sessions:` in the guest's `dumpsys package installs` (an
unreadable list counts as a session): Play installs GMS about 80 s after its own update. The `dumpsys` runs in the
background, so a stop request does not wait for it. A `dex2oat` process in the guest (`pidof dex2oat64 dex2oat32
dex2oat`, an unreadable answer counts as one) holds every done rule like an install session.

| Run | Done (`podman exec ... sync`, `podman stop -t 5`, exit 0) | Otherwise |
|---|---|---|
| Setup: `--setup` (`microemu-gapps-install`), or GMS or Play not above the tree's 204516046 and 83662520 at the start | GMS and Play above the tree's versions | after 20 min `play services update not done after 20 min (GMS <v>, Play <v>)`, exit 1, plus a line naming `--clear-play` when GMS is still the tree's |
| Maintenance: both above the tree's at the start | 30 s after the last change of either with no install session, or `already current after 13 min` (counted from boot) with no change and no session; when a GMS session (`appPackageName=com.google.android.gms`) was seen and GMS did not change, the line is `GMS install session ended without an update (GMS <v>), Play backs off; microemu-play-update --clear-play schedules it at once` | `stopped after 20 min`, exit 0, or `stopped after 20 min with an install session active, run microemu-play-update again` |

When a run ends by a done rule or `already current`, before the stop it compiles with `speed` the apps whose versionCode in `packages.xml` changed since the
last compile (`cmd_real package list packages -3` plus GMS, GSF and Play; the compiled versions are kept in
`microemu-compiled` in the context), one `compile -m speed <pkg>` at a time, at most 10 min (`compile stopped after 10
min at <pkg>`, the next run goes on). Runs that end at the 20 min bound or with the GMS session line do not compile;
the next run does. A stop request during the compile syncs, stops the container after 1 s and exits
0 (`stop requested during the compile, the update is kept`).

`--clear-play` runs `pm clear com.android.vending` once Android booted, which makes Play schedule its updates at once;
it also resets Play's own settings, so it is not the default. `ExecStopPost=` is `microemu-play-stop --post --headless`,
so `microemu-android-sync` runs after it too.

Any Android launch stops a running update: `microemu-apk` stops the unit before its scope and resets its `failed`
state, and a start of
`microemu-play.service` stops it through `Conflicts=`. A RetroArch game and leaving the microemu session do not: the update runs on
until it ends or `device-off`. A stop is
`podman stop -t 1` (TERM to `microemu-play-run` and Lepton when no container exists yet), `stop requested, update
interrupted`, exit 2. In the foreground the command follows the journal with `-t microemu-play-update` and prints the
unit's `Result` when it is not `success`, or `stopped` when the start failed and the unit was reset meanwhile.

`microemu-android-sync` writes `Update Google Play.update` when the layer is on, the marker is absent and no `.update`
file exists under `~/ROMs/androidgames/`, then the marker (also when a `.update` file exists), so a deleted entry
stays deleted. `microemu-play-reset --gapps` also removes `~/.local/share/microemu/gapps/`, `Google Play.play` and
`Update Google Play.update`.


## License

GPL-2.0-or-later, see [LICENSE](LICENSE). The Art Book Next theme is by Anthony Caccese and the people credited in
`art-book-next.txt`, licensed CC BY-NC-SA 2.0; the volume glyph is from its Batocera Edition, credits in
`art-book-next-speaker.txt`, same license (https://creativecommons.org/licenses/by-nc-sa/2.0/). The shaders keep the
licenses in `shaders-audit`, Retro Crisis GPL-3.0. Google's APKs are not shipped: `microemu-gapps-install` downloads
them on the device.
