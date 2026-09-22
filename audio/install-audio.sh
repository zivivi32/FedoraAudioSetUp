#!/usr/bin/bash
# ---------------------------------------------------------------------------
# install-audio.sh -- Fedora 44 pro audio setup using PIPEWIRE.
# Makes no changes to the system Wine packages.
#
# Adapted from tuxaudio/linux-audio-setup-scripts (fedora/43/install-audio.sh).
# Upstream's Wine/COPR section is deliberately absent -- see README.md. yabridge
# is available via --yabridge, installed the Bottles way (upstream tarball, no
# system Wine changes) per github.com/microfortnight/yabridge-bottles-wineloader.
#
# Run it as your normal user:      ./install-audio.sh
# or under sudo/pkexec:            sudo ./install-audio.sh
#
# Everything here is idempotent: re-running changes nothing that is already set.
# ---------------------------------------------------------------------------

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

REAPER_VER=757
REAPER_URL="https://www.reaper.fm/files/7.x/reaper${REAPER_VER}_linux_x86_64.tar.xz"
YABRIDGE_VER=5.1.1
YABRIDGE_URL="https://github.com/robbert-vdh/yabridge/releases/download/${YABRIDGE_VER}/yabridge-${YABRIDGE_VER}.tar.gz"
YABRIDGE_SHA256=d11f0307412b5566b09a75ed4aa191266db56d22f4de4d20e4fbde6296cd1a47
NI_WINE_COPR=selimbucher/ni-wine
YABRIDGE_NIGHTLY=https://nightly.link/robbert-vdh/yabridge/workflows/build/master
YABRIDGE_STAMP_REL=.fedora44-setup-version   # inside ~/.local/share/yabridge

LIMITS_FILE=/etc/security/limits.d/99-audio.conf
SYSCTL_FILE=/etc/sysctl.d/90-audio.conf

DO_UPDATE=0
DO_REALTIME_SETUP=0
DO_MASK_RTKIT=0
DO_REAPER=1
DO_YABRIDGE=0
DO_NI_WINE=0
YABRIDGE_CHANNEL=auto
DO_ROUTE_PREFIXES=0
ROUTE_RUNNER=""
CHECK_ONLY=0
FORCE=0
YES="${ASSUME_YES:-0}"

usage() {
    cat <<'USAGE'
usage: install-audio.sh [options]

By default this sets the preempt=full kernel argument, installs realtime limits
and sysctl tuning, adds you to the 'pipewire' group, and installs REAPER.

  --check             report current audio-tuning state and exit, change nothing
  --update            also run a full 'dnf update' first          (default: off)
  --realtime-setup    install realtime-setup, join 'realtime'     (default: off)
  --mask-rtkit        disable+mask rtkit-daemon, only once direct
                      realtime limits are verified active         (default: off)
  --no-reaper         skip the REAPER install
  --yabridge          install yabridge + Bottles + the Bottles wineloader,
                      scoped to the Plasma session only   (default: off)
  --ni-wine           install ni-wine, for Native Access / Kontakt in a
                      dedicated Wine prefix               (default: off)
  --yabridge-stable   force the pinned stable yabridge 5.1.1 instead of the
                      development build. Only correct if your system Wine is
                      older than 9.22 (see yabridge issue #382)
  --route-prefixes    give every Wine prefix yabridge scans a bottle.yml, so
                      the wineloader shim routes it to a Bottles runner instead
                      of silently falling back to the system Wine. Without this
                      an unrouted prefix is only reported, never changed
  --route-runner NAME runner --route-prefixes should point those prefixes at
                      (default: the runner the first configured Bottle uses)
  --force             skip the safety check guarding --mask-rtkit
  -y, --yes           never prompt
  -h, --help          this message
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)          CHECK_ONLY=1 ;;
        --update)         DO_UPDATE=1 ;;
        --realtime-setup) DO_REALTIME_SETUP=1 ;;
        --mask-rtkit)     DO_MASK_RTKIT=1 ;;
        --no-reaper)      DO_REAPER=0 ;;
        --yabridge)       DO_YABRIDGE=1 ;;
        --ni-wine)        DO_NI_WINE=1 ;;
        --yabridge-stable) YABRIDGE_CHANNEL=stable ;;
        --route-prefixes) DO_ROUTE_PREFIXES=1 ;;
        --route-runner)   ROUTE_RUNNER="${2:-}"; [[ -n $ROUTE_RUNNER ]] || { echo "--route-runner needs a runner name" >&2; exit 2; }; shift ;;
        --force)          FORCE=1 ;;
        -y|--yes)         YES=1 ;;
        -h|--help)        usage; exit 0 ;;
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
        || die "run this from your normal account (sudo ./install-audio.sh), not as root directly"
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

confirm() {
    [[ $YES -eq 1 ]] && return 0
    [[ -t 0 ]] || die "not an interactive terminal; re-run with --yes"
    local a; read -rp "$1 [y/N] " a
    [[ ${a,,} == y* ]]
}

# rtprio hard limit as the target user. Run as root this opens a fresh PAM
# session (/etc/pam.d/runuser includes pam_limits), so it reflects the limits
# that are on disk right now rather than the ones your login session got.
rt_hard_limit() {
    if [[ $EUID -eq 0 ]]; then
        runuser -u "$TARGET_USER" -- bash -c 'ulimit -Hr' 2>/dev/null || echo 0
    else
        ulimit -Hr
    fi
}

