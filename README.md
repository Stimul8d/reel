# reel

Screen recording with your face in the corner and, optionally, your own words
burned in as captions. A Loom-shaped thing that never leaves the Mac: no
account, no upload, no bot, no server. You press stop and there is an mp4 in
`~/Movies/Reel/<timestamp>/`.

Early. It records, it composites, it transcribes, it muxes. It has not been
through a long recording or a hostile network of external displays yet.

## What comes out

One directory per recording:

| File | What it is |
|------|------------|
| `recording.mp4` | the one you send: screen, camera bubble, mixed sound |
| `recording-captioned.mp4` | the same with captions burned in, only if you asked |
| `video.mp4` | picture only, before the sound went on. Kept deliberately |
| `me.wav` | your microphone, raw |
| `them.wav` | whatever the Mac was playing, raw |
| `transcript.json` | timed lines and caption chunks, on the video's clock |
| `transcript.txt` | readable version |
| `captions.srt` | subtitles you can switch off, unlike burned ones |

The raw parts stay because they cost nothing and they let you fix things
afterwards. Correct a name in `transcript.json`, run `--burn` on the directory,
and the captions are re-cut without recording anything again.

## Using it

No flags gives you the menu bar app. Click the record dot, and everything is in
the panel: which screen, which camera, where the bubble sits and how big, mic,
system sound, transcription, captions.

The camera bubble is a real floating window you can drag anywhere. It is
excluded from the capture, so it appears in the recording exactly once, where
you left it.

```
reel --seconds 20 --corner bottomRight --captions
reel --no-camera --no-system-audio          # just a screen and a voice
reel --burn ~/Movies/Reel/2026-08-28-142230 # re-cut the captions
reel --probe                                # what this machine will allow
reel --help
```

## Building

```
make signing-identity   # once per machine, shared with scribe
make install            # -> ~/Applications/Reel.app
make run ARGS="--probe"
```

`swiftc` and a Makefile, no Xcode project, same as procwatch and scribe.

## The bits that were not obvious

**Sign with a real identity, never ad-hoc.** TCC pins its grant to the code
requirement, and for `codesign --sign -` that requirement is the cdhash, which
changes on every build. Every rebuild silently revokes screen recording and the
only symptom is `SCStream` error **-3801, "the user declined TCCs"**, which is a
lie. `make signing-identity` makes a self-signed cert so the requirement becomes
`identifier "house.huntley.reel" and certificate root = H"..."` and survives
rebuilds. Reel and scribe share the cert.

**Screen Recording never prompts.** For a self-signed app it appears in System
Settings > Privacy & Security > Screen & System Audio Recording with the toggle
off, and a human has to flip it. Takes effect next launch. The camera and the
microphone do prompt, but only because the entitlements are in
`Resources/Reel.entitlements`; under the hardened runtime a missing entitlement
means no prompt at all and silent black frames or silent audio.

**It must be an installed `.app`.** TCC attributes a bare binary run from a
terminal to the terminal, and Warp is itself denied screen capture. Canonical
home is `~/Applications/Reel.app`.

**Picture and sound are recorded separately on purpose.** The live pass writes
`video.mp4` with no audio track plus one wav per lane. The microphone and the
ScreenCaptureKit stream run off different hardware clocks; summing two clocks in
real time gives drift you cannot undo. The mux happens after you press stop,
where there is no clock pressure, and each lane is shifted onto the video's
timeline using the wall clock of its own first sample.

**The camera is burned into the picture, not kept as a track.** That fixes the
bubble where it was at record time. One file that plays anywhere, against
flexibility nobody has asked for.

**Captions are always a second pass.** The clean recording stays untouched, so
re-burning is cheap and a wrong name is not permanent.

**`AnalysisContext.contextualStrings` does nothing.** Measured in scribe: output
is byte-identical with and without a vocabulary list. Names are still the one
thing the model reliably gets wrong. Fix them in the transcript and re-burn.

**The stale CLT modulemap breaks every `swiftc` build on this machine.** The
Makefile works around it with a single-file VFS overlay. Map the file, not the
directory: a directory remap breaks SwiftShims lookup.

## Lifted from scribe

`Lane` (the on-device `SpeechAnalyzer` pipeline), `MicAudio`, `WavWriter`, the
`CMSampleBuffer` to `AVAudioPCMBuffer` conversion, the console sink, and the
whole Makefile signing dance. Same machine, same traps, no reason to learn them
twice.

## Not done

- Nothing is persisted between launches: the panel resets to defaults each time.
- No login item.
- No pause and resume, no trimming, no region select. Whole display only.
- Long recordings are untested. Disk is roughly the mp4 plus about 12 MB a
  minute of raw wav, which the app never cleans up.
- Recording other people raises a consent question this does not answer.
