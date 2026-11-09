# dictate + meeting

One DankMaterialShell bar button with two modes. Click the title in the popout (**Dictate ⇅** / **Meeting ⇅**) to switch; the mode is remembered.

- **Dictate:** talk, and the text is pasted where you are typing (ElevenLabs Scribe).
- **Meeting:** record your mic + what you hear (e.g. a WhatsApp call) into one file.

Both work the same way: click the bar button for the popout, **right click starts/stops the current mode**. While something records the button is filled and shows a timer (teal = dictating, red = meeting). A dot next to the title tells you the other mode is busy too.

## Dictate

- **Key (niri):** `Mod+B` starts, and pressing it again stops and pastes.
- **Bar button:** teal with a timer while you talk; the icon breathes while it works (✨ while cleaning up). Click it for ✕ ✨ ✓.
- **Card:** a small pill in the top-right corner, only for what the bar can't show. Problems show there as a short red line (with ⟳ retry and ✕). And while a fullscreen window covers the bar, it shows the take: glowing mic + timer; put the mouse on it and it turns into ✕ (throw away), ✨ (clean up with Luna, then paste) and ✓ (paste).
- **Popout:** one row that never moves: mic, Dictate (+ timer while talking), ⚡ Live, and Start / ✕ ✨ ✓ / Cancel / Retry. Finishing from the popout copies instead of pasting (you are in the popout, not your app). The card hides while the popout is open on Dictate.
- **Recent is just files:** every take is `~/Music/Dictations/<time>.ogg` (+ `.txt`, + `.clean.txt`). Not transcribed → ⟳ Transcribe. Transcribed → ✨ clean up (or copy the cleaned text), 📋 copy raw text. The last 20 are kept; older ones go to the trash.
- **Two engines:** normal (default) uploads the audio when you stop and pastes it. **Live** (⚡) streams while you talk and *types* each sentence straight into the field when you pause (ElevenLabs decides when a sentence is done; no Ctrl+V). It types with a built-in virtual keyboard that sends real key codes, so apps like Claude don't drop spaces (wtype sends fake ones). While the popout is open it holds the text back, and ✨ with live puts the cleaned version on your clipboard (the raw one is already typed). If live fails before anything was typed, it falls back to a normal upload.
- **No time limit:** the audio is written to disk while you talk, so long takes are fine and nothing is lost if something fails.

## Meeting

- **Popout:** Record / Stop, and **Recent**: the newest 5 recordings, *Show N more* for all of them. Open folder and Delete all (asks first, goes to the trash) sit next to the title, like in Dictate. While recording, the name of the meeting is under the title; click it to rename.
- Files are `~/Music/Meetings/2026-11-09_14-30-00_<name>.ogg`. The name is exactly what you type (spaces and all); only characters a file name can't hold (`/ \ : * ? " < > |`) are dropped. Nothing else stores names.
- On each recording (hover it): **Rename**, **Transcribe**, **Copy file** (paste into a chat/browser/file manager), **Show in folder**, **Delete** (goes to the trash, with its transcript). Click the row to play it.
- **Transcribe** sends the recording to ElevenLabs (Scribe, with speakers) in the background and saves `<recording>.txt` next to it, in ElevenLabs' own text format: `00:00:04,400 --> 00:00:09,820 [speaker_1]` and then what was said. Click **Transcript** to open it; the same button then **copies the transcript** text. Renaming or deleting a recording takes its transcript along.
- When you stop, a notification offers Copy file / Show in folder too.
- It records as a user service (`meetrec.service`), so it keeps going if the bar restarts.

## Install

```bash
./install.sh
dictate set-key        # only if no key was found
```

The installer builds the `dictate` binary to `~/.local/bin/dictate`, starts `dictate.service`, links `meetrec` and `record-meeting` into `~/.local/bin`, and links the DMS plugin. It reuses the key from `voxtype-elevenlabs-adapter` if one exists. Then add the **Dictate & Meeting** widget to your bar in DMS settings and bind a key:

```kdl
Mod+B { spawn "dictate" "toggle" "direct"; }
```

Meeting needs `ffmpeg`, `pactl` (PipeWire/PulseAudio), `wl-clipboard`, `libnotify`, `curl`, `python3`.

ElevenLabs key: `$ELEVENLABS_API_KEY`, or `~/.config/dictate/api-key` (meetrec also looks in `~/.config/meetrec/api-key` and `~/.config/voxtype-elevenlabs-adapter/api-key`).

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

meetrec start [name] | stop | toggle | status | list
meetrec copy|open|reveal|delete|transcribe|copy-text <file>
meetrec delete all             every recording (not the one being recorded) to the trash
meetrec rename <file> <name>
meetrec folder
record-meeting [name]          foreground, Ctrl+C to stop
```

For a key, through the bar:

```
dms ipc call dictate popout        open the popout on Dictate
dms ipc call dictate switchMode    Dictate <-> Meeting
dms ipc call meetrec open          open the popout on Meeting
dms ipc call meetrec toggle        start/stop a meeting
dms ipc call meetrec rename        jump to naming the meeting
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
Dictate   pw-record -> dictate daemon -> ffmpeg -> ~/Music/Dictations/<time>.ogg (while you talk)
                    -> ElevenLabs (upload the .ogg, or scribe_v2_realtime WebSocket) -> <time>.txt
                    -> optional Luna cleanup -> <time>.clean.txt -> wl-copy + Ctrl+V (built-in virtual keyboard)
Meeting   meetrec start -> ffmpeg (speaker monitor + mic, mixed) as meetrec.service -> ~/Music/Meetings/<time>_<name>.ogg

DMS plugin (dms-plugin/)
  DictateWidget.qml   the bar button + popout, both modes
                      <- `dictate watch` (JSON lines), <- $XDG_RUNTIME_DIR/meetrec/current (watched file)
  DictateCard.qml     the top-right card while dictating
```

Layout: `src/` is the dictate daemon (Rust), `bin/` is the meeting recorder (bash), `dms-plugin/` is the one plugin for both.

Adding or renaming a file in `dms-plugin/` needs a DMS restart (Qt remembers the folder listing); editing a file only needs `dms ipc call plugins reload dictate`.

For testing dictate without a mic or pasting: `DICTATE_TEST_AUDIO=file.mp3 DICTATE_NO_PASTE=1 DICTATE_DIR=/tmp/takes dictate serve`.
