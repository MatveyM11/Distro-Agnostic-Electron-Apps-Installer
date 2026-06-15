#!/usr/bin/env bash
# install-brave-arch.sh
# Install / update the Brave browser from the official standalone Linux .zip as a
# REAL, pacman-tracked native package on Arch. Re-run after dropping a newer .zip
# in the folder to upgrade; the same version is a no-op (vercmp decides).
#
# The .zip carries NO metadata inside - the version and channel live only in the
# file name (brave-browser-nightly-1.93.64-linux-amd64). This script parses both
# from the name, so it handles nightly / beta / stable, then synthesizes the
# .desktop, the /usr/bin launcher symlink and the icons, and repackages into a
# .pkg.tar.zst.
#
# Usage:
#   ./install-brave-arch.sh             # install/upgrade from the .zip in the folder
#   ./install-brave-arch.sh -f          # force (re)install even if versions match
#   ./install-brave-arch.sh /path.zip
#
# Needs only bsdtar (libarchive) and pacman, both in a base Arch install. It
# re-runs itself under sudo.
set -euo pipefail

BRAVE_DIR="${BRAVE_DIR:-/home/USER/Documents/Apps/Brave/}"

# Re-exec as root (needed for correct root:root ownership and for pacman -U).
SELF="$(readlink -f "$0")"
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$SELF" "$@"
fi

FORCE=0; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force) FORCE=1 ;;
    -h|--help)  sed -n '2,24p' "$SELF"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  SRC="$1" ;;
  esac
  shift
done

command -v bsdtar >/dev/null || { echo "bsdtar (libarchive) is required." >&2; exit 1; }
command -v vercmp >/dev/null || { echo "vercmp (pacman) is required." >&2; exit 1; }

# --- locate the .zip ---------------------------------------------------------
if [ -z "$SRC" ]; then
  SRC="$(ls -1t "$BRAVE_DIR"/brave-browser*linux*amd64.zip "$BRAVE_DIR"/brave-browser*.zip 2>/dev/null | head -n1 || true)"
fi
[ -n "$SRC" ] && [ -f "$SRC" ] || { echo "No Brave .zip found in $BRAVE_DIR" >&2; exit 1; }
echo "Using: $SRC"

# --- parse version + channel from the file name (the only place they exist) --
zipbase="$(basename "$SRC" .zip)"           # brave-browser-nightly-1.93.64-linux-amd64
name="${zipbase%-linux-*}"                  # brave-browser-nightly-1.93.64
pkgver="${name##*-}"                         # 1.93.64
prod="${name%-*}"                            # brave-browser-nightly  (== pkgname & launcher)
case "$pkgver" in
  [0-9]*) : ;;
  *) echo "Could not parse a version from the file name: $zipbase" >&2; exit 1 ;;
esac
chan="${prod#brave-browser}"; chan="${chan#-}"   # nightly | beta | "" (stable)
iconsuf=""; [ -n "$chan" ] && iconsuf="_$chan"
if [ -n "$chan" ]; then disp="Brave Browser ${chan^}"; else disp="Brave Browser"; fi
PKGNAME="$prod"
PREFIX="/opt/$prod"
pkgrel=1
newver="$pkgver-$pkgrel"
echo "Detected: $disp, version $newver"

# --- compare against installed -----------------------------------------------
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

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
EX="$WORK/src"; STAGE="$WORK/pkg"; mkdir -p "$EX" "$STAGE"

# --- 1. extract the zip ------------------------------------------------------
bsdtar -C "$EX" -xf "$SRC"
appsrc="$(find "$EX" -mindepth 1 -maxdepth 1 -type d | head -n1)"   # the single top folder
[ -d "$appsrc" ] && [ -f "$appsrc/brave" ] || appsrc="$EX"          # fall back to flat layout
[ -f "$appsrc/brave" ] || { echo "Unexpected .zip layout (no 'brave' binary)." >&2; exit 1; }

# --- 2. lay out the package tree ---------------------------------------------
# 2a. the app itself -> /opt/<prod>
mkdir -p "$STAGE$PREFIX"
cp -a "$appsrc/." "$STAGE$PREFIX/"

