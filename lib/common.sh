# shellcheck shell=bash
# Shared helpers for bootstrap.sh and modules/*.sh: logging, distro detection,
# sudo keepalive, idempotent package/file/service helpers. Source, don't run.

[[ -n "${_DOTFILES_COMMON:-}" ]] && return 0
_DOTFILES_COMMON=1

: "${DOTFILES_DIR:=$HOME/dotfiles}"
: "${DOTFILES_TEST:=0}"
DOTFILES_HOSTNAME="Arnold"  # used by bootstrap.sh
export DOTFILES_HOSTNAME
export DOTFILES_DIR DOTFILES_TEST

CURRENT_STEP="startup"
SCRIPT_NAME="dotfiles"
PKG_REFRESHED=0
LAST_WRITE_CHANGED=0

# ---------------------------------------------------------------- logging ---

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_STEP=$'\e[1;38;2;244;181;133m'
  C_OK=$'\e[38;2;126;201;126m' C_INFO=$'\e[38;2;182;182;154m'
  C_WARN=$'\e[38;2;239;191;113m' C_ERR=$'\e[1;38;2;241;110;101m'
  C_CHG=$'\e[38;2;113;180;214m'
else
  C_RESET='' C_BOLD='' C_STEP='' C_OK='' C_INFO='' C_WARN='' C_ERR='' C_CHG=''
fi

step()    { CURRENT_STEP="$*"; printf '\n%s==> [%s] %s%s\n' "$C_STEP" "$SCRIPT_NAME" "$*" "$C_RESET"; }
info()    { printf '  %s%s%s\n' "$C_INFO" "$*" "$C_RESET"; }
ok()      { printf '  %s✓%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn()    { printf '  %s!%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()     { printf '\n%s✗ [%s] %s: %s%s\n' "$C_ERR" "$SCRIPT_NAME" "$CURRENT_STEP" "$*" "$C_RESET" >&2; exit 1; }
test_skip() { printf '  %s~%s [test mode] skipped: %s\n' "$C_WARN" "$C_RESET" "$*"; }

# Record that this run changed the system; the count proves idempotency.
changed() {
  printf '  %s+%s %s\n' "$C_CHG" "$C_RESET" "$*"
  printf '%s\n' "$*" >>"$DOTFILES_RUN_DIR/changes"
}

# Queue a line for the end-of-run summary (manual steps, reboots, ...).
note() { printf '%s\n' "$*" >>"$DOTFILES_RUN_DIR/notes"; }

is_test() { [[ "$DOTFILES_TEST" == 1 ]]; }

# `cmd | matches PATTERN`: like `grep -q`, but reads all input. `grep -q`
# exits at the first match, the writer gets SIGPIPE, and with pipefail a
# successful match is reported as failure.
matches() { grep "$@" >/dev/null; }

on_err() {
  local code=$1 line=$2 src=${3##*/}
  printf '\n%s✗ [%s] step "%s" failed (exit %s at %s:%s)%s\n' \
    "$C_ERR" "$SCRIPT_NAME" "$CURRENT_STEP" "$code" "$src" "$line" "$C_RESET" >&2
  printf '%s  Fix the problem above and rerun; finished steps are skipped.%s\n' "$C_INFO" "$C_RESET" >&2
}

on_exit() {
  if [[ "${DOTFILES_RUN_OWNER:-}" == "$$" ]]; then
    [[ -n "${DOTFILES_SUDO_PID:-}" ]] && kill "$DOTFILES_SUDO_PID" 2>/dev/null
    rm -rf "$DOTFILES_RUN_DIR"
  fi
  return 0
}

# ------------------------------------------------------------------ init ----

# dotfiles_init <name>: call once at the top of every entry script.
dotfiles_init() {
  SCRIPT_NAME=$1
  set -E
  trap 'on_err $? $LINENO "${BASH_SOURCE[0]}"' ERR
  trap on_exit EXIT
  trap 'exit 130' INT TERM

  [[ $EUID -ne 0 ]] || die "run as your normal user, not root; sudo is used where needed"

  if [[ -z "${DOTFILES_RUN_DIR:-}" || ! -d "${DOTFILES_RUN_DIR:-}" ]]; then
    DOTFILES_RUN_DIR=$(mktemp -d)
    DOTFILES_RUN_OWNER=$$
    : >"$DOTFILES_RUN_DIR/changes"
    : >"$DOTFILES_RUN_DIR/notes"
    export DOTFILES_RUN_DIR DOTFILES_RUN_OWNER
  fi

  detect_distro
  sudo_init
  is_test && info "DOTFILES_TEST=1: skipping hardware/browser steps"
  return 0
}

# Print notes and change count, only from the top-level script.
dotfiles_finish() {
  [[ "${DOTFILES_RUN_OWNER:-}" == "$$" ]] || return 0
  step "Summary"
  if [[ -s "$DOTFILES_RUN_DIR/notes" ]]; then
    while IFS= read -r line; do printf '  %s•%s %s\n' "$C_WARN" "$C_RESET" "$line"; done <"$DOTFILES_RUN_DIR/notes"
  fi
  printf '\n  %sChanges made this run: %s%s\n' "$C_BOLD" "$(wc -l <"$DOTFILES_RUN_DIR/changes" | tr -d ' ')" "$C_RESET"
}

# ---------------------------------------------------------------- distro ----

# Sets DISTRO (arch|fedora|ubuntu), OS_ID, OS_PRETTY, UBUNTU_CODENAME.
# shellcheck disable=SC1091 # /etc/os-release exists only at runtime
detect_distro() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot detect the distro"
  local id like
  id=$(. /etc/os-release && printf '%s' "${ID:-}")
  like=$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")
  OS_ID=$id
  OS_PRETTY=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$id}")
  UBUNTU_CODENAME=$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-}")

  case " $id $like " in
    *" arch "*) DISTRO=arch ;;
    *" rhel "* | *" centos "*) DISTRO="" ;;  # RHEL clones list fedora in ID_LIKE
    *" fedora "*) DISTRO=fedora ;;
    *" ubuntu "*) DISTRO=ubuntu ;;
    *) DISTRO="" ;;
  esac
  [[ -n "$DISTRO" ]] || die "unsupported distro '$OS_PRETTY' (ID=$id ID_LIKE=$like). Supported: Arch-based, Fedora, Ubuntu and derivatives."
  if [[ $DISTRO == ubuntu && -z "$UBUNTU_CODENAME" ]]; then
    die "Ubuntu-family distro without UBUNTU_CODENAME in /etc/os-release"
  fi
  export DISTRO OS_ID UBUNTU_CODENAME
}

