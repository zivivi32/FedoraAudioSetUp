# fedora44-setup

How this machine is put together: KDE Plasma running alongside Hyprland without
the two interfering, and a pro-audio configuration for PipeWire.

Both parts are idempotent scripts with a `--check` mode, so they double as
documentation you can actually run.

## Machine profile

| | |
|---|---|
| OS | Fedora 44, kernel 7.2.5-200.fc44.x86_64 |
| Boot | legacy BIOS, GRUB (`grub2-pc`), BLS entries in `/boot/loader/entries` |
| Machine | VM, virtio GPU, btrfs root on `/dev/vda3` |
| Primary session | Hyprland 0.56.2 (COPR `lionheartp/Hyprland`), Lua config, Noctalia shell |
| Login | greetd 0.10.3 + noctalia-greeter 1.5.0 |
| Second session | KDE Plasma 6.7.5, isolated config home |
| Audio | PipeWire 1.6.9 + WirePlumber, JACK via `pipewire-jack` |

## Layout

```
kde/
  install-kde.sh        install/sync Plasma + the isolation, or --check
  README.md             the conflict analysis and the design
  files/                installed verbatim by install-kde.sh
    plasma-session          session wrapper (XDG_CONFIG_HOME + WINELOADER)
    plasma-config-sync      builds the ~/.config-plasma symlink farm
    hypr-theme-backup       save/restore the Hyprland theming files
    plasma-studio.desktop.in, plasma-studio-x11.desktop.in

audio/
  install-audio.sh      realtime limits, sysctl, pipewire group, REAPER,
                        --yabridge for yabridge + Bottles, --ni-wine for
                        Native Access / Kontakt
  README.md             what differs from upstream and why
  files/
    wineloader.sh         Bottles wineloader shim, vendored (public domain)
    yabridgectl-wrapper   pins yabridgectl's config home to Plasma's
```

The two halves are decoupled but meet in one place: `--yabridge` installs
`~/.local/bin/wineloader.sh`, and the Plasma session wrapper exports
`WINELOADER` only if that file exists. So yabridge is active in the Plasma
session and nowhere else.

## Order, on a fresh Fedora install

Assumes Hyprland, greetd and Noctalia are already set up — these scripts add
Plasma and the audio stack next to that, they do not build it.

```bash
cd ~/fedora44-setup

# 1. Plasma, isolated. Creates ~/.config-plasma and the session wrapper.
kde/install-kde.sh --check        # read-only look first
kde/install-kde.sh

# 2. System audio tuning. Needs a reboot for preempt=full and the new group.
audio/install-audio.sh
sudo reboot
audio/install-audio.sh --check    # rtprio hard limit should read 90

# 3. yabridge, Bottles and the wineloader shim.
audio/install-audio.sh --yabridge

# 3b. Optional: Native Access / Kontakt in their own Wine prefix.
audio/install-audio.sh --ni-wine
```

**Run step 3 before your first Plasma login, and the ordering takes care of
itself.** The session wrapper decides whether to export `WINELOADER` by
checking for `~/.local/bin/wineloader.sh` *at login*, so if the shim already
exists, the variable is there the first time you log in. Install yabridge into
an already-running Plasma session and you have to log out and back in — the
script detects that and says so.

Step 1 before step 3 also matters: `yabridgectl`'s config is pinned to
`~/.config-plasma`, which step 1 creates. The script warns if it is missing.

Then, in the Plasma session:

```bash
# 4. In Bottles (GUI): install a runner, create a bottle, install your
#    Windows plugins into it. Any runner works with the development build.
# 5. Pick up the new bottle and bridge its plugins:
audio/install-audio.sh --yabridge     # or just: yabridgectl sync
# 6. Rescan plugins in your DAW.
```

### What stays manual, and why

