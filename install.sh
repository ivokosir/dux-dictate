#!/usr/bin/env bash
# Installs both halves and the one Dux Shell (dms) plugin:
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

# ✨ clean-up: the script runs from here; your prompt is yours to edit.
ln -sfn "$PWD/bin/dictate-clean" "$bin/dictate-clean"
[[ -e "$conf/dictate/cleanup-prompt.txt" ]] || install -Dm644 config/cleanup-prompt.txt "$conf/dictate/cleanup-prompt.txt"

# Meeting: the scripts run from here.
ln -sfn "$PWD/bin/meetrec" "$bin/meetrec"
ln -sfn "$PWD/bin/record-meeting" "$bin/record-meeting"

# One plugin for both. The old separate "Meeting Recorder" plugin goes away.
# Dux Shell keeps its config in ~/.config/dms (older DankMaterialShell: ~/.config/DankMaterialShell).
shell_conf="$conf/dms"
[[ -d "$shell_conf" ]] || shell_conf="$conf/DankMaterialShell"
plugins="$shell_conf/plugins"
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
echo "Installed. Add the 'Dictate & Meeting' widget to your bar in the shell's settings, and bind a key in niri, e.g.:"
echo '  Mod+B { spawn "dictate" "toggle" "direct"; }'
