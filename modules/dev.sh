#!/usr/bin/env bash
# Dev tools: VS Code, uv, Node LTS via fnm, pnpm, Obsidian.
# Run alone or via bootstrap --dev.
set -Eeuo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/common.sh
. "$DOTFILES_DIR/lib/common.sh"

BIN="$HOME/.local/bin"
FNM_DIR="$HOME/.local/share/fnm"
export PNPM_HOME="$HOME/.local/share/pnpm"

vscode_arch() {
  if command -v code >/dev/null; then
    ok "VS Code installed"
  elif command -v paru >/dev/null && ! is_test; then
    paru -S --needed --noconfirm visual-studio-code-bin
    changed "installed visual-studio-code-bin (AUR via paru)"
  else
    warn "VS Code skipped: visual-studio-code-bin is in the AUR and paru is not installed."
    note "VS Code not installed (no paru). Install paru, then: paru -S visual-studio-code-bin"
  fi
}

vscode_fedora() {
  if ! rpm -q gpg-pubkey --qf '%{SUMMARY}\n' 2>/dev/null | matches -i microsoft; then
    local asc
    asc=$(mktemp)
    fetch https://packages.microsoft.com/keys/microsoft.asc >"$asc"  # fetch retries; rpm's own download doesn't
    sudo rpm --import "$asc"
    rm -f "$asc"
    changed "imported Microsoft RPM key"
  fi
  put_root_file /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  pkg_install code
}

vscode_ubuntu() {
  local key=/usr/share/keyrings/microsoft.gpg
  pkg_install gnupg
  if ! sudo test -s "$key"; then
    fetch https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee "$key" >/dev/null
    sudo chmod a+r "$key"
    changed "added Microsoft apt key"
  fi
  put_root_file /etc/apt/sources.list.d/vscode.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: ${key}
EOF
  [[ $LAST_WRITE_CHANGED == 1 ]] && pkg_refresh force
  # We manage the repo above; stop the package adding a duplicate one.
  if ! sudo debconf-show code 2>/dev/null | matches 'add-microsoft-repo: false'; then
    echo "code code/add-microsoft-repo boolean false" | sudo debconf-set-selections
  fi
  pkg_install code
}

step_uv() {
  step "uv"
  if [[ -x "$BIN/uv" ]]; then
    ok "uv $("$BIN/uv" --version | awk '{print $2}')"
  else
    fetch https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$BIN" UV_NO_MODIFY_PATH=1 sh
    changed "installed uv"
  fi
}

step_node() {
  step "Node LTS (fnm) and pnpm"
  pkg_install unzip openssl  # openssl: lets the pnpm installer verify npm signatures
  if [[ -x "$FNM_DIR/fnm" ]]; then
    ok "fnm installed"
  else
    # --skip-shell: fish integration lives in the stowed config.fish.
    fetch https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell
    changed "installed fnm"
  fi
  local fnm="$FNM_DIR/fnm"
  export FNM_DIR
  if "$fnm" list 2>/dev/null | matches 'lts-latest'; then
    ok "Node LTS installed ($("$fnm" list | grep lts-latest | awk '{print $2}'))"
  else
    "$fnm" install --lts
    changed "installed Node LTS"
  fi
  if "$fnm" list 2>/dev/null | grep 'lts-latest' | matches default; then
    ok "Node LTS is the fnm default"
  else
    "$fnm" default lts-latest
    changed "set Node LTS as default"
  fi

  if [[ -x "$PNPM_HOME/bin/pnpm" ]]; then
    ok "pnpm installed"
  else
    # Standalone pnpm: Node 25+ no longer bundles corepack. SHELL=bash keeps
    # `pnpm setup` out of the stowed config.fish (PNPM_HOME is set there).
    fetch https://get.pnpm.io/install.sh | env SHELL=/bin/bash PNPM_HOME="$PNPM_HOME" sh -
    changed "installed pnpm"
  fi
}

main() {
  dotfiles_init dev

  step "VS Code"
  "vscode_$DISTRO"

  step_uv
  step_node

  step "Obsidian (Flatpak)"
  flathub_setup
  flatpak_install md.obsidian.Obsidian

  dotfiles_finish
}

main "$@"
