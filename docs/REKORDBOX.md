# Rekordbox integration: research notes

Research for two changes: splitting the Clock into a **Beat Detection** input, and adding a
**Rekordbox** input with deck state (which tracks are loaded, how far in they are, when songs
change) that the Sequencer/timeline milestone can build on.

Setup assumed: one Mac running Rekordbox 7.2.19 (Performance mode) and Jim Viz, a DDJ-FLX4 over
USB, no CDJs, no network.

## What exists today

- `RekordboxReader` decrypts `master.db` (+ WAL) once a second and reads `djmdSongHistory`:
  title, artist, album, key, BPM, length, artwork, cues.
- A new history row fires `clock.track` and sets the audio tempo tracker's preferred BPM.
- Limitation: Rekordbox only writes history after a track has played for the **Playback time**
  in Preferences (30–60 s by default; reportedly no faster than ~10 s however low it's set).
  History has **no deck number**.

## Ways to get data out of Rekordbox

| Source | Gives | Latency | Cost / risk | Verdict |
|---|---|---|---|---|
| `master.db` history (have it) | Confirmed track played, full metadata, cues | 10–60 s | None | Keep. Ground truth, but late and deck-less |
| ANLZ analysis files (`share/PIONEER/USBANLZ/…/ANLZ0000.DAT/.EXT`) | Beat grid (PQTZ), **phrase structure** (PSSI: intro/up/chorus/down/outro), colour waveform (PWV5), cues | Instant once the track is known | Binary parsing, formats documented by pyrekordbox / Deep Symmetry | **Do it.** Your library: 262 analysed tracks, 83 have phrase data |
| DDJ-FLX4 MIDI (we already open the port) | Per deck: Load, Play, Cue, hot cues, channel fader, tempo slider, EQ; crossfader | Instant | No permissions. Play is a toggle, so the initial state is unknown; can't see jog/search jumps | **Do it.** Best source of "which deck is on air" and instant change triggers |
| Screen reading (ScreenCaptureKit + Vision OCR of the deck headers) | Per deck: title, artist, elapsed/remaining time, BPM, key, the moment a track loads | ~0.25–0.5 s | Screen Recording permission; layout-dependent (2/4 decks, window size, skin) | **Optional phase 2.** The only no-hack way to get an exact play position |
| Accessibility API | Possibly the same text as OCR | Instant | Untested: Rekordbox wasn't running. Custom-drawn apps usually expose nothing | Probe once, expect nothing |
| Memory reading (rkbx_link and friends) | Everything: exact position, beat, phrase, master deck | Instant | macOS needs Rekordbox **re-signed** with `get-task-allow` and run with `sudo`; Mac offsets only exist for 7.2.8/7.2.17/7.2.18 | **Ruled out** (we agreed not to re-sign Rekordbox; 7.2.19 unsupported anyway) |
| Pro DJ Link | Deck status, beat, track IDs | Instant | Only CDJs/XDJs broadcast deck status; a controller setup has nothing on the network; tools fight Rekordbox for ports | Not applicable without CDJs |
| Ableton Link | Master tempo and beat phase | Instant | Rekordbox decks must follow Link, and users report the pitch fader can't drive it | Ruled out (VISION already says LINK stays off) |

## Proposed devices

### Beat Detection (replaces Clock)

Today's Clock minus the Rekordbox bits: audio tempo tracking, tap tempo, Auto/Audio/Manual,
latency. Outputs stay `pulse`, `beat`, `bar`, `phrase`. `clock.track` moves to Rekordbox.
When a Rekordbox input is present, its master-deck BPM (track BPM × tempo slider) is the
tempo hint, so the audio tracker locks on without half/double-time confusion.

### Rekordbox (new input)

Fuses the three cheap sources: MIDI for instant deck events, `master.db` for track identity and
metadata, ANLZ for beat grid and phrases.

**Per deck (A, B) and "Master" (the deck that's on air):**

| Output | How |
|---|---|
| `playing` 0/1 | FLX4 Play presses (toggle, reconciled with audio level and history) |
| `on air` 0…1 | Channel fader × crossfader curve, from MIDI. Absolute, so always right |
| `progress` 0…1, `elapsed`, `remaining` | Dead-reckoned: starts on Play, runs at track tempo × tempo slider, jumps on Cue/hot cue (cue times from `djmdCue`). Exact with OCR |
| `bpm` | Track BPM × tempo slider |
| phrase ramp + phrase kind | Position against the ANLZ phrase list |

**Triggers** (decaying pulses like `clock.pulse`): track loaded (Load button), track changed
(the master deck switched, or a new history row), phrase change, per-kind phrase hits
(chorus/drop, breakdown), "last 32 bars" warning, hot cue pressed.

**Whole mixer:** `mix` −1…1 (which deck dominates, from faders + crossfader). Handy for
blending two scenes during a transition.

**Track metadata:** title, artist, key/Camelot (the reader already makes a key palette), BPM,
genre, colour, comment. Text isn't a value, so this would be a third IO kind (say `track`)
consumed by the Sequencer, and later by a text generator or by the palette.

**Known weak spot:** without OCR, a track's identity is only known when its history row lands
(10–60 s after it starts). Until then we know "deck B just loaded something and is playing"
but not what. History rows are matched to the deck that most recently started playing.

## How it feeds the timeline (milestone 7)

The Rekordbox input can expose a **transport** (track ID, position, beat, phrase) that the
Sequencer consumes, the way the generator consumes video. That enables two timeline styles:

1. **Set timeline.** Cues on a bar/beat timeline from Beat Detection. Works without Rekordbox.
2. **Track-attached cues.** Cues saved against a track ID, at a beat or a phrase ("2nd
   chorus"), that fire whenever that track plays. Plus rules: "on any Chorus phrase → scene
   X", "on track change → next scene".

A neat extra: read Rekordbox's own memory/hot cue comments as timeline markers (for example
a memory cue named `viz: strobe`), so you prep visuals inside Rekordbox while prepping the set.

## Experiments before building

1. **History lag.** Set Preferences → Advanced → Browse → Playback time to its minimum, play
   a track, and time how long the history row takes.
2. **FLX4 MIDI capture.** Log every message while doing Load, Play, Cue, hot cue, Sync, Shift
   combinations, fader and crossfader moves on both decks. Confirm exact bytes (Mixxx's FLX4
   mapping and pyflx4 are the references) and see whether anything reveals Rekordbox's real
   play state.
3. **Load-time DB writes.** Diff `master.db` before and after loading an already-analysed
   track. If Rekordbox writes anything at load time, we get track identity instantly without OCR.
4. **OCR feasibility.** Capture the Rekordbox window and run Vision text recognition on the
   deck headers at your usual window size and layout.
5. **Accessibility probe.** Give Terminal Accessibility access and dump Rekordbox's AX tree
   (script in this research; it came back empty only because Rekordbox wasn't running).

## Sources

- [rkbx_link](https://github.com/grufkork/rkbx_link) and its
  [MACOS_SETUP.md](https://github.com/grufkork/rkbx_link/blob/master/MACOS_SETUP.md) (memory reading, re-sign requirement, supported versions)
- [Now Playing: rekordbox source](https://nowplayingapp.com/help/guide/track-sources/rekordbox/) (reads `master.db`; Playback time lag; no deck numbers)
- [Now Playing: Rekordbox Library reference](https://nowplayingapp.com/help/reference/integrations/rekordbox/) (Playback time floor)
- [beat-link](https://github.com/Deep-Symmetry/beat-link) (Pro DJ Link; port conflicts with Rekordbox on the same machine)
- [rekordbox FAQ: Ableton Link](https://rekordbox.com/en/support/faq/ableton-link/) and a [user report on Link tempo](https://community.pioneerdj.com/hc/en-us/community/posts/22976380697753/comments/22984247507993)
- [pyrekordbox: analysis file format](https://pyrekordbox.readthedocs.io/en/latest/formats/anlz.html) (PQTZ, PSSI, PWV5)
- [pyflx4](https://pypi.org/project/pyflx4/) (DDJ-FLX4 MIDI map, cross-checked against Mixxx)
