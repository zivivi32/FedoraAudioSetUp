# KDE Plasma alongside Hyprland, without the two fighting

Installs a lean Plasma on Fedora 44 next to an existing Hyprland session, with
Plasma's configuration isolated so nothing it writes can change how the
Hyprland session looks.

## The machine this was built against

Captured 2026-09-21, after the install:

| | |
|---|---|
| Fedora | 44, kernel 7.2.5-200.fc44.x86_64, legacy BIOS boot (GRUB `grub2-pc`) |
| Compositor | `hyprland` 0.56.2-3.fc44 from COPR `lionheartp/Hyprland` |
| Hyprland config | Lua (`~/.config/hypr/hyprland.lua` + modules), not hyprlang |
| Shell / bar | `noctalia-hyprland-meta` 0.2-7, Noctalia (Quickshell) |
| Login | `greetd` 0.10.3 + `noctalia-greeter-git` 1.5.0 — **not** sddm or gdm |
| Qt theming | `qt6ct` 0.11 with a Noctalia palette, plus `~/.config/kdeglobals` |
| Plasma | 6.7.5, KDE Gear 26.08.1 |

`install-kde.sh` checks the Fedora version, that Hyprland is installed, and
that greetd owns `display-manager.service`. A different Fedora release, a
missing Hyprland or a different display manager are all warnings you can
confirm past — only "not Fedora at all" is fatal, because the package list and
paths are Fedora-specific.

## The actual conflict

Plasma and this Hyprland setup want to write the same files. Plasma's System
Settings and `kde-gtk-config` own all of these, and Noctalia writes several of
them too:

```
~/.config/kdeglobals        Qt/KDE colours, widget style, icon theme, fonts
~/.config/kdedefaults/      look-and-feel defaults
~/.config/gtk-{2,3,4}.0/    kde-gtk-config rewrites settings.ini
~/.config/xsettingsd/       kde-gtk-config rewrites xsettingsd.conf
~/.config/dconf/            gsettings org.gnome.desktop.interface (GTK theme)
~/.config/mimeapps.list     default applications
~/.config/qt{5,6}ct/        the Hyprland session's Qt theming
~/.config/Trolltech.conf    legacy Qt
```

Before the install this machine had `kdeglobals` set to `ColorScheme=Noctalia`
and `widgetStyle=qt6ct-style`. A single Plasma login would have replaced both.

Nothing else collides: no display-manager change, no session file overlap, and
portals already key off `XDG_CURRENT_DESKTOP` (`hyprland-portals.conf` pins
`default=hyprland;gtk`, while `kde.portal` is `UseIn=KDE`).

## The design: a second config home, mostly symlinks

`XDG_CONFIG_HOME` is all-or-nothing — there is no way to redirect one file — so
the Plasma session runs against `~/.config-plasma` instead of `~/.config`.
Pointing it at an empty directory would lose every app config, so the directory
is a **symlink farm**: everything that is not a conflict file is a symlink back
into the real `~/.config`.

```
~/.config/              ~/.config-plasma/
  kdeglobals      -->     kdeglobals      real file, Plasma's own
  gtk-3.0/        -->     gtk-3.0/        real dir,  Plasma's own
  dconf/          -->     dconf/          real dir,  Plasma's own
  qt6ct/          -->     (absent)        Plasma must not see it
  kitty/          <--     kitty/          symlink, shared
  fish/           <--     fish/           symlink, shared
  hypr/           <--     hypr/           symlink, shared
  ...                     ...             symlink, shared
```

So Kitty, fish, btop and everything else behave identically in both sessions,
while the theming files are two independent sets. Anything Plasma creates that
did not exist before simply lands in `~/.config-plasma` and stays there.

`plasma-config-sync` rebuilds the farm on every Plasma login: it links new
entries, refuses to link anything on the private list, and prunes links whose
target disappeared. Add a new app in Hyprland and it shows up in Plasma at the
next login with no manual step.

### The two files this cannot cover

`~/.gtkrc-2.0` and `~/.icons/default/` live outside `XDG_CONFIG_HOME`, and
`kde-gtk-config` writes both. They are covered by `hypr-theme-backup` instead.

### Why not the alternatives

- *Shared config, repair on login* — a Hyprland `exec-once` restoring the files
  each time. Simpler, but there is always a window where the files are Plasma's,
  and a stale snapshot can undo a deliberate Noctalia theme change.
- *Separate user account* — total isolation, but your files, projects and SSH
  keys are in this account.
- *Accept it* — Plasma restyles the Qt and GTK apps in Hyprland on first login.

## What gets installed

