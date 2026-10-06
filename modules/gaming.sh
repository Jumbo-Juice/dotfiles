#!/usr/bin/env bash
# Gaming: Nvidia (iGPU drives the display, RTX 2060 on demand), Steam,
# GameMode, MangoHud, controller udev rules. Run alone or via bootstrap --gaming.
set -Eeuo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/common.sh
. "$DOTFILES_DIR/lib/common.sh"

DRIVER_INSTALLED=0

nvidia_gpu_present() {
  lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | matches -i nvidia
}

nvidia_driver_working() {
  [[ -e /proc/driver/nvidia/version ]] || modinfo nvidia >/dev/null 2>&1
}

secure_boot_hint() {
  secure_boot_enabled || return 0
  note "Secure Boot is ON. If a password was requested for MOK, the blue 'MOK management' screen appears on the next reboot: Enroll MOK -> Continue -> Yes -> type that password -> Reboot. Skipping it leaves the Nvidia module unloaded (iGPU still works)."
}

# ------------------------------------------------------------- repos --------

step_repos() {
  step "32-bit and extra repositories"
  case $DISTRO in
    arch)
      if pacman-conf --repo-list | matches -x multilib; then
        ok "multilib enabled"
      else
        sudo cp /etc/pacman.conf "/etc/pacman.conf.dotfiles-$(date +%Y%m%d-%H%M%S)"
        if grep -q '^#\[multilib\]' /etc/pacman.conf; then
          sudo sed -i '/^#\[multilib\]/{s/^#//;n;s/^#[[:space:]]*Include/Include/}' /etc/pacman.conf
        else
          printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
        fi
        changed "enabled multilib in /etc/pacman.conf"
        pkg_refresh force
      fi
      ;;
    fedora)
      local rel
      rel=$(rpm -E %fedora)
      if rpm -q --quiet rpmfusion-free-release && rpm -q --quiet rpmfusion-nonfree-release; then
        ok "RPM Fusion free + nonfree enabled"
      else
        sudo dnf install -y \
          "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm" \
          "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm"
        changed "enabled RPM Fusion free + nonfree"
      fi
      ;;
    ubuntu)
      if dpkg --print-foreign-architectures | matches -x i386; then
        ok "i386 architecture enabled"
      else
        sudo dpkg --add-architecture i386
        changed "enabled i386 architecture"
        PKG_REFRESHED=0
      fi
      if grep -rhsE '^[^#]*(multiverse)' /etc/apt/sources.list /etc/apt/sources.list.d/ | matches .; then
        ok "multiverse enabled"
      else
        pkg_install software-properties-common
        sudo add-apt-repository -y multiverse
        changed "enabled multiverse"
        PKG_REFRESHED=0
      fi
      ;;
  esac
}

# ------------------------------------------------------------- driver -------

driver_arch() {
  if nvidia_driver_working || pkg_installed nvidia-utils; then
    ok "existing Nvidia driver found (chwd or earlier install); leaving it alone"
  else
    # nvidia-open supports Turing (RTX 20xx) and newer; dkms covers any kernel.
    local pkgs=(nvidia-open-dkms nvidia-utils) k
    while IFS= read -r k; do
      pkg_available "${k}-headers" && pkgs+=("${k}-headers")
    done < <(pacman -Qq | grep -E '^linux(-[a-z0-9]+)*$' | grep -vE -- '-(headers|firmware.*|api-headers|docs|tools)$' || true)
    if is_test; then
      pkg_check_only "${pkgs[@]}"
    else
      pkg_install "${pkgs[@]}"
      DRIVER_INSTALLED=1
    fi
  fi
  # 32-bit userspace for Steam, and prime-run.
  pkg_install lib32-nvidia-utils nvidia-prime
}

