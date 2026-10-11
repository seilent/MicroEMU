# MicroEMU

An ES-DE emulation session for [Armada](https://github.com/armada-os/armada), shipped as a systemd-sysext overlay.

Status: builder and an empty sysext. Targets the AYANEO Pocket MICRO 2.

## Layout

| Path | Content |
|---|---|
| `sysext/` | Static overlay, copied into `dist/` as is. `/usr` only, nothing under `/etc`. |
| `build/` | `base.env` (pinned image), `Containerfile`, `build.sh`, device scripts for the dev loop. |
| `tests/` | Bash tests, binaries stubbed through `PATH`, paths through `MICROEMU_*` variables. |

`dist/usr/share/microemu/` holds `version` and `build-manifest` (image digest, `IMAGE_VERSION`, `VERSION_ID`, microemu
version, the builder's `rpm -qa`).

## Builder

The builder container is `FROM` the exact Armada image the device runs, pinned by digest in `build/base.env`
(`20261011.b995457`, the first with session drop-in support, the digest microdap pins). The image already carries what the build uses (`rpm`,
`mksquashfs`), so the Containerfile installs nothing. Build host is any podman on
arm64, or with an arm64 binfmt registered with the `F` flag (without it, mount the interpreter into the container).

## Recipes

| Recipe | Does |
|---|---|
| `just base` | Reads `IMAGE_VERSION`, `VERSION_ID` and the booted image digest from the device into `build/base.env`. |
| `just dist` | Builds the builder image and runs `build/build.sh`: checks the builder's `IMAGE_VERSION` and `VERSION_ID` and the `VERSION_ID` in `extension-release.microemu` against `base.env`, and the extension `ID` against the builder's, copies `sysext/`, writes `version` and `build-manifest`. |
| `just build` | `dist` plus `microemu-<ver>-armada<VERSION_ID>-arm64.raw` (squashfs, zstd). |
| `just dev` | Refuses when the device `IMAGE_VERSION`, `VERSION_ID` or digest differ from the manifest. Then rsyncs `dist/` to `/var/tmp/microemu/` and `build/device-apply` to `/var/tmp/microemu-apply` on the device and runs it as root: refuses unless `gamescope-session-plus@steam.service` is active (`MICROEMU_DEPLOY_ANY_SESSION=1` skips the check) and when `/var/lib/extensions/microemu.raw` exists, copies the stage to `/var/lib/extensions/microemu/` owned by root, runs `systemd-sysext refresh` and restarts polkit. Then `systemctl --user daemon-reload`. |
| `just off` | Copies `build/device-off` to `/var/tmp/microemu-off` and runs it as root on the device. |
| `just test` | `tests/build-test.sh`, `tests/device-apply-test.sh`, `tests/device-off-test.sh`. |

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
refuses a directory deploy beside `microemu.raw`). Then `systemd-sysext refresh` and `systemctl restart polkit`. Uninstall: `just off`, or
the same steps as `build/device-off`.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).
