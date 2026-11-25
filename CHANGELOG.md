# Changelog

## Unreleased

- **City geo:** a little Manhattan to look down on, a tile of blocks sized by width and length, with stepped-back towers, water towers, parks, a river with piers, street lamps, crosswalks, cars that stop at red lights and people who cross at the corners. Lights Change and Reshuffle trigger inputs.
- **Generator trigger inputs:** a generator's shader can declare `// @trigger name Label`; it reads how many times it has fired as `p.<name>Count`.

## 1.3.0 (2026-11-16)

- **Shoes geo:** a pair of low-poly high-tops dancing a 32-beat routine, with a Sync clock input so it follows the beat.
- **Instruments geo:** a drum kit, saxophone, trumpet and trombone with nobody playing them, and a knob for each thing a player would do.
- **Opacity on every geo:** fades the whole generator, background included, into what's drawn before it.
- **Video · Restart:** a trigger input that starts the video again from its in point.
- **Sidebar order and folders:** drag scenes and playlists to reorder them or put them in folders. Kept in the library's `Sidebar.json`.
- **Browser:** a tool's presets stay folded until opened.
- Removing a tool now removes its mappings with it.

## 1.2.0 (2026-11-16)

- **Ridges geo.**
- **Toggle modulator.**
- **Spectrum history:** spectrum outputs carry their last four seconds.
- Video on the Street geo.
- Fixed a video's length being read wrong.
- MIDI: every message in a packet is read, not just the first.

## 1.1.0 (2026-11-13)

- Renamed the app to Jim Viz.
- **Shrek geo.**
- A bigger app icon.
- CI checks and builds every push and pull request.

## 1.0.0 (2026-11-10)

- First release.