in_group() { id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$1"; }

# Standard Windows plugin directories inside a Bottle prefix.
YABRIDGE_PLUGIN_SUBDIRS=(
    "drive_c/Program Files/Common Files/VST3"
    "drive_c/Program Files/Common Files/VST2"
    "drive_c/Program Files/Common Files/CLAP"
    "drive_c/Program Files/Steinberg/VstPlugins"
)

# yabridgectl obeys XDG_CONFIG_HOME, and yabridge is scoped to the Plasma
# session here, so pin it to the isolated config home. Without this, running
# this script (or yabridgectl) from Hyprland would silently use a second,
# empty config and "sync" would appear to do nothing.
yabridge_config_home() {
    if [[ -d "$TARGET_HOME/.config-plasma" ]]; then
        printf '%s' "$TARGET_HOME/.config-plasma"
    else
        printf '%s' "$TARGET_HOME/.config"
    fi
}

yc() {   # run yabridgectl as the target user against that config home
    run_user env XDG_CONFIG_HOME="$(yabridge_config_home)" \
        "$TARGET_HOME/.local/share/yabridge/yabridgectl" "$@"
}

# Every Bottles prefix root, including a custom one, the way wineloader.sh
# resolves it.
bottles_roots() {
    local d c
    for d in "$TARGET_HOME/.var/app/com.usebottles.bottles/data/bottles" \
             "$TARGET_HOME/.local/share/bottles"; do
        if [[ -d "$d/bottles" ]]; then printf '%s\n' "$d/bottles"; fi
        if [[ -f "$d/data.yml" ]] && command -v yq >/dev/null 2>&1; then
            c="$(yq -r '.custom_bottles_path // ""' "$d/data.yml" 2>/dev/null || true)"
            if [[ -n $c && -d $c ]]; then printf '%s\n' "$c"; fi
        fi
    done
}

# Runner that yabridge 5.1.1 needs; see yabridge issue #382.
YABRIDGE_RUNNER_HINT=kron4ek-wine-9.21-staging-tkg-amd64

# Runners Bottles can see. It discovers them by scanning <root>/runners,
# so this is the same list the GUI shows.
bottles_runners() {
    local d
    for d in "$TARGET_HOME/.var/app/com.usebottles.bottles/data/bottles" \
             "$TARGET_HOME/.local/share/bottles"; do
        if [[ -d "$d/runners" ]]; then
            find "$d/runners" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null
        fi
    done
}

# The runner a given bottle prefix is configured to use.
bottle_runner() {
    local prefix=$1
    [[ -f "$prefix/bottle.yml" ]] || return 1
    yq -r '.Runner // ""' "$prefix/bottle.yml" 2>/dev/null
}

# WINELOADER has to be in the *session's* environment, not this script's, so
# read it off the running plasmashell. Works even when running under sudo.
wineloader_active_in_session() {
    local pid
    pid="$(pgrep -x plasmashell 2>/dev/null | head -1)"
    [[ -n $pid ]] || return 1
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^WINELOADER='
}

# Stable yabridge 5.1.1 does not work with Wine >= 9.22: mouse clicks do not
# register in plugin GUIs, so plugins either misbehave or appear broken
# (yabridge issue #382). The fix is in master but unreleased. ni-wine's prefix
# needs Wine >= 11, so on any current Fedora the development build is the only
# one that actually works - hence the automatic choice.
wine_needs_dev_yabridge() {
    local v maj min
    v="$(wine --version 2>/dev/null | sed 's/^wine-//;s/ .*//')"
    [[ -n $v ]] || return 1
    maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
    [[ $maj =~ ^[0-9]+$ ]] || return 1
    (( maj > 9 )) && return 0
    (( maj == 9 )) && [[ $min =~ ^[0-9]+$ ]] && (( min >= 22 )) && return 0
    return 1
}

# The two nightly artifact URLs; their names carry the git describe, which
# changes, so they are discovered rather than hardcoded.
yabridge_dev_urls() {
    curl -fsSL --max-time 60 "$YABRIDGE_NIGHTLY" 2>/dev/null \
        | grep -oE 'https://nightly\.link/[^"]+\.tar\.gz\.zip' | sort -u
}

# What this script last installed, e.g. "5.1.1" or "5.1.1-57-gb580a9f7".
yabridge_stamp() {
    cat "$TARGET_HOME/.local/share/yabridge/$YABRIDGE_STAMP_REL" 2>/dev/null || true
}

yabridge_installed_ver() {
    local b="$TARGET_HOME/.local/share/yabridge/yabridgectl"
    [[ -x $b ]] || { printf ''; return; }
    "$b" --version 2>/dev/null | awk '{print $NF}' | head -1
}

# ---------------------------------------------------------------------------
# Watchdogs: three ways this setup installs "successfully" and still does not
# work. All three are silent -- nothing fails, the thing just never appears or
# quietly uses the wrong Wine. Each has a detector here and a fix at its step.
# ---------------------------------------------------------------------------

REAPER_DESKTOP_ID=cockos-reaper.desktop
REAPER_DESKTOP_REL=".local/share/applications/$REAPER_DESKTOP_ID"
REAPER_DESKTOP_LEGACY_REL=".gnome/apps/$REAPER_DESKTOP_ID"

# REAPER's installer runs --integrate-desktop, which calls xdg-desktop-menu.
# Here that writes the entry to the legacy ~/.gnome/apps -- unread since
# GNOME 2 -- and tags it "OnlyShowIn=Old" so modern menus skip it as a
# duplicate of a modern copy that never gets written. REAPER then installs
# perfectly and is invisible in the launcher. Note that copying the file into
# place is not enough on its own: OnlyShowIn has to go with it, or every
# desktop environment still hides it.
reaper_desktop_ok() {
    local f="$TARGET_HOME/$REAPER_DESKTOP_REL"
    [[ -f $f ]] || return 1
    ! grep -q '^OnlyShowIn=' "$f"
}

install_reaper_desktop_entry() {
    local exe="$TARGET_HOME/REAPER/reaper" dest="$TARGET_HOME/$REAPER_DESKTOP_REL"
    [[ -x $exe ]] || return 1
    run_user mkdir -p "$(dirname "$dest")"
    printf '%s\n' \
        '[Desktop Entry]' \
        'Type=Application' \
        'Name=REAPER' \
        'Comment=Digital audio workstation' \
        'Categories=AudioVideo;Audio;AudioVideoEditing;Recorder;' \
        "Exec=\"$exe\" %F" \
        'Icon=cockos-reaper' \
        'MimeType=application/x-reaper-project;application/x-reaper-project-backup;application/x-reaper-theme;' \
        'StartupWMClass=REAPER' \
        'StartupNotify=true' \
        'Terminal=false' \
        | run_user tee "$dest" >/dev/null || return 1
    run_user chmod 0644 "$dest" || true
    # The icons are installed correctly by REAPER's own installer, into the
    # user icon themes, so only the menu caches need a nudge.
    run_user update-desktop-database "$(dirname "$dest")" >/dev/null 2>&1 || true
    run_user kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    return 0
}

# Prefixes yabridgectl is configured to scan. A plugin dir is
# <prefix>/drive_c/Program Files/..., and the prefix containing that drive_c is
# exactly what yabridge hands the shim as WINEPREFIX.
yabridge_prefixes() {
    local cfg; cfg="$(yabridge_config_home)/yabridgectl/config.toml"
    [[ -f $cfg ]] || return 0
    grep -oE "'[^']*/drive_c/[^']*'" "$cfg" 2>/dev/null \
        | tr -d "'" | sed 's#/drive_c/.*##' | sort -u
}

# wineloader.sh keys off one thing: whether $WINEPREFIX/bottle.yml exists. If it
# does not, the shim falls through to call_system_wine and the plugin is bridged
# against whatever Wine dnf ships -- silently, and regardless of which runner
# yabridge was synced against. Any prefix outside Bottles (~/.wine, ~/.wine-ni)
# is unrouted by default, which is the single most confusing failure here:
# everything reports "synced" and the plugins still run on the wrong Wine.
prefix_routed() { [[ -f "$1/bottle.yml" ]]; }

# Full path of any existing Bottle prefix. Used only as the .Path anchor below.
# Returns the path, not the bare name: with more than one Bottles root the name
# alone does not say which root it came from, and the caller needs its runner.
anchor_bottle() {
    local root b
    while read -r root; do
        [[ -n $root ]] || continue
        for b in "$root"/*/; do
            [[ -f "${b}bottle.yml" ]] || continue
            printf '%s' "${b%/}"; return 0
        done
    done < <(bottles_roots)
    return 1
}

# Give a non-Bottles prefix the routing a Bottle gets, without making it a
# Bottle. wineloader.sh reads exactly two keys: .Runner, the runner to exec, and
# .Path, whose basename only has to match a directory under a Bottles root so
# BOTTLES_ROOT can be resolved from it. Bottles itself never scans this prefix,
# so it does not show up in the GUI, and the file dies with the prefix.
route_prefix() {   # route_prefix <prefix> <runner> <anchor-bottle>
    local prefix=$1 runner=$2 anchor=$3
    [[ -d $prefix ]] || return 1
    printf '%s\n' \
        '# Written by install-audio.sh. Read only by ~/.local/bin/wineloader.sh,' \
        '# which needs .Runner and .Path to route this prefix to a Bottles runner' \
        '# instead of the system Wine. Bottles does not scan this prefix.' \
        "Runner: $runner" \
        "Path: $anchor" \
        | run_user tee "$prefix/bottle.yml" >/dev/null || return 1
    return 0
}

# Which Wine a prefix actually resolves to through the shim -- the only answer
# that matters, since yabridgectl's own "wine_version" is probed globally with
# no WINEPREFIX and so never reflects the shim at all.
prefix_wine_version() {
    local prefix=$1 shim="$TARGET_HOME/.local/bin/wineloader.sh"
    [[ -x $shim ]] || { wine --version 2>/dev/null; return; }
    run_user env WINEPREFIX="$prefix" "$shim" --version 2>/dev/null | head -1
}

# Bottles is a Flatpak and cannot see the host graphics driver; it needs a
# matching org.freedesktop.Platform.GL.nvidia-<driver> extension. Without one it
# falls back to Mesa/nouveau, which cannot talk to the proprietary nvidia kernel
# module, and Bottles dies on its first window with BadDrawable. GL32 counts
# just as much: Wine needs the 32-bit libraries for 32-bit plugins. Prints the
# extension suffix when something is missing, nothing when the stack is fine.
bottles_gl_needed() {
    local drv slug have
    [[ -r /proc/driver/nvidia/version ]] || return 0
    drv="$(modinfo -F version nvidia 2>/dev/null || true)"
    [[ -n $drv ]] || return 0
    slug="nvidia-${drv//./-}"
    have="$(flatpak list --runtime --columns=application 2>/dev/null || true)"
    if ! grep -qx "org.freedesktop.Platform.GL.$slug" <<<"$have" \
    || ! grep -qx "org.freedesktop.Platform.GL32.$slug" <<<"$have"; then
        printf '%s' "$slug"
    fi
}

# Is preempt=full already configured in GRUB? Reading that needs root, so this
# returns 2 ("unknown") rather than prompting for a password during --check.
grubby_configured() {
    if [[ $EUID -eq 0 ]]; then
        grubby --info=ALL 2>/dev/null | grep -q 'preempt=full'
    elif sudo -n true 2>/dev/null; then
        sudo -n grubby --info=ALL 2>/dev/null | grep -q 'preempt=full'
    else
        return 2
    fi
}

write_root_file() {   # write_root_file <path> <content> <description>
    local path=$1 content=$2 desc=$3
    # Both sides go through a command substitution so the trailing newline is
    # stripped from each; comparing "$(cat file)" against a $content that ends
    # in \n would never match, and the file would be rewritten on every run.
    if [[ -f $path ]] && [[ "$(cat "$path")" == "$(printf '%s' "$content")" ]]; then
        skipped "$desc already up to date"
        return 1
    fi
    # This function gets called from `if` / `|| true` contexts, where set -e is
    # suspended for the whole body -- so a failed write has to be caught here or
    # it would be reported as success.
    if ! printf '%s' "$content" | run_root tee "$path" >/dev/null; then
        die "could not write $path (root required; run under sudo or pkexec)"
    fi
    run_root chmod 0644 "$path" || die "could not chmod $path"
    ok "$desc written"
    return 0
}

# ---------------------------------------------------------------------------
report() {
    notify "Current state"
    local lim; lim="$(rt_hard_limit)"

    if grep -qw 'preempt=full' /proc/cmdline; then
        printf '  %-24s %s\n' "kernel preempt:" "full (active now)"
    else
        _rc=0; grubby_configured || _rc=$?
        case $_rc in
            0) printf '  %-24s %s\n' "kernel preempt:" "full (configured, needs reboot)" ;;
            2) printf '  %-24s %s\n' "kernel preempt:" "not active (GRUB config needs root to read)" ;;
            *) printf '  %-24s %s\n' "kernel preempt:" "not configured" ;;
        esac
    fi
    grep -q '^CONFIG_PREEMPT_DYNAMIC=y' "/boot/config-$(uname -r)" 2>/dev/null \
        || printf '  %-24s %s\n' "" "note: kernel has no CONFIG_PREEMPT_DYNAMIC, preempt= is ignored"

    printf '  %-24s %s %s\n' "rtprio hard limit:" "$lim" \
        "$([[ $lim == unlimited || ${lim:-0} -ge 90 ]] && echo '(realtime available directly)' || echo '(too low -- relying on rtkit)')"
    printf '  %-24s %s\n' "groups:" "$(id -nG "$TARGET_USER")"
    printf '  %-24s %s\n' "limits file:" "$([[ -f $LIMITS_FILE ]] && echo "$LIMITS_FILE" || echo 'not installed')"
    printf '  %-24s %s\n' "sysctl file:" "$([[ -f $SYSCTL_FILE ]] && echo "$SYSCTL_FILE" || echo 'not installed')"
    printf '  %-24s swappiness=%s inotify.max_user_watches=%s\n' "sysctl values:" \
        "$(sysctl -n vm.swappiness)" "$(sysctl -n fs.inotify.max_user_watches)"
    printf '  %-24s %s / %s\n' "rtkit-daemon:" \
        "$(systemctl is-active rtkit-daemon 2>&1)" "$(systemctl is-enabled rtkit-daemon 2>&1)"

    local pw; pw="$(pgrep -x pipewire | head -1 || true)"
    if [[ -n $pw ]]; then
        printf '  %-24s %s\n' "pipewire rt threads:" \
            "$(ps -L -o cls=,rtprio=,comm= -p "$pw" 2>/dev/null | awk '$1!="TS"{printf "%s:%s(%s) ", $3, $1, $2}')"
    else
        printf '  %-24s %s\n' "pipewire rt threads:" "pipewire not running"
    fi
    printf '  %-24s %s\n' "REAPER:" "$([[ -d $TARGET_HOME/REAPER ]] && echo "$TARGET_HOME/REAPER" || echo 'not installed')"
    local yb; yb="$(yabridge_installed_ver)"
    printf '  %-24s %s\n' "yabridge:" "${yb:-not installed}"
    printf '  %-24s %s\n' "wineloader.sh:" "$([[ -x $TARGET_HOME/.local/bin/wineloader.sh ]] && echo "$TARGET_HOME/.local/bin/wineloader.sh" || echo 'not installed')"
    printf '  %-24s %s\n' "yq:" "$(command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | awk '{print $NF}' || echo 'not installed')"
    printf '  %-24s %s\n' "bottles:" "$(flatpak info com.usebottles.bottles >/dev/null 2>&1 && echo 'installed' || echo 'not installed')"
    if [[ -n $yb ]]; then
        printf '  %-24s %s\n' "yabridgectl config:" "$(yabridge_config_home)/yabridgectl/config.toml"
        printf '  %-24s %s\n' "yabridgectl on PATH:" "$([[ -x $TARGET_HOME/.local/bin/yabridgectl ]] && echo 'yes (~/.local/bin wrapper)' || echo 'no')"
    fi
    printf '  %-24s %s\n' "yabridge build:" "$(yabridge_stamp || true)"
    printf '  %-24s %s\n' "system wine:" "$(wine --version 2>/dev/null || echo 'not installed')$(wine_needs_dev_yabridge && echo '  (>= 9.22: needs the dev build)' || true)"
    printf '  %-24s %s\n' "ni-wine:" "$(rpm -q ni-wine >/dev/null 2>&1 && rpm -q --qf '%{version}' ni-wine || echo 'not installed')"
    printf '  %-24s %s\n' "ni-wine prefix:" "$([[ -d $TARGET_HOME/.wine-ni ]] && echo "$TARGET_HOME/.wine-ni" || echo 'not created')"
    printf '  %-24s %s\n' "bottles runners:" "$(bottles_runners 2>/dev/null | paste -sd' ' - || echo none)"
    printf '  %-24s %s\n' "WINELOADER in session:" "$(wineloader_active_in_session && echo 'active' || echo 'NOT set - log out of Plasma and back in')"
    printf '  %-24s %s\n' "REAPER launcher entry:" \
        "$(reaper_desktop_ok && echo "ok (~/$REAPER_DESKTOP_REL)" \
           || { [[ -f $TARGET_HOME/$REAPER_DESKTOP_LEGACY_REL ]] \
                && echo 'BROKEN - only the inert ~/.gnome/apps copy exists' \
                || echo 'missing'; })"
    # Braces stay out of the expansion here: a literal "{,32}" inside ${gl:+...}
    # closes the expansion at the wrong }, and the line silently prints garbage.
    local gl; gl="$(bottles_gl_needed)"
    if [[ -n $gl ]]; then
        printf '  %-24s %s\n' "bottles GPU driver:" \
            "MISSING org.freedesktop.Platform.GL.$gl and GL32.$gl"
    else
        printf '  %-24s %s\n' "bottles GPU driver:" "ok"
    fi

    # Per prefix, because this is decided per prefix: yabridgectl's own
    # wine_version is a global probe and never sees the shim.
    local prefix r
    while read -r prefix; do
        [[ -n $prefix ]] || continue
        if prefix_routed "$prefix"; then
            r="$(bottle_runner "$prefix" 2>/dev/null || true)"
            printf '  %-24s %s -> %s\n' "prefix routing:" "$prefix" "${r:-?}"
        else
            printf '  %-24s %s -> SYSTEM WINE (no bottle.yml)\n' "prefix routing:" "$prefix"
        fi
    done < <(yabridge_prefixes)
}

if [[ $CHECK_ONLY -eq 1 ]]; then
    report
    echo
    exit 0
fi

# ---------------------------------------------------------------------------
if [[ $DO_UPDATE -eq 1 ]]; then
    notify "Update the system"
    if [[ $YES -eq 1 ]]; then run_root dnf update -y; else run_root dnf update; fi
fi

# ---------------------------------------------------------------------------
notify "Kernel: preempt=full"
if ! command -v grubby >/dev/null; then
    warn "grubby not found, skipping"
elif ! grep -q '^CONFIG_PREEMPT_DYNAMIC=y' "/boot/config-$(uname -r)" 2>/dev/null; then
    warn "this kernel has no CONFIG_PREEMPT_DYNAMIC, so preempt=full would be ignored; skipping"
elif grep -qw 'preempt=full' /proc/cmdline; then
    ok "already active in the running kernel"
elif grubby_configured; then
    ok "already configured, applies on next boot"
else
    run_root grubby --args="preempt=full" --update-kernel=ALL
    ok "added to all kernels (takes effect after reboot)"
fi

# ---------------------------------------------------------------------------
# Realtime limits.
# Fedora already ships /etc/security/limits.d/25-pw-rlimits.conf with rtprio 70.
# pam_limits reads limits.d in lexical order and the last value read wins, so a
# 99- prefix guarantees these take precedence instead of racing that file.
# See https://wiki.linuxaudio.org/wiki/system_configuration
# ---------------------------------------------------------------------------
notify "Realtime limits"
write_root_file "$LIMITS_FILE" '# Managed by ~/fedora44-setup/audio/install-audio.sh
# 99- prefix: read after Fedora s 25-pw-rlimits.conf, so these values win.
@pipewire   -   rtprio      90
@pipewire   -   nice        -19
@pipewire   -   memlock     unlimited
' "$LIMITS_FILE" || true

# ---------------------------------------------------------------------------
# sysctl. Upstream appends to /etc/sysctl.conf; a drop-in is the Fedora way and
# stays idempotent. 90- is read before 99-sysctl.conf -> /etc/sysctl.conf, which
# is stock and sets neither of these.
# ---------------------------------------------------------------------------
notify "sysctl tuning"
if write_root_file "$SYSCTL_FILE" 'vm.swappiness = 10
fs.inotify.max_user_watches = 600000
' "$SYSCTL_FILE"; then
    run_root sysctl --system >/dev/null
fi
ok "swappiness=$(sysctl -n vm.swappiness) inotify.max_user_watches=$(sysctl -n fs.inotify.max_user_watches)"

# ---------------------------------------------------------------------------
notify "Group membership"
if in_group pipewire; then
    ok "$TARGET_USER is already in 'pipewire'"
else
    run_root usermod -a -G pipewire "$TARGET_USER"
    ok "added $TARGET_USER to 'pipewire' -- takes effect at your next login"
fi

# ---------------------------------------------------------------------------
if [[ $DO_REALTIME_SETUP -eq 1 ]]; then
    notify "realtime-setup"
    run_root dnf install -y realtime-setup
    run_root systemctl enable realtime-setup.service realtime-entsk.service
    if in_group realtime; then
        ok "$TARGET_USER is already in 'realtime'"
    else
        run_root usermod -a -G realtime "$TARGET_USER"
        ok "added $TARGET_USER to 'realtime' (rtprio 99 via /etc/security/limits.d/realtime.conf)"
    fi
fi

# ---------------------------------------------------------------------------
# rtkit. Upstream masks it unconditionally, before anything has confirmed that
# direct realtime limits actually work -- if the run dies later you are left
# with no realtime path at all. Opt-in, and guarded.
# ---------------------------------------------------------------------------
if [[ $DO_MASK_RTKIT -eq 1 ]]; then
    notify "rtkit-daemon"
    lim="$(rt_hard_limit)"
    if [[ $lim != unlimited && ${lim:-0} -lt 90 && $FORCE -ne 1 ]]; then
        warn "rtprio hard limit for $TARGET_USER is '$lim', below 90."
        warn "The new limits are not in effect yet, so masking rtkit now would leave"
        warn "PipeWire with no realtime path. Reboot, run --check, then re-run with"
        warn "--mask-rtkit (or override with --force)."
    elif confirm "  Disable and mask rtkit-daemon?"; then
        run_root systemctl disable --now rtkit-daemon.service
        run_root systemctl mask rtkit-daemon.service
        ok "masked -- undo with: sudo systemctl unmask --now rtkit-daemon"
    else
        skipped "rtkit-daemon left alone"
    fi
fi

# ---------------------------------------------------------------------------
# REAPER. Portable install: a reaper.ini inside the install dir makes REAPER
# keep its configuration there instead of in ~/.config.
# Note: REAPER is not free. It is incredible software - and cheap.
# Please do the right thing and purchase it.
# ---------------------------------------------------------------------------
if [[ $DO_REAPER -eq 1 ]]; then
    notify "REAPER $REAPER_VER"
    if [[ -d $TARGET_HOME/REAPER ]]; then
        skipped "$TARGET_HOME/REAPER already exists, leaving it untouched"
    else
        command -v curl >/dev/null || die "curl not found (dnf install curl)"
        tmp="$TARGET_HOME/.cache/fedora44-setup"
        run_user mkdir -p "$tmp"
        run_user curl -fL --progress-bar -o "$tmp/reaper.tar.xz" "$REAPER_URL"
        run_user tar -C "$tmp" -xf "$tmp/reaper.tar.xz"
        run_user "$tmp/reaper_linux_x86_64/install-reaper.sh" --install "$TARGET_HOME" --integrate-desktop
        run_user touch "$TARGET_HOME/REAPER/reaper.ini"
        run_user rm -rf "$tmp"
        ok "installed to $TARGET_HOME/REAPER (portable)"
    fi

    # Runs on every pass, not just a fresh install: the entry --integrate-desktop
    # leaves behind is broken in place, so an install that happened months ago is
    # exactly the case that needs this.
    if reaper_desktop_ok; then
        ok "launcher entry present at ~/$REAPER_DESKTOP_REL"
    elif install_reaper_desktop_entry; then
        ok "launcher entry written to ~/$REAPER_DESKTOP_REL, menu cache rebuilt"
        if [[ -f "$TARGET_HOME/$REAPER_DESKTOP_LEGACY_REL" ]]; then
            ok "the stale ~/$REAPER_DESKTOP_LEGACY_REL copy is inert; delete it if you like"
        fi
    else
        warn "could not write the REAPER launcher entry"
        warn "(is $TARGET_HOME/REAPER/reaper missing or not executable?)"
    fi
fi

# ---------------------------------------------------------------------------
# yabridge, the Bottles way.
#
# Follows github.com/microfortnight/yabridge-bottles-wineloader: Bottles owns
# the Wine runner, and WINELOADER points yabridge's Wine plugin hosts at the
# runner configured for each individual Bottle.
#
# Two deliberate departures from that README, both explained in README.md:
#  * yabridge comes from the upstream tarball, not Fedora's COPR. The COPR
#    package hard-requires "wine = 1:9.21" and would downgrade the system Wine,
#    which is the opposite of letting Bottles choose the Wine version.
#  * WINELOADER is exported by ~/.local/bin/plasma-session rather than dropped
#    into ~/.config/environment.d. That keeps it inside the Plasma session, and
#    under greetd it is the only placement that works at all.
# ---------------------------------------------------------------------------
if [[ $DO_YABRIDGE -eq 1 ]]; then
    notify "yabridge + Bottles"

    # yq: wineloader.sh reads the runner out of Bottles' YAML with it.
    # Fedora ships mikefarah/yq v4, whose syntax the script is compatible with.
    if rpm -q yq >/dev/null 2>&1; then
        skipped "yq already installed ($(yq --version 2>/dev/null | awk '{print $NF}'))"
    else
        run_root dnf install -y yq
        ok "yq installed"
    fi

    # flatpak itself, and the Flathub remote. Neither is guaranteed on a bare
    # Fedora install: Workstation only offers Flathub as an opt-in during setup,
    # and a minimal install has no flatpak at all.
    if rpm -q flatpak >/dev/null 2>&1; then
        skipped "flatpak already installed"
    else
        run_root dnf install -y flatpak
        ok "flatpak installed"
    fi
    if flatpak remotes --columns=name 2>/dev/null | grep -qx flathub; then
        skipped "flathub remote already configured"
    else
        run_root flatpak remote-add --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo
        ok "flathub remote added"
    fi

    # Bottles, at system scope to match the other flatpaks on this machine.
    if flatpak info com.usebottles.bottles >/dev/null 2>&1; then
        skipped "Bottles already installed"
    elif confirm "  Install Bottles from Flathub (system-wide flatpak)?"; then
        run_root flatpak install --system -y flathub com.usebottles.bottles
        ok "Bottles installed"
    else
        warn "Bottles not installed - yabridge would have no Wine runner to use"
    fi

    # yabridge itself: upstream tarball, entirely inside $HOME, no root, and
    # no opinion about which Wine is installed.
    if [[ $YABRIDGE_CHANNEL == auto ]]; then
        if wine_needs_dev_yabridge; then
            YABRIDGE_CHANNEL=dev
            echo "  system Wine is $(wine --version 2>/dev/null): using the development build"
            echo "  (stable 5.1.1 breaks plugin GUIs on Wine >= 9.22, yabridge issue #382)"
        else
            YABRIDGE_CHANNEL=stable
        fi
    fi

    tmp="$TARGET_HOME/.cache/fedora44-setup"
    stamp="$TARGET_HOME/.local/share/yabridge/$YABRIDGE_STAMP_REL"

    if [[ $YABRIDGE_CHANNEL == stable ]]; then
        if [[ "$(yabridge_stamp)" == "$YABRIDGE_VER" ]]; then
            skipped "yabridge $YABRIDGE_VER (stable) already installed"
        else
            run_user mkdir -p "$tmp" "$TARGET_HOME/.local/share"
            run_user curl -fsSL -o "$tmp/yabridge.tar.gz" "$YABRIDGE_URL"
            if ! echo "$YABRIDGE_SHA256  $tmp/yabridge.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
                die "yabridge tarball checksum mismatch - refusing to install"
            fi
            ok "tarball checksum verified"
            run_user tar -C "$TARGET_HOME/.local/share" -xzf "$tmp/yabridge.tar.gz"
            run_user rm -f "$tmp/yabridge.tar.gz"
            printf '%s' "$YABRIDGE_VER" | run_user tee "$stamp" >/dev/null
            ok "yabridge $YABRIDGE_VER (stable) installed to ~/.local/share/yabridge"
        fi
    else
        # Development build. There is no release to pin, so the artifact URLs
        # are discovered and the build is identified by its git describe.
        mapfile -t dev_urls < <(yabridge_dev_urls)
        if [[ ${#dev_urls[@]} -lt 2 ]]; then
            die "could not find the yabridge nightly artifacts at $YABRIDGE_NIGHTLY"
        fi
        dev_ver=""
        for u in "${dev_urls[@]}"; do
            case "${u##*/}" in
                yabridge-*) dev_ver="${u##*/yabridge-}"; dev_ver="${dev_ver%.tar.gz.zip}" ;;
            esac
        done
        if [[ "$(yabridge_stamp)" == "$dev_ver" ]]; then
            skipped "yabridge $dev_ver (development build) already installed"
        else
            run_user mkdir -p "$tmp/ybdev" "$TARGET_HOME/.local/share/yabridge"
            for u in "${dev_urls[@]}"; do
                run_user curl -fsSL --max-time 300 -o "$tmp/ybdev/${u##*/}" "$u"
            done
            # GitHub wraps the tarball in a zip, so it unpacks twice.
            run_user python3 -c "
