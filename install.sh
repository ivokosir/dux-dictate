#!/usr/bin/env bash
# Builds dictate, installs the user service and the DankMaterialShell plugin.
set -euo pipefail
cd "$(dirname "$0")"

cargo build --release
install -Dm755 target/release/dictate "$HOME/.local/bin/dictate"
install -Dm644 systemd/dictate.service "$HOME/.config/systemd/user/dictate.service"

# Reuse the key from voxtype-elevenlabs-adapter if there is one.
conf="${XDG_CONFIG_HOME:-$HOME/.config}"
old_key="$conf/voxtype-elevenlabs-adapter/api-key"
if [[ ! -s "$conf/dictate/api-key" && -s "$old_key" ]]; then
  install -Dm600 "$old_key" "$conf/dictate/api-key"
fi

plugins="$conf/DankMaterialShell/plugins"
mkdir -p "$plugins"
ln -sfn "$PWD/dms-plugin" "$plugins/dictate"

systemctl --user daemon-reload
systemctl --user enable --now dictate.service
systemctl --user restart dictate.service
dms ipc call plugins reload dictate >/dev/null 2>&1 || true

[[ -s "$conf/dictate/api-key" ]] || echo "Now run: dictate set-key"
echo "dictate installed. Bind keys in niri, e.g.:"
echo '  Mod+B { spawn "dictate" "toggle" "direct"; }'
echo '  Mod+G { spawn "dictate" "toggle" "luna"; }'
