# fish config (stowed from ~/dotfiles). Colours: conf.d/theme.fish.
# Per-machine additions go in ~/.config/fish/local.fish (not in the repo).

set -g fish_greeting

# -g (global) instead of universal so nothing is written to fish_variables.
fish_add_path -g ~/.local/bin

# pnpm standalone (modules/dev.sh); pnpm 11+ puts itself and global bins in bin/
set -gx PNPM_HOME ~/.local/share/pnpm
fish_add_path -g $PNPM_HOME/bin

# Node via fnm: picks up .nvmrc / .node-version on cd
if test -x ~/.local/share/fnm/fnm
    fish_add_path -g ~/.local/share/fnm
end
if command -q fnm
    fnm env --use-on-cd --shell fish | source
end

if status is-interactive
    if command -q starship
        starship init fish | source
    end
end

if test -f ~/.config/fish/local.fish
    source ~/.config/fish/local.fish
end
