#!/usr/bin/env bash
# install-chrome.sh
# Install / update Google Chrome from the official .deb as a REAL, pacman-tracked
# native package on Arch. Re-run after dropping a newer .deb in the folder to
# upgrade; the same version is a no-op (pacman's vercmp decides).
#
# How it works: it cracks the .deb open with bsdtar (no dpkg needed), reads the
# version, repackages the payload into a .pkg.tar.zst with a generated .PKGINFO,
# and installs it with `pacman -U`. The shipped .desktop file and the product
# logos (registered into hicolor) come straight from the .deb.
#
# Usage:
#   ./install-chrome.sh            # install or upgrade from the .deb in the folder
#   ./install-chrome.sh -f         # force (re)install even if versions match
#   ./install-chrome.sh /path.deb  # use a specific .deb instead of the folder
#
# Tools used are all part of a base Arch system (bsdtar from libarchive, vercmp
# and pacman from pacman). Needs root, so it re-runs itself under sudo.
set -euo pipefail

CHROME_DIR="${CHROME_DIR:-/home/USER/Downloads/Chrome}"
PKGNAME="google-chrome"

# Re-exec as root (needed for correct root:root ownership and for pacman -U).
SELF="$(readlink -f "$0")"
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$SELF" "$@"
fi

FORCE=0; DEB=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force) FORCE=1 ;;
    -h|--help)  sed -n '2,20p' "$SELF"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  DEB="$1" ;;
  esac
  shift
done

command -v bsdtar >/dev/null || { echo "bsdtar (libarchive) is required." >&2; exit 1; }
command -v vercmp >/dev/null || { echo "vercmp (pacman) is required." >&2; exit 1; }

# --- locate the .deb ---------------------------------------------------------
if [ -z "$DEB" ]; then
  DEB="$CHROME_DIR/google-chrome-stable_current_amd64.deb"
  [ -f "$DEB" ] || DEB="$(ls -1t "$CHROME_DIR"/google-chrome*amd64.deb 2>/dev/null | head -n1 || true)"
fi
[ -n "$DEB" ] && [ -f "$DEB" ] || { echo "No Chrome .deb found in $CHROME_DIR" >&2; exit 1; }
echo "Using: $DEB"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
EX="$WORK/deb"; STAGE="$WORK/pkg"; mkdir -p "$EX" "$STAGE"

# --- 1. crack the .deb (bsdtar reads the ar wrapper and auto-detects xz/zst) --
bsdtar -C "$EX" -xf "$DEB"
ctrl="$(echo "$EX"/control.tar.*)"
data="$(echo "$EX"/data.tar.*)"
[ -f "$ctrl" ] && [ -f "$data" ] || { echo "Unexpected .deb layout." >&2; exit 1; }

# --- 2. read the version from the control metadata ---------------------------
mkdir -p "$EX/control"; bsdtar -C "$EX/control" -xf "$ctrl"
debver="$(awk -F': ' '/^Version:/{print $2; exit}' "$EX/control/control")"
[ -n "$debver" ] || { echo "Could not read Version from control file." >&2; exit 1; }
pkgver="${debver%%-*}"
pkgrel="${debver##*-}"; [ "$pkgrel" = "$debver" ] && pkgrel=1
newver="$pkgver-$pkgrel"
echo "Version in .deb: $newver"

# --- 3. compare against what's installed -------------------------------------
installed="$(pacman -Q "$PKGNAME" 2>/dev/null | awk '{print $2}')" || true
if [ -n "$installed" ] && [ "$FORCE" -ne 1 ]; then
  case "$(vercmp "$newver" "$installed")" in
    0)  echo "Already at $installed - nothing to do."; exit 0 ;;
    -*) echo "Installed $installed is newer than $newver - skipping (use -f to force)."; exit 0 ;;
    *)  echo "Upgrading $installed -> $newver" ;;
  esac
else
  [ -n "$installed" ] && echo "Forcing (re)install of $newver" || echo "Installing $newver"
fi

# --- 4. unpack the payload into the staging root -----------------------------
bsdtar -C "$STAGE" -xf "$data"

# Debian-only cruft that's useless or broken on Arch (re-adds an apt repo).
rm -rf "$STAGE/etc/cron.daily" "$STAGE/etc/cron.d" 2>/dev/null || true

# Register the product logos into hicolor so the .desktop's Icon=google-chrome
# resolves in app menus (the .deb relies on its postinst to do this).
for s in 16 24 32 48 64 128 256; do
  src="$STAGE/opt/google/chrome/product_logo_${s}.png"
  [ -f "$src" ] || continue
  dst="$STAGE/usr/share/icons/hicolor/${s}x${s}/apps"
  mkdir -p "$dst"; cp -a "$src" "$dst/google-chrome.png"
done

# Normalise ownership to root:root (chown can strip the suid bit, so do it FIRST)
chown -Rh 0:0 "$STAGE"
# The sandbox helper must be SUID root (matches the .deb's postinst). Set last.
sb="$STAGE/opt/google/chrome/chrome-sandbox"
[ -f "$sb" ] && chmod 4755 "$sb"

# --- 5. generate .PKGINFO ----------------------------------------------------
size="$(du -sb "$STAGE" | awk '{print $1}')"
cat > "$STAGE/.PKGINFO" <<EOF
pkgname = $PKGNAME
pkgver = $newver
pkgdesc = Google Chrome (repackaged from the official .deb)
url = https://www.google.com/chrome/
builddate = $(date +%s)
packager = install-chrome.sh <local>
size = $size
arch = x86_64
license = custom:chrome
depends = gtk3
depends = nss
depends = alsa-lib
depends = libcups
depends = dbus
EOF

# --- 6. assemble the package (.PKGINFO must be the first archive member) ------
pkgfile="$WORK/${PKGNAME}-${newver}-x86_64.pkg.tar.zst"
if ! ( cd "$STAGE" && bsdtar --zstd -cf "$pkgfile" .PKGINFO * ) 2>/dev/null; then
  pkgfile="$WORK/${PKGNAME}-${newver}-x86_64.pkg.tar"   # fallback: uncompressed
  ( cd "$STAGE" && bsdtar -cf "$pkgfile" .PKGINFO * )
fi

# --- 7. install (tracked, upgradable, cleanly removable) ---------------------
pacman -U --noconfirm "$pkgfile"

echo
echo "Done: $PKGNAME $newver is installed and tracked by pacman."
echo "  launch:  google-chrome-stable"
echo "  remove:  sudo pacman -Rns $PKGNAME"
echo "  verify:  pacman -Qi $PKGNAME"
