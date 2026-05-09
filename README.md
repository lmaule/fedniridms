# fedniridms

Install script to configure a brand-new minimal Fedora install with **Niri** and **Dank Material Shell (DMS)** on an NVIDIA GPU.

## What it does

1. **Preflight** — verifies Fedora, sudo, network, base CLI tools, and an NVIDIA GPU.
2. **System update** — `dnf upgrade --refresh`.
3. **Terra repository + sub-repos** — installs `terra-release` and the `terra-release-extras`, `terra-release-mesa`, `terra-release-nvidia` (and `terra-release-multimedia` on Fedora 43+) subpackages, which lay down the matching `.repo` files. Terra provides the NVIDIA driver, Niri, DMS, and the DMS greeter, so no RPM Fusion is needed. See https://developer.fyralabs.com/terra/installing.
4. **NVIDIA drivers** (from Terra) — `akmod-nvidia` + CUDA + VAAPI; sets `nvidia-drm.modeset=1`, blacklists nouveau, waits for the kernel module to build.
5. **Niri compositor** — installs `niri`. All Wayland session bits (xdg-desktop-portal, PipeWire, Polkit, etc.) come along automatically as Niri's dependencies.
6. **Dank Material Shell** — installs `dms` from Terra. `quickshell`, `dgop`, fonts, and other DMS deps are pulled in automatically.
7. **DMS greeter** — enables Copr `avengemedia/danklinux` (the greeter is **not** in Terra) and installs `dms-greeter` (which pulls in `greetd`). Writes `/etc/greetd/config.toml` with `command = "dms-greeter --command niri"` and sets the graphical target as default. Docs: https://danklinux.com/docs/dankgreeter/
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

When it finishes, **reboot** so the NVIDIA kernel command line (`nvidia-drm.modeset=1`) and the freshly built `akmod-nvidia` module take effect. On reboot you'll be greeted by `dms-greeter` (running under `greetd`); log in and Niri will start with DMS auto-spawning.

## Verifying after reboot

```bash
nvidia-smi
cat /sys/module/nvidia_drm/parameters/modeset   # expect: Y
dnf repolist --enabled | grep -i terra
systemctl status greetd
niri --version
```
