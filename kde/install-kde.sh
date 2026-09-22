#!/usr/bin/bash
# ---------------------------------------------------------------------------
# install-kde.sh -- install KDE Plasma alongside an existing Hyprland session
#                   on Fedora 44, with Plasma's configuration isolated so it
#                   can never restyle the Hyprland session.
#
# Run it as your normal user:   ./install-kde.sh
# or under sudo/pkexec:         sudo ./install-kde.sh
#
# Idempotent: re-running changes nothing that is already in place.
# See README.md for the design and the reasoning behind the isolation.
# ---------------------------------------------------------------------------

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SESSIONS_DIR=/usr/local/share/wayland-sessions
USER_SCRIPTS=(plasma-session plasma-config-sync hypr-theme-backup)

PKGS=(
    # session + shell
    plasma-workspace plasma-workspace-x11 plasma-desktop plasma-systemsettings
    kwin kwin-x11 kscreen plasma-nm powerdevil plasma-pa plasma-systemmonitor
    # integration
    kde-cli-tools kde-gtk-config breeze-gtk qqc2-breeze-style polkit-kde
    xdg-desktop-portal-kde
    # a few apps that make Plasma usable
    dolphin konsole ark gwenview
    # X11 session
    xorg-x11-server-Xorg xorg-x11-xinit xorg-x11-xauth
)
# Excluded on purpose: sddm would fight greetd for display-manager.service,
# and Discover is not wanted. See README.md.
DNF_EXCLUDES=(--exclude='sddm*' --exclude='plasma-discover*')

CHECK_ONLY=0
DO_PACKAGES=1
FORCE=0
YES="${ASSUME_YES:-0}"

usage() {
    cat <<'USAGE'
usage: install-kde.sh [options]

Installs a lean Plasma, the isolated-session wrapper scripts, and two greeter
session entries, while leaving greetd and the Hyprland session untouched.

  --check         report current state and exit, change nothing
  --no-packages   skip the dnf step, only (re)install the scripts and sessions
  --force         continue even if the machine does not match the expected
                  profile (Fedora 44 + Hyprland + greetd)
  -y, --yes       never prompt
  -h, --help      this message
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_ONLY=1 ;;
        --no-packages) DO_PACKAGES=0 ;;
        --force)       FORCE=1 ;;
        -y|--yes)      YES=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

notify() { printf '\n--------------------------------------------------------------------\n%s\n--------------------------------------------------------------------\n' "$1"; }
ok()     { printf '  [ok]    %s\n' "$1"; }
skipped(){ printf '  [skip]  %s\n' "$1"; }
warn()   { printf '  [warn]  %s\n' "$1" >&2; }
die()    { printf '\nerror: %s\n' "$1" >&2; exit 1; }

# --- who are we acting for, and how do we become root ----------------------
if [[ $EUID -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-}"
    if [[ -z $TARGET_USER && -n ${PKEXEC_UID:-} ]]; then
        TARGET_USER="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
    fi
    [[ -n $TARGET_USER && $TARGET_USER != root ]] \
        || die "run this from your normal account (sudo ./install-kde.sh), not as root directly"
    run_root() { "$@"; }
    run_user() { runuser -u "$TARGET_USER" -- "$@"; }
else
    TARGET_USER="$(id -un)"
    command -v sudo >/dev/null || die "sudo not found; run this under sudo instead"
    run_root() { sudo "$@"; }
    run_user() { "$@"; }
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d $TARGET_HOME ]] || die "cannot resolve home directory for $TARGET_USER"
WRAPPER="$TARGET_HOME/.local/bin/plasma-session"
PLASMA_CONFIG="$TARGET_HOME/.config-plasma"

confirm() {
    [[ $YES -eq 1 ]] && return 0
    [[ -t 0 ]] || die "not an interactive terminal; re-run with --yes"
    local a; read -rp "$1 [y/N] " a
    [[ ${a,,} == y* ]]
}

