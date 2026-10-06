#!/usr/bin/env bash
# Core setup for Arnold. Run from a fresh install with:
#   curl -fsSL https://raw.githubusercontent.com/Jumbo-Juice/dotfiles/main/bootstrap.sh | bash
#   ... | bash -s -- --all            # chain modules: --gaming --docker --dev --all
# Safe to rerun: every step checks before it changes anything.
# DOTFILES_TEST=1 skips steps that need real hardware or a browser.
set -Eeuo pipefail

REPO_SLUG="Jumbo-Juice/dotfiles"
REPO_HTTPS="https://github.com/${REPO_SLUG}.git"
REPO_SSH="git@github.com:${REPO_SLUG}.git"
TAILSCALE_HOSTNAME="arnold"
STARSHIP_VERSION="v1.26.0"
NERD_FONTS_VERSION="v3.5.1"

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--gaming] [--docker] [--dev] [--all]

Core setup (hostname, Tailscale, git/gh, fish, starship, kitty, font,
Flatpak/Zen, stow) always runs; flags chain the matching modules/ after it.
EOF
}

# --------------------------------------------------------- piped entry ------
# `curl ... | bash` feeds the script on stdin, so prompts (sudo, gh) cannot
# read the keyboard. Get git, clone the repo, then re-exec from disk with the
# terminal as stdin.
piped_entry() {
  local dir="${DOTFILES_DIR:-$HOME/dotfiles}" url="${DOTFILES_REPO_URL:-$REPO_HTTPS}"
  printf '\n==> [bootstrap] fetching %s into %s\n' "$REPO_SLUG" "$dir"

  if ! command -v git >/dev/null; then
    printf '  installing git (sudo password may be asked)\n'
    if command -v pacman >/dev/null; then
      sudo pacman -Syu --needed --noconfirm git
    elif command -v dnf >/dev/null; then
      sudo dnf install -y git
    elif command -v apt-get >/dev/null; then
      sudo apt-get update -q && sudo apt-get install -y git ca-certificates
    else
      printf 'Unsupported distro: no pacman, dnf or apt-get found.\n' >&2
      exit 1
    fi
  fi

  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" pull --ff-only "$url" main ||
      printf '  ! could not fast-forward %s; using the local copy as is\n' "$dir" >&2
  elif [[ -e "$dir" ]]; then
    printf '%s exists but is not a git checkout; move it away and rerun.\n' "$dir" >&2
    exit 1
  else
    git clone "$url" "$dir"
  fi

  if { : </dev/tty; } 2>/dev/null; then
    exec bash "$dir/bootstrap.sh" "$@" </dev/tty
  fi
  exec bash "$dir/bootstrap.sh" "$@"
}

# ----------------------------------------------------------------- steps ----

step_hostname() {
  step "1. Hostname"
  if is_test; then test_skip "hostnamectl set-hostname $DOTFILES_HOSTNAME"; return 0; fi
  if [[ "$(hostnamectl --static 2>/dev/null)" == "$DOTFILES_HOSTNAME" ]]; then
    ok "hostname is $DOTFILES_HOSTNAME"
  else
    sudo hostnamectl set-hostname "$DOTFILES_HOSTNAME"
    changed "hostname set to $DOTFILES_HOSTNAME"
  fi
}

