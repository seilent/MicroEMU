# MicroEMU

An ES-DE emulation session for [Armada](https://github.com/armada-os/armada), shipped as a systemd-sysext overlay.

Status: the `microemu` gamescope session with ES-DE as its client, written, not run
on a device. No emulators yet. Targets the AYANEO Pocket MICRO 2. Needs an Armada image with session drop-in support
(`/usr/lib/armada/sessions.d`, `armada-session-switch@.service`).

## Layout

| Path | Content |
|---|---|
| `sysext/` | Static overlay, copied into `dist/` as is. `/usr` only, nothing under `/etc`. |
| `build/` | `base.env` (pinned image), `Containerfile`, `build.sh`, `esde.sh`, device scripts for the dev loop. |
| `tests/` | Bash tests, binaries stubbed through `PATH`, paths through `MICROEMU_*` variables. `esde-test.sh` runs the real `curl`, `python3`, `mksquashfs` and `unsquashfs` (with `-o`) on the host, `systems-test.sh` runs `xmllint`. |

`dist/usr/share/microemu/` holds `version` and `build-manifest` (image digest, `IMAGE_VERSION`, `VERSION_ID`, microemu
version, the ES-DE version, asset sha256 and size, extracted tree size, the builder's `rpm -qa`).

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
| `microemu-client` | Runs `microemu-game-stop` to clear what a previous session left, links `~/.local/share/microemu/ES-DE/custom_systems/es_systems.xml` to the shipped file (replacing a file, link or directory there) and removes `es_find_rules.xml` there, then runs ES-DE with `ESDE_APPDATA_DIR=~/.local/share/microemu/ES-DE`. When ES-DE exits and the unit is `deactivating`, it blocks in `sleep infinity`. Otherwise (ES-DE quit, crash or missing) it runs `systemctl start armada-session-switch@gamemode.service`, retries once after 2 s, then blocks in `sleep infinity`; after a second failure it exits 1. |
| `microemu-leave session` | Inside the microemu session, `systemctl --no-block start armada-session-switch@gamemode.service`, then returns. Elsewhere a log line. |
| `microemu-game-stop` | Runs every executable in `/usr/libexec/microemu/game-stop.d/` in name order within 5 s in total (each hook gets what is left, SIGKILL 1 s after its bound; one that would start after the 5 s is skipped; a failure is logged, the rest still run), then `systemctl --user reset-failed`, `stop`, `reset-failed` of `microemu-game.scope`. A game that outlives the scope stops through a hook there. |
| `microemu-stop` | `ExecStop` of the session, bounded at 15 s (SIGKILL 2 s later): `microemu-game-stop`, then SIGTERM to the process whose `/proc/<pid>/exe` is `/usr/lib/microemu/es-de/usr/bin/es-de` and whose cgroup is the microemu session unit, every 500 ms up to 6 times or until it exits. |
| `microemu-pad xb360` | Sets every InputPlumber composite device to `xb360` plus `keyboard`, logging each device set or failed. Run by `microemu-pad.service` (`BindsTo=` and `After=` the session, wanted through `20-microemu-pad.conf`). |
| `30-microemu-stop.conf` | `ExecStop=-microemu-stop`, `ExecStopPost=-microemu-game-stop`, `TimeoutStopSec=25`, `TimeoutStopFailureMode=terminate`. |

ES-DE loads only microemu's systems: `/usr/share/microemu/es-de/es_systems.xml` has a top level `<loadExclusive/>` before `<systemList>`, and every
command in it is a `/usr/libexec/microemu/` wrapper. ES-DE's settings, game lists and media
live in `~/.local/share/microemu/ES-DE`; `~/ES-DE` is not used. The controller type goes back to the configured one when
session-control switches to game mode.

## Builder

The builder container is `FROM` the exact Armada image the device runs, pinned by digest in `build/base.env`
(`20261011.b995457`, the first with session drop-in support, the digest microdap pins). The image already carries what the build uses (`curl`, `sha256sum`,
`od`, `dd`, `du`, `unsquashfs`, `mksquashfs`, `rpm`), so the Containerfile installs nothing. Build host is any podman on
arm64, or with an arm64 binfmt registered with the `F` flag (without it, mount the interpreter into the container).

## Recipes

| Recipe | Does |
|---|---|
| `just base` | Reads `IMAGE_VERSION`, `VERSION_ID` and the booted image digest from the device into `build/base.env`. |
| `just dist` | Builds the builder image and runs `build/build.sh`: checks the builder's `IMAGE_VERSION` and `VERSION_ID` and the `VERSION_ID` in `extension-release.microemu` against `base.env`, and the extension `ID` against the builder's, copies `sysext/`, runs `build/esde.sh`, writes `version` and `build-manifest`. |
| `just build` | `dist` plus `microemu-<ver>-armada<VERSION_ID>-arm64.raw` (squashfs, zstd). |
| `just dev` | Refuses when the device `IMAGE_VERSION`, `VERSION_ID` or digest differ from the manifest. Then rsyncs `dist/` to `/var/tmp/microemu/` and `build/device-apply` to `/var/tmp/microemu-apply` on the device and runs it as root: refuses unless `gamescope-session-plus@steam.service` is active (`MICROEMU_DEPLOY_ANY_SESSION=1` skips the check) and when `/var/lib/extensions/microemu.raw` exists, copies the stage to `/var/lib/extensions/microemu/` owned by root, runs `systemd-sysext refresh` and restarts polkit. Then `systemctl --user daemon-reload`. |
| `just off` | Copies `build/device-off` to `/var/tmp/microemu-off` and runs it as root on the device. |
| `just test` | `tests/build-test.sh`, `tests/device-apply-test.sh`, `tests/device-off-test.sh`, `tests/esde-test.sh`, `tests/session-test.sh`, `tests/systems-test.sh`, `tests/client-test.sh`, `tests/leave-test.sh`, `tests/stop-test.sh`, `tests/pad-test.sh`. |

`MICROEMU_DEVICE` overrides `armada@pm2`. Root steps run through `ssh -t` and `sudo`.

## Removal

`build/device-off`, as root (exits 1 otherwise):

1. Reads the `ActiveState` of `gamescope-session-plus@microemu.service` for the user at once and then every second up
   to 60 s. The first time it reads `active` or `activating`, it starts `armada-session-switch@gamemode.service` with
   `--no-block`.
2. Goes on when the state is `inactive` or `failed`, or empty while `user@<uid>.service` is not active, and no
   `/etc/sddm.conf.d/*.conf` has a `Session=microemu.desktop` line (whitespace and CR allowed). An empty state with the
   user manager up is a failed query and counts as running. On timeout it exits 1 and changes nothing.
3. Stops `microemu-hotkeyd.service` and `microemu-pad.service` as the user.
4. Removes `/var/lib/extensions/microemu`, `/var/lib/extensions/microemu.raw` and `/run/microemu` only, then `systemd-sysext refresh`, `systemctl
   daemon-reload` and `systemctl --user daemon-reload` as the user.
5. Stops and resets `microemu-hotkeyd.service` again: `Upholds=` from `default.target` starts it again after step 3
   while the unit is still merged.
6. `systemctl restart polkit`.

Other extensions (microdap) stay merged. The user is `SUDO_USER`, else `armada`; user commands run through `runuser`
with `XDG_RUNTIME_DIR` set.

## Rebuild per Armada release

Every Armada release (new digest or `VERSION_ID`) needs microemu rebuilt against it: `just base && just build`. A new
`VERSION_ID` also goes into `sysext/usr/lib/extension-release.d/extension-release.microemu`; the build fails until it
matches.

## Install contract

`systemd-sysext` merges an image only under the name in its `extension-release.<name>`, so the asset
`microemu-<ver>-armada<VERSION_ID>-arm64.raw` goes to `/var/lib/extensions/microemu.raw`, or the `dist/` tree to
`/var/lib/extensions/microemu/`, never both: remove the other form first (`just off` removes both; `device-apply`
refuses a directory deploy beside `microemu.raw`). Then `systemd-sysext refresh`, `systemctl restart polkit` and, as the user, `systemctl --user daemon-reload`. Install and
uninstall from game mode. Uninstall: `just off`, or
the same steps as `build/device-off`.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE). ES-DE is MIT licensed.
