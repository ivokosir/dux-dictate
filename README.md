# dictate

Talk, and the text is pasted where you are typing. Uses ElevenLabs Scribe directly, with a DankMaterialShell card that shows while you talk.

- **Mouse:** click the mic in the bar to start, click again (or **Done** on the card) to stop. Right click the mic for settings and recent transcripts.
- **Keys (niri):** `Mod+B` raw transcript, `Mod+G` cleaned up with Luna.
- **Card:** shows only while you talk (and if something fails). A timer, a mic that glows softly with your voice, the words in live mode, and Cancel / Clean up / Done. When it is done it just disappears: no "pasted" popup, no text.
- **Two engines:** normal (default) uploads the audio when you stop. **Live transcription** (toggle in the right-click menu) streams audio over a WebSocket so you see words while you talk. If live fails, it falls back to a normal upload.
- **Nothing gets lost:** audio is saved to `~/.local/state/dictate/recordings/` until it is transcribed. If ElevenLabs fails, the card shows **Retry**.

## Install

```bash
./install.sh
dictate set-key        # only if no key was found
```

The installer builds the binary to `~/.local/bin/dictate`, starts `dictate.service`, and links the DMS plugin. It reuses the key from `voxtype-elevenlabs-adapter` if one exists. Then add the **Dictate** widget to your bar in DMS settings and bind keys:

```kdl
Mod+B { spawn "dictate" "toggle" "direct"; }
Mod+G { spawn "dictate" "toggle" "luna"; }
```

## Commands

```
dictate toggle [direct|luna]   start, or stop and paste
dictate stop [direct|luna]     stop; the mode picks raw or Luna cleanup
dictate cancel                 throw the recording away
dictate retry                  transcribe the last failed recording again
dictate streaming on|off|toggle
dictate status | watch         state as JSON (the DMS plugin uses watch)
```

## Config

`~/.config/dictate/config.json` (all optional):

```json
{
  "streaming": false,
  "language": "en",
  "luna_command": "/home/you/.local/bin/voxtype-luna-cleanup",
  "luna_timeout_secs": 95,
  "max_minutes": 10
}
```

## How it works

```text
pw-record -> dictate daemon -> ElevenLabs (scribe_v2 upload, or scribe_v2_realtime WebSocket)
          -> optional Luna cleanup -> wl-copy + Ctrl+V (wtype)
DMS plugin <- `dictate watch` (JSON lines) -> card + bar button
```

For testing without a mic or pasting: `DICTATE_TEST_AUDIO=file.mp3 DICTATE_NO_PASTE=1 dictate serve`.