step_tailscale() {
  step "2. Tailscale"
  case $DISTRO in
    ubuntu) pkg_install curl ca-certificates ;;
    *) pkg_install curl ;;
  esac
  if command -v tailscale >/dev/null; then
    ok "tailscale installed"
  else
    fetch https://tailscale.com/install.sh | sh
    changed "installed tailscale (official script)"
  fi
  svc_enable tailscaled

  if is_test; then test_skip "tailscale up --ssh --hostname=$TAILSCALE_HOSTNAME"; return 0; fi
  if sudo tailscale status --json 2>/dev/null | matches -E '"BackendState":[[:space:]]*"Running"'; then
    ok "tailscale already connected"
    return 0
  fi

  # `tailscale up` blocks until login; run it in the background so the URL
  # can be shown prominently, then wait for it.
  local log url="" pid i
  log=$(mktemp)
  # shellcheck disable=SC2024 # the log is ours; only tailscale needs root
  sudo tailscale up --reset --ssh --hostname="$TAILSCALE_HOSTNAME" >"$log" 2>&1 &
  pid=$!
  for ((i = 0; i < 60; i++)); do
    url=$(grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' "$log" | head -n1 || true)
    [[ -n "$url" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if [[ -n "$url" ]]; then
    printf '\n  %s┌──────────────────────────────────────────────────────────────┐%s\n' "$C_STEP" "$C_RESET"
    printf '  %s│ Log in to Tailscale (any device):%s\n' "$C_STEP" "$C_RESET"
    printf '  %s│%s   %s%s%s\n' "$C_STEP" "$C_RESET" "$C_BOLD" "$url" "$C_RESET"
    printf '  %s└──────────────────────────────────────────────────────────────┘%s\n' "$C_STEP" "$C_RESET"
    info "waiting for the login to finish..."
  fi
  if ! wait "$pid"; then
    cat "$log" >&2
    rm -f "$log"
    die "tailscale up failed"
  fi
  rm -f "$log"
  changed "tailscale connected as $TAILSCALE_HOSTNAME"
  note "Tailscale: if the old 'arnold' node still exists, delete it in the admin console and rename this one to 'arnold' (https://login.tailscale.com/admin/machines)."
  note "Remote access now works: ssh $USER@$TAILSCALE_HOSTNAME"
}

install_gh_ubuntu() {
  local keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
  if ! sudo test -s "$keyring"; then
    sudo install -d -m 0755 /etc/apt/keyrings
    fetch https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee "$keyring" >/dev/null
    sudo chmod go+r "$keyring"
    changed "added GitHub CLI apt key"
  fi
  put_root_file /etc/apt/sources.list.d/github-cli.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main
EOF
  [[ $LAST_WRITE_CHANGED == 1 ]] && pkg_refresh force
  # An older distro gh may already be installed; upgrade it from the new repo.
  local installed candidate
  installed=$(dpkg-query -W -f='${Version}' gh 2>/dev/null || true)
  candidate=$(apt-cache policy gh | awk '/Candidate:/ {print $2}')
  if [[ -n "$installed" && "$installed" != "$candidate" ]]; then
    sudo "${APT_ENV[@]}" apt-get install -y gh
    changed "upgraded gh to $candidate"
  else
    pkg_install gh
  fi
}

# Pin GitHub's SSH host keys from its API (over HTTPS) instead of trusting
# whatever answers the first ssh connection.
pin_github_host_keys() {
  local kh="$HOME/.ssh/known_hosts" keys
  if [[ -f "$kh" ]] && ssh-keygen -F github.com -f "$kh" >/dev/null 2>&1; then
    ok "github.com host keys known"
    return 0
  fi
  keys=$(fetch https://api.github.com/meta | grep -oE '"(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+"' | tr -d '"')
  [[ -n "$keys" ]] || die "could not read GitHub's SSH host keys from api.github.com/meta"
  local k
  while IFS= read -r k; do printf 'github.com %s\n' "$k"; done <<<"$keys" >>"$kh"
  chmod 600 "$kh"
  changed "pinned github.com SSH host keys"
}

step_git_gh() {
  step "3. git, gh and SSH key"
  case $DISTRO in
    arch) pkg_install git openssh tar unzip xz github-cli ;;
    fedora) pkg_install git openssh-clients tar unzip xz gh ;;
    ubuntu) pkg_install git openssh-client tar unzip xz-utils gnupg; install_gh_ubuntu ;;
  esac

  install -d -m 700 "$HOME/.ssh"
  local key="$HOME/.ssh/id_ed25519"
  if [[ -f "$key" ]]; then
    ok "SSH key exists: $key"
  elif is_test; then
    ssh-keygen -q -t ed25519 -C "${USER}@${DOTFILES_HOSTNAME}" -N "" -f "$key"
    changed "generated $key (no passphrase, test mode)"
  else
    # ssh-keygen asks twice and re-asks by itself until both entries match.
    info "Choose a passphrase for the new SSH key (typing is hidden)."
    ssh-keygen -q -t ed25519 -C "${USER}@${DOTFILES_HOSTNAME}" -f "$key"
    changed "generated $key"
  fi
  pin_github_host_keys

  if is_test; then
    test_skip "gh auth login (browser) and SSH key upload"
  else
    if gh auth status --hostname github.com >/dev/null 2>&1; then
      if gh auth status --hostname github.com 2>&1 | matches 'admin:public_key'; then
        ok "gh logged in"
      else
        info "gh token lacks admin:public_key; refreshing (browser)"
        gh auth refresh --hostname github.com --scopes admin:public_key
        changed "refreshed gh token scopes"
      fi
    else
      info "GitHub login: a one-time code and URL follow; open the URL in any browser."
      gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key --scopes admin:public_key
      changed "logged in to GitHub with gh"
    fi

    local pub title
    pub=$(awk '{print $2}' "$key.pub")
    if gh api user/keys --paginate --jq '.[].key' | matches -F "$pub"; then
      ok "SSH key already on GitHub"
    else
      title="${DOTFILES_HOSTNAME}-${OS_ID}-$(date +%F)"
      gh ssh-key add "$key.pub" --title "$title"
      changed "uploaded SSH key to GitHub as $title"
    fi
  fi

  if [[ "$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null)" == "$REPO_SSH" ]]; then
    ok "dotfiles remote uses SSH"
  else
    git -C "$DOTFILES_DIR" remote set-url origin "$REPO_SSH"
    changed "switched dotfiles remote to $REPO_SSH"
  fi
}

