# reel

Screen recording with your face in the corner and, optionally, your own words
burned in as captions. Like Loom, except nothing leaves the Mac.

## Get it

[Download Reel.zip](../../releases/latest/download/Reel.zip) from the latest
release. Apple Silicon, macOS 26, 612 KB.

1. Unzip, drag **Reel.app** into Applications.
2. First open is refused: it is signed, but not notarized by Apple.
   **System Settings > Privacy & Security**, scroll down, **Open Anyway**.
3. Same pane, **Screen & System Audio Recording**, turn Reel on. It is already
   listed and switched off, because that permission never prompts.
4. Quit and reopen. It only takes effect on the next launch.
5. The camera and microphone prompt normally the first time you record.

## Run it

Open it and press record. Everything is in the menu bar panel: which screen,
which camera, where the bubble sits and how big, mic, system sound, captions.
Drag the bubble anywhere you like; it is a real window and it is left out of the
shot. Recordings land in `~/Movies/Reel/<timestamp>/` and the one you send is
`recording.mp4`.

Every setting is also a flag:

```
reel --seconds 20 --corner bottomRight --captions
reel --no-camera --no-system-audio          # just a screen and a voice
reel --burn ~/Movies/Reel/2026-08-28-142230 # re-cut the captions after a fix
reel --probe                                # what this machine will allow
reel --help
```

## Build it

```
make signing-identity   # once per machine
make install            # -> ~/Applications/Reel.app
make release            # -> build/Reel.zip
```

Command Line Tools, no Xcode, no package manager.

---

Early: short recordings, one machine. [NOTES.md](NOTES.md) has what else is in
the folder, the traps, and what it still does not do.
