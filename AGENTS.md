# AGENTS.md

macOS LaunchAgent. **Right Option tap** speaks the selection. **Right Command hold** dictates into the focused app (including Warp / Grok PTYs).

Pure Swift. Apple frameworks only. No Karabiner. No SPM. No Homebrew.

## Layout

| Path | What |
|---|---|
| `Sources/talk-keys.swift` | Daemon (event tap, `say`, Speech, paste) |
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

- Launchd runs `/usr/bin/open -W -n -g -a Talk Keys.app` so TCC attaches to the **app**. Direct `Contents/MacOS/talk-keys` often starts with `AX=false` (tap armed, no keys). Background Items then show **open**.
- Never write the live plist through a **symlink** into this repo (bakes `$HOME` into git). `write_plist` deletes a dest symlink first. Sample path stays `/Users/you/…`.
- **Speak:** AX selected text, then `Cmd+C` **to the front app pid**, then clipboard. Global HID copy misses Warp.
- **Dictate:** Speech framework (mic + speech TCC), stream by **pasting** `Cmd+V` to the front pid. HID unicode / system Dictation do not reach PTYs. Swallow Right Command while dictating or injected keys become Cmd+chords.
- Modifier-alone = `CGEventTap` `.defaultTap` (not Carbon hotkeys, not `listenOnly`).
- Do not add Karabiner, crates, or npm.

## Permissions

Need all of: Accessibility, Input Monitoring, Microphone, Speech Recognition. After a rebuild, toggle Talk Keys off/on in the first two, then `talk-keys restart`.

## Versioning

Minor bump default (`CHANGELOG.md` + `Info.plist` + git tag). Patch only for hotfixes. No AI attribution in commits.

## Docs

Humans: `README.md`. This file is for agents. `CLAUDE.md` → `AGENTS.md`.
