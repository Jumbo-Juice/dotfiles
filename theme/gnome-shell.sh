#!/usr/bin/env bash
# Build the "zen-square" GNOME Shell theme from the installed shell's own
# stylesheet: every radius and box-shadow removed, hard-coded greys and
# accents swapped for theme/palette.sh. Output goes to ~/.local/share/themes
# and is not committed (it is ~180 KB and tracks the shell version).
#   theme/gnome-shell.sh            (re)generate after palette or shell updates
# One-time: sudo dnf install gnome-shell-extension-user-theme, enable
# "User Themes", then:  gsettings set org.gnome.shell.extensions.user-theme name zen-square
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=palette.sh
. "$here/palette.sh"

name=zen-square
dest="${XDG_DATA_HOME:-$HOME/.local/share}/themes/$name/gnome-shell"
mkdir -p "$dest"

export black gray0 gray1 gray2 gray3 gray4 gray7 gray8 gray10 white red6 orange6 yellow
python3 - "$dest/gnome-shell.css" <<'PY'
import os, re, sys
from gi.repository import Gio

res = Gio.Resource.load("/usr/share/gnome-shell/gnome-shell-theme.gresource")
css = res.lookup_data("/org/gnome/shell/theme/gnome-shell-dark.css", 0).get_data().decode()
p = {k: os.environ[k] for k in
     "gray0 gray1 gray2 gray3 gray7 gray8 gray10 white red6 orange6 yellow".split()}

def rgb(hexcol):
    return ", ".join(str(int(hexcol[i:i + 2], 16)) for i in (1, 3, 5))

# Square and flat. Keep any trailing !important.
css = re.sub(r"(border(?:-[a-z]+){0,2}-radius):[^;]+?(\s*!important)?\s*;",
             lambda m: f"{m.group(1)}: 0{m.group(2) or ''};", css)
css = re.sub(r"(?<![-\w])box-shadow:[^;]+?(\s*!important)?\s*;",
             lambda m: f"box-shadow: none{m.group(1) or ''};", css)

# Surfaces, darkest first.
hexmap = {
    "#222226": p["gray0"], "#2e2e33": p["gray1"], "#36363a": p["gray2"],
    "#38383b": p["gray2"], "#333333": p["gray2"],
    "#4a4a4f": p["gray3"], "#47474c": p["gray3"], "#4d4d4d": p["gray3"],
    "#424247": p["gray3"], "#48484c": p["gray3"], "#414146": p["gray3"],
    "#56565c": p["gray3"],
    "#9b9b9d": p["gray7"], "#b2b2b4": p["gray8"],
    "#fafafb": p["gray10"], "#ffffff": p["white"],
    "#cd9309": p["yellow"], "#c01c28": p["red6"], "#d61f2d": p["red6"],
    "#ff7800": p["orange6"],
}
css = re.sub(r"#[0-9a-fA-F]{6}\b", lambda m: hexmap.get(m.group(0).lower(), m.group(0)), css)
rgbmap = {"255, 255, 255": rgb(p["white"]), "250, 250, 251": rgb(p["gray10"]),
          "56, 56, 59": rgb(p["gray2"]), "54, 54, 58": rgb(p["gray2"]),
          "46, 46, 51": rgb(p["gray1"]), "205, 147, 9": rgb(p["yellow"])}
css = re.sub(r"rgba\((\d+, \d+, \d+),", lambda m: f"rgba({rgbmap.get(m.group(1), m.group(1))},", css)

css = css.replace("DO NOT EDIT */", "DO NOT EDIT */\n/* Modified by dotfiles/theme/gnome-shell.sh. */", 1)
open(sys.argv[1], "w").write(css)
PY
echo "wrote $dest/gnome-shell.css"
