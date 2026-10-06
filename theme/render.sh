#!/usr/bin/env bash
# Render theme/templates/* into stow/ using theme/palette.sh.
#   theme/render.sh          write the outputs (commit them)
#   theme/render.sh --check  exit 1 if committed outputs differ from the palette
# Placeholders: {{name}} -> #rrggbb, {{name:hex}} -> rrggbb (MangoHud, fish).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
# shellcheck source=palette.sh
. "$here/palette.sh"

# template (in theme/templates) : output (relative to repo root)
TARGETS=(
  "kitty-theme.conf:stow/kitty/.config/kitty/theme.conf"
  "fish-theme.fish:stow/fish/.config/fish/conf.d/theme.fish"
  "starship.toml:stow/starship/.config/starship.toml"
  "MangoHud.conf:stow/mangohud/.config/MangoHud/MangoHud.conf"
)

sed_args=()
for name in "${PALETTE[@]}"; do
  value=${!name}
  [[ "$value" =~ ^#[0-9a-fA-F]{6}$ ]] || { echo "palette.sh: $name='$value' is not #rrggbb" >&2; exit 1; }
  sed_args+=(-e "s/{{${name}}}/${value}/g" -e "s/{{${name}:hex}}/${value#\#}/g")
done

check=0
[[ "${1:-}" == --check ]] && check=1
status=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for t in "${TARGETS[@]}"; do
  src="$here/templates/${t%%:*}"
  out="$root/${t#*:}"
  sed "${sed_args[@]}" "$src" >"$tmp"
  if grep -n '{{[^}]*}}' "$tmp" >&2; then
    echo "render.sh: unknown placeholder in ${src#"$root"/}" >&2
    exit 1
  fi
  if ((check)); then
    if ! cmp -s "$tmp" "$out"; then
      echo "out of date: ${out#"$root"/} (run theme/render.sh)" >&2
      status=1
    fi
  else
    mkdir -p "$(dirname "$out")"
    cp "$tmp" "$out"
    echo "rendered ${out#"$root"/}"
  fi
done
((check && status == 0)) && echo "theme outputs match palette.sh"
exit "$status"
