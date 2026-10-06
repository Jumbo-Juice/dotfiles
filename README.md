# dotfiles

Setup for **Arnold** (hybrid laptop: Intel/AMD iGPU + RTX 2060, user `juji`)
across the distros I hop between: CachyOS/Arch, Fedora, and Ubuntu and its derivatives
(Kubuntu, Mint, Pop!_OS). The distro family is detected from `/etc/os-release`
(`ID` / `ID_LIKE`). Anything else stops with a message.

The repo holds no secrets. Each install creates a fresh SSH key and logs in to
Tailscale and GitHub through the browser.

## Install

Fresh install, as `juji`:

```sh
curl -fsSL https://raw.githubusercontent.com/Jumbo-Juice/dotfiles/main/bootstrap.sh | bash
```

If the install has no curl yet:

```sh
wget -qO- https://raw.githubusercontent.com/Jumbo-Juice/dotfiles/main/bootstrap.sh | bash
```

Add modules after the core with `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/Jumbo-Juice/dotfiles/main/bootstrap.sh | bash -s -- --all
```

| Flag       | Module              | What it does                                                    |
|------------|---------------------|-----------------------------------------------------------------|
| `--gaming` | `modules/gaming.sh` | Nvidia (iGPU display, Nvidia on demand), Steam, GameMode, MangoHud, controller udev rules |
| `--docker` | `modules/docker.sh` | Docker Engine, compose, buildx; `juji` in the `docker` group    |
| `--dev`    | `modules/dev.sh`    | VS Code, uv, Node LTS (fnm), pnpm, Obsidian                     |
| `--all`    | all three           |                                                                 |

The piped script installs git, clones this repo to `~/dotfiles`, and re-runs
itself from disk with the keyboard attached (sudo and `gh` prompts need it).
After that, run anything locally:

```sh
bash ~/dotfiles/bootstrap.sh --gaming     # rerun core and add a module
bash ~/dotfiles/modules/docker.sh         # a module on its own
```

Every script can be rerun safely. Finished steps report `✓` and change nothing,
and the summary ends with `Changes made this run: N`. You enter the sudo
password once per run.

### What core does, in order

1. Sets the hostname to `Arnold`.
2. Tailscale: official install script, `tailscaled` enabled,
   `tailscale up --ssh --hostname=arnold`. The login URL is printed in a box.
   Once you've logged in, you can finish the setup remotely: `ssh juji@arnold`.
