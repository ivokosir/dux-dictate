#!/usr/bin/env bash
# Installs both halves and the one DankMaterialShell plugin:
#   dictate   (Rust daemon, user service)   talk and paste
#   meetrec   (script)                      record a meeting
set -euo pipefail
cd "$(dirname "$0")"

conf="${XDG_CONFIG_HOME:-$HOME/.config}"
bin="$HOME/.local/bin"
mkdir -p "$bin"

# Dictate: build, install, run as a user service.
cargo build --release
install -Dm755 target/release/dictate "$bin/dictate"
install -Dm644 systemd/dictate.service "$conf/systemd/user/dictate.service"

# Reuse the key from voxtype-elevenlabs-adapter if there is one.
old_key="$conf/voxtype-elevenlabs-adapter/api-key"
if [[ ! -s "$conf/dictate/api-key" && -s "$old_key" ]]; then
  install -Dm600 "$old_key" "$conf/dictate/api-key"
fi

# Meeting: the scripts run from here.
ln -sfn "$PWD/bin/meetrec" "$bin/meetrec"
ln -sfn "$PWD/bin/record-meeting" "$bin/record-meeting"

# One plugin for both. The old separate "Meeting Recorder" plugin goes away.
plugins="$conf/DankMaterialShell/plugins"
mkdir -p "$plugins"
ln -sfn "$PWD/dms-plugin" "$plugins/dictate"
if [[ -L "$plugins/meetingRecorder" ]]; then
  dms ipc call plugins disable meetingRecorder >/dev/null 2>&1 || true
  rm "$plugins/meetingRecorder"
fi

systemctl --user daemon-reload
systemctl --user enable --now dictate.service
systemctl --user restart dictate.service
dms ipc call plugins reload dictate >/dev/null 2>&1 || true

[[ -s "$conf/dictate/api-key" ]] || echo "Now run: dictate set-key"
echo "Installed. Add the 'Dictate & Meeting' widget to your bar in DMS settings, and bind a key in niri, e.g.:"
echo '  Mod+B { spawn "dictate" "toggle" "direct"; }'
