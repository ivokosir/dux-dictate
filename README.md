# dictate

Talk, and the text is pasted where you are typing. Uses ElevenLabs Scribe directly, with a DankMaterialShell card that shows while you talk.

- **Mouse:** click the mic in the bar for the popout (Start, Live, Recent). Right click the mic starts/stops right away.
- **Key (niri):** `Mod+B` starts, and pressing it again stops and pastes.
- **Card:** a small pill in the top-right corner while you talk: glowing mic + timer. Put the mouse on it and it turns into ✕ (throw away), ✨ (clean up with Luna, then paste) and ✓ (paste). While it works the mic spins; problems show as a short red line. When it is done it just disappears.
- **Popout:** one row that never moves: mic, Dictate (+ timer while talking), ⚡ Live, and Start / ✕ ✨ ✓ / Cancel / Retry. Finishing from the popout copies instead of pasting (you are in the popout, not your app). The card hides while the popout is open.
- **Recent is just files:** every take is `~/Music/Dictations/<time>.ogg` (+ `.txt`, + `.clean.txt`). Not transcribed → ⟳ Transcribe. Transcribed → ✨ clean up (or copy the cleaned text), 📋 copy raw text. The last 20 are kept; older ones go to the trash.
- **Two engines:** normal (default) uploads the audio when you stop and pastes it. **Live** (⚡) streams while you talk and *types* each sentence straight into the field when you pause (ElevenLabs decides when a sentence is done; no Ctrl+V). It types with a built-in virtual keyboard that sends real key codes, so apps like Claude don't drop spaces (wtype sends fake ones). While the popout is open it holds the text back, and ✨ with live puts the cleaned version on your clipboard (the raw one is already typed). If live fails before anything was typed, it falls back to a normal upload.
- **No time limit:** the audio is written to disk while you talk, so long takes are fine and nothing is lost if something fails.

## Install

```bash
./install.sh
dictate set-key        # only if no key was found
```

The installer builds the binary to `~/.local/bin/dictate`, starts `dictate.service`, and links the DMS plugin. It reuses the key from `voxtype-elevenlabs-adapter` if one exists. Then add the **Dictate** widget to your bar in DMS settings and bind a key:

```kdl
Mod+B { spawn "dictate" "toggle" "direct"; }
```

`dms ipc call dictate popout` opens the popout (handy for a key too).

## Commands

```
dictate toggle [direct|luna]   start, or stop and paste
dictate stop [direct|luna] [copy]
dictate cancel                 throw the recording away / dismiss a problem
dictate retry                  transcribe the last failed take again
dictate streaming on|off|toggle
dictate status | watch         state as JSON (the DMS plugin uses watch)

dictate list [n]               takes in ~/Music/Dictations as JSON
dictate transcribe <take>      (re)make <take>.txt
dictate clean <take>           make <take>.clean.txt
dictate copy <take> [raw|clean]
dictate reveal <take> | trash <take>|all | folder
```

## Config

`~/.config/dictate/config.json` (all optional):

```json
{
  "streaming": false,
  "language": "en",
  "luna_command": "/home/you/.local/bin/voxtype-luna-cleanup",
  "luna_timeout_secs": 95,
  "keep": 20
}
```

## How it works

```text
pw-record -> dictate daemon -> ffmpeg -> ~/Music/Dictations/<time>.ogg (while you talk)
          -> ElevenLabs (upload the .ogg, or scribe_v2_realtime WebSocket) -> <time>.txt
          -> optional Luna cleanup -> <time>.clean.txt -> wl-copy + Ctrl+V (built-in virtual keyboard)
DMS plugin <- `dictate watch` (JSON lines) -> card + bar button
```

For testing without a mic or pasting: `DICTATE_TEST_AUDIO=file.mp3 DICTATE_NO_PASTE=1 DICTATE_DIR=/tmp/takes dictate serve`.