# ------------------------------------------------------------------ sudo ----

# One password prompt per run; a background loop keeps the timestamp fresh
# until the top-level script exits. Child modules reuse the parent's loop.
sudo_init() {
  command -v sudo >/dev/null || die "sudo is not installed; install it and add $USER to the admin group"
  if [[ -n "${DOTFILES_SUDO_PID:-}" ]] && kill -0 "$DOTFILES_SUDO_PID" 2>/dev/null; then
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    info "sudo password needed once for this run:"
  fi
  sudo -v || die "could not get sudo rights"
  local parent=$$
  (
    trap - ERR EXIT
    while kill -0 "$parent" 2>/dev/null; do
      sudo -n -v 2>/dev/null || true
      sleep 30
    done
  ) >/dev/null 2>&1 &
  DOTFILES_SUDO_PID=$!
  export DOTFILES_SUDO_PID
}

# --------------------------------------------------------------- download ---

fetch() {
  if command -v curl >/dev/null; then
    curl -fsSL --retry 3 "$1"
  elif command -v wget >/dev/null; then
    wget -qO- "$1"
  else
    die "neither curl nor wget is available to download $1"
  fi
}

# -------------------------------------------------------------- packages ----

pkg_installed() {
  case $DISTRO in
    arch) pacman -T "$1" >/dev/null 2>&1 ;;
    fedora) rpm -q --quiet "$1" 2>/dev/null || rpm -q --quiet --whatprovides "$1" 2>/dev/null ;;
    ubuntu) [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]] ;;
  esac
}

# pkg_refresh [force]: sync package databases once per process.
pkg_refresh() {
  [[ $PKG_REFRESHED == 1 && "${1:-}" != force ]] && return 0
  case $DISTRO in
    arch) sudo pacman -Syu --noconfirm ;;  # never -Sy alone: partial upgrades break Arch
    fedora) sudo dnf makecache -q ;;
    ubuntu) sudo "${APT_ENV[@]}" apt-get update -q ;;
  esac
  PKG_REFRESHED=1
}

