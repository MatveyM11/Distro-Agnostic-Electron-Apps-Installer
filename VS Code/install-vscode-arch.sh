#!/usr/bin/env bash
# install-vscode-arch.sh
# Install / update Visual Studio Code from Microsoft's official Linux x64 .tar.gz
# as a REAL, pacman-tracked native package on Arch. Re-run after dropping a newer
# tarball in the folder to upgrade; the same version is a no-op (vercmp decides).
#
# Unlike the .deb, the VS Code tarball ships no metadata, no .desktop file, no
# launcher symlink and no registered icon - so this script reads the version from
# resources/app/package.json and creates the .desktop, the /usr/bin/code symlink
# and the icon itself, then repackages everything into a .pkg.tar.zst.
#
# Usage:
#   ./install-vscode-arch.sh             # install/upgrade from the tarball in the folder
#   ./install-vscode-arch.sh -f          # force (re)install even if versions match
#   ./install-vscode-arch.sh /path.tar.gz
#
# Needs only bsdtar (libarchive) and pacman, both in a base Arch install. It
# re-runs itself under sudo.
set -euo pipefail

VSCODE_DIR="${VSCODE_DIR:-/home/USER/Downloads/VScode}"
PKGNAME="visual-studio-code-bin"
PREFIX="/opt/visual-studio-code"

# Re-exec as root (needed for correct root:root ownership and for pacman -U).
SELF="$(readlink -f "$0")"
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$SELF" "$@"
fi

FORCE=0; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force) FORCE=1 ;;
    -h|--help)  sed -n '2,21p' "$SELF"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  SRC="$1" ;;
  esac
  shift
done

command -v bsdtar >/dev/null || { echo "bsdtar (libarchive) is required." >&2; exit 1; }
command -v vercmp >/dev/null || { echo "vercmp (pacman) is required." >&2; exit 1; }

# --- locate the tarball ------------------------------------------------------
if [ -z "$SRC" ]; then
  SRC="$(ls -1t "$VSCODE_DIR"/code-*x64*.tar.gz "$VSCODE_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)"
fi
[ -n "$SRC" ] && [ -f "$SRC" ] || { echo "No VS Code .tar.gz found in $VSCODE_DIR" >&2; exit 1; }
echo "Using: $SRC"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
EX="$WORK/src"; STAGE="$WORK/pkg"; mkdir -p "$EX" "$STAGE"

# --- 1. extract the tarball --------------------------------------------------
bsdtar -C "$EX" -xf "$SRC"
# the stable x64 tarball extracts to VSCode-linux-x64/; fall back to the single top dir
appsrc="$EX/VSCode-linux-x64"
[ -d "$appsrc" ] || appsrc="$(find "$EX" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -d "$appsrc/resources/app" ] || { echo "Unexpected tarball layout (no resources/app)." >&2; exit 1; }

# --- 2. read the version from resources/app/package.json ---------------------
pkgjson="$appsrc/resources/app/package.json"
pkgver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$pkgjson" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$pkgver" ] || { echo "Could not read version from package.json" >&2; exit 1; }
pkgrel=1
newver="$pkgver-$pkgrel"
echo "Version in tarball: $newver"

# --- 3. compare against installed --------------------------------------------
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

# --- 4. lay out the package tree ---------------------------------------------
# 4a. the app itself -> /opt/visual-studio-code
mkdir -p "$STAGE$PREFIX"
cp -a "$appsrc/." "$STAGE$PREFIX/"

# 4b. CLI launcher: /usr/bin/code -> /opt/visual-studio-code/bin/code
mkdir -p "$STAGE/usr/bin"
ln -s "$PREFIX/bin/code" "$STAGE/usr/bin/code"

# 4c. icon: the tarball doesn't register one, so place the shipped logo where the
#     .desktop's Icon= can find it (matches Microsoft's own .deb: pixmaps fallback)
mkdir -p "$STAGE/usr/share/pixmaps"
cp -a "$appsrc/resources/app/resources/linux/code.png" \
      "$STAGE/usr/share/pixmaps/com.visualstudio.code.png"

# 4d. .desktop files (the tarball ships none): main launcher + vscode:// handler
mkdir -p "$STAGE/usr/share/applications"
cat > "$STAGE/usr/share/applications/code.desktop" <<EOF
[Desktop Entry]
Name=Visual Studio Code
Comment=Code Editing. Redefined.
GenericName=Text Editor
Exec=$PREFIX/code --unity-launch %F
Icon=com.visualstudio.code
Type=Application
StartupNotify=false
StartupWMClass=Code
Categories=TextEditor;Development;IDE;
MimeType=application/x-code-workspace;
Actions=new-empty-window;
Keywords=vscode;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=$PREFIX/code --new-window %F
Icon=com.visualstudio.code
EOF
cat > "$STAGE/usr/share/applications/code-url-handler.desktop" <<EOF
[Desktop Entry]
Name=Visual Studio Code - URL Handler
Comment=Code Editing. Redefined.
GenericName=Text Editor
Exec=$PREFIX/code --open-url %U
Icon=com.visualstudio.code
Type=Application
NoDisplay=true
StartupNotify=true
Categories=Utility;TextEditor;Development;IDE;
MimeType=x-scheme-handler/vscode;
Keywords=vscode;
EOF

# 4e. ownership root:root (do this BEFORE the suid chmod; chown can strip suid)
chown -Rh 0:0 "$STAGE"
# 4f. the Electron sandbox helper must be SUID root
sb="$STAGE$PREFIX/chrome-sandbox"
[ -f "$sb" ] && chmod 4755 "$sb"

# --- 5. .PKGINFO -------------------------------------------------------------
size="$(du -sb "$STAGE" | awk '{print $1}')"
cat > "$STAGE/.PKGINFO" <<EOF
pkgname = $PKGNAME
pkgver = $newver
pkgdesc = Visual Studio Code (Microsoft binary build, repackaged from the official tarball)
url = https://code.visualstudio.com/
builddate = $(date +%s)
packager = install-vscode-arch.sh <local>
size = $size
arch = x86_64
license = custom:commercial
depends = gtk3
depends = nss
depends = alsa-lib
depends = libsecret
depends = xdg-utils
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
echo "  launch:  code   (or find 'Visual Studio Code' in your app menu)"
echo "  remove:  sudo pacman -Rns $PKGNAME"
echo "  verify:  pacman -Qi $PKGNAME"
