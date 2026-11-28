# Rounded notification sounds

The desktop app plays a compact set of rounded cues (`apps/nano/src/sound.zig`,
which embeds the copies in `apps/nano/src/sounds/`; the same files are in
`apps/nano/assets/sounds/`):

- [`done.wav`](../../apps/nano/assets/sounds/done.wav): completion, settling
  rounded pair.
- [`request.wav`](../../apps/nano/assets/sounds/request.wav): agent question,
  rising rounded pair.
- [`attention.wav`](../../apps/nano/assets/sounds/attention.wav): failure or
  durable disconnection, restrained downward rounded pair.
- [`attach.wav`](../../apps/nano/assets/sounds/attach.wav): a file or image
  landing in the composer.
- [`appshot.wav`](../../apps/nano/assets/sounds/appshot.wav): the Appshot cue.

The WAVs are checked in; no generator script is in the repository.

Settings → Notifications has a master **Session sounds** switch and independent
choices for **Task completed**, **Input required** and **Errors and
disconnections**. **Attaching files** has its own switch, outside Session
sounds. Appshots keep their independent **Capture sound** setting on the
Appshots page.

## Additional auditions

[Ten additional variants](auditions/README.md) cover send, queue, upload ready,
completion, questions, attention, microphone on/off, reconnection and undo. Only
the attention audition is promoted to an application asset; the rest remain
references without triggers.

Earlier click-only alternatives: [completion](auditions/done-minimal.wav) and
[agent question](auditions/request-minimal.wav).

All ten were synthesized from original rounded pressure pulses, with no
external samples.
