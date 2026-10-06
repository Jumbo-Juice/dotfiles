#!/usr/bin/env bash
# Run `bootstrap.sh --all` (DOTFILES_TEST=1) in throwaway containers, twice,
# and check stow links, fish syntax, theme outputs and idempotency.
#   tests/containers.sh                      # arch, fedora, ubuntu in parallel
#   tests/containers.sh ubuntu:24.04         # one image
# Logs land in $LOG_DIR (default: a temp dir, printed at the end).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
images=("$@")
((${#images[@]})) || images=(archlinux:latest fedora:latest ubuntu:24.04)
LOG_DIR=${LOG_DIR:-$(mktemp -d)}
mkdir -p "$LOG_DIR"

# Snapshot the working tree (incl. uncommitted edits) as a git repo, so the
# piped bootstrap can clone it like it clones GitHub.
snap=$(mktemp -d)
git -C "$root" ls-files -co --exclude-standard -z |
  (cd "$root" && tar --null -T - -cf -) | tar -xf - -C "$snap"
git -C "$snap" init -q -b main
git -C "$snap" add -A
git -C "$snap" -c user.name=test -c user.email=test@localhost commit -qm snapshot
mount=$snap
command -v cygpath >/dev/null && mount=$(cygpath -m "$snap")

declare -A pids
for img in "${images[@]}"; do
  log="$LOG_DIR/${img//[:\/]/_}.log"
  # --privileged: flatpak's bubblewrap needs namespaces inside the container.
  # MSYS_NO_PATHCONV: stop Git Bash on Windows rewriting /src paths.
  MSYS_NO_PATHCONV=1 docker run --rm --privileged -v "$mount:/src:ro" "$img" bash /src/tests/in-container.sh >"$log" 2>&1 &
  pids[$img]=$!
  echo "started $img -> $log"
done

fail=0
for img in "${images[@]}"; do
  if wait "${pids[$img]}"; then
    echo "PASS $img"
  else
    echo "FAIL $img (see $LOG_DIR/${img//[:\/]/_}.log)"
    fail=1
  fi
done
rm -rf "$snap"
echo "logs: $LOG_DIR"
exit "$fail"