# ---------------------------------------------------------------------------
# These scripts were written for one specific setup. Say so if that is not
# what we are looking at.
# ---------------------------------------------------------------------------
check_profile() {
    local problems=0 ver
    # Hard requirement: this is a dnf/rpm distro.
    grep -q '^ID=fedora' /etc/os-release 2>/dev/null \
        || die "this is not Fedora; the package list and paths here are Fedora-specific"

    # A different Fedora release is fine - nothing here is pinned to 44 - but
    # say so, because the package names were only verified on 44.
    ver="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null)"
    if [[ $ver != 44 ]]; then
        warn "built and verified on Fedora 44, this is Fedora ${ver:-unknown}."
        warn "Package names may have changed; the run will tell you if any are missing."
        problems=1
    fi
    if ! rpm -q hyprland >/dev/null 2>&1; then
        warn "hyprland is not installed. The isolation still works, it just has"
        warn "nothing to isolate Plasma from yet."
        problems=1
    fi
    if [[ "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" != */greetd.service ]]; then
        warn "greetd is not the display manager. The session entries go to"
        warn "/usr/local/share/wayland-sessions, which sddm and gdm also read, so"
        warn "they should still appear - but that is not what this was tested on."
        problems=1
    fi

    if [[ $problems -eq 1 && $FORCE -ne 1 ]]; then
        confirm "  Continue anyway?" || die "aborted (use --force, or -y, to skip this prompt)"
    fi
}

private_leaks() {   # names that must never be symlinks inside ~/.config-plasma
    local n leaks=()
    for n in kdeglobals kdedefaults gtk-2.0 gtk-3.0 gtk-4.0 xsettingsd dconf \
             mimeapps.list qt5ct qt6ct Trolltech.conf; do
        if [[ -L "$PLASMA_CONFIG/$n" ]]; then leaks+=("$n"); fi
    done
    printf '%s' "${leaks[*]:-}"
}

# rpm -q prints "package X is not installed" on STDOUT and returns 1, so a
# plain `rpm -q foo || echo missing` prints both. Use this instead.
rpm_ver() {
    if rpm -q "$1" >/dev/null 2>&1; then
        rpm -q --qf '%{version}-%{release}' "$1"
    else
        printf '%s' "${2:-not installed}"
    fi
}

report() {
    notify "Current state"
    printf '  %-26s %s\n' "fedora:" "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"
    printf '  %-26s %s\n' "hyprland:" "$(rpm_ver hyprland)"
    printf '  %-26s %s\n' "plasma-workspace:" "$(rpm_ver plasma-workspace)"
    printf '  %-26s %s\n' "display-manager:" "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo 'none')"
    printf '  %-26s %s\n' "sddm:" "$(rpm_ver sddm 'not installed (good)')"

    local missing=() p
    for p in "${PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
    printf '  %-26s %s\n' "packages:" "$(( ${#PKGS[@]} - ${#missing[@]} ))/${#PKGS[@]} installed${missing:+ (missing: ${missing[*]})}"

    local s
    for s in "${USER_SCRIPTS[@]}"; do
        if [[ ! -x "$TARGET_HOME/.local/bin/$s" ]]; then
            printf '  %-26s %s\n' "$s:" "NOT INSTALLED"
        elif cmp -s "$SRC/files/$s" "$TARGET_HOME/.local/bin/$s"; then
            printf '  %-26s %s\n' "$s:" "installed, matches this folder"
        else
            printf '  %-26s %s\n' "$s:" "installed, DIFFERS from this folder"
        fi
    done

    printf '  %-26s %s\n' "session entries:" "$(ls -1 "$SESSIONS_DIR" 2>/dev/null | tr '\n' ' ' || echo 'none')"
    if command -v noctalia-greeter >/dev/null 2>&1; then
        printf '  %-26s %s\n' "greeter lists:" "$(noctalia-greeter sessions 2>/dev/null | paste -sd'|' -)"
    fi

    if [[ -d $PLASMA_CONFIG ]]; then
        printf '  %-26s %s symlinks, kdeglobals is %s\n' "isolated config home:" \
            "$(find "$PLASMA_CONFIG" -maxdepth 1 -type l 2>/dev/null | wc -l)" \
            "$([[ -L $PLASMA_CONFIG/kdeglobals ]] && echo 'A SYMLINK (broken isolation!)' || echo 'a real file (good)')"
        local leaks; leaks="$(private_leaks)"
        if [[ -n $leaks ]]; then printf '  %-26s %s\n' "ISOLATION LEAK:" "$leaks"; fi
    else
        printf '  %-26s %s\n' "isolated config home:" "not created"
    fi

    local bak="$TARGET_HOME/.local/state/hyprland-theme-backup"
    printf '  %-26s %s\n' "theme backup:" \
        "$([[ -d $bak ]] && echo "$(cat "$bak/.saved-at" 2>/dev/null || echo present)" || echo 'none')"
}

if [[ $CHECK_ONLY -eq 1 ]]; then
    report; echo; exit 0
fi

check_profile

