# Fedora 44 audio setup (Wine-free)

Adapted from [`tuxaudio/linux-audio-setup-scripts`](https://github.com/tuxaudio/linux-audio-setup-scripts)
`fedora/43/install-audio.sh` (clone at `~/linux-audio-setup-scripts`, commit `9babae7`).

Kept outside that clone on purpose, so `git pull` there stays clean.
Part of `~/fedora44-setup` -- see the top-level `README.md` for how this
machine is put together.

## Why not just run the upstream script

Checked against this machine on 2026-09-21:

1. **It aborts partway and leaves rtkit masked.** Seven of the eight COPRs it
   enables no longer exist — `wine-mono`, `mingw-wine-gecko`, `vkd3d`,
   `wine-dxvk`, `winetricks`, `yabridge` and `libcurl-gnutls` were all
   consolidated into `patrickl/wine-tkg` and deleted. The script uses `set -e`,
   so it dies on `copr enable patrickl/wine-mono` — *after* it has already run
   `systemctl mask rtkit-daemon`. On this box PipeWire's `data-loop.0` gets its
   `SCHED_RR` priority purely from rtkit, so that leaves you with no realtime
   path and no Wine stack either.
2. **`wine-tkg` is older than Fedora's Wine.** The COPR has wine `9.21`; Fedora 44
   ships `11.0-3`, which is what is installed. `dnf install wine` would not
   downgrade, so you would silently keep Fedora Wine while `winetricks` and
   `wine-dxvk-dxgi` *would* be replaced by COPR builds — a mixed stack.
3. Minor: it appends to `/etc/security/limits.d/audio.conf` and `/etc/sysctl.conf`
   with `tee -a`, so re-running duplicates the entries, and it adds a second
   `@pipewire` block competing with Fedora's `25-pw-rlimits.conf`.

None of this touches the desktop — the upstream script makes no display-manager,
session, portal or `~/.config` changes, so the Hyprland/Plasma split is unaffected.

## What this version does

| Step | Default | Notes |
|---|---|---|
| `preempt=full` via grubby | on | Skipped if the kernel lacks `CONFIG_PREEMPT_DYNAMIC` (this one has it) |
| `/etc/security/limits.d/99-audio.conf` | on | `@pipewire` rtprio 90, nice -19, memlock unlimited. `99-` so it is read *after* Fedora's `25-pw-rlimits.conf` and wins |
| `/etc/sysctl.d/90-audio.conf` | on | swappiness 10, inotify watches 600000 — a drop-in instead of appending to `sysctl.conf` |
| add you to `pipewire` group | on | The group exists and is empty; this is what makes rtprio 90 reachable |
| REAPER (portable, `~/REAPER`) | on | Skipped if `~/REAPER` exists. `--no-reaper` to skip. The launcher entry is repaired on every run — see below |
| full `dnf update` | **off** | `--update`. Off by default because it would also pull Hyprland updates from the `lionheartp` COPR |
| `realtime-setup` + `realtime` group | **off** | `--realtime-setup`. Largely redundant: rtprio limits already apply to every process you own |
| mask `rtkit-daemon` | **off** | `--mask-rtkit`, and it refuses unless the rtprio limit is verified ≥ 90 |
| yabridge + Bottles + wineloader | **off** | `--yabridge`, scoped to the Plasma session. See below |
| route unrouted Wine prefixes | **off** | `--route-prefixes`, with `--route-runner NAME`. Reported by `--check` either way |

Everything is idempotent — re-running changes nothing already in place.

## Usage

```bash
cd ~/fedora44-setup/audio
./install-audio.sh --check      # read-only status, no sudo needed
./install-audio.sh              # apply the defaults
sudo reboot
./install-audio.sh --check      # confirm: rtprio hard limit should now be 90
```

Then, only once `--check` reports `rtprio hard limit: 90`:

```bash
./install-audio.sh --mask-rtkit
```

The guard uses `runuser` to open a fresh PAM session, which applies
`pam_limits`, so it reports the limits that are on disk now rather than the ones
your current login session happened to get.

For the yabridge/Bottles half:

```bash
./install-audio.sh --yabridge   # then follow the manual Bottles steps it prints
```

`--check` also reports the three things that install cleanly and still do not
work — the REAPER launcher entry, the GPU driver inside the Bottles Flatpak,
and the Wine each registered prefix actually routes to:

```
REAPER launcher entry:   ok (~/.local/share/applications/cockos-reaper.desktop)
bottles GPU driver:      ok
prefix routing:          /home/olivier/.wine    -> kron4ek-wine-9.21-staging-tkg-amd64
prefix routing:          /home/olivier/.wine-ni -> SYSTEM WINE (no bottle.yml)
```

Runs either as your user (using `sudo` per step) or under `sudo`/`pkexec`.

## REAPER's launcher entry

REAPER installs with `--integrate-desktop`, which calls `xdg-desktop-menu`. On
this system that writes the entry to `~/.gnome/apps/` — a path nothing has read
since GNOME 2 — and tags it `OnlyShowIn=Old;` so modern menus skip it as a
duplicate of a modern copy that is never written. The result is that REAPER
installs perfectly and does not appear in the launcher at all.

Copying the file into `~/.local/share/applications/` is not enough on its own:
`OnlyShowIn=Old` restricts it to a desktop environment that does not exist, so
every desktop still hides it. Both have to be fixed together.

The script writes a correct entry, then refreshes `update-desktop-database` and
`kbuildsycoca6`. It runs on **every** pass, not just a fresh install, because
the broken entry is left behind in place — an install from months ago is
exactly the case that needs repairing. It is reported by `--check` as
`REAPER launcher entry:`.

The icons are fine; REAPER's own installer puts `cockos-reaper.svg` into the
user icon themes correctly. Only the `.desktop` file lands in the wrong place.
The stale `~/.gnome/apps` copy is left alone — it is inert, and deleting it is
cosmetic.

## yabridge with Bottles (`--yabridge`)

Upstream's Wine section is gone: the eight dead `copr enable` lines,
`dnf install wine …`, `winetricks -q corefonts`, the `~/.wine` VST directories,
and the `WINEESYNC`/`WINEFSYNC` appends to `~/.bashrc` (Bottles exposes those as
per-bottle settings).

In its place `--yabridge` follows
[microfortnight/yabridge-bottles-wineloader](https://github.com/microfortnight/yabridge-bottles-wineloader):
Bottles owns the Wine runner, and `WINELOADER` points yabridge's Wine plugin
hosts at the runner configured for each individual Bottle.

The shim itself is used unmodified. `files/wineloader.sh` is byte-identical to
commit `fa16212` ("Add support for Proton runners"), the same as the clone at
`~/yabridge-bottles-wineloader`. It is vendored rather than referenced so the
script is reproducible offline and pinned; if you `git pull` that clone later,
`cmp` the two to see whether anything moved.

This supersedes a caveat given earlier in this project — that yabridge plus
Flatpak Bottles is awkward. It is not, and the wineloader shim is exactly the
fix, provided the DAW and yabridge live outside the Flatpak. Both do here:
REAPER is a native install and yabridge sits in `~/.local/share`.

| Installed | Where from |
|---|---|
| `yq` | dnf. wineloader.sh reads the runner out of Bottles' YAML with it |
| Bottles | Flathub, system scope, matching the other flatpaks here |
| yabridge 5.1.1 | upstream tarball into `~/.local/share/yabridge`, sha256 pinned |
| `~/.local/bin/wineloader.sh` | vendored verbatim in `files/` from commit `fa16212` (the repo is public domain) |
| `~/.local/bin/yabridgectl` | small wrapper that pins yabridgectl's config home (see below) |

It then registers every prepared Bottle automatically: for each prefix it finds
under the Flatpak, native and custom Bottles roots, it creates the four standard
plugin directories (`Common Files/VST3`, `VST2`, `CLAP`, `Steinberg/VstPlugins`),
`yabridgectl add`s them, and runs `yabridgectl sync`. Re-running is harmless —
`add` is idempotent.

Fedora ships **mikefarah/yq v4**, not the Python jq-wrapper the script's syntax
suggests. All three invocations wineloader.sh makes — `.Runner`, `.Path` and
`.custom_bottles_path // ""` — were tested against v4.53.3 and behave correctly,
including `-r`.

### Two departures from that README

**1. Not the Fedora COPR.** The README defers to yabridge's own README, which
tells Fedora users to install from COPR `patrickl/wine-tkg`. That package
hard-requires an exact Wine version:

```
wine = 1:9.21            wine-devel = 1:9.21
wine(x86-32) = 1:9.21    wine-devel(x86-32) = 1:9.21
```

plus cargo, cmake, meson, gcc, boost-devel and vim. Installing it would
downgrade Fedora's wine 11.0-3 to 9.21 — the exact opposite of letting Bottles
choose the Wine version, which is the entire point of this setup. The upstream
tarball carries no such pin, and every library it needs is already present
here (checked with `ldd` against all five binaries: nothing missing, and no
`libcurl-gnutls` required).

**2. `WINELOADER` does not go in `~/.config/environment.d`.** That method
assumes GNOME/GDM or Plasma/SDDM. Under greetd the systemd `--user` manager
starts *before* the session wrapper runs, so it reads the shared
`~/.config/environment.d` and the variable would apply to the Hyprland session
too. Instead `~/.local/bin/plasma-session` exports it — reliable here, and
exactly the Plasma-only scoping this machine wants. The wrapper also runs
`systemctl --user unset-environment WINELOADER` on logout, so it cannot leak
into a later Hyprland session through the shared user manager.

`wineloader.conf` from the repo is therefore not installed. The wrapper's export
is conditional on `~/.local/bin/wineloader.sh` existing, so the KDE half and the
audio half stay decoupled: installing the shim activates it, removing it
deactivates it, and neither script has to know about the other.

### What "only in KDE" actually covers

- **`WINELOADER`** — Plasma session only. Plugins loaded there use the Bottle's
  runner. A DAW started under Hyprland falls back to system Wine 11 and bridged
  plugins will most likely fail to load. That is the intended behaviour.
- **`yabridgectl` is available everywhere**, via `~/.local/bin/yabridgectl`
  (already on `PATH` in both bash and fish). It is a wrapper, not a symlink,
  and it exports `XDG_CONFIG_HOME=~/.config-plasma` before exec'ing the real
  binary. That matters: yabridgectl keeps its config under `XDG_CONFIG_HOME`,
  so without the wrapper the same command would read `~/.config-plasma/...`
  inside Plasma and an empty `~/.config/...` anywhere else — and an `add` from
  the wrong session would silently go nowhere. With it there is exactly one
  config, `~/.config-plasma/yabridgectl/config.toml`, wherever you run it.
  Managing plugins is not the same thing as *running* them, so this being
  global costs nothing.
- **The bridged `.so` files** (`~/.vst3/yabridge` and friends) are ordinary
  files in `$HOME`. Nothing about them is session-scoped.

### Which yabridge build, and why it matters

`--yabridge` picks the build from the system Wine version:

| System Wine | Build | Why |
|---|---|---|
| >= 9.22 (so: any current Fedora) | **development**, from the nightly artifacts | stable 5.1.1 has [yabridge #382](https://github.com/robbert-vdh/yabridge/issues/382): mouse clicks do not register in plugin GUIs, so plugins render wrong or fail outright |
| < 9.22 | stable 5.1.1, pinned by sha256 | the release build, no reason to track master |

`--yabridge-stable` forces the pinned release if you ever need it.

This is not theoretical — it is what broke Kontakt here. Kontakt 6 loaded in
REAPER but its UI misbehaved, and Kontakt 7 did not work at all; both are
bridged from `~/.wine-ni`, which runs on the system Wine 11. After switching
to the development build, Kontakt 6, 7 and 8 all work. yabridge master's
changelog fixes exactly that:

> Fixed a compatibility issue with **Wine 9.22** and above that caused mouse
> clicks in plugin GUIs to not register properly.

Two dead ends worth recording, so nobody retries them:

- **COPR `ycollet/audinux`**, which ni-wine's README recommends for Fedora, is
  plain stable 5.1.1 — its SRPM contains only `yabridge-5.1.1.tar.gz` and a
  spec file, no patches. It does not contain the fix.
- **COPR `patrickl/wine-tkg`** pins `wine = 1:9.21`. That version of Wine does
  avoid #382, but Native Access needs Wine >= 11, so it would trade a working
  Kontakt UI for a Native Access that cannot run at all.

The development build has no release to pin against, so the script discovers
the nightly artifact URLs (their names carry the git describe), verifies the
archive contains the expected binaries, and records what it installed in
`~/.local/share/yabridge/.fedora44-setup-version` so re-runs are idempotent.
The build in use here is `5.1.1-57-gb580a9f7`.

### Where the plugins are bridged from

Two prefixes are registered, and they get their Wine from different places:

| Prefix | Wine it runs on |
|---|---|
| the Bottle (`…/bottles/<Bottle>`) | the Bottle's runner, via `wineloader.sh` reading its `bottle.yml` |
| `~/.wine-ni` (Native Access, Kontakt) | **system Wine**, because it has no `bottle.yml` and `wineloader.sh` falls back |

That fallback is by design — ni-wine needs Wine >= 11 — and it is the reason
the development build of yabridge is mandatory on this machine rather than a
preference. The script registers `~/.wine-ni` automatically when it exists,
but never creates directories inside it: Native Access owns that prefix.

The trap is that the fallback is **silent**. `yabridgectl sync` reports every
plugin as synced either way, because sync and routing never consult each other:
sync records one global Wine version, while routing is decided per prefix, at
load time, purely by whether `bottle.yml` is present. A prefix can be fully
synced and still be running on a Wine two major versions from the one it was
bridged against, with no warning anywhere.

So `--check` reports the routing of every registered prefix, and
`--route-prefixes` fixes the ones that fall back by writing a `bottle.yml` into
them:

```bash
./install-audio.sh --yabridge --route-prefixes
./install-audio.sh --yabridge --route-prefixes --route-runner kron4ek-wine-9.21-staging-tkg-amd64
```

`wineloader.sh` reads exactly two keys from that file — `.Runner`, the runner to
exec, and `.Path`, whose basename only has to match an existing Bottle so
`BOTTLES_ROOT` resolves. Bottles never scans these prefixes, so they do not
become visible Bottles, and the file disappears with the prefix.

Leave `~/.wine-ni` unrouted unless you have a reason: ni-wine wants Wine >= 11
and the fallback gives it exactly that. Routing is for prefixes whose plugins
you bridge and want on a specific runner.

### Bottles needs a GPU driver inside the Flatpak

Bottles owns the Wine runner here, so a Bottles that will not open is not a
cosmetic problem — there is no other way to install or change a runner.

It is a Flatpak, so it cannot see the host's graphics driver: it needs a
matching `org.freedesktop.Platform.GL.nvidia-<driver>` extension. Without one
it falls back to the Mesa/nouveau stack, which cannot talk to a proprietary
`nvidia` kernel module, and Bottles dies on its first window with
`BadDrawable (invalid Pixmap or Window parameter)` — after logging
`Bottles Started!`, which makes it look like a Bottles bug rather than a
missing driver.

The extension version must match the running driver **exactly**, so a driver
upgrade breaks it again until the matching extension is pulled in. The script
checks for both and prints the install command:

```bash
flatpak install -y flathub \
  org.freedesktop.Platform.GL.nvidia-<driver> \
  org.freedesktop.Platform.GL32.nvidia-<driver>
```

`GL32` is not optional — Wine needs the 32-bit libraries for 32-bit plugins,
and plenty of Native Instruments plugin code is still 32-bit. Installing only
the 64-bit half gets Bottles to open while leaving plugins broken. Reported by
`--check` as `bottles GPU driver:`.

### You must log in again before plugins will load

`WINELOADER` can only enter a session at login, and the wrapper decides whether
to export it by checking whether `~/.local/bin/wineloader.sh` exists *at that
moment*. Install yabridge into an already-running Plasma session and the
variable is simply not there yet. The script detects this by reading
`WINELOADER` out of the running `plasmashell`'s `/proc/<pid>/environ`, and says
so loudly.

Until you log out and back in, plugins are bridged against the **system** Wine
instead of the Bottle's runner.

Do **not** try to check that with `grep wine_version …/yabridgectl/config.toml`.
That field is written from a plain `wine --version` probe with no `WINEPREFIX`
set, so it never goes through the shim and never reports a Bottle runner — it
reads `wine-11.0 (Staging)` even when routing is working perfectly. It is
yabridgectl's "you upgraded Wine, re-sync" hint and nothing more.

Ask the shim instead, per prefix, since that is what actually decides:

```bash
WINEPREFIX=~/.wine  ~/.local/bin/wineloader.sh --version
```

or let the script list every registered prefix at once:

```bash
./install-audio.sh --check      # see the "prefix routing:" lines
```

### Then

1. Bottles → Preferences → Runners: install a runner. With the **development**
   build any runner works, including `sys-*` (which makes `wineloader.sh` fall
   back to the system Wine — by design, and fine here). Only **stable**
   yabridge needs the Bottle pinned to `kron4ek-wine-9.21-staging-tkg-amd64`,
   per [issue #382](https://github.com/robbert-vdh/yabridge/issues/382); the
   script only warns about the runner when you forced `--yabridge-stable`.
2. Install plugins into a Bottle — "Run Executable…" for installers, or drop
   VST3 bundles into `C:\Program Files\Common Files\VST3`.
3. `yabridgectl sync`, or re-run `./install-audio.sh --yabridge`, which also
   picks up Bottles created since the last run.
4. Rescan plugins in your DAW.

## Native Instruments / Kontakt (`--ni-wine`)

A separate track from Bottles, and complementary to it.
[`ni-wine`](https://github.com/selimbucher/native-instruments) (COPR
`selimbucher/ni-wine`) manages a dedicated Wine prefix at `~/.wine-ni` that
Native Access and its installers are happy in, which is a different problem
from hosting a plugin in a DAW.

```bash
./install-audio.sh --ni-wine
```

enables the COPR, installs `ni-wine` (dnf pulls winetricks, msitools, Xvfb,
cabextract, zenity with it) and then runs `ni doctor` and shows you the result.
Everything after that needs your NI account and a GUI, so the script leaves it
to you:

| | |
|---|---|
| `ni setup` | create `~/.wine-ni`, install Native Access |
| `ni launch` | sign in; installing Kontakt arms the MSI installer hook |
| `ni link <BOTTLE_PREFIX>` | expose the installed NI products to a DAW's Wine prefix — point it at the Bottle yabridgectl already scans |
| `yabridgectl sync` | bridge whatever the link exposed |
| `ni doctor` | re-check |

`ni link` is the join between the two tracks: NI products get installed in
`~/.wine-ni`, linked into the Bottle, and yabridge bridges them from there like
any other Windows plugin.

**It requires `wine >= 11`,** so it depends on the system Wine staying put.
That is a second, independent reason the yabridge `wine-tkg` COPR was the wrong
choice here: it pins `wine = 1:9.21`, which would have broken ni-wine as well
as defeating Bottles. The script warns if it ever finds system Wine below 11.

### Realtime prerequisite: already satisfied

yabridge warns if it cannot lock memory. `99-audio.conf` grants `@pipewire`
`memlock unlimited` and you are in that group — verified on this machine as
`ulimit -Hl` = unlimited and `ulimit -Hr` = 90. Nothing extra is needed, and in
particular `--realtime-setup` is not a prerequisite for yabridge here.

## Undo

```bash
sudo rm -f /etc/security/limits.d/99-audio.conf /etc/sysctl.d/90-audio.conf
sudo sysctl --system
sudo gpasswd -d "$USER" pipewire
sudo grubby --remove-args="preempt=full" --update-kernel=ALL
sudo systemctl unmask --now rtkit-daemon     # if you masked it
rm -rf ~/REAPER                              # portable install, self-contained

# yabridge
rm -rf ~/.local/share/yabridge ~/.vst3/yabridge ~/.vst/yabridge
rm -f  ~/.local/bin/wineloader.sh             # deactivates the WINELOADER export
rm -rf ~/.config-plasma/yabridgectl
sudo flatpak uninstall --system com.usebottles.bottles
```