Installing a Wine runner and creating a bottle are Bottles GUI actions —
Bottles owns that catalogue, and which plugins go in which bottle is a
per-project decision. The script does not guess: it detects what exists,
creates the four standard plugin directories in every bottle it finds,
registers and syncs them, and warns when the runner yabridge needs is missing
or when a bottle is set to a `sys-*` runner that would silently fall back to
the system Wine.

Neither script touches the other's territory: the KDE side never edits
`~/.config`, and the audio side makes no desktop, session or display-manager
changes. They meet at exactly one point — `--yabridge` installs
`~/.local/bin/wineloader.sh`, and the Plasma wrapper exports `WINELOADER` only
if that file exists.

## Status on this machine

- **KDE**: installed and running. 24 packages (205 with dependencies), session
  entries in place, `~/.config-plasma` holding 20 shared symlinks with
  `kdeglobals` private. The Hyprland theming files were byte-identical to their
  pre-install snapshot afterwards.
- **Audio**: applied and verified. `preempt=full` active, rtprio hard limit 90,
  `jarvis` in the `pipewire` group, both drop-in files installed
  (swappiness 10, inotify watches 600000), REAPER in `~/REAPER`.

  The proof that the limits are doing the work rather than rtkit: rtkit's
  `MaxRealtimePriority` is 20 and PipeWire's configured `rt.prio` is 60. Before,
  `data-loop.0` ran at `SCHED_RR` 20 — rtkit's ceiling. It now runs at
  `SCHED_FIFO` 60, which rtkit could not have granted.

  rtkit-daemon is still active and enabled. Nothing needs it now, so
  `audio/install-audio.sh --mask-rtkit` will pass its guard if you want it gone;
  leaving it costs nothing either.
- **yabridge**: installed (5.1.1) with Bottles, the wineloader shim and the
  yabridgectl wrapper. `WINELOADER` is **active** in the running Plasma
  session, the `YabridgeVST` bottle is registered on the
  `kron4ek-wine-9.21-staging-tkg-amd64` runner, and ValhallaSupermassive is
  bridged as both VST2 and VST3.
- **yabridge build**: the **development** build `5.1.1-57-gb580a9f7`, not
  stable. Stable 5.1.1 is incompatible with Wine >= 9.22 (yabridge #382), which
  was what broke Kontakt: 6 loaded with a misbehaving UI, 7 not at all. With
  the development build, **Kontakt 6, 7 and 8 all work** in REAPER.
- **Bridged plugins**: 5 — ValhallaSupermassive (VST2 + VST3) from the Bottle,
  and Kontakt 6, 7 and 8 (VST3) from `~/.wine-ni`.
- **ni-wine**: installed (2.4.1) with the prefix at `~/.wine-ni`. `ni doctor`
  reports all green; Native Access is in, Kontakt 8 itself is not installed
  yet. `ni link <bottle>` then `yabridgectl sync` is what brings it into the
  DAW once it is.

## Provenance

The audio script is adapted from
[`tuxaudio/linux-audio-setup-scripts`](https://github.com/tuxaudio/linux-audio-setup-scripts)
`fedora/43/install-audio.sh` (clone at `~/linux-audio-setup-scripts`, commit
`9babae7`). It is **not** a copy: the upstream script aborts partway on Fedora
44 and leaves rtkit masked, and its Wine/yabridge half is built on COPRs that no
longer exist. `audio/README.md` documents each change. Wine is out of scope here
anyway — Bottles handles that.

The yabridge half follows
[microfortnight/yabridge-bottles-wineloader](https://github.com/microfortnight/yabridge-bottles-wineloader)
(public domain), with two documented departures: yabridge comes from the
upstream tarball rather than Fedora's COPR, which would downgrade Wine 11 to a
pinned 9.21, and `WINELOADER` is exported by the Plasma session wrapper rather
than `~/.config/environment.d`, which under greetd would apply it to every
session.

The KDE side has no upstream; `kde/README.md` explains why the isolation works
the way it does, including the alternatives that were rejected.
