# Okiru alarm audio

The audio files in this directory are bundled into every installed copy of
Okiru. They are used by AlarmKit, local notifications, previews, and the
foreground challenge player.

## Release requirements

- Use only audio licensed for commercial application distribution and
  redistribution inside the app bundle. "Royalty-free" does not necessarily
  mean "copyright-free" or permit redistribution.
- Keep the source URL, creator, license name/version, download date, proof of
  purchase or permission, and any required attribution in the private release
  evidence folder. Before making the Git repository public, verify that the
  license also permits public distribution of each original WAV file and its
  historical Git versions, not only inclusion in the App binary.
- Notification-compatible files must be AIFF, WAV, or CAF, use a supported
  system-sound encoding, and be shorter than 30 seconds. WAV is the current
  project convention.
- Normalize levels and listen on the iPhone speaker before release. Avoid a
  clipped first transient and leave a short seamless loop boundary because the
  foreground challenge repeats the file.

## Replacing the current six sounds without changing code

Convert six reviewed tracks to WAV and replace these exact files:

- `sunrise.wav`
- `bells.wav`
- `marimba.wav`
- `pulse.wav`
- `orbit.wav`
- `tide.wav`

Keeping these filenames preserves existing saved alarms. Update the
`sound.*` localized labels if the names shown to users should change. The
project generator discovers the WAV files in this directory and deliberately
does not overwrite them.

After replacement, regenerate the Xcode project, run the release checks, build
and sign a new app, install it on a physical iPhone, and test preview, AlarmKit,
local notification, foreground looping, and completion.
