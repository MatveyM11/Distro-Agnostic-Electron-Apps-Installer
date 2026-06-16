#!/usr/bin/env bash
# integrate-onlyoffice.sh
# Integrate the ONLYOFFICE Desktop Editors AppImage into the desktop: install a
# .desktop launcher + icon for the current user and declare which office formats
# it can open (Word / Excel / PowerPoint + OpenDocument), so it is OFFERED as a
# handler for them. It does NOT change your default apps - you set those yourself.
# Re-run any time to refresh.
#
# Deliberately NOT a pacman package: an AppImage is a single self-contained file
# meant to run in place, and desktop integration is per-user. Everything is
# user-level (~/.local/share) and needs NO root. This writes only the .desktop
# and icon; it never touches ~/.config/mimeapps.list.
#
# Usage:
#   ./integrate-onlyoffice.sh                  # use the default AppImage path
#   ./integrate-onlyoffice.sh /path/App.appimage
#   ./integrate-onlyoffice.sh --remove         # undo the integration
set -euo pipefail

APPIMAGE_DEFAULT="/home/marat/Documents/Apps/OnlyOffice/DesktopEditors-x86_64.appimage"

# ----------------------------------------------------------------------------
# YOU MUST PROVIDE THE LOGO. This script does not generate or download an icon.
# Create a large, SQUARE PNG of the ONLYOFFICE logo yourself - 256x256 or
# 512x512 works best - and save it at the exact path below BEFORE running.
# (A small or non-square image will render tiny in the menu.)
# ----------------------------------------------------------------------------
LOGO_PNG="${LOGO_PNG:-/home/marat/Documents/Apps/OnlyOffice/logo_symbol/logo_symbol.png}"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
ICONS_DIR="$DATA_HOME/icons"
DESKTOP_ID="onlyoffice-desktopeditors.desktop"
DESKTOP_FILE="$APPS_DIR/$DESKTOP_ID"

# Office MIME types to DECLARE in the .desktop, so OnlyOffice is offered as a
# handler for them (this does not make it the default - that's your call). No PDF
# on purpose; add application/pdf below if you want it offered for PDFs too.
MIMES=(
  application/msword
  application/vnd.openxmlformats-officedocument.wordprocessingml.document
  application/vnd.openxmlformats-officedocument.wordprocessingml.template
  application/vnd.oasis.opendocument.text
  application/vnd.oasis.opendocument.text-template
  application/rtf
  application/vnd.ms-excel
  application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  application/vnd.openxmlformats-officedocument.spreadsheetml.template
  application/vnd.oasis.opendocument.spreadsheet
  application/vnd.oasis.opendocument.spreadsheet-template
  text/csv
  application/vnd.ms-powerpoint
  application/vnd.openxmlformats-officedocument.presentationml.presentation
  application/vnd.openxmlformats-officedocument.presentationml.template
  application/vnd.openxmlformats-officedocument.presentationml.slideshow
  application/vnd.oasis.opendocument.presentation
  application/vnd.oasis.opendocument.presentation-template
)

REMOVE=0; APPIMAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remove) REMOVE=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) APPIMAGE="$1" ;;
  esac
  shift
done
[ "$(id -u)" -eq 0 ] && { echo "Run this as your normal user, not root (it integrates into your home)." >&2; exit 1; }

refresh_dbs() {
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
  command -v gtk-update-icon-cache  >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f "$ICONS_DIR/hicolor" 2>/dev/null || true
}

# --- removal -----------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
  rm -f "$DESKTOP_FILE"
  find "$ICONS_DIR" \( -name 'onlyoffice-desktopeditors.png' -o -name 'onlyoffice-desktopeditors.svg' \) -delete 2>/dev/null || true
  refresh_dbs
  echo "Removed ONLYOFFICE launcher + icon for $USER."
  echo "(Left ~/.config/mimeapps.list untouched - clear any default you set there yourself.)"
  exit 0
fi

# --- resolve the AppImage ----------------------------------------------------
[ -n "$APPIMAGE" ] || APPIMAGE="$APPIMAGE_DEFAULT"
APPIMAGE="$(readlink -f "$APPIMAGE" 2>/dev/null || echo "$APPIMAGE")"
[ -f "$APPIMAGE" ] || { echo "AppImage not found: $APPIMAGE" >&2; exit 1; }
chmod +x "$APPIMAGE" 2>/dev/null || true
echo "AppImage: $APPIMAGE"

# The logo must exist - this is the icon. Remind and stop if it's missing.
if [ ! -f "$LOGO_PNG" ]; then
  echo >&2
  echo "!! No logo found - create it first." >&2
  echo "   Make a large SQUARE PNG of the ONLYOFFICE logo (256x256 or 512x512)" >&2
  echo "   and save it at this exact path, then run this script again:" >&2
  echo "       $LOGO_PNG" >&2
  echo >&2
  exit 1