step_fish() {
  step "4. fish"
  if [[ $DISTRO == ubuntu ]]; then
    local candidate
    pkg_refresh
    candidate=$(apt-cache policy fish | awk '/Candidate:/ {print $2}')
    if [[ "${candidate%%.*}" =~ ^[0-9]+$ ]] && ((${candidate%%.*} < 3)); then
      info "distro fish $candidate is older than 3.x; adding ppa:fish-shell/release-4"
      pkg_install software-properties-common
      sudo add-apt-repository -y ppa:fish-shell/release-4
      changed "added ppa:fish-shell/release-4"
      pkg_refresh force
    fi
  fi
  pkg_install fish
  [[ $DISTRO == fedora ]] && pkg_install util-linux  # provides chsh

  local fish_path
  fish_path=$(command -v fish)
  if grep -qxF "$fish_path" /etc/shells; then
    ok "$fish_path listed in /etc/shells"
  else
    printf '%s\n' "$fish_path" | sudo tee -a /etc/shells >/dev/null
    changed "added $fish_path to /etc/shells"
  fi

  if is_test; then test_skip "chsh -s $fish_path $USER"; return 0; fi
  if [[ "$(getent passwd "$USER" | cut -d: -f7)" == "$fish_path" ]]; then
    ok "login shell is fish"
  else
    sudo chsh -s "$fish_path" "$USER"
    changed "login shell set to fish"
    note "Login shell is now fish; it takes effect at your next login."
  fi
}

step_terminal() {
  step "5. starship, kitty, JetBrains Mono Nerd Font"
  local bin="$HOME/.local/bin" have=""
  mkdir -p "$bin"
  [[ -x "$bin/starship" ]] && have=$("$bin/starship" --version | awk 'NR==1 {print $2}')
  if [[ "v$have" == "$STARSHIP_VERSION" ]]; then
    ok "starship $have"
  else
    fetch https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$bin" --version "$STARSHIP_VERSION"
    changed "installed starship $STARSHIP_VERSION to $bin"
  fi

  pkg_install kitty fontconfig

  local fontdir="$HOME/.local/share/fonts/JetBrainsMonoNerdFont" tmp
  if [[ "$(cat "$fontdir/.version" 2>/dev/null)" == "$NERD_FONTS_VERSION" ]]; then
    ok "JetBrains Mono Nerd Font $NERD_FONTS_VERSION"
  else
    tmp=$(mktemp -d)
    fetch "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/JetBrainsMono.tar.xz" >"$tmp/font.tar.xz"
    rm -rf "$fontdir"
    mkdir -p "$fontdir"
    tar -xJf "$tmp/font.tar.xz" -C "$fontdir" --wildcards '*.ttf'
    printf '%s\n' "$NERD_FONTS_VERSION" >"$fontdir/.version"
    rm -rf "$tmp"
    fc-cache -f "$fontdir" >/dev/null
    changed "installed JetBrains Mono Nerd Font $NERD_FONTS_VERSION"
  fi
}