fedora_secure_boot_key() {
  secure_boot_enabled || return 0
  local der=/etc/pki/akmods/certs/public_key.der
  pkg_install kmodtool akmods mokutil openssl
  if ! sudo test -f "$der"; then
    sudo kmodgenca -a
    changed "generated akmods signing key"
  fi
  if mokutil --test-key "$der" 2>&1 | matches -i 'already enrolled'; then
    ok "akmods key enrolled in MOK"
  elif mokutil --list-new 2>/dev/null | matches .; then
    ok "MOK enrolment already pending"
  else
    info "Secure Boot is on: choose a one-time password for MOK enrolment."
    sudo mokutil --import "$der"
    changed "queued akmods key for MOK enrolment"
  fi
  note "Secure Boot: the akmods key must be enrolled at the next boot (MOK screen) or the Nvidia module will not load."
}

# akmod-nvidia pulls kernel-devel for the newest kernel, which drags in only
# its kernel-core + kernel-modules-core. Without kernel-modules (i915,
# iwlwifi) that kernel boots at 800x600 with no wifi, so complete it.
fedora_complete_kernels() {
  local v pkgs extra=0
  rpm -q --quiet kernel-core || return 0
  rpm -q --quiet kernel-modules-extra && extra=1
  while IFS= read -r v; do
    rpm -q --quiet "kernel-modules-$v" && continue
    pkgs=("kernel-$v" "kernel-modules-$v")
    ((extra)) && pkgs+=("kernel-modules-extra-$v")
    sudo dnf install -y "${pkgs[@]}"
    sudo dracut --force --kver "$v"
    changed "completed kernel $v (installed ${pkgs[*]}, rebuilt initramfs)"
    DRIVER_INSTALLED=1
  done < <(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
}

driver_fedora() {
  if rpm -q --quiet akmod-nvidia; then
    ok "akmod-nvidia installed"
  elif is_test; then
    pkg_check_only akmod-nvidia xorg-x11-drv-nvidia-cuda
  else
    fedora_secure_boot_key
    pkg_install akmod-nvidia xorg-x11-drv-nvidia-cuda
    DRIVER_INSTALLED=1
    info "waiting for akmods to build the kernel module (can take ~5 min)"
    local i
    for ((i = 0; i < 40; i++)); do
      modinfo -F version nvidia >/dev/null 2>&1 && break
      sleep 15
    done
    if ! modinfo -F version nvidia >/dev/null 2>&1; then
      info "still not built; running akmods --force"
      sudo akmods --force
    fi
    modinfo -F version nvidia >/dev/null 2>&1 ||
      die "nvidia kernel module did not build; check 'journalctl -u akmods' and /var/cache/akmods"
    ok "nvidia module $(modinfo -F version nvidia) built"
  fi
  is_test || fedora_complete_kernels
  pkg_install xorg-x11-drv-nvidia-libs.i686
  pkg_install switcheroo-control
  svc_enable switcheroo-control
}

driver_ubuntu() {
  if command -v system76-power >/dev/null; then
    # Pop!_OS manages Nvidia and graphics modes with its own tooling.
    if nvidia_driver_working || pkg_installed system76-driver-nvidia; then
      ok "system76-driver-nvidia present"
    elif is_test; then
      pkg_check_only system76-driver-nvidia
    else
      pkg_install system76-driver-nvidia
      DRIVER_INSTALLED=1
    fi
    if is_test; then
      test_skip "system76-power graphics hybrid"
    elif [[ "$(system76-power graphics 2>/dev/null)" == hybrid ]]; then
      ok "graphics mode: hybrid"
    else
      sudo system76-power graphics hybrid
      changed "graphics mode set to hybrid"
      DRIVER_INSTALLED=1
    fi
    return 0
  fi

  pkg_install ubuntu-drivers-common
  if nvidia_driver_working || dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-driver-*' 2>/dev/null | matches '^ii'; then
    ok "Nvidia driver installed"
  elif is_test; then
    test_skip "ubuntu-drivers install (needs the real GPU)"
    pkg_check_only nvidia-prime
  else
    sudo ubuntu-drivers install
    changed "installed the recommended Nvidia driver (ubuntu-drivers)"
    DRIVER_INSTALLED=1
  fi

  local ver
  ver=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-driver-*' 2>/dev/null |
    awk '/^ii/ {print $2}' | grep -oE '[0-9]+' | head -n1 || true)
  [[ -n "$ver" ]] && pkg_install "libnvidia-gl-${ver}:i386"

  if is_test; then
    test_skip "prime-select on-demand"
  elif ! command -v prime-select >/dev/null; then
    warn "prime-select not found; skipping (driver install may have failed)"
  elif [[ "$(prime-select query 2>/dev/null)" == on-demand ]]; then
    ok "prime-select: on-demand"
  else
    sudo prime-select on-demand
    changed "prime-select set to on-demand"
  fi
}

