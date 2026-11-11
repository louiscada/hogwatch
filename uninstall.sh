#!/usr/bin/env bash
# Removes hogwatch: stops it, deletes the login item, the app, the command
# and its settings.

set -euo pipefail

APP_DIR="${HOGWATCH_APP_DIR:-$HOME/Applications}"
BIN_DIR="${HOGWATCH_BIN_DIR:-$HOME/.local/bin}"
LABEL="com.hogwatch.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
pkill -x hogwatch >/dev/null 2>&1 || true
rm -f "$PLIST" "$BIN_DIR/hogwatch"
rm -rf "$APP_DIR/hogwatch.app"
defaults delete com.louiscada.hogwatch >/dev/null 2>&1 || true
defaults delete hogwatch >/dev/null 2>&1 || true

echo "hogwatch has been removed."