| Path | What |
|---|---|
| `~/.local/bin/plasma-session` | session wrapper: exports `XDG_CONFIG_HOME`, syncs the farm, logs to `~/.local/state/plasma-session.log`, starts Plasma. Also exports `WINELOADER` and puts `yabridgectl` on `PATH` **if** yabridge is installed (see below) |
| `~/.local/bin/plasma-config-sync` | builds/refreshes the symlink farm (idempotent, safe to run any time) |
| `~/.local/bin/hypr-theme-backup` | `save` / `restore` / `list` for the Hyprland theming files |
| `~/.config-plasma/` | Plasma's config home, seeded with a Breeze Dark `kdeglobals` |
| `/usr/local/share/wayland-sessions/plasma-studio.desktop` | greeter entry, Wayland |
| `/usr/local/share/wayland-sessions/plasma-studio-x11.desktop` | greeter entry, X11 |
| 24 packages (205 with dependencies, ~765 MiB) | Plasma, kwin, System Settings, portal-kde, Dolphin/Konsole/Ark/Gwenview, Xorg |

The wrapper also runs
`systemctl --user unset-environment XDG_CONFIG_HOME WINELOADER` on exit, so
neither variable can leak into a later Hyprland session through the shared
systemd user manager.

### yabridge lives in this session too

If `~/.local/bin/wineloader.sh` exists, the wrapper exports `WINELOADER` so
yabridge's Wine plugin hosts use the runner configured for each Bottle, and
adds `~/.local/share/yabridge` to `PATH`. Both are conditional, so the wrapper
is unchanged in behaviour when yabridge is not installed, and the two halves of
`~/fedora44-setup` stay decoupled.

This is deliberately *not* `~/.config/environment.d/wineloader.conf`, which the
wineloader project recommends: under greetd the systemd `--user` manager starts
before this wrapper, reads the **shared** `~/.config/environment.d`, and would
apply `WINELOADER` to the Hyprland session as well. `audio/README.md` has the
detail.

One consequence worth remembering: `yabridgectl`'s config obeys
`XDG_CONFIG_HOME` like everything else, so inside Plasma it is
`~/.config-plasma/yabridgectl/config.toml`. Run `yabridgectl` from a terminal
inside the Plasma session.

## How the greeter fits

`noctalia-greeter` scans `/usr/share/wayland-sessions`,
`/usr/local/share/wayland-sessions` and `/run/current-system/sw/share/wayland-sessions`.
Two consequences shaped the install:

1. **It does not scan `/usr/share/xsessions`.** So the X11 entry also lives in
   `wayland-sessions` and runs `startx /usr/bin/startplasma-x11`; `startx` picks
   the VT up from `XDG_VTNR`, which `pam_systemd` sets for the greetd session.
   X11 is offered because Wine-hosted plugin GUIs embed more reliably on real X
   than under XWayland.
2. **It does not deduplicate by filename.** The stock `plasma.desktop` from
   `plasma-workspace` therefore still appears as a separate `Plasma` entry, and
   that one bypasses the isolation. The entries installed here use unique
   basenames so nothing can shadow them, and live in `/usr/local/share`, which
   dnf never touches.

Session entries carry no `TryExec=`: `/home/jarvis` is mode 700, so the greeter
(running as user `greeter`) cannot stat a path inside it and would hide the
entry.

## Keeping greetd

`sddm*` and `plasma-discover*` are excluded from the dnf transaction. None of
the Plasma packages actually depend on sddm, but Fedora's preset has
`enable sddm.service`, so if it ever arrives it would contend for
`display-manager.service`. After installing, the script re-checks that symlink
and masks sddm if it is present.

## Usage

```bash
cd ~/fedora44-setup/kde
./install-kde.sh --check      # read-only status
./install-kde.sh              # install / bring back into sync
```

Then log out — no reboot — and pick **Plasma Studio** (or **Plasma Studio
(X11)**) at the greeter. Avoid the stock **Plasma** entry.

`--check` verifies the isolation is intact, including that no private file has
become a symlink into the shared config.

If a session fails to start you land back at the greeter;
`~/.local/state/plasma-session.log` is truncated at each login and holds the
reason.

## Recovery

```bash
hypr-theme-backup restore     # put the Hyprland theming files back
hypr-theme-backup list        # what is in the snapshot
```

## Undo

```bash
sudo rm -f /usr/local/share/wayland-sessions/plasma-studio*.desktop
rm -rf ~/.config-plasma
rm -f ~/.local/bin/plasma-session ~/.local/bin/plasma-config-sync
sudo dnf remove plasma-workspace plasma-desktop   # takes the rest with it
```

