#!/usr/bin/env bash
# Make the built-in laptop panel look more vivid. A narrow-gamut panel (the
# G531GV's Panda LM156LF-GL02 covers ~60% sRGB) looks washed out because, with
# no profile, mutter sends it sRGB unchanged. This writes an ICC profile from
# the panel's EDID primaries, pulled towards white by SAT, with a gamma of
# GAMMA. Mutter's colour transform then raises saturation and midtone
# contrast. The profile goes to ~/.local/share/icc and becomes the panel's
# default in colord (Settings > Color lists it as "Vivid ...").
#   theme/display-profile.sh              apply (SAT=0.5 GAMMA=1.6, the strongest)
#   theme/display-profile.sh 0.7 1.8      milder; 1 2.2 is plain EDID-accurate
#   theme/display-profile.sh --off        remove it (back to no profile)
set -euo pipefail

icc_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icc"

# colormgr prints its errors on stdout; surface them instead of exiting silently.
cm() {
  local out
  out=$(colormgr "$@" 2>&1) || { echo "colormgr $1 failed: $out" >&2; exit 1; }
  printf '%s\n' "$out"
}

off=0 sat=0.5 gamma=1.6
case ${1:-} in
  --off) off=1 ;;
  -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
  ?*) sat=$1 gamma=${2:-$gamma} ;;
esac
python3 -c "import sys; s, g = map(float, sys.argv[1:]); sys.exit(not (0.5 <= s <= 1 and 1.6 <= g <= 2.6))" "$sat" "$gamma" ||
  { echo "SAT must be 0.5-1 and GAMMA 1.6-2.6 (got $sat $gamma)" >&2; exit 2; }

# colord only lets the active desktop session change a display. Shells with a
# login session of their own (ssh, embedded terminals) are refused, so rerun
# through the user's systemd manager, which polkit counts as the desktop.
if [[ -z ${DISPLAY_PROFILE_RELAUNCHED:-} ]] &&
  ! pkcheck --action-id org.freedesktop.color-manager.modify-device --process $$ >/dev/null 2>&1; then
  exec systemd-run --user --quiet --wait --pipe --collect -E DISPLAY_PROFILE_RELAUNCHED=1 \
    ${XDG_DATA_HOME:+-E "XDG_DATA_HOME=$XDG_DATA_HOME"} "$(realpath "$0")" "$@"
fi

edid="" conn=""
for c in /sys/class/drm/card*-eDP-*; do
  [[ -e $c/status && $(<"$c/status") == connected ]] || continue
  edid=$c/edid conn=${c##*/} conn=${conn#card*-}
done
[[ -n $edid ]] || { echo "no connected built-in (eDP) panel found" >&2; exit 1; }

device=$(cm get-devices-by-kind display |
  awk -v c="XRANDR_name=$conn" '/^Object Path:/ {p = $3} $2 == c {print p}')
[[ -n $device ]] || { echo "colord has no display device for $conn" >&2; exit 1; }

target="$icc_dir/vivid-$conn-s$sat-g$gamma.icc"

# Detach and delete profiles from runs with other settings. colord keeps
# their entries until logout (it refuses to delete them); that is harmless.
for f in "$icc_dir"/vivid-"$conn"-*.icc; do
  [[ -e $f ]] || continue
  [[ $f == "$target" ]] && ((!off)) && continue
  p=$(colormgr find-profile-by-filename "$f" 2>/dev/null | awk '/^Object Path:/ {print $3}' || true)
  [[ -n $p ]] && gdbus call --system -d org.freedesktop.ColorManager -o "$device" \
    -m org.freedesktop.ColorManager.Device.RemoveProfile "$p" >/dev/null 2>&1 || true  # not attached
  rm -f "$f"
done
if ((off)); then
  echo "removed the Vivid profile from $conn"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
file="$tmp/profile.icc"
python3 - "$edid" "$file" "$sat" "$gamma" "$conn" <<'PY'
import ctypes as C, hashlib, struct, sys

edid_path, out, sat, gamma, conn = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
d = open(edid_path, "rb").read()

# EDID 1.4 bytes 25-34: chromaticity as 10-bit fractions of 1024.
lo, hi = (d[25] << 8) | d[26], d[27:35]
xy = [((hi[i] << 2) | (lo >> (14 - 2 * i)) & 3) / 1024 for i in range(8)]
(rx, ry), (gx, gy), (bx, by), (wx, wy) = zip(xy[0::2], xy[1::2])

def pull(x, y):  # towards the white point: a smaller claimed gamut
    return wx + sat * (x - wx), wy + sat * (y - wy)

class xyY(C.Structure):
    _fields_ = [("x", C.c_double), ("y", C.c_double), ("Y", C.c_double)]

class Triple(C.Structure):
    _fields_ = [("r", xyY), ("g", xyY), ("b", xyY)]

lcms = C.CDLL("liblcms2.so.2")
lcms.cmsBuildGamma.restype = C.c_void_p
lcms.cmsBuildGamma.argtypes = [C.c_void_p, C.c_double]
lcms.cmsCreateRGBProfile.restype = C.c_void_p
lcms.cmsCreateRGBProfile.argtypes = [C.POINTER(xyY), C.POINTER(Triple), C.c_void_p * 3]
lcms.cmsMLUalloc.restype = C.c_void_p
lcms.cmsMLUalloc.argtypes = [C.c_void_p, C.c_uint32]
lcms.cmsMLUsetASCII.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p]
lcms.cmsWriteTag.argtypes = [C.c_void_p, C.c_uint32, C.c_void_p]
lcms.cmsSaveProfileToFile.argtypes = [C.c_void_p, C.c_char_p]

