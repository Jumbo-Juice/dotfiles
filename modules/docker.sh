#!/usr/bin/env bash
# Docker Engine + compose + buildx. Arch: distro packages. Fedora/Ubuntu
# family: Docker's official docker-ce repos. Run alone or via bootstrap --docker.
set -Eeuo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/common.sh
. "$DOTFILES_DIR/lib/common.sh"

DOCKER_CE_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

repo_fedora() {
  # Write the .repo file directly: works the same with dnf4 and dnf5.
  local repo
  repo=$(fetch https://download.docker.com/linux/fedora/docker-ce.repo)
  put_root_file /etc/yum.repos.d/docker-ce.repo <<<"$repo"
  [[ $LAST_WRITE_CHANGED == 0 ]] && ok "docker-ce repo configured"
  return 0
}

repo_ubuntu() {
  local key=/etc/apt/keyrings/docker.asc
  pkg_install ca-certificates curl
  if ! sudo test -s "$key"; then
    sudo install -d -m 0755 /etc/apt/keyrings
    fetch https://download.docker.com/linux/ubuntu/gpg | sudo tee "$key" >/dev/null
    sudo chmod a+r "$key"
    changed "added Docker apt key"
  fi
  # UBUNTU_CODENAME, not VERSION_CODENAME: Mint/Pop report their own codename.
  put_root_file /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: ${key}
EOF
  if [[ $LAST_WRITE_CHANGED == 1 ]]; then
    pkg_refresh force
  else
    ok "docker apt repo configured ($UBUNTU_CODENAME)"
  fi
}

main() {
  dotfiles_init docker

  step "Docker packages"
  case $DISTRO in
    arch) pkg_install docker docker-compose docker-buildx ;;
    fedora) repo_fedora; pkg_install "${DOCKER_CE_PKGS[@]}" ;;
    ubuntu) repo_ubuntu; pkg_install "${DOCKER_CE_PKGS[@]}" ;;
  esac

  step "Docker service and group"
  svc_enable docker.service
  add_user_to_group docker

  dotfiles_finish
}

main "$@"
