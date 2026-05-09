# fedniridms

Install script to configure a brand-new minimal Fedora install with **Niri** and **Dank Material Shell (DMS)** on an NVIDIA GPU.

## What it does

1. **Preflight** — verifies Fedora, sudo, network, base CLI tools, and an NVIDIA GPU.
2. **System update** — `dnf upgrade --refresh`.
3. **RPM Fusion** (free + nonfree) — required for the proprietary NVIDIA driver.
4. **Terra repository** — installs `terra-release` and enables every Terra subrepo it ships.
5. **NVIDIA drivers** — `akmod-nvidia` + CUDA + VAAPI; sets `nvidia-drm.modeset=1`, blacklists nouveau, waits for the kernel module to build.
6. **Niri compositor** — installs `niri` and the usual Wayland session bits (xdg-desktop-portal, PipeWire, Polkit, NetworkManager, fuzzel, mako, grim/slurp, wl-clipboard, etc.).
7. **Dank Material Shell** — installs `quickshell`, `dgop`, and `dms` from Terra plus fonts/icons.
8. **Niri config** — writes a starter `~/.config/niri/config.kdl` that auto-spawns DMS and sets the NVIDIA Wayland env vars.

The script is **idempotent** — re-running it skips anything already in place.

## Usage

From a TTY on a freshly logged-in minimal Fedora install (run as your normal user, not root):

```bash
curl -fsSL https://raw.githubusercontent.com/lmaule/fedniridms/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

Or, if you cloned the repo:

```bash
git clone https://github.com/lmaule/fedniridms.git
cd fedniridms
./install.sh
```

When it finishes, **reboot** so the NVIDIA kernel command line (`nvidia-drm.modeset=1`) and the freshly built `akmod-nvidia` module take effect. Then log back in on a TTY and run:

```bash
niri-session
```

DMS is configured to auto-spawn.

## Verifying after reboot

```bash
nvidia-smi
cat /sys/module/nvidia_drm/parameters/modeset   # expect: Y
dnf repolist --enabled | grep -i terra
niri --version
```