# ---------------------------------------------------------------------------
notify "Snapshot the Hyprland theming files"
if [[ -d "$TARGET_HOME/.local/state/hyprland-theme-backup" ]]; then
    skipped "backup already exists ($TARGET_HOME/.local/state/hyprland-theme-backup)"
else
    run_user install -D -m 0755 "$SRC/files/hypr-theme-backup" "$TARGET_HOME/.local/bin/hypr-theme-backup"
    run_user "$TARGET_HOME/.local/bin/hypr-theme-backup" save
fi

# ---------------------------------------------------------------------------
notify "Install the session scripts into ~/.local/bin"
for s in "${USER_SCRIPTS[@]}"; do
    if cmp -s "$SRC/files/$s" "$TARGET_HOME/.local/bin/$s"; then
        skipped "$s already current"
    else
        run_user install -D -m 0755 "$SRC/files/$s" "$TARGET_HOME/.local/bin/$s"
        ok "$s installed"
    fi
done

# ---------------------------------------------------------------------------
# Plasma's own config home. Seeding kdeglobals keeps Plasma's first launch off
# the Hyprland session's qt6ct-style / Noctalia colour scheme.
# ---------------------------------------------------------------------------
notify "Isolated config home ($PLASMA_CONFIG)"
run_user mkdir -p "$PLASMA_CONFIG"
if [[ -f "$PLASMA_CONFIG/kdeglobals" ]]; then
    skipped "kdeglobals already present"
else
    printf '[General]\nColorScheme=BreezeDark\n\n[Icons]\nTheme=breeze-dark\n\n[KDE]\nwidgetStyle=Breeze\n' \
        | run_user tee "$PLASMA_CONFIG/kdeglobals" >/dev/null
    ok "seeded kdeglobals with Breeze Dark"
fi
run_user "$TARGET_HOME/.local/bin/plasma-config-sync"
ok "symlink farm synced ($(find "$PLASMA_CONFIG" -maxdepth 1 -type l | wc -l) entries shared with ~/.config)"
leaks="$(private_leaks)"
if [[ -n $leaks ]]; then warn "these should not be symlinks: $leaks"; fi

# ---------------------------------------------------------------------------
if [[ $DO_PACKAGES -eq 1 ]]; then
    notify "Install Plasma"
    missing=()
    for p in "${PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [[ ${#missing[@]} -eq 0 ]]; then
        skipped "all ${#PKGS[@]} packages already installed"
    else
        echo "  installing ${#missing[@]} package(s): ${missing[*]}"
        if [[ $YES -eq 1 ]]; then
            run_root dnf install -y "${DNF_EXCLUDES[@]}" "${missing[@]}"
        else
            run_root dnf install "${DNF_EXCLUDES[@]}" "${missing[@]}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Session entries live in /usr/local/share/wayland-sessions: the greeter scans
# it, and dnf never touches it. Unique basenames so a stock file can never
# shadow them.
# ---------------------------------------------------------------------------
notify "Greeter session entries"
run_root install -d -m 0755 "$SESSIONS_DIR"
for t in "$SRC"/files/*.desktop.in; do
    name="$(basename "$t" .in)"
    tmp="$(mktemp)"
    sed "s|@WRAPPER@|$WRAPPER|" "$t" > "$tmp"
    if cmp -s "$tmp" "$SESSIONS_DIR/$name"; then
        skipped "$name already current"
    else
        run_root install -m 0644 "$tmp" "$SESSIONS_DIR/$name"
        ok "$name installed"
    fi
    rm -f "$tmp"
done
command -v restorecon >/dev/null 2>&1 && run_root restorecon -RF "$SESSIONS_DIR" || true

# ---------------------------------------------------------------------------
notify "Keep greetd as the display manager"
if rpm -q sddm >/dev/null 2>&1; then
    warn "sddm is installed; disabling and masking it so it cannot take over"
    run_root systemctl disable --now sddm.service 2>/dev/null || true
    run_root systemctl mask sddm.service 2>/dev/null || true
else
    ok "sddm is not installed"
fi
dm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
if [[ $dm == /usr/lib/systemd/system/greetd.service ]]; then
    ok "display-manager.service still points at greetd"
else
    warn "display-manager.service pointed at '$dm' - restoring greetd"
    run_root ln -sfn /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
    run_root systemctl daemon-reload
fi

# ---------------------------------------------------------------------------
report
notify "Done"
echo "Log out (no reboot needed) and pick 'Plasma Studio' at the greeter."
echo "Avoid the stock 'Plasma' entry: it bypasses the isolated config home."
echo