# 2b. Debian-only cruft (the apt-repo updater) - useless on Arch
rm -rf "$STAGE$PREFIX/cron" 2>/dev/null || true

# 2c. make sure the executables are actually executable (some zips drop modes)
for f in brave "$prod" chrome-sandbox chrome_crashpad_handler chrome-management-service; do
  [ -f "$STAGE$PREFIX/$f" ] && chmod 755 "$STAGE$PREFIX/$f"
done

# 2d. pick the launcher: the channel wrapper if present, else the bare binary
launcher="$prod"; [ -f "$STAGE$PREFIX/$launcher" ] || launcher="brave"

# 2e. CLI launcher: /usr/bin/<prod> -> /opt/<prod>/<launcher>
mkdir -p "$STAGE/usr/bin"
ln -s "$PREFIX/$launcher" "$STAGE/usr/bin/$prod"

# 2f. icons: register the product logos into hicolor so Icon=<prod> resolves
for s in 16 24 32 48 64 128 256; do
  src="$STAGE$PREFIX/product_logo_${s}${iconsuf}.png"
  [ -f "$src" ] || continue
  dst="$STAGE/usr/share/icons/hicolor/${s}x${s}/apps"
  mkdir -p "$dst"; cp -a "$src" "$dst/${prod}.png"
done

# 2g. license (the zip ships a LICENSE file)
if [ -f "$STAGE$PREFIX/LICENSE" ]; then
  mkdir -p "$STAGE/usr/share/licenses/$prod"
  cp -a "$STAGE$PREFIX/LICENSE" "$STAGE/usr/share/licenses/$prod/LICENSE"
fi

# 2h. .desktop (the zip ships none)
mkdir -p "$STAGE/usr/share/applications"
cat > "$STAGE/usr/share/applications/${prod}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=$disp
GenericName=Web Browser
Comment=Access the Internet
Exec=$PREFIX/$launcher %U
StartupNotify=true
Terminal=false
Icon=$prod
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;x-scheme-handler/http;x-scheme-handler/https;
Actions=new-window;new-private-window;
StartupWMClass=$prod

[Desktop Action new-window]
Name=New Window
Exec=$PREFIX/$launcher

[Desktop Action new-private-window]
Name=New Incognito Window
Exec=$PREFIX/$launcher --incognito
EOF

# 2i. ownership root:root (BEFORE the suid chmod; chown can strip suid)
chown -Rh 0:0 "$STAGE"
# 2j. the sandbox helper must be SUID root
sb="$STAGE$PREFIX/chrome-sandbox"
[ -f "$sb" ] && chmod 4755 "$sb"

# --- 3. .PKGINFO -------------------------------------------------------------
size="$(du -sb "$STAGE" | awk '{print $1}')"
cat > "$STAGE/.PKGINFO" <<EOF
pkgname = $PKGNAME
pkgver = $newver
pkgdesc = $disp (repackaged from the official standalone .zip)
url = https://brave.com/
builddate = $(date +%s)
packager = install-brave-arch.sh <local>
size = $size
arch = x86_64
license = custom
depends = gtk3
depends = nss
depends = alsa-lib
depends = libcups
depends = dbus
EOF

# --- 4. assemble the package (.PKGINFO must be the first archive member) ------
pkgfile="$WORK/${PKGNAME}-${newver}-x86_64.pkg.tar.zst"
if ! ( cd "$STAGE" && bsdtar --zstd -cf "$pkgfile" .PKGINFO * ) 2>/dev/null; then
  pkgfile="$WORK/${PKGNAME}-${newver}-x86_64.pkg.tar"   # fallback: uncompressed
  ( cd "$STAGE" && bsdtar -cf "$pkgfile" .PKGINFO * )
fi

# --- 5. install (tracked, upgradable, cleanly removable) ---------------------
pacman -U --noconfirm "$pkgfile"

echo
echo "Done: $PKGNAME $newver is installed and tracked by pacman."
echo "  launch:  $prod   (or find '$disp' in your app menu)"
echo "  remove:  sudo pacman -Rns $PKGNAME"
echo "  verify:  pacman -Qi $PKGNAME"
