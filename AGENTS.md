# AGENTS.md

macOS LaunchAgent. **Menubar** picks speak/dictate modifiers (defaults: **Control tap** speaks, **Right Command hold** dictates). Works on boards with no Option key.

Pure Swift. Apple frameworks only. No Karabiner. No SPM. No Homebrew.

## Layout

| Path | What |
|---|---|
| `Sources/talk-keys.swift` | Daemon (event tap, dottie-talk/koko or `say`, Speech, paste) |
| `scripts/talk-keys` | `build` / `install` / `restart` / `status` / `doctor` |
| `scripts/build-icons.sh` | Talku art → `AppIcon.icns` (needs Pillow; committed icons are enough) |
| `Resources/` | `Info.plist`, `AppIcon.icns` |
| `launchd/com.stevederico.talk-keys.plist` | **Sample only** (`/Users/you/…`). Install writes a real file under `~/Library/LaunchAgents/` |
| `docs/characters/` | Talku master / banner |

Runtime: `~/Applications/Talk Keys.app`, log `/tmp/talk-keys.log`, label `com.stevederico.talk-keys`.

## Commands

```bash
./scripts/talk-keys install    # rebuild if source newer, load agent
./scripts/talk-keys restart    # reload only — does not rebuild (keeps TCC)
./scripts/talk-keys status
tail -f /tmp/talk-keys.log
```

`restart` must not compile. Re-sign drops Accessibility + Input Monitoring.

## Landmines

- Launchd runs `/usr/bin/open -W -n -a Talk Keys.app` so TCC attaches to the **app**. Direct `Contents/MacOS/talk-keys` often starts with `AX=false` (tap armed, no keys). Do not pass `-g` (hides the TCC prompt).
- **Background Items shows `open`, not Talk Keys.** That item is this agent. Deny it and login start dies. Re-enable: System Settings → General → Login Items & Extensions → Allow in the Background → **open**. `AssociatedBundleIdentifiers` does not rename it.
- Need **both** Accessibility and Input Monitoring. AX off → `tap not created`. ListenEvent off → tap exists, no hotkeys. After toggling, `talk-keys restart`. The live process keeps `AX=false` until relaunch. `status` must show both true **and** `armed`.
- **KeepAlive is off.** Menubar Quit stays quit until login or `talk-keys start` / `restart`. Do not turn KeepAlive back on.
- Never `NSAlert.runModal` for TCC: it blocked the retry timer, and launchd `open -g` hid the alert so grants never attached.
- Adhoc sign only (`codesign -s -`). Recompile drops both TCC panes.
- Never write the live plist through a **symlink** into this repo (bakes `$HOME` into git). `write_plist` deletes a dest symlink first. Sample path stays `/Users/you/…`.
- **Speak:** Prefer **dottie-talk** koko on `:1314` (auto-spawn `ensure-tts.js` / `bin/koko` from `~/Projects/dottie-talk` when down). Fall back to `/usr/bin/say`. Second speak-key tap stops `afplay`/`say`. AX selected text (skip URL-only / full-control dumps), then clipboard. In terminals (Ghostty, Warp, …) **never `Cmd+C`** — Grok’s Copied toast already wrote the pasteboard; a synthetic copy clobbers it with `https://x.com` or empty. `Cmd+C` only for non-terminals, still to the front app pid.
- **Dictate:** Speech framework (mic + speech TCC), stream by **pasting** `Cmd+V` to the front pid. HID unicode / system Dictation do not reach PTYs. Swallow the dictate modifier while dictating or injected keys become chords.
- **Menubar:** Set Speak Key… / Set Dictate Key… records next alone-modifier; UserDefaults `speakKeyCode` / `dictateKeyCode`. Defaults Control (L/R) + Right Command.
- Modifier-alone = `CGEventTap` `.defaultTap` (not Carbon hotkeys, not `listenOnly`).
- Do not add Karabiner, crates, or npm. Do not claim `~/.dotfiles/setup.sh` links the CLI unless it actually does.

## Permissions

Need all of: Accessibility, Input Monitoring, Microphone, Speech Recognition. First two are required for speak; last two for dictate. After a rebuild **or** after the user toggles the panes, `talk-keys restart` (do not rebuild). Off/on in both panes if the checkboxes were already listed.

## Versioning

Minor bump default (`CHANGELOG.md` + `Info.plist` + git tag). Patch only for hotfixes. No AI attribution in commits.

## Docs

Humans: `README.md`. This file is for agents. `CLAUDE.md` → `AGENTS.md`.