step_driver() {
  step "Nvidia driver (iGPU display, Nvidia on demand)"
  pkg_install pciutils
  [[ $DISTRO == arch ]] || pkg_install mokutil
  if ! is_test && ! nvidia_gpu_present; then
    warn "no Nvidia GPU found by lspci; skipping the driver"
    return 0
  fi
  "driver_$DISTRO"
  secure_boot_hint
  # nvidia-drm.modeset=1 is the default since driver 560 (Arch, RPM Fusion
  # and Ubuntu packages all enable it), so no kernel parameter is added.
}

step_prime_run() {
  step "prime-run"
  local wrapper="$HOME/.local/bin/prime-run" d
  for d in /usr/local/bin /usr/bin /bin; do
    if [[ -x "$d/prime-run" ]]; then
      ok "prime-run provided by the distro: $d/prime-run"
      return 0
    fi
  done
  put_user_file "$wrapper" 0755 <<'EOF'
#!/bin/sh
# Run a program on the Nvidia GPU (PRIME render offload). Installed by ~/dotfiles.
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "$@"
EOF
  [[ $LAST_WRITE_CHANGED == 0 ]] && ok "prime-run wrapper at $wrapper"
  return 0
}

# ------------------------------------------------------------- games --------

arch_vulkan_drivers() {
  # Steam needs vulkan-driver/lib32-vulkan-driver; name the iGPU's providers
  # explicitly so --noconfirm does not pick an arbitrary one.
  local gpus pkgs=(mesa lib32-mesa)
  gpus=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' || true)
  grep -qi intel <<<"$gpus" && pkgs+=(vulkan-intel lib32-vulkan-intel)
  grep -qiE 'amd|ati' <<<"$gpus" && pkgs+=(vulkan-radeon lib32-vulkan-radeon)
  ((${#pkgs[@]} > 2)) || pkgs+=(vulkan-intel lib32-vulkan-intel vulkan-radeon lib32-vulkan-radeon)
  pkg_install "${pkgs[@]}"
}

step_steam() {
  step "Steam (native package)"
  case $DISTRO in
    arch) arch_vulkan_drivers; pkg_install steam ;;
    fedora) pkg_install steam ;;
    ubuntu) pkg_install steam-installer ;;
  esac
}

step_tools() {
  step "GameMode and MangoHud"
  case $DISTRO in
    arch) pkg_install gamemode lib32-gamemode mangohud lib32-mangohud ;;
    fedora) pkg_install gamemode gamemode.i686 mangohud mangohud.i686 ;;
    ubuntu)
      # Ubuntu does not package 32-bit MangoHud; 64-bit games are covered.
      pkg_install gamemode libgamemode0:i386 libgamemodeauto0:i386 mangohud
      ;;
  esac
  add_user_to_group gamemode
}

step_controllers() {
  step "Controller udev rules"
  pkg_install steam-devices
  if [[ $DISTRO == arch ]]; then
    if pkg_installed game-devices-udev; then
      ok "game-devices-udev installed"
    elif command -v paru >/dev/null && ! is_test; then
      paru -S --needed --noconfirm game-devices-udev
      changed "installed game-devices-udev (AUR)"
    else
      info "game-devices-udev is AUR-only; skipped (steam-devices covers Steam-supported pads)"
    fi
  fi
}

main() {
  dotfiles_init gaming
  step_repos
  step_driver
  step_prime_run
  step_steam
  step_tools
  step_controllers
  if [[ $DRIVER_INSTALLED == 1 ]]; then
    note "Reboot required: the Nvidia driver was installed or changed."
  fi
  note "Steam launch option for the RTX 2060: prime-run gamemoderun %command%  (add 'mangohud' before %command% for the overlay)"
  dotfiles_finish
}

main "$@"