3. git and gh (gh comes from GitHub's apt repo on Ubuntu). Creates
   `~/.ssh/id_ed25519` (`juji@Arnold`, asks you for a passphrase), logs in with `gh auth login --web`
   (scope `admin:public_key`), uploads the key as `Arnold-<distro>-<date>`,
   and switches `~/dotfiles` to the SSH remote.
4. fish, set as the login shell.
5. starship (official installer, pinned version, `~/.local/bin`), kitty, and
   JetBrains Mono Nerd Font (pinned nerd-fonts release, `~/.local/share/fonts`).
6. Flatpak + Flathub, Zen (`app.zen_browser.zen`).
7. GNU Stow links `stow/*` into `$HOME`.
8. Prints the manual steps below.

## Manual checklist (every hop)

1. **Tailscale login.** Open the URL that step 2 prints. Then open the
   [admin console](https://login.tailscale.com/admin/machines) and delete the
   old `arnold` machine. If you don't, the new one becomes `arnold-1`. If that
   already happened, rename it to `arnold` there.
2. **Tailscale SSH check mode.** The default tailnet policy uses `"check"`,
   which makes you re-authenticate in a browser periodically (every 12h by
   default). To trust your own devices without that, change the SSH rule in
   *Access controls* to `accept`:

   ```json
   "ssh": [
     {
       "action": "accept",
       "src":    ["autogroup:member"],
       "dst":    ["autogroup:self"],
       "users":  ["autogroup:nonroot"]
     }
   ]
   ```

   This rule covers your normal user only. To keep root logins, add a
   second rule with `"action": "check"` and `"users": ["root"]`. If you'd rather
   keep the prompt but see it less often, stay on `"check"` and add
   `"checkPeriod": "168h"`.
3. **GitHub login.** Step 3 prints a one-time code. Enter it at
   github.com/login/device. If you skipped it, rerun `bootstrap.sh`.
4. **Secure Boot / MOK** (only if the gaming module said so). On the next
   reboot a blue *MOK management* screen appears: **Enroll MOK → Continue →
   Yes**, type the password you chose, then **Reboot**. The screen uses a
   QWERTY layout. If you skip it, the Nvidia module won't load and the iGPU
   keeps working.
5. **Zen.** Sign in to Zen Sync. That brings back uBlock Origin, Dark Reader,
   Bitwarden, Obsidian Web Clipper and SponsorBlock. Then in Stylus, create a
   new style for all sites (or import) and paste
   [`browser/zen-stylus.css`](browser/zen-stylus.css).
6. **Steam offload.** Per game, *Properties → Launch options*:

   ```
   prime-run gamemoderun %command%
   ```

   Add the MangoHud overlay with `prime-run gamemoderun mangohud %command%`.
   Toggle it in game with **Right Shift + F12** (`toggle_hud` in
   `stow/mangohud/.config/MangoHud/MangoHud.conf`).

Also: log out and back in after the docker or gaming module (group membership,
login shell), and reboot after a driver install.

## Notes per module

**Gaming.** In every case the iGPU drives the display and the RTX 2060 renders
only through `prime-run`.

- CachyOS/Arch: if a driver is already there (CachyOS's `chwd` installs one),
  the module leaves it alone. Otherwise it installs `nvidia-open-dkms`
  (Turing+) plus headers for your kernels. It also installs `nvidia-prime`
  (provides `prime-run`) and `lib32-nvidia-utils`, and enables `multilib` on
  plain Arch (after backing up `/etc/pacman.conf`).
- Fedora: RPM Fusion free + nonfree, `akmod-nvidia`,
  `xorg-x11-drv-nvidia-cuda`, then waits for the akmod build.
  `switcheroo-control` is enabled. With Secure Boot on, it creates and queues
  the akmods signing key (`kmodgenca`, `mokutil --import`) before installing
  the driver.
- Ubuntu/Kubuntu/Mint: `ubuntu-drivers install`, `prime-select on-demand`, and
  32-bit `libnvidia-gl`. Pop!_OS uses its own `system76-driver-nvidia` and
  `system76-power graphics hybrid` instead.
- `nvidia-drm.modeset=1` is **not** set. It has been the driver default since
  560, and Arch, RPM Fusion and Ubuntu packages all enable it. To check:
  `cat /sys/module/nvidia_drm/parameters/modeset` should print `Y`.
- Steam is always the native package (`steam` on Arch/Fedora, `steam-installer`
  from multiverse on Ubuntu, with i386 enabled). The first launch downloads the
  Steam client and asks you to accept its licence.
- Controllers: `steam-devices` udev rules on all three. `game-devices-udev` is
  AUR-only, so it's installed only if `paru` exists.
- Ubuntu doesn't package 32-bit MangoHud, so the overlay works in 64-bit games
  only there.

**Docker.** Arch uses `docker docker-compose docker-buildx`. Fedora and the
Ubuntu family use Docker's `docker-ce` repos. Derivatives use
`UBUNTU_CODENAME`, so Mint and Pop get the matching Ubuntu repo.

**Dev.** VS Code comes from Microsoft's repos on Fedora/Ubuntu. On Arch it's
`visual-studio-code-bin` via `paru`, or skipped with a message if paru isn't
installed (no AUR helper is installed for you). uv, fnm and pnpm use their
official installers into `~/.local`. pnpm is standalone because Node 25+ no
longer ships corepack. Update Node with `fnm install --lts && fnm default lts-latest`.
Obsidian comes from Flathub.

## Layout

```
bootstrap.sh            core, curl-able entry point
modules/{gaming,docker,dev}.sh
lib/common.sh           distro detection, logging, package helpers, sudo keepalive
theme/palette.sh        the colours (single source of truth)
theme/render.sh         templates -> stow/ (outputs are committed)
theme/templates/        kitty, fish, starship, MangoHud templates
stow/<pkg>/...          linked into $HOME: fish, starship, kitty, git, mangohud
browser/zen-stylus.css  Stylus theme for Zen (import by hand)
tests/                  container tests (see below)
```

Stow runs with `--no-folding`, so it links files, not whole directories. Files
that apps write next to their config (fish's `fish_variables`, for example)
stay out of the repo. Real files that would block a link are moved to
`~/.dotfiles-backup/<timestamp>/` first. Nothing is deleted.

Per-machine overrides that stay out of the repo: `~/.gitconfig.local`,
`~/.config/fish/local.fish`, `~/.config/kitty/local.conf`.

## Theme

Warm and readable on a faded IPS panel. One palette, taken from the Zen/Stylus
theme. Anything that carries information (comments, autosuggestions, prompt
segments) is at least `gray6` (5.4:1 on the `gray0` background). For that
reason kitty's bright-black (`color8`) is `gray6` rather than `gray5` (3.9:1).
Everything is square, with no rounded powerline glyphs.

To change a colour:

```sh
$EDITOR ~/dotfiles/theme/palette.sh
bash ~/dotfiles/theme/render.sh          # rewrites the files under stow/
stow -d ~/dotfiles/stow -t ~ --no-folding -R fish kitty starship git mangohud
```

The rendered files are symlinked, so kitty (`ctrl+shift+f5`), fish (new shell)
and starship pick up changes immediately. `theme/render.sh --check` fails if
the committed outputs don't match the palette. Commit the template, the
palette and the outputs together.

## Testing

`DOTFILES_TEST=1` skips anything that needs real hardware or a browser:
hostnamectl, `tailscale up`, gh login and key upload, chsh, systemctl, the
Nvidia driver install (its packages are only resolved) and prime/graphics
switching.

```sh
tests/containers.sh                     # archlinux:latest, fedora:latest, ubuntu:24.04
tests/containers.sh ubuntu:24.04        # just one
```

Each container creates a sudo user `juji` and plants a conflicting
`config.fish`. It then runs the curl-style entry (`cat bootstrap.sh | bash -s -- --all`)
and reruns it. The rerun must report `Changes made this run: 0`. Then it
checks every stow link, the config.fish backup, `fish --no-execute`,
`render.sh --check`, that the tools are on fish's PATH, and that the Flatpaks
are installed. Containers run `--privileged` (Flatpak's bubblewrap needs it),
and a no-op `systemctl` shim stands in for systemd.

Lint: `shellcheck -x bootstrap.sh lib/*.sh modules/*.sh theme/*.sh tests/*.sh`.
