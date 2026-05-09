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

# ---------- terra repo + subrepos ----------
install_terra() {
    hdr "terra repo"

    # 1. base terra repo via terra-release
    if rpm -q terra-release >/dev/null 2>&1; then
        ok "terra-release already installed"
    else
        sudo dnf install -y --nogpgcheck \
            --repofrompath "terra,https://repos.fyralabs.com/terra\$releasever" \
            terra-release
        ok "terra-release installed"
    fi

    # 2. sub-repos. each ships as its own terra-release-<name> subpackage; installing
    #    the subpackage drops the matching .repo file (terra-extras, terra-mesa,
    #    terra-nvidia, terra-multimedia). docs:
    #    https://developer.fyralabs.com/terra/installing
    local subrepos=(terra-release-extras terra-release-mesa terra-release-nvidia)
    # terra-multimedia is Fedora 43+
    if (( FEDORA_VER >= 43 )); then
        subrepos+=(terra-release-multimedia)
    fi

    log "installing terra sub-repo packages: ${subrepos[*]}"
    sudo dnf install -y "${subrepos[@]}"

    # 3. confirm what's now enabled
    log "enabled terra repos:"
    dnf repolist --enabled 2>/dev/null | awk 'tolower($1) ~ /^terra/ {print "    " $1}'

    sudo dnf makecache
    ok "terra + sub-repos ready"
}

# ---------- nvidia drivers (from terra) ----------
install_nvidia() {
    hdr "nvidia drivers (terra)"
    if rpm -q akmod-nvidia >/dev/null 2>&1; then
        ok "akmod-nvidia already installed"
    else
        # Terra ships akmod-nvidia + companions; pull them from terra explicitly
        # so we don't accidentally fall through to a different source.
        sudo dnf install -y \
            akmod-nvidia \
            nvidia-vaapi-driver \
            libva-utils \
            vdpauinfo
        ok "nvidia packages installed from terra"
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

    sudo systemctl enable --now NetworkManager 2>/dev/null || true
}

# ---------- dank material shell ----------
install_dms() {
    hdr "dank material shell"

    sudo dnf install -y dms || {
        warn "package 'dms' not found; trying 'dank-material-shell'"
        sudo dnf install -y dank-material-shell || {
            err "could not install DMS from terra. check 'dnf search dms' / 'dnf search dank'."
            return 1
        }
    }

    ok "DMS installed"
}

# ---------- dms greeter (greetd-based login screen) ----------
# dms-greeter is NOT in Terra — it ships from copr avengemedia/danklinux.
# docs: https://danklinux.com/docs/dankgreeter/
install_dms_greeter() {
    hdr "dms greeter"

    # `dnf copr` lives in dnf-plugins-core
    if ! sudo dnf copr --help >/dev/null 2>&1; then
        sudo dnf install -y dnf-plugins-core
    fi

    if ! sudo dnf copr list --enabled 2>/dev/null | grep -qi 'avengemedia/danklinux'; then
        sudo dnf copr enable -y avengemedia/danklinux
        ok "enabled copr avengemedia/danklinux"
    else
        ok "copr avengemedia/danklinux already enabled"
    fi

    if rpm -q dms-greeter >/dev/null 2>&1; then
        ok "dms-greeter already installed"
    else
        sudo dnf install -y dms-greeter
        ok "dms-greeter installed (greetd pulled in as a dependency)"
    fi

    # point greetd at dms-greeter, asking it to launch niri inside the greeter session
    local greetd_cfg=/etc/greetd/config.toml
    if [[ -f "$greetd_cfg" ]]; then
        sudo cp -n "$greetd_cfg" "${greetd_cfg}.bak" || true
    fi

    sudo install -d -m 0755 /etc/greetd
    sudo tee "$greetd_cfg" >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "dms-greeter --command niri"
user = "greeter"
EOF
    ok "wrote $greetd_cfg"

    # disable any other display manager that may have come along, then enable greetd
    for dm in gdm sddm lightdm lxdm; do
        if systemctl is-enabled --quiet "$dm" 2>/dev/null; then
            sudo systemctl disable --now "$dm" || true
        fi
    done
    sudo systemctl enable greetd.service
    sudo systemctl set-default graphical.target
    ok "greetd enabled as the default display manager"
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

    ok "wrote $cfg (note: Mod+Return launches 'foot' — install your terminal of choice)"
}

# ---------- summary ----------
finish() {
    hdr "done"
    cat <<EOF
${GRN}install complete.${RST}

next steps:
  1. ${BLD}reboot${RST} so the NVIDIA kms cmdline + freshly built modules take effect:
       sudo reboot
  2. you'll be greeted by ${BLD}dms-greeter${RST} (greetd); log in and niri starts.
     DMS auto-spawns from ~/.config/niri/config.kdl

verify after reboot:
  - nvidia driver:  nvidia-smi
  - kms:            cat /sys/module/nvidia_drm/parameters/modeset   # expect: Y
  - terra repos:    dnf repolist --enabled | grep -i terra
  - greetd:         systemctl status greetd
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
    install_terra
    install_nvidia
    install_niri
    install_dms
    install_dms_greeter
    configure_niri
    finish
}

main "$@"
