#!/usr/bin/env bash
# Runs as root inside a throwaway container (see tests/containers.sh).
# Expects the repo snapshot (a git repo) mounted read-only at /src.
set -euo pipefail

say() { printf '\n######## %s\n' "$*"; }
fail() { printf '\nTEST FAILURE: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091 # runtime file
. /etc/os-release
say "preparing $PRETTY_NAME"
case " $ID ${ID_LIKE:-} " in
  *" arch "*) pacman -Syu --noconfirm --needed sudo ;;
  *" fedora "*) dnf install -y sudo util-linux ;; # su is not in the image
  *" ubuntu "*)
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q sudo
    ;;
esac

# No systemd in containers. Tailscale's own installer runs
# `systemctl enable --now tailscaled`; give it a no-op found first on PATH.
for d in /usr/local/sbin /usr/local/bin; do
  mkdir -p "$d"
  printf '#!/bin/sh\necho "[container shim] systemctl $*"\n' >"$d/systemctl"
  chmod +x "$d/systemctl"
done

id juji >/dev/null 2>&1 || useradd -m -s /bin/bash juji
printf 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\njuji ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/juji
chmod 440 /etc/sudoers.d/juji
printf '[safe]\n\tdirectory = *\n' >/etc/gitconfig

# A distro-default config that stow must back up, not delete.
su - juji -c 'mkdir -p ~/.config/fish && echo "# distro default" > ~/.config/fish/config.fish'

as_juji() { su - juji -c "$1"; }

say "run 1: piped bootstrap --all"
as_juji 'cat /src/bootstrap.sh | DOTFILES_TEST=1 DOTFILES_REPO_URL=/src bash -s -- --all'

say "run 2: rerun must change nothing"
as_juji 'DOTFILES_TEST=1 bash ~/dotfiles/bootstrap.sh --all' 2>&1 | tee /tmp/run2.log
grep -q 'Changes made this run: 0$' /tmp/run2.log || fail "second run made changes: $(grep -E '^\s+\+' /tmp/run2.log | head -20)"

say "stow links"
# shellcheck disable=SC2016 # expands in the juji shell
as_juji 'cd ~/dotfiles/stow && find . -type f | while read -r f; do
  pkg=${f#./}; pkg=${pkg%%/*}; rel=${f#./$pkg/}
  [ "$(readlink -f ~/"$rel")" = "$(readlink -f "$f")" ] || { echo "NOT LINKED: ~/$rel"; exit 1; }
  echo "linked ~/$rel"
done' || fail "stow links"
as_juji 'test -L ~/.config/fish && exit 1; test -d ~/.config/fish' || fail ".config/fish was folded into a symlink"
as_juji 'ls ~/.dotfiles-backup/*/.config/fish/config.fish && grep -q "distro default" ~/.dotfiles-backup/*/.config/fish/config.fish' ||
  fail "conflicting config.fish was not backed up"

say "fish syntax"
as_juji 'cd ~/dotfiles && find . -name "*.fish" -print -exec fish --no-execute {} \;' || fail "fish --no-execute"

say "theme outputs match palette"
as_juji 'bash ~/dotfiles/theme/render.sh --check' || fail "render.sh --check"

say "tools on fish PATH"
as_juji "fish -c 'for c in git gh fish starship kitty stow tailscale flatpak docker steam gamemoderun mangohud prime-run uv fnm node pnpm code
  if type -q \$c; echo \"ok      \$c\"; else; echo \"MISSING \$c\"; end
end; node --version; pnpm --version; starship --version | head -1'" | tee /tmp/tools.log
case " $ID ${ID_LIKE:-} " in
  *" arch "*) expected_missing='code' ;; # AUR-only without paru
  *) expected_missing='' ;;
esac
missing=$(awk '/^MISSING/ {print $2}' /tmp/tools.log | xargs)
[[ "$missing" == "$expected_missing" ]] || fail "unexpected missing tools: '$missing' (expected '$expected_missing')"

say "flatpaks"
flatpak list --system --app --columns=application | tee /tmp/flatpaks.log
grep -qx app.zen_browser.zen /tmp/flatpaks.log || fail "Zen not installed"
grep -qx md.obsidian.Obsidian /tmp/flatpaks.log || fail "Obsidian not installed"

say "ALL CHECKS PASSED on $PRETTY_NAME"