curve = lcms.cmsBuildGamma(None, gamma)
prims = Triple(xyY(*pull(rx, ry), 1), xyY(*pull(gx, gy), 1), xyY(*pull(bx, by), 1))
h = lcms.cmsCreateRGBProfile(C.byref(xyY(wx, wy, 1)), C.byref(prims), (C.c_void_p * 3)(curve, curve, curve))

def text(tag, s):
    mlu = lcms.cmsMLUalloc(None, 1)
    lcms.cmsMLUsetASCII(mlu, b"en", b"US", s.encode())
    lcms.cmsWriteTag(h, tag, mlu)

text(0x64657363, f"Vivid {conn} (saturation {sat}, gamma {gamma})")  # desc
text(0x63707274, "No copyright, generated by ~/dotfiles/theme/display-profile.sh")  # cprt
if not lcms.cmsSaveProfileToFile(h, out.encode()):
    sys.exit("could not write " + out)

# Same settings -> same bytes, so a rerun keeps the profile colord already has:
# pin the header date, then recompute the profile ID (ICC.1 7.2.18).
b = bytearray(open(out, "rb").read())
b[24:36] = struct.pack(">6H", 2026, 1, 1, 0, 0, 0)
z = bytearray(b)
z[44:48] = z[64:68] = bytes(4)
z[84:100] = bytes(16)
b[84:100] = hashlib.md5(z).digest()
open(out, "wb").write(b)
PY

mkdir -p "$icc_dir"
cmp -s "$file" "$target" || cp "$file" "$target"

# Mutter registers new files in the ICC directory with colord within ~1 s.
profile=""
for ((i = 0; i < 20; i++)); do
  profile=$(colormgr find-profile-by-filename "$target" 2>/dev/null | awk '/^Object Path:/ {print $3}' || true)
  [[ -n $profile ]] && break
  sleep 0.5
done
[[ -n $profile ]] || { echo "colord did not register $target" >&2; exit 1; }

current=$(colormgr device-get-default-profile "$device" 2>/dev/null | awk '/^Object Path:/ {print $3}' || true)
if [[ $current == "$profile" ]]; then
  echo "${target##*/} is already active on $conn"
  exit 0
fi
colormgr device-add-profile "$device" "$profile" >/dev/null 2>&1 || true  # may already be attached
cm device-make-profile-default "$device" "$profile" >/dev/null
echo "applied ${target##*/} to $conn"