step_flatpak() {
  step "6. Flatpak, Flathub, Zen"
  flathub_setup
  flatpak_install app.zen_browser.zen
}

# Move real files that would block a stow link into the backup dir.
backup_conflicts() {
  local pkgdir=$1 f rel target backup_root=$2
  while IFS= read -r -d '' f; do
    rel=${f#"$pkgdir/"}
    target="$HOME/$rel"
    if [[ -L "$target" ]]; then
      [[ "$(readlink -f "$target")" == "$(readlink -f "$f")" ]] && continue
    elif [[ ! -e "$target" ]]; then
      continue
    fi
    mkdir -p "$backup_root/$(dirname "$rel")"
    mv "$target" "$backup_root/$rel"
    changed "backed up ~/$rel to $backup_root/"
  done < <(find "$pkgdir" \( -type f -o -type l \) -print0)
}

step_stow() {
  step "7. stow dotfiles"
  pkg_install stow
  local stowdir="$DOTFILES_DIR/stow" pkgs=() p backup_root
  backup_root="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
  for p in "$stowdir"/*/; do pkgs+=("$(basename "$p")"); done
  for p in "${pkgs[@]}"; do backup_conflicts "$stowdir/$p" "$backup_root"; done
  [[ -d "$backup_root" ]] && note "Replaced configs were moved to $backup_root (nothing deleted)."

  # --no-folding links files, not directories, so apps writing next to
  # their config (fish_variables, ...) never write into the repo.
  local plan
  plan=$(stow --dir="$stowdir" --target="$HOME" --no-folding --no --verbose=1 "${pkgs[@]}" 2>&1)
  if grep -q 'LINK' <<<"$plan"; then
    stow --dir="$stowdir" --target="$HOME" --no-folding "${pkgs[@]}"
    changed "stowed ${pkgs[*]}"
  else
    ok "stowed: ${pkgs[*]}"
  fi
}

print_manual_steps() {
  step "8. Manual steps left (details in ~/dotfiles/README.md)"
  cat <<EOF
  1. Tailscale: delete the old 'arnold' machine in the admin console so this
     one is 'arnold', not 'arnold-1'.
  2. Tailscale SSH: the default policy may use "check" mode (browser re-auth);
     README shows the ACL to switch to "accept".
  3. GitHub: done in the browser during step 3 (rerun if it was skipped).
  4. Secure Boot MOK enrolment on the next reboot, if a module asked for it.
  5. Zen: sign in to Zen Sync, then import ~/dotfiles/browser/zen-stylus.css into Stylus.
  6. Steam launch option for the Nvidia GPU: prime-run gamemoderun %command%
EOF
}

main() {
  local wanted=" " modules=() m arg
  for arg in "$@"; do
    case $arg in
      --gaming | --docker | --dev) wanted+="${arg#--} " ;;
      --all) wanted+="gaming docker dev " ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  for m in gaming docker dev; do
    [[ "$wanted" == *" $m "* ]] && modules+=("$m")
  done

  if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
    piped_entry "$@"
  fi

  DOTFILES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  export DOTFILES_DIR
  # shellcheck source=lib/common.sh
  . "$DOTFILES_DIR/lib/common.sh"
  dotfiles_init bootstrap
  info "$OS_PRETTY detected (family: $DISTRO)"

  step_hostname
  step_tailscale
  step_git_gh
  step_fish
  step_terminal
  step_flatpak
  step_stow

  for m in "${modules[@]}"; do
    step "Module: $m"
    bash "$DOTFILES_DIR/modules/$m.sh"
  done

  print_manual_steps
  dotfiles_finish
}

# Everything runs from main so a truncated download never executes half a script.
main "$@"