# Debconf questions need a terminal; without one (tests) take defaults.
APT_ENV=(env)
[[ -t 0 ]] || APT_ENV=(env DEBIAN_FRONTEND=noninteractive)

# pkg_install pkg...: installs only what is missing, so reruns change nothing.
pkg_install() {
  local p missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  if ((${#missing[@]} == 0)); then
    ok "installed: $*"
    return 0
  fi
  info "installing: ${missing[*]}"
  pkg_refresh
  case $DISTRO in
    arch) sudo pacman -S --needed --noconfirm "${missing[@]}" ;;
    fedora) sudo dnf install -y "${missing[@]}" ;;
    ubuntu) sudo "${APT_ENV[@]}" apt-get install -y "${missing[@]}" ;;
  esac
  changed "installed ${missing[*]}"
}

# pkg_available pkg: true if the package can be installed from enabled repos.
pkg_available() {
  case $DISTRO in
    arch) pacman -Si "$1" >/dev/null 2>&1 || pacman -Sg "$1" >/dev/null 2>&1 ;;
    fedora) dnf -q repoquery --available "$1" 2>/dev/null | matches . ;;
    ubuntu) apt-cache policy "$1" 2>/dev/null | matches 'Candidate: [^(]' ;;
  esac
}

# pkg_check_only pkg...: test mode stand-in for installs that need hardware.
pkg_check_only() {
  local p
  pkg_refresh
  for p in "$@"; do
    pkg_available "$p" || die "package '$p' not found in the enabled repositories"
  done
  ok "resolvable (not installed in test mode): $*"
}

# ------------------------------------------------------------ files etc. ----

# shellcheck disable=SC2034 # LAST_WRITE_CHANGED is read by callers
# put_root_file <dest> [mode] < content: write a system file only if it differs.
put_root_file() {
  local dest=$1 mode=${2:-0644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if sudo test -f "$dest" && sudo cmp -s "$tmp" "$dest"; then
    LAST_WRITE_CHANGED=0
  else
    sudo install -D -m "$mode" "$tmp" "$dest"
    changed "wrote $dest"
    LAST_WRITE_CHANGED=1
  fi
  rm -f "$tmp"
}

# shellcheck disable=SC2034 # LAST_WRITE_CHANGED is read by callers
# put_user_file <dest> [mode] < content
put_user_file() {
  local dest=$1 mode=${2:-0644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    LAST_WRITE_CHANGED=0
  else
    install -D -m "$mode" "$tmp" "$dest"
    changed "wrote $dest"
    LAST_WRITE_CHANGED=1
  fi
  rm -f "$tmp"
}

# svc_enable <unit>: enable + start, skipped in test mode (no systemd in containers).
svc_enable() {
  if is_test; then
    test_skip "systemctl enable --now $1"
    return 0
  fi
  if systemctl is-enabled -q "$1" 2>/dev/null && systemctl is-active -q "$1" 2>/dev/null; then
    ok "$1 enabled and running"
  else
    sudo systemctl enable --now "$1"
    changed "enabled $1"
  fi
}

# add_user_to_group <group>
add_user_to_group() {
  getent group "$1" >/dev/null || return 0
  if id -nG "$USER" | tr ' ' '\n' | matches -x "$1"; then
    ok "$USER is in group $1"
  else
    sudo usermod -aG "$1" "$USER"
    changed "added $USER to group $1"
    note "Log out and back in (or reboot) so membership of group '$1' applies."
  fi
}

# Secure Boot state; mokutil is installed by callers that care.
secure_boot_enabled() {
  command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | matches -i 'SecureBoot enabled'
}

# ---------------------------------------------------------------- flatpak ---

flathub_setup() {
  pkg_install flatpak
  if flatpak remotes --system --columns=name 2>/dev/null | matches -x flathub; then
    if flatpak remotes --system --show-disabled --columns=name,options 2>/dev/null | grep -E '^flathub\s' | matches disabled; then
      sudo flatpak remote-modify --system --enable flathub
      changed "enabled the flathub remote"
    else
      ok "flathub remote configured"
    fi
  else
    sudo flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    changed "added the flathub remote"
  fi
}

flatpak_install() {
  if flatpak info --system "$1" >/dev/null 2>&1; then
    ok "flatpak $1 installed"
  else
    sudo flatpak install --system -y --noninteractive flathub "$1"
    changed "installed flatpak $1"
  fi
}
