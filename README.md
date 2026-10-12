# MicroEMU

An ES-DE emulation session for [Armada](https://github.com/armada-os/armada), shipped as a systemd-sysext overlay.

Status: runs on the AYANEO Pocket MICRO 2 (Armada `20261011.b995457`, 2026-10-13). Needs an Armada
image with session drop-in support (`/usr/lib/armada/sessions.d`, `armada-session-switch@.service`).

## Layout

| Path | Content |
|---|---|
| `sysext/` | Static overlay, copied into `dist/` as is, without `__pycache__` or `*.pyc`. `/usr` only, nothing under `/etc`. |
| `build/` | `base.env` (pinned image), `Containerfile`, `build.sh`, `esde.sh`, `retroarch.sh`, `shaders.sh` with `shaders-audit`, `theme.sh`, `osd.sh`, `stub.sh`, device scripts for the dev loop. |
| `android/restrictions-stub/` | Source of the `restrictions` binder stub and its init `.rc`, built by `build/stub.sh`. |
| `tests/` | Bash tests, binaries stubbed through `PATH`, paths through `MICROEMU_*` variables. `esde-test.sh` runs the real `curl`, `python3`, `mksquashfs` and `unsquashfs` (with `-o`) on the host, `systems-test.sh` runs `xmllint`, `stub-test.sh` and `gapps-install-test.sh` run `zip` and `unzip`, `sync-test.sh` runs `python3` with `sqlite3`, `play-update-test.sh` runs `python3`, `osd-test.sh` runs `python3` with `gi` (Pango, PangoCairo) and `cairo` and renders the pill when `dist/` holds the theme fonts and `speaker.svg` (`MICROEMU_OSD_TEST_THEME` and `MICROEMU_OSD_TEST_SPEAKER` override), `shaders-test.sh` runs `zip`, `unzip`, `curl` (file URLs) and `python3`. |

`dist/usr/share/microemu/` holds `version` and `build-manifest` (image digest, `IMAGE_VERSION`, `VERSION_ID`, microemu
version, the ES-DE version, asset sha256 and size, extracted tree size, the RetroArch version and core count, the slang-shaders commit, Retro Crisis zip sha256 and shader file count, the theme
revision, tarball sha256 and size, tree size, the speaker glyph's revision and sha256, the builder's `rpm -qa`). `paths` lists every file and link
the sysext ships.

## ES-DE

Upstream `ES-DE_aarch64.AppImage` 3.5.0, unmodified, extracted at build time to `/usr/lib/microemu/es-de/` and started
through its `AppRun` (a link to `usr/bin/es-de`). No FUSE mount at run time. `build/esde.sh` pins the GitLab package
file URL and the sha256 (132372640 byte asset), caches it in `build/cache/es-de/`, fetches again on a cache miss or a
bad hash, refuses a download with another hash, checks the little endian ELF64 header, reads the squashfs offset from it (the end of the
section header table) and unpacks it with `unsquashfs -o`. A failed download leaves nothing in the cache. The
extraction runs in a work directory inside `dist/`. The tree is 324 MB. ES-DE's MIT license goes to
`/usr/share/licenses/microemu/es-de.txt`; the third party licenses stay in the tree under `usr/share/es-de/licenses/`.

## Session

`gamescope-session-plus@microemu.service`, started by sddm from `microemu.desktop`. microemu registers it with Armada's
session-control through `/usr/lib/armada/sessions.d/microemu.conf` (`DESKTOP=microemu.desktop`,
`UNIT=gamescope-session-plus@microemu.service`), so `armada-session-switch@microemu.service` switches to it and
`armada-session-switch@gamemode.service` back.

| Path | Does |
|---|---|
| `usr/share/gamescope-session-plus/sessions.d/microemu` | `CLIENTCMD=/usr/libexec/microemu/microemu-client`, `GAMESCOPE_BIN=/usr/libexec/microemu/microemu-gamescope`, no `ORIENTATION` (landscape from the panel). `short_session_recover` starts the switch to game mode with `--no-block`. |
| `microemu-gamescope` | Drops `--steam` and execs `/usr/bin/gamescope` with the other arguments. Without `--steam`, gamescope focuses ES-DE and the windows it starts with no `STEAM_GAME` atoms. |
| `microemu-client` | Runs `microemu-game-stop` to clear what a previous session left, links `~/.local/share/microemu/ES-DE/custom_systems/es_systems.xml` to the shipped file (replacing a file, link or directory there) and removes `es_find_rules.xml` there, then starts `microemu-osd` (Volume pill) and runs ES-DE with `ESDE_APPDATA_DIR=~/.local/share/microemu/ES-DE`. While `$XDG_RUNTIME_DIR/microemu/esde-reload` exists and `microemu-game.scope` is not active (checked every second), it removes the file, sends ES-DE SIGTERM and starts it again in place, on the Android Games gamelist (`StartupSystem` `androidgames`, `StartupView` `gamelist` in `es_settings.xml`; the previous lines are kept in `settings/microemu-startup.saved` and put back after that ES-DE exits, or at the next client start, unless the startup setting was changed meanwhile). When ES-DE exits and the unit is `deactivating`, it blocks in `sleep infinity`. Otherwise (ES-DE quit, crash or missing) it runs `systemctl start armada-session-switch@gamemode.service`, retries once after 2 s, then blocks in `sleep infinity`; after a second failure it exits 1. |
| `microemu-leave session` | Inside the microemu session, `systemctl --no-block start armada-session-switch@gamemode.service`, then returns. Elsewhere a log line. |
| `microemu-game-stop` | Runs every executable in `/usr/libexec/microemu/game-stop.d/` in name order within 5 s in total (each hook gets what is left, SIGKILL 1 s after its bound; one that would start after the 5 s is skipped; a failure is logged, the rest still run), then `systemctl --user reset-failed`, `stop`, `reset-failed` of `microemu-game.scope`. A game that outlives the scope stops through a hook there. |
| `microemu-stop` | `ExecStop` of the session, bounded at 15 s (SIGKILL 2 s later): `microemu-game-stop`, then SIGTERM to the process whose `/proc/<pid>/exe` is `/usr/lib/microemu/es-de/usr/bin/es-de` and whose cgroup is the microemu session unit, every 500 ms up to 6 times or until it exits, then a blocking stop of `microemu-play.service` within what is left. |
| `microemu-pad xb360` | Sets every InputPlumber composite device to `xb360` plus `keyboard`, logging each device set or failed. Run by `microemu-pad.service` (`BindsTo=` and `After=` the session, wanted through `20-microemu-pad.conf`). |
| `30-microemu-stop.conf` | `ExecStop=-microemu-stop`, `ExecStopPost=-microemu-game-stop`, `TimeoutStopSec=25`, `TimeoutStopFailureMode=terminate`. |

ES-DE loads only microemu's systems: `/usr/share/microemu/es-de/es_systems.xml` has a top level `<loadExclusive/>` before `<systemList>`, and every
command in it is a `/usr/libexec/microemu/` wrapper. ES-DE's settings, game lists and media
live in `~/.local/share/microemu/ES-DE`; `~/ES-DE` is not used. The controller type goes back to the configured one when
session-control switches to game mode.

## RetroArch

Fedora 44 `retroarch-1.22.0-20.fc44`, `mbedtls-3.6.7-1.fc44` and 13 `libretro-*` core rpms, unmodified, fetched from
koji by `build/retroarch.sh` (sha256 pinned, cached in `build/cache/retroarch/`, 9.6 MB of rpms) and unpacked with
`rpm2cpio`:

| Path | From |
|---|---|
| `/usr/lib/microemu/retroarch/bin/retroarch` | `retroarch` |
| `/usr/lib/microemu/retroarch/lib64/libmbed*.so.*` | `mbedtls` (the only RetroArch dependency missing on the image) |
| `/usr/lib64/libretro/<core>_libretro.so` | the core rpms |
| `/usr/share/microemu/retroarch/info/<core>_libretro.info` | `retroarch`, for the 13 cores |
| `/usr/share/microemu/retroarch/autoconfig/udev/` | `retroarch` (pad profiles, `Microsoft X-Box 360 pad.cfg` among them) |
| `/usr/share/licenses/microemu/<rpm>/` | every license file of each rpm |
| `/usr/share/microemu/retroarch/shaders/shaders_slang/` | `build/shaders.sh`: 42 files of libretro's [slang-shaders](https://github.com/libretro/slang-shaders) at `e1d75632a205c70f14a4cc947c46d5abb7b3f7f1` (each fetched from that commit and checked against its own sha256) and the 1080p Flat and 4K Flat NES and SNES Clean presets of [Retro Crisis GDV-NTSC](https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC) `20260321` (zip sha256 pinned), cached in `build/cache/shaders/`; the build fails when a shipped preset or shader references a missing file |
| `/usr/share/microemu/retroarch/shaders/presets/<core>/<core>.slangp` | microemu's core presets, read only |
| `/usr/share/licenses/microemu/slang-shaders/AUDIT`, `retro-crisis/LICENSE` | the license each shipped shader file states (several state none), Retro Crisis's GPL-3.0 |

Cores: `stella2014`, `prosystem`, `handy`, `nestopia`, `bsnes_mercury_performance`, `gambatte`, `mgba`, `gw`,
`mednafen_ngp`, `mednafen_pce_fast`, `pcsx_rearmed`, `mednafen_vb`, `mednafen_wswan`.

`/usr/libexec/microemu/bin/retroarch -L /usr/lib64/libretro/<core>_libretro.so <rom>` is the only way ES-DE starts
RetroArch. It exits 1 with a log line unless `gamescope-session-plus@microemu.service` is active, and unless there is
exactly one `-L` naming a core directly under `/usr/lib64/libretro/`; it refuses `--libretro`, `--config`,
`--appendconfig` and any short option cluster holding `L` or `c` other than the one `-L`. Then it creates `~/.config/microemu/retroarch/retroarch.cfg` (when absent) and the data directories,
applies the defaults and copies the core files (below), unsets `LD_LIBRARY_PATH`, runs `microemu-game-free` (waits up to 8 s
while `microemu-game.scope` is still stopping, then `reset-failed`; otherwise exit 1, `microemu-game.scope is still
stopping`) and

```
systemd-run --user --scope --collect --expand-environment=no --unit=microemu-game \
    --property=BindsTo=gamescope-session-plus@microemu.service --property=After=gamescope-session-plus@microemu.service \
    --property=TimeoutStopSec=5 -- /usr/bin/env LD_LIBRARY_PATH=/usr/lib/microemu/retroarch/lib64 \
    /usr/lib/microemu/retroarch/bin/retroarch -c ~/.config/microemu/retroarch/retroarch.cfg \
    --appendconfig /usr/share/microemu/retroarch/microemu.cfg -L <core> <rom>
```

ES-DE waits for it; its exit code is the game's. `microemu.cfg` is applied over `~/.config/microemu/retroarch/retroarch.cfg` at every launch:
`menu_driver = "rgui"` (no assets), `video_fullscreen = "true"` (the 960x640 output; windowed, RetroArch sizes the
window from `video_scale`), `desktop_menu_enable = "false"` (Fedora's build has Qt 6 and with it on builds the Qt
desktop companion at every start, which crashed about 1 in 3 starts), `input_menu_toggle = "f15"` (RC), `autosave_interval = "10"`, online and core
updaters hidden, cores, info and pad profiles from the paths above, the `udev` input and joypad drivers (under the
`x` input driver gamescope turns RC's F15 into `XF86Launch6`, which RetroArch does not map to `f15`), saves, states, system
(BIOS) files, screenshots, remaps, playlists, logs, thumbnails, core assets (`downloads`) and cache under
`~/.local/share/microemu/retroarch/`, the config dir `~/.config/microemu/retroarch/config` and the shader dir
`/usr/share/microemu/retroarch/shaders`.

Defaults, from `/usr/share/microemu/retroarch/defaults` (`<version> <target> <key> <from> <value> [present]`, the target
`retroarch.cfg` or a core's override `config/<core>/<core>.cfg`): for each version with no
`~/.config/microemu/retroarch/.defaults-<n>` yet, a launch sets each of its keys that is still at `<from>` (and, without
`present`, a missing one), leaves any other value, then writes the marker. A new line always takes a version higher than
any used before; a used number such as 2 or 3 is never reused, since its marker may already exist. The values are the scripts'
`retro_arch_common_auto_config.sh`:

| Key | Value |
|---|---|
| `video_driver` | `vulkan` |
| `fps_show`, `video_shader_enable` | `true` |
| `audio_block_frames` | `192` |
| `sort_savefiles_enable`, `sort_savestates_enable` | `true` (RetroArch's own default: saves and states per core) |
| `savestate_auto_index`, `savestate_auto_load`, `savestate_auto_save` | `true` |
| `savestate_max_keep` | `10` |
| `quit_on_close_content`, `quit_press_twice` | `1`, `false` (closing content returns to ES-DE) |
| `menu_shader_pipeline` | `1` |

Version 4 replaces values earlier microemu builds wrote, only where they are still those values: `video_driver`
`glcore`, `audio_block_frames` `0`, `savestate_max_keep` `0` and `menu_shader_pipeline` `2` in `retroarch.cfg`, and
`video_threaded = "true"` in the bsnes-mercury, PCSX ReARMed and Nestopia overrides (set to `false`). Version 5 sets
`video_scale_integer` from the scripts' `true` to `false`: games fill the 640 px height at the core's aspect ratio.
Version 6 sets `input_player1_analog_dpad_mode` to `1` when missing or `0`: the left stick works as the d-pad, except
in a core that asks for analog input (PCSX ReARMed with a DualShock).

From the scripts and not applied: Ozone (microemu's menu is RGUI), run ahead and rewind as global keys (per core here),
`sort_*_by_content_enable` (saves stay per core), device vibration and the Android download steps.
`run_ahead_secondary_instance` keeps RetroArch's default `true`, as the script's line (two spaces before `=`) leaves
it; `input_overlay_enable` (`false`), `quick_menu_show_shaders`, `auto_shaders_enable` and
`video_shader_preset_save_reference_enable` (`true`) are already at the scripts' values.

The pad is InputPlumber's Xbox 360 pad, which RetroArch maps by position (the bottom button is RetroPad B). Core
remaps under `/usr/share/microemu/retroarch/remaps/<core>/` are copied to `~/.local/share/microemu/retroarch/remaps/<core>/`
when missing and swap A and B for mGBA, Gambatte, Nestopia, Beetle VB and Game & Watch, and A, B, X and Y for
bsnes-mercury, so the pad's labels match the console's. PS1 and the other cores stay by position.

A game resumes from its last auto state, so an in game save made after that state can be lost when RetroArch is killed
instead of quit.

Core files under `/usr/share/microemu/retroarch/config/<core>/` are copied to `~/.config/microemu/retroarch/config/<core>/`
when missing, never over a file that exists: `Gambatte.opt` (accurate GBC color correction, LCD ghosting, `GBC - Pastel
Mix` palette, boot ROM when `gb_bios.bin` or `gbc_bios.bin` is in the system dir), `mGBA.opt`
(`mgba_interframe_blending = "mix_smart"`), and `<core>.cfg` with one frame of run ahead and rewind (granularity 15,
muted) for Gambatte, mGBA, Nestopia, Stella 2014, ProSystem, Handy, Beetle NeoPop, Beetle PCE Fast, Beetle VB, Beetle
WonderSwan and Game & Watch, rewind only for bsnes-mercury (its save states are not deterministic, so RetroArch turns
run ahead off); PCSX ReARMed gets none. RetroArch loads core presets from
the shader dir's `presets/<core>/` after a preset of the same name in the config dir: Gambatte LCD grid with pixel transparency,
mGBA LCD grid with SP101 color, Nestopia Retro Crisis GDV-NTSC `1080p Flat/RC GDV-NTSC - NES - Clean`, bsnes-mercury
`1080p Flat/RC GDV-NTSC - SNES - Clean` (the presets the scripts' `nestopia_auto_config.sh` and `bsnes_auto_config.sh`
reference). `crt-guest-advanced-fast`, `crt-guest-advanced-fastest` and the 4K Flat Clean presets ship too, for Quick
Menu > Shaders. A preset saved from
the menu goes to the config dir, since the shader dir is read only. The settings follow BruhMeh's
[Ayaneo-Handheld-Scripts](https://github.com/BruhMeh/Ayaneo-Handheld-Scripts) at `168d1c9`.

ES-DE systems, each with the bundled 3.5.0 system's name, path (`%ROMPATH%/<name>`, `~/ROMs/<name>` by default),
extensions, platform and theme:

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

## Android

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

## Theme

[Art Book Next (ES-DE Edition)](https://github.com/anthonycaccese/art-book-next-es-de) by Anthony Caccese, at
`d772d07109701d9bd7c9fda305bfef6601105ab8`, unmodified. `build/theme.sh` fetches the GitHub archive tarball (sha256
pinned, 219247637 bytes, cached in `build/cache/theme/`) and unpacks it to
`/usr/share/microemu/es-de/themes/art-book-next-es-de/` (227 MB). The README's Credits and License sections go to
`/usr/share/licenses/microemu/art-book-next.txt`.

`microemu-client` links every theme there into `~/.local/share/microemu/ES-DE/themes/`, replacing a link or file of the
same name; a real directory of that name (a copy put there by hand) is kept and logged, other themes stay. It adds these
keys to `~/.local/share/microemu/ES-DE/settings/es_settings.xml` when they are missing, so later changes in ES-DE's
menu stay:

| Key | Value |
|---|---|
| `Theme` | `art-book-next-es-de` |
| `ThemeColorScheme` | `dark-screenshots` |
| `ThemeVariant` | `gamelist-list-metadata-cover` |
| `ThemeFontSize` | `medium` |
| `ThemeAspectRatio` | `3:2` |
| `ApplicationUpdaterFrequency` | `never` (no online update check at start; microemu pins ES-DE) |

## Keys

`microemu-hotkeyd.service`, a user unit kept up by `Upholds=` from `default.target.d/50-microemu.conf`, reads `KEY_F14`
(LC, `MICROEMU_HOTKEYD_KEY` overrides) on `InputPlumber Keyboard` and the volume keys on `gpio-keys` and `pm8941_resin`
with non grabbing `evtest`. A hold is 1000 ms, timed from the press event; a release without a press is dropped.

| Session at the hold | LC hold |
|---|---|
| game mode | buzz, `systemctl --no-block start armada-session-switch@microemu.service` |
| game mode, a title running (`SteamLaunch AppId=`) | first hold logged; a second within 3 s switches |
| microemu, `microemu-game.scope` active, or `microemu-play.service` active, booting or stopping | buzz, `microemu-game-stop` in the background; holds while it runs are dropped |
| microemu | buzz, `microemu-leave session` |
| microdap | logged, ignored |
| Plasma (`plasmashell` running) | buzz, switch to microemu |
| anything else | logged, ignored |

Before acting, the daemon checks `/run/armada/session-switch.lock` with `flock -n -E 75`; exit 75 (held) drops the hold
with no buzz (`switch in progress, hold dropped`), any other error is logged and the lock taken as free, a missing
lock file counts as free. It keeps the last time it saw the lock held and the time the last game stop
ended, and drops any press whose event time is at or before either. Taps do nothing.

Volume keys act only in the microemu session. Each press adds 5%, a held key repeats after 400 ms, then every 100 ms.
One `wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ <n>%+` (or `-`) runs at a time; steps that arrive meanwhile go into
the next call as one sum. After each call, while `$XDG_RUNTIME_DIR/microemu/osd` is a FIFO, a background job reads
`wpctl get-volume @DEFAULT_AUDIO_SINK@` and writes the level (0 to 100, 0 when muted) to it with a non blocking open;
with no reader or a full pipe the line is dropped. One read runs at a time; a call that ends meanwhile gets a new read
after it, so the last line is the latest level.

## Volume pill

`/usr/libexec/microemu/microemu-osd`, started by `microemu-client` before ES-DE with `GDK_BACKEND=x11` (python3, GTK 3,
cairo, Pango; no accessibility bridge, `NO_AT_BRIDGE=1`). It replaces whatever is at `$XDG_RUNTIME_DIR/microemu/osd` with a FIFO and reads levels from it. Each level
shows a pill in the top row style of Art Book Next (`systemstatus`, 3:2, medium font size): `111111ee`, radius
0.01 W, the speaker glyph and `N%` (`X` at 0) in `ffffff` Mulish Light, 0.7 of a 0.0417 H row, padding 0.0097 W left,
0.0109 W right and 0.0104 H top and bottom, the text cell as wide as `100%`. It sits on the system status row, 0.005 W
(ES-DE's entry spacing) left of where ES-DE's status pill starts with every entry shown (Bluetooth, Wi-Fi, cellular,
battery and its percentage). It stays 1000 ms after the last level, then fades out in 250 ms.

The window is the root's size, transparent outside the pill, with an empty input shape, `STEAM_OVERLAY=1` (set with
`xprop` before the first map) and no focus, so gamescope draws it 1:1 over ES-DE and games as its overlay and input
stays with the app. It is mapped only while the pill shows. The font comes from the shipped theme's `_inc/fonts`
through `$XDG_RUNTIME_DIR/microemu/osd-fonts.conf` (the system config plus that dir), set for this process only. The
glyph is `/usr/share/microemu/osd/speaker.svg`, Art Book Next (Batocera Edition)'s `menu-icon-sound.svg`, fetched by
`build/osd.sh` at a pinned revision and sha256. If `microemu-osd` exits, the client logs `microemu-osd exited with <rc>`
and the session goes on without it. `microemu-osd --render <png> <width> <height> <level> [<alpha>]` draws one frame
to a PNG.

The buzz is 15 ms through `org.shadowblip.Output.ForceFeedback` on every composite device. Dry run: drop-in
`~/.config/systemd/user/microemu-hotkeyd.service.d/dryrun.conf` with `Environment=MICROEMU_HOTKEYD_DRY_RUN=1` logs `would:`
lines instead of acting. Without `InputPlumber Keyboard` after 15 s the daemon exits 0 and systemd restarts it 10 s later
(`RestartSec=10`); the same when the key stream ends. A volume stream that ends stops a running repeat.

## Guard

`microemu-guard.service`, a user oneshot wanted by `default.target` (`default.target.d/50-microemu.conf`), runs at each
login and after every dev loop. A user unit, because systemd's user manager starts after `systemd-sysext.service` merged the
extension. On systemd 259 `systemd-sysext refresh` reloads the service manager only when a merged extension-release
sets `EXTENSION_RELOAD_MANAGER=1`, so a system unit pulled in by a sysext `multi-user.target.d` drop-in would not load
at that boot without the key. microemu ships no system unit that has to run at boot, so `extension-release.microemu` does
not set it. It checks:

- `/usr/libexec/armada/session-control list-sessions` runs and prints `microemu` (drop-in support on the image, the
  microemu drop-in accepted).
- No path in `/usr/share/microemu/paths` exists in the booted deployment (resolved from `ostree=` on the kernel command
  line under `/sysroot`, its `usr/lib/os-release` required), and none in another extension under
  `/var/lib/extensions/`. Only directory extensions are scanned; `.raw` images are logged as not checked.

Each problem is a `user.warning` journal line (`journalctl --user -t microemu-guard`) and a line in
`$XDG_RUNTIME_DIR/microemu/drift`; a clean run logs `no drift` and leaves no file. `just test-paths` compares `dist/`
with microdap's `dist/` (`MICRODAP_DIST`, default `../MicroDAP/dist`) at build time.

## Builder

The builder container is `FROM` the exact Armada image the device runs, pinned by digest in `build/base.env`
(`20261011.b995457`, the first with session drop-in support, the digest microdap pins). The image already carries what the build uses (`curl`, `sha256sum`,
`od`, `dd`, `du`, `unsquashfs`, `mksquashfs`, `rpm`, `rpm2cpio`, `cpio`, `tar`, `unzip`); the Containerfile adds
`java-25-openjdk-devel` for the restrictions stub. Build host is any podman on arm64, or with an arm64 binfmt
registered with the `F` flag (without it, mount the interpreter into the container, `podman build --volume` and
`podman run -v` both).

## Recipes

| Recipe | Does |
|---|---|
| `just base` | Reads `IMAGE_VERSION`, `VERSION_ID` and the booted image digest from the device into `build/base.env`. |
| `just dist` | Builds the builder image and runs `build/build.sh`: checks the builder's `IMAGE_VERSION` and `VERSION_ID` and the `VERSION_ID` in `extension-release.microemu` against `base.env`, and the extension `ID` against the builder's, copies `sysext/`, runs `build/esde.sh`, `build/retroarch.sh`, `build/theme.sh` and `build/stub.sh`, writes `version` and `build-manifest`. |
| `just build` | `dist` plus `microemu-<ver>-armada<VERSION_ID>-arm64.raw` (squashfs, zstd). |
| `just dev` | Refuses when the device `IMAGE_VERSION`, `VERSION_ID` or digest differ from the manifest. Then rsyncs `dist/` to `/var/tmp/microemu/` and `build/device-apply` to `/var/tmp/microemu-apply` on the device and runs it as root: refuses unless `gamescope-session-plus@steam.service` is active (`MICROEMU_DEPLOY_ANY_SESSION=1` skips the check) and when `/var/lib/extensions/microemu.raw` exists, copies the stage to `/var/lib/extensions/microemu/` owned by root, runs `systemd-sysext refresh` and restarts polkit. Then `systemctl --user daemon-reload` and a restart of `microemu-hotkeyd.service` and `microemu-guard.service`. |
| `just test-paths` | `tests/paths-test.sh` against microdap's `dist/`: fails on any path both ship. |
| `just off` | Copies `build/device-off` to `/var/tmp/microemu-off` and runs it as root on the device. |
| `just test` | `tests/build-test.sh`, `tests/device-apply-test.sh`, `tests/device-off-test.sh`, `tests/esde-test.sh`, `tests/session-test.sh`, `tests/systems-test.sh`, `tests/client-test.sh`, `tests/leave-test.sh`, `tests/stop-test.sh`, `tests/pad-test.sh`, `tests/hotkeyd-test.sh`, `tests/retroarch-test.sh`, `tests/game-free-test.sh`, `tests/retroarch-build-test.sh`, `tests/shaders-test.sh`, `tests/theme-test.sh`, `tests/play-unit-test.sh`, `tests/apk-test.sh`,
`tests/sideload-test.sh`, `tests/android-hook-test.sh`, `tests/reset-test.sh`, `tests/pad-fuzz-test.sh`,
`tests/stub-test.sh`, `tests/gapps-install-test.sh`, `tests/play-update-test.sh`, `tests/sync-test.sh` (the download pin overrides of `build/stub.sh`, `build/shaders.sh`
and `microemu-gapps-install` apply only with `MICROEMU_TEST=1`), `tests/guard-test.sh`, `tests/paths-test.sh` (prints `skip` without `MICROEMU_OTHER_DIST`). |

`MICROEMU_DEVICE` overrides `armada@pm2`. Root steps run through `ssh -t` and `sudo`.

## Removal

`build/device-off`, as root (exits 1 otherwise):

1. Reads the `ActiveState` of `gamescope-session-plus@microemu.service` for the session account (`SUDO_USER`, else `armada`) at once and then every second up
   to 60 s. The first time it reads `active` or `activating`, it starts `armada-session-switch@gamemode.service` with
   `--no-block`.
2. Goes on when the state is `inactive` or `failed`, or empty while `user@<uid>.service` is not active, and no
   `/etc/sddm.conf.d/*.conf` has a `Session=microemu.desktop` line (whitespace and CR allowed). An empty state with
   systemd's user manager up is a failed query and counts as running. On timeout it exits 1 and changes nothing.
3. Stops `microemu-hotkeyd.service`, `microemu-pad.service`, `microemu-guard.service` and `microemu-play-update.service` as the account.
4. Removes `/var/lib/extensions/microemu`, `/var/lib/extensions/microemu.raw`, `/run/microemu` and the account's
   `$XDG_RUNTIME_DIR/microemu` only, then `systemd-sysext refresh`, `systemctl
   daemon-reload` and `systemctl --user daemon-reload` as the account.
5. Stops and resets `microemu-hotkeyd.service` again (`Upholds=` from `default.target` starts it again after step 3
   while the unit is still merged) and resets `microemu-play-update.service`, which a stop leaves `failed`.
6. `systemctl restart polkit`.

Other extensions (microdap) stay merged. Commands for the account run through `runuser`
with `XDG_RUNTIME_DIR` set.

## Rebuild per Armada release

Every Armada release (new digest or `VERSION_ID`) needs microemu rebuilt against it: `just base && just build`. A new
`VERSION_ID` also goes into `sysext/usr/lib/extension-release.d/extension-release.microemu`; the build fails until it
matches.

## Install contract

`systemd-sysext` merges an image only under the name in its `extension-release.<name>`, so the asset
`microemu-<ver>-armada<VERSION_ID>-arm64.raw` goes to `/var/lib/extensions/microemu.raw`, or the `dist/` tree to
`/var/lib/extensions/microemu/`, never both: remove the other form first (`just off` removes both; `device-apply`
refuses a directory deploy beside `microemu.raw`). Then `systemd-sysext refresh`, `systemctl restart polkit` and, as `armada`, `systemctl --user daemon-reload`. Install and
uninstall from game mode. Uninstall: `just off`, or
the same steps as `build/device-off`.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE). ES-DE is MIT licensed. RetroArch, mbedtls and the cores keep their own
licenses, shipped in `/usr/share/licenses/microemu/`. The Art Book Next theme is by Anthony Caccese and the people
credited in `art-book-next.txt`, licensed CC BY-NC-SA 2.0; the volume glyph is from its Batocera Edition, credits in
`art-book-next-speaker.txt`, same license (https://creativecommons.org/licenses/by-nc-sa/2.0/). Google's APKs are
not shipped: `microemu-gapps-install` downloads them on the device.
