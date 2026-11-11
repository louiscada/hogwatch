#!/usr/bin/env bash
# hogwatch installer.
#
#   curl -fsSL https://raw.githubusercontent.com/louiscada/hogwatch/main/install.sh | bash
#
# or, from a clone of the repository:
#
#   ./install.sh
#
# Builds from source, installs hogwatch.app to ~/Applications, links the
# `hogwatch` command into ~/.local/bin, and registers a LaunchAgent so it
# starts when you log in. Nothing needs sudo.

set -euo pipefail

REPO_URL="${HOGWATCH_REPO:-https://github.com/louiscada/hogwatch.git}"
APP_DIR="${HOGWATCH_APP_DIR:-$HOME/Applications}"
BIN_DIR="${HOGWATCH_BIN_DIR:-$HOME/.local/bin}"
APP="$APP_DIR/hogwatch.app"
LABEL="com.hogwatch.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "hogwatch only runs on macOS."

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || fail "hogwatch needs macOS 13 (Ventura) or later."

command -v swift >/dev/null 2>&1 || fail "Swift not found. Run 'xcode-select --install', then run this installer again."

# Use the surrounding checkout if there is one; otherwise clone.
SOURCE_DIR=""
CLEANUP_DIR=""
script_path="${BASH_SOURCE[0]:-}"
if [ -n "$script_path" ] && [ -f "$(dirname "$script_path")/Package.swift" ]; then
    SOURCE_DIR="$(cd "$(dirname "$script_path")" && pwd)"
else
    command -v git >/dev/null 2>&1 || fail "git not found. Run 'xcode-select --install' first."
    CLEANUP_DIR="$(mktemp -d)"
    trap 'rm -rf "$CLEANUP_DIR"' EXIT
    say "Downloading hogwatch"
    git clone --depth 1 --quiet "$REPO_URL" "$CLEANUP_DIR/hogwatch"
    SOURCE_DIR="$CLEANUP_DIR/hogwatch"
fi

say "Building (this takes a minute the first time)"
swift build -c release --package-path "$SOURCE_DIR"
BUILT_BINARY="$(swift build -c release --package-path "$SOURCE_DIR" --show-bin-path)/hogwatch"
[ -x "$BUILT_BINARY" ] || fail "Build finished but no binary was produced."

say "Installing $APP"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
pkill -x hogwatch >/dev/null 2>&1 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BUILT_BINARY" "$APP/Contents/MacOS/hogwatch"
install -m 644 "$SOURCE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$SOURCE_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough for an app built on this Mac.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

say "Linking the hogwatch command into $BIN_DIR"
mkdir -p "$BIN_DIR"
ln -sf "$APP/Contents/MacOS/hogwatch" "$BIN_DIR/hogwatch"

say "Registering login item"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/hogwatch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF
launchctl bootstrap "$DOMAIN" "$PLIST"

say "Done. hogwatch is running: look for the H icon in the menu bar."
echo "    A short welcome opens the first time it runs."
echo "    Uninstall: see the README, or run ./uninstall.sh from a clone"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "    Note: $BIN_DIR is not on your PATH, so the 'hogwatch' command needs its full path." ;;
esac