import glob, zipfile, tarfile, os
d = '$tmp/ybdev'
for z in glob.glob(os.path.join(d, '*.zip')):
    zipfile.ZipFile(z).extractall(d)
for t in glob.glob(os.path.join(d, '*.tar.gz')):
    tarfile.open(t).extractall(d)
"
            [[ -f "$tmp/ybdev/yabridge/libyabridge-vst3.so" && -f "$tmp/ybdev/yabridgectl/yabridgectl" ]] \
                || die "yabridge nightly archive did not contain the expected files"
            run_user cp -a "$tmp/ybdev/yabridge/." "$TARGET_HOME/.local/share/yabridge/"
            run_user cp -a "$tmp/ybdev/yabridgectl/yabridgectl" "$TARGET_HOME/.local/share/yabridge/yabridgectl"
            run_user rm -rf "$tmp/ybdev"
            printf '%s' "$dev_ver" | run_user tee "$stamp" >/dev/null
            ok "yabridge $dev_ver (development build) installed to ~/.local/share/yabridge"
        fi
    fi

    # The Bottles wineloader shim (vendored from the repo above, public domain).
    if cmp -s "$SRC_DIR/files/wineloader.sh" "$TARGET_HOME/.local/bin/wineloader.sh"; then
        skipped "wineloader.sh already current"
    else
        run_user install -D -m 0755 "$SRC_DIR/files/wineloader.sh" "$TARGET_HOME/.local/bin/wineloader.sh"
        ok "wineloader.sh installed to ~/.local/bin"
    fi

    # Put yabridgectl on PATH now. The session wrapper's PATH export only
    # applies from the next login, which is no use if yabridge was installed
    # after the session started - the usual case. ~/.local/bin is already on
    # PATH for both bash and fish, and yabridgectl resolves its own real path
    # via /proc/self/exe, so a symlink is enough.
    if cmp -s "$SRC_DIR/files/yabridgectl-wrapper" "$TARGET_HOME/.local/bin/yabridgectl"; then
        skipped "yabridgectl wrapper already current (~/.local/bin, on PATH)"
    else
        run_user install -D -m 0755 "$SRC_DIR/files/yabridgectl-wrapper" \
                                    "$TARGET_HOME/.local/bin/yabridgectl"
        ok "yabridgectl wrapper installed in ~/.local/bin (on PATH already, no re-login)"
    fi

    # Register every prepared Bottle. Creating the four standard plugin
    # directories is what makes "drop your plugins here" unambiguous; adding a
    # directory with nothing in it is harmless.
    cfg="$(yabridge_config_home)"
    if [[ ! -d "$TARGET_HOME/.config-plasma" ]]; then
        warn "~/.config-plasma does not exist, so yabridgectl's config is going to"
        warn "~/.config instead. Run ../kde/install-kde.sh first on a fresh machine,"
        warn "then re-run this, or the config ends up in the wrong place."
    fi
    echo "  yabridgectl config: $cfg/yabridgectl/config.toml"
    bottles_found=0
    while read -r root; do
        [[ -n $root ]] || continue
        for bottle in "$root"/*/; do
            [[ -d "${bottle}drive_c" ]] || continue
            bottles_found=$((bottles_found + 1))
            for sub in "${YABRIDGE_PLUGIN_SUBDIRS[@]}"; do
                run_user mkdir -p "${bottle}${sub}"
                yc add "${bottle}${sub}" >/dev/null
            done
            ok "registered bottle: $(basename "${bottle%/}")"
        done
    done < <(bottles_roots)

    # ni-wine's prefix, when present. ni-wine's own README tells Linux DAW
    # users to bridge straight from here, so these directories are registered
    # but never created - Native Access owns that prefix's layout.
    if [[ -d "$TARGET_HOME/.wine-ni/drive_c" ]]; then
        ni_added=0
        for sub in "${YABRIDGE_PLUGIN_SUBDIRS[@]}"; do
            if [[ -d "$TARGET_HOME/.wine-ni/$sub" ]]; then
                yc add "$TARGET_HOME/.wine-ni/$sub" >/dev/null
                ni_added=$((ni_added + 1))
            fi
        done
        if [[ $ni_added -gt 0 ]]; then
            ok "registered ni-wine prefix (~/.wine-ni, $ni_added dir(s))"
            echo "          these load with the system Wine ($(wine --version 2>/dev/null)):"
            echo "          ~/.wine-ni has no bottle.yml, so wineloader.sh falls back."
            echo "          That is precisely why the development build is used."
        fi
    fi

    if [[ $bottles_found -eq 0 ]]; then
        warn "no Bottles prefixes found. Create one in Bottles (Create new bottle,"
        warn "environment 'Application'), then re-run with --yabridge."
    else
        echo
        yc sync
    fi

    # Runner sanity, but only for the stable build. Pinning a Bottle to Wine
    # 9.21 was purely a workaround for yabridge #382; the development build
    # fixes that, so with it any runner is fine and so is the system Wine.
    if [[ $YABRIDGE_CHANNEL == stable ]]; then
        if ! bottles_runners | grep -qx "$YABRIDGE_RUNNER_HINT"; then
            warn "runner '$YABRIDGE_RUNNER_HINT' is not installed."
            warn "Stable yabridge needs it (yabridge issue #382). Install it via"
            warn "Bottles > Preferences > Runners, then re-run with --yabridge."
        fi
        while read -r root; do
            [[ -n $root ]] || continue
            for bottle in "$root"/*/; do
                [[ -f "${bottle}bottle.yml" ]] || continue
                r="$(bottle_runner "${bottle%/}" || true)"
                if [[ -z $r || $r == sys-* ]]; then
                    warn "bottle '$(basename "${bottle%/}")' uses runner '${r:-none}',"
                    warn "so it falls back to the system Wine - broken with stable yabridge."
                fi
            done
        done < <(bottles_roots)
    fi

    # Prefix routing. yabridgectl will happily report every plugin as "synced"
    # while the shim quietly bridges them against the system Wine, because the
    # two never consult each other: sync records a global `wine --version`, and
    # routing is decided per prefix at load time by whether bottle.yml is there.
    # So this checks the thing that actually decides, one prefix at a time.
    unrouted=()
    while read -r prefix; do
        [[ -n $prefix ]] || continue
        prefix_routed "$prefix" || unrouted+=("$prefix")
    done < <(yabridge_prefixes)

    if [[ ${#unrouted[@]} -eq 0 ]]; then
        ok "every prefix yabridge scans routes through the shim to a Bottles runner"
    elif [[ $DO_ROUTE_PREFIXES -eq 1 ]]; then
        anchor_prefix="$(anchor_bottle || true)"
        if [[ -z $anchor_prefix ]]; then
            warn "no Bottle exists yet, so there is nothing to anchor routing to."
            warn "Create one in Bottles first, then re-run with --route-prefixes."
        else
            anchor="$(basename "$anchor_prefix")"
            runner="$ROUTE_RUNNER"
            if [[ -z $runner ]]; then
                runner="$(bottle_runner "$anchor_prefix" || true)"
            fi
            if [[ -z $runner || $runner == sys-* ]]; then
                warn "the anchor Bottle '$anchor' uses runner '${runner:-none}', which is"
                warn "the system Wine -- routing to it would be a no-op. Pick one with"
                warn "--route-runner, e.g. --route-runner $YABRIDGE_RUNNER_HINT"
            else
                for prefix in "${unrouted[@]}"; do
                    if route_prefix "$prefix" "$runner" "$anchor"; then
                        ok "routed $prefix -> $runner"
                        ok "  now resolves to: $(prefix_wine_version "$prefix")"
                    else
                        warn "could not write $prefix/bottle.yml"
                    fi
                done
            fi
        fi
    else
        for prefix in "${unrouted[@]}"; do
            warn "$prefix has no bottle.yml, so the shim falls back to the system Wine:"
            warn "  plugins there load under $(prefix_wine_version "$prefix")"
        done
        warn "Re-run with --route-prefixes to point them at a Bottles runner instead."
    fi

    # Bottles owns the Wine runner here, so a Bottles that cannot open is not a
    # cosmetic problem: there is no other way to configure or change a runner.
    gl_slug="$(bottles_gl_needed)"
    if [[ -n $gl_slug ]]; then
        warn "Bottles has no matching NVIDIA driver inside the Flatpak sandbox."
        warn "It will crash on its first window with a BadDrawable X error. Fix:"
        warn "  flatpak install -y flathub org.freedesktop.Platform.GL.$gl_slug \\"
        warn "                            org.freedesktop.Platform.GL32.$gl_slug"
        warn "GL32 is not optional -- Wine needs the 32-bit libraries for 32-bit plugins."
    fi

    # WINELOADER can only enter a session at login.
    if wineloader_active_in_session; then
        ok "WINELOADER is active in the running Plasma session"
    else
        warn "WINELOADER is NOT set in the running Plasma session."
        warn "The wrapper exports it at login, and yabridge was installed after this"
        warn "session started. LOG OUT OF PLASMA AND BACK IN before loading plugins,"
        warn "or they will be bridged against system Wine instead of the Bottle runner."
    fi

    cat <<'NEXT'

  Still yours to do:
    * Plugins already in a Bottle are registered and synced by the run above.
      After installing more, just re-run: yabridgectl sync
    * Bottle runners: with the development build any runner works, including
      "sys-*" (the system Wine). Only stable yabridge needs a Bottle pinned to
      kron4ek-wine-9.21-staging-tkg-amd64, per yabridge issue #382.
    * Rescan plugins in your DAW. If you changed yabridge build (stable <->
      development), rescan even if the plugin list looks unchanged.
NEXT
fi

# ---------------------------------------------------------------------------
# ni-wine: Native Instruments software (Native Access, Kontakt) in a dedicated
# Wine prefix at ~/.wine-ni, from COPR selimbucher/ni-wine.
#
# A separate track from Bottles, and complementary to it. Bottles supplies the
# Wine runner yabridge hosts plugins with; ni-wine manages the prefix that NI's
# installers expect, and `ni link <DAW_PREFIX>` then exposes the installed
# products to a DAW's own Wine prefix -- that is, to the Bottle yabridgectl
# already scans.
#
# It requires wine >= 11, so it depends on the system Wine staying where it is.
# That is a second, independent reason the yabridge wine-tkg COPR was rejected:
# it pins wine 9.21 and would break this.
# ---------------------------------------------------------------------------
if [[ $DO_NI_WINE -eq 1 ]]; then
    notify "ni-wine (Native Instruments under Wine)"

    if rpm -q ni-wine >/dev/null 2>&1; then
        skipped "ni-wine $(rpm -q --qf '%{version}' ni-wine) already installed"
    else
        run_root dnf copr enable -y "$NI_WINE_COPR"
        run_root dnf install -y ni-wine
        ok "ni-wine installed (dnf pulls winetricks, msitools, Xvfb, cabextract, zenity)"
    fi

    wv="$(wine --version 2>/dev/null | sed 's/^wine-//' | cut -d. -f1)"
    if [[ -n $wv && $wv -lt 11 ]]; then
        warn "system Wine is ${wv}.x but ni-wine needs >= 11. Do not install yabridge"
        warn "from the wine-tkg COPR: it pins wine 9.21 and would break this."
    fi

    echo
    run_user ni doctor 2>&1 | sed 's/^/  /' || true

    cat <<'NEXT'

  ni-wine next steps: these need your NI account and a GUI, so they stay yours:
    1. ni setup                 create ~/.wine-ni and install Native Access
    2. ni launch                sign in; installing Kontakt arms the MSI hook
    3. ni link <BOTTLE_PREFIX>  expose the installed NI products to the Bottle
                                yabridge already watches, e.g.
                                ni link "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/<Bottle>"
    4. yabridgectl sync         bridge whatever that exposed
    5. ni doctor                re-check
NEXT
fi

# ---------------------------------------------------------------------------
report
notify "Done"
echo "Reboot to pick up the kernel argument and your new group membership,"
echo "then re-run './install-audio.sh --check' to confirm the rtprio limit is 90."
if [[ $DO_YABRIDGE -eq 0 && -z "$(yabridge_installed_ver)" ]]; then
    echo
    echo "NOTE: yabridge and the Bottles wineloader were NOT set up - that step"
    echo "      is opt-in. Run './install-audio.sh --yabridge' if you want it."
fi
echo