fi

mkdir -p "$APPS_DIR" "$ICONS_DIR"

# --- read Name + window class from the AppImage's embedded .desktop ----------
# (Only for the correct StartupWMClass so the window groups under the launcher;
#  --appimage-extract needs no FUSE. The icon comes from your LOGO_PNG, not here.)
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
icon_name="onlyoffice-desktopeditors"          # sensible default, refined below
wmclass=""; disp="ONLYOFFICE Desktop Editors"
( cd "$WORK"; "$APPIMAGE" --appimage-extract '*.desktop' >/dev/null 2>&1 || true )
emb="$(find "$WORK/squashfs-root" -maxdepth 2 -name '*.desktop' 2>/dev/null | head -n1 || true)"
if [ -n "$emb" ] && [ -f "$emb" ]; then
  v="$(awk -F= '/^Icon=/{print $2; exit}'           "$emb")"; [ -n "$v" ] && icon_name="$v"
  v="$(awk -F= '/^StartupWMClass=/{print $2; exit}' "$emb")"; [ -n "$v" ] && wmclass="$v"
  v="$(awk -F= '/^Name=/{print $2; exit}'           "$emb")"; [ -n "$v" ] && disp="$v"
fi

# --- install the icon (your LOGO_PNG, snapped to its real size) --------------
got_icon=0
install_png() {  # $1 = png file -> nearest STANDARD hicolor size from its real px
  local f="$1" w h dim best bd d
  w=$(od -An -tu1 -j16 -N4 "$f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')
  h=$(od -An -tu1 -j20 -N4 "$f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')
  if [ -n "${w:-}" ] && [ "${w:-0}" -gt 0 ] 2>/dev/null && [ "${h:-0}" -gt 0 ] 2>/dev/null; then
    dim=$(( w > h ? w : h ))
  else
    dim=256
  fi
  # snap to the closest standard bucket so the desktop renders it at true scale
  # (a 66px PNG dropped into 256x256 would render at ~1/4 size -> looks "tiny")
  best=256; bd=1000000
  for b in 16 22 24 32 48 64 128 256 512; do
    d=$(( b > dim ? b - dim : dim - b )); [ "$d" -lt "$bd" ] && { bd=$d; best=$b; }
  done
  local dst="$ICONS_DIR/hicolor/${best}x${best}/apps"
  mkdir -p "$dst"; cp -f "$f" "$dst/${icon_name}.png"; got_icon=1
}

# Clear any previously-installed icon first, so a stale / mis-sized icon from an
# earlier run can't shadow the new one.
find "$ICONS_DIR" \( -name "${icon_name}.png" -o -name "${icon_name}.svg" \) -delete 2>/dev/null || true

install_png "$LOGO_PNG"
echo "Icon: using your logo $LOGO_PNG"

# --- write the .desktop ------------------------------------------------------
mime_line="$(IFS=';'; echo "${MIMES[*]}");"
{
  echo "[Desktop Entry]"
  echo "Type=Application"
  echo "Name=$disp"
  echo "GenericName=Office Suite"
  echo "Comment=Edit documents, spreadsheets and presentations"
  echo "Exec=\"$APPIMAGE\" %U"
  echo "TryExec=$APPIMAGE"
  echo "Icon=$icon_name"
  echo "Terminal=false"
  echo "Categories=Office;WordProcessor;Spreadsheet;Presentation;"
  echo "MimeType=$mime_line"
  [ -n "$wmclass" ] && echo "StartupWMClass=$wmclass"
  echo "StartupNotify=true"
  echo "Keywords=office;document;spreadsheet;presentation;docx;xlsx;pptx;odt;ods;odp;"
} > "$DESKTOP_FILE"
chmod 644 "$DESKTOP_FILE"

refresh_dbs

# NOTE: no default handler is set on purpose. The MimeType= line above declares
# that OnlyOffice CAN open these formats, so it appears in "Open With" and in
# your desktop's default-apps picker - but your ~/.config/mimeapps.list is left
# alone. Make it the default yourself via your DE settings, or:
#   xdg-mime default $DESKTOP_ID <mime-type>

echo
echo "Done. '$disp' is in your app menu and offered as a handler for office files."
echo "  desktop file: $DESKTOP_FILE"
echo "  set as default yourself in your DE's settings, or with: xdg-mime default $DESKTOP_ID <type>"
echo "  undo:         $0 --remove"
echo
echo "If double-clicking the AppImage ever fails to launch, you likely need FUSE:"
echo "  sudo pacman -S fuse2     (or change Exec to add --appimage-extract-and-run)"
