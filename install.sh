#!/usr/bin/env bash
#
# Notch — one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notch/master/install.sh | bash
#
# Downloads the latest release, installs Notch.app into /Applications, and
# clears the macOS quarantine flag so it opens without a Gatekeeper prompt.
#
set -euo pipefail

REPO="cyrus-cai/notch"
APP_NAME="NotchGlass.app"
INSTALL_DIR="/Applications"

# --- pretty output ---------------------------------------------------------
bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; reset=$'\033[0m'
info()  { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()    { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
die()   { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "Notch is a macOS app — this installer only runs on macOS."
command -v curl >/dev/null 2>&1 || die "curl is required but not found."

# --- find the latest release asset -----------------------------------------
info "Looking up the latest release of ${REPO}…"
api="https://api.github.com/repos/${REPO}/releases/latest"
release_json="$(curl -fsSL "$api")" || die "Could not reach the GitHub API."

# Pull the first .zip browser_download_url out of the release JSON (no jq dependency).
asset_url="$(printf '%s' "$release_json" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' \
  | head -n1 \
  | sed -E 's/.*"(https[^"]+)".*/\1/')"

tag="$(printf '%s' "$release_json" \
  | grep -o '"tag_name": *"[^"]*"' \
  | head -n1 \
  | sed -E 's/.*"([^"]+)".*/\1/')"

[ -n "$asset_url" ] || die "No .zip asset found on the latest release. Has one been published yet?"
ok "Found ${tag:-latest}: $(basename "$asset_url")"

# --- download into a temp dir ----------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
zip="$tmp/notch.zip"

info "Downloading…"
curl -fsSL "$asset_url" -o "$zip" || die "Download failed."

info "Unpacking…"
ditto -x -k "$zip" "$tmp/extracted" || die "Could not unzip the archive."

src="$(/usr/bin/find "$tmp/extracted" -maxdepth 2 -name "$APP_NAME" -type d | head -n1)"
[ -n "$src" ] || die "Could not find ${APP_NAME} inside the archive."

# --- install ---------------------------------------------------------------
dest="$INSTALL_DIR/$APP_NAME"
if [ -d "$dest" ]; then
  info "Replacing existing ${APP_NAME}…"
  rm -rf "$dest" 2>/dev/null || die "Could not remove old ${dest} (try: sudo rm -rf \"$dest\")."
fi

info "Installing to ${INSTALL_DIR}…"
ditto "$src" "$dest" || die "Could not copy into ${INSTALL_DIR} (you may need write permission)."

# --- clear quarantine so it opens without a Gatekeeper prompt ---------------
# The app is not notarized; downloaded apps carry a quarantine flag that makes
# macOS refuse to open them. Strip it, the same way Homebrew cask does.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

ok "Notch installed to ${dest}"
info "Launching…"
open "$dest" || true
printf '\n%sDone.%s Hover your notch to wake it. Quit with: %spkill -f NotchGlass%s\n' \
  "$bold" "$reset" "$dim" "$reset"
