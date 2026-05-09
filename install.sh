#!/usr/bin/env bash
#
# fedniridms - Fedora minimal install -> Niri + Dank Material Shell (NVIDIA)
#
# Run from a TTY on a freshly logged-in minimal Fedora install.
# Re-runnable: each step checks current state before acting.

set -euo pipefail

# ---------- ui helpers ----------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; BLU=$'\033[0;34m'; BLD=$'\033[1m'; RST=$'\033[0m'

log()  { printf '%s[*]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; }
hdr()  { printf '\n%s%s== %s ==%s\n' "$BLD" "$BLU" "$*" "$RST"; }

trap 'err "failed at line $LINENO: $BASH_COMMAND"' ERR

# ---------- preflight ----------
preflight() {
    hdr "preflight checks"

    if [[ $EUID -eq 0 ]]; then
        err "do not run as root. run as your normal user; sudo will be invoked when needed."
        exit 1
    fi

    if [[ ! -f /etc/fedora-release ]]; then
        err "this script targets Fedora. /etc/fedora-release not found."
        exit 1
    fi

    FEDORA_VER=$(rpm -E %fedora)
    ok "Fedora ${FEDORA_VER} detected"

    if ! sudo -v; then
        err "sudo authentication failed."
        exit 1
    fi
    ok "sudo authenticated"

    # keep sudo alive while the script runs
    ( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

    # network reachable?
    if ! curl -fsS --max-time 5 https://repos.fyralabs.com >/dev/null 2>&1; then
        err "no network or terra repo unreachable."
        exit 1
    fi
    ok "network reachable"

    # required tools that should already exist on minimal Fedora
    local need=(curl dnf rpm grep awk sed lsmod)
    local missing=()
    for t in "${need[@]}"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if (( ${#missing[@]} )); then
        log "installing missing base tools: ${missing[*]}"
        sudo dnf install -y "${missing[@]}"
    fi
    ok "base tools present"

    # nvidia gpu present?
    if ! lspci 2>/dev/null | grep -Ei 'vga|3d|display' | grep -qi nvidia; then
        if command -v lspci >/dev/null 2>&1; then
            warn "no NVIDIA GPU detected by lspci. continuing, but the NVIDIA step may be unnecessary."
        else
            sudo dnf install -y pciutils
            if ! lspci | grep -Ei 'vga|3d|display' | grep -qi nvidia; then
                warn "no NVIDIA GPU detected. continuing anyway."
            else
                ok "NVIDIA GPU detected"
            fi
        fi
    else
        ok "NVIDIA GPU detected"
    fi
}

# ---------- system update ----------
system_update() {
    hdr "system update"
    sudo dnf upgrade --refresh -y
    ok "system up to date"
}

# ---------- rpm fusion (needed for nvidia) ----------
install_rpmfusion() {
    hdr "rpm fusion"
    if rpm -q rpmfusion-free-release >/dev/null 2>&1 \
       && rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
        ok "rpm fusion already enabled"
        return
    fi
    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm"
    sudo dnf install -y core
    ok "rpm fusion enabled"
}

# ---------- terra repo + subrepos ----------
install_terra() {
    hdr "terra repo"
    if rpm -q terra-release >/dev/null 2>&1; then
        ok "terra-release already installed"
    else
        sudo dnf install -y --nogpgcheck \
            --repofrompath "terra,https://repos.fyralabs.com/terra\$releasever" \
            terra-release
        ok "terra-release installed"
    fi

    # enable all terra subrepos shipped by terra-release
    log "enabling all terra subrepos"
    mapfile -t TERRA_REPOS < <(dnf repolist --all 2>/dev/null \
        | awk 'tolower($1) ~ /^terra/ {print $1}')
    if (( ${#TERRA_REPOS[@]} == 0 )); then
        warn "no terra repos discovered in dnf repolist"
    else
        sudo dnf config-manager setopt "${TERRA_REPOS[@]/%/.enabled=1}" 2>/dev/null \
            || for r in "${TERRA_REPOS[@]}"; do sudo dnf config-manager --set-enabled "$r" || true; done
        ok "terra subrepos enabled: ${TERRA_REPOS[*]}"
    fi

    sudo dnf makecache
}

# ---------- nvidia drivers ----------
install_nvidia() {
    hdr "nvidia drivers"
    if rpm -q akmod-nvidia >/dev/null 2>&1; then
        ok "akmod-nvidia already installed"
    else
        sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda \
            nvidia-vaapi-driver libva-utils vdpauinfo
        ok "nvidia packages installed"
    fi

    # enable kms for wayland (required by niri on nvidia)
    if ! grep -q 'nvidia-drm.modeset=1' /proc/cmdline; then
        log "enabling nvidia-drm.modeset=1 in kernel cmdline"
        sudo grubby --update-kernel=ALL --args='nvidia-drm.modeset=1 nvidia-drm.fbdev=1'
        NVIDIA_REBOOT_REQUIRED=1
    else
        ok "nvidia-drm.modeset already set"
    fi

    # blacklist nouveau just in case
    if ! grep -qsr 'blacklist nouveau' /etc/modprobe.d/ 2>/dev/null; then
        echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null
        ok "nouveau blacklisted"
    fi

    log "waiting for akmod to build the nvidia kernel module (can take several minutes)..."
    local waited=0 max=900
    while (( waited < max )); do
        if modinfo -F version nvidia >/dev/null 2>&1; then
            ok "nvidia kernel module built (version $(modinfo -F version nvidia))"
            return
        fi
        sleep 15
        waited=$((waited+15))
        printf '.'
    done
    echo
    warn "nvidia module not yet visible to modinfo; build may finish after reboot."
}

# ---------- niri ----------
install_niri() {
    hdr "niri compositor"
    if rpm -q niri >/dev/null 2>&1; then
        ok "niri already installed"
    else
        sudo dnf install -y niri
        ok "niri installed"
    fi

    # session essentials niri usually expects
    sudo dnf install -y \
        xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
        pipewire pipewire-pulseaudio wireplumber \
        polkit gnome-keyring \
        brightnessctl playerctl \
        wl-clipboard grim slurp \
        fuzzel mako swaybg swayidle swaylock \
        network-manager-applet NetworkManager \
        pavucontrol \
        || warn "one or more session helper packages failed; continuing"

    sudo systemctl enable --now NetworkManager
    ok "niri session deps installed"
}

# ---------- dank material shell ----------
install_dms() {
    hdr "dank material shell"

    # DMS runs on quickshell; both ship via terra
    sudo dnf install -y quickshell dgop dms || {
        warn "primary DMS package install failed; trying alternate package names"
        sudo dnf install -y quickshell dgop dank-material-shell || {
            err "could not install DMS from terra. check 'dnf search dms' / 'dnf search dank'."
            return 1
        }
    }

    # fonts + icons DMS expects
    sudo dnf install -y \
        google-noto-fonts-common google-noto-sans-fonts \
        google-noto-sans-mono-fonts google-noto-emoji-fonts \
        google-noto-color-emoji-fonts \
        jetbrains-mono-fonts-all \
        material-icons-fonts adw-gtk3-theme papirus-icon-theme \
        ddcutil ddcui \
        || warn "some optional DMS deps failed; continuing"

    ok "DMS installed"
}

# ---------- niri config to launch DMS ----------
configure_niri() {
    hdr "niri configuration"
    local cfg_dir="$HOME/.config/niri"
    local cfg="$cfg_dir/config.kdl"
    mkdir -p "$cfg_dir"

    if [[ -f "$cfg" ]]; then
        ok "niri config already present at $cfg (leaving untouched)"
        return
    fi

    cat > "$cfg" <<'KDL'
// niri config - generated by fedniridms
// docs: https://github.com/YaLTeR/niri/wiki/Configuration:-Overview

input {
    keyboard {
        xkb { layout "us"; }
    }
    touchpad {
        tap; natural-scroll;
    }
}

layout {
    gaps 8
    center-focused-column "never"
    preset-column-widths { proportion 0.33333; proportion 0.5; proportion 0.66667; }
    default-column-width { proportion 0.5; }
    focus-ring { width 2; }
}

prefer-no-csd

// launch DMS at startup
spawn-at-startup "dms" "run"

environment {
    QT_QPA_PLATFORM "wayland"
    GDK_BACKEND     "wayland,x11"
    MOZ_ENABLE_WAYLAND "1"
    // nvidia bits
    LIBVA_DRIVER_NAME "nvidia"
    GBM_BACKEND       "nvidia-drm"
    __GLX_VENDOR_LIBRARY_NAME "nvidia"
    NVD_BACKEND       "direct"
}

binds {
    Mod+Return       { spawn "foot"; }
    Mod+D            { spawn "fuzzel"; }
    Mod+Q            { close-window; }
    Mod+Shift+E      { quit; }
    Mod+H            { focus-column-left; }
    Mod+L            { focus-column-right; }
    Mod+J            { focus-window-down; }
    Mod+K            { focus-window-up; }
    Mod+Shift+H      { move-column-left; }
    Mod+Shift+L      { move-column-right; }
    Mod+R            { switch-preset-column-width; }
    Mod+F            { maximize-column; }
    Mod+Shift+F      { fullscreen-window; }
    XF86AudioRaiseVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
    XF86AudioMute        allow-when-locked=true { spawn "wpctl" "set-mute"   "@DEFAULT_AUDIO_SINK@" "toggle"; }
    XF86MonBrightnessUp                         { spawn "brightnessctl" "set" "5%+"; }
    XF86MonBrightnessDown                       { spawn "brightnessctl" "set" "5%-"; }
    Print            { spawn "sh" "-c" "grim -g \"$(slurp)\" - | wl-copy"; }
}
KDL

    sudo dnf install -y foot >/dev/null 2>&1 || warn "foot terminal not installed"
    ok "wrote $cfg"
}

# ---------- summary ----------
finish() {
    hdr "done"
    cat <<EOF
${GRN}install complete.${RST}

next steps:
  1. ${BLD}reboot${RST} so the NVIDIA kms cmdline + freshly built modules take effect:
       sudo reboot
  2. log back in on a TTY and run: ${BLD}niri-session${RST}
       (or just: niri --session)
  3. DMS is set to auto-spawn from the niri config at ~/.config/niri/config.kdl

verify after reboot:
  - nvidia driver:  nvidia-smi
  - kms:            cat /sys/module/nvidia_drm/parameters/modeset   # expect: Y
  - terra repos:    dnf repolist --enabled | grep -i terra
  - niri:           niri --version
  - dms:            dms --version || quickshell --version

EOF
    if [[ "${NVIDIA_REBOOT_REQUIRED:-0}" == "1" ]]; then
        warn "reboot is REQUIRED to load the NVIDIA driver with nvidia-drm.modeset=1"
    fi
}

# ---------- main ----------
main() {
    preflight
    system_update
    install_rpmfusion
    install_terra
    install_nvidia
    install_niri
    install_dms
    configure_niri
    finish
}

main "$@"
