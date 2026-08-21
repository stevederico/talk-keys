<div align="center">
  <img src="docs/characters/talku-banner.jpg" width="100%" alt="Talku">
  <h1 align="center" style="border-bottom: none; margin-bottom: 0;">Talk Keys</h1>
  <h3 align="center" style="margin-top: 0; font-weight: normal;">
    tap right option to speak · hold right command to dictate
  </h3>
  <p><em>the little speaker who reads what you highlight</em> · starring <strong>Talku</strong></p>
</div>

<br />

## 🚀 Quick Start

```bash
git clone https://github.com/stevederico/talk-keys.git
cd talk-keys
./scripts/talk-keys install
```

Turn on **Talk Keys** in:

1. System Settings → Privacy & Security → **Accessibility**
2. System Settings → Privacy & Security → **Input Monitoring**

If the toggles were already on from an older build, turn them **off then on**. Then:

```bash
talk-keys restart
```

Select text. Tap **Right Option** to hear it. Hold **Right Command** to dictate into the focused field.

Turn on **System Settings → Keyboard → Dictation**. Talk Keys starts/stops it with **Fn-D** (Apple’s shortcut).

<br />

## ✨ What's Included

### 🗣️ **Speak on a modifier tap**
- **Right Option alone** speaks the current highlight (or the clipboard)
- **Second tap** stops `say`
- **Option+key chords** still work (accents, Warp Alt on Left Option, menus)

### 🎙️ **Hold to dictate**
- **Hold Right Command ~200ms** starts macOS Dictation into the focused field
- **Release** stops Dictation
- **Cmd+C / Cmd+V** and other Right Command chords are unchanged (hold timer cancels)

### 🍡 **Talku**
- **Yuru-chara mascot** for the product (same idea as Snap Cat’s Snapu)
- **App icon** and README banner are Talku on white, flat 2D sticker art

### 🔒 **No third-party remappers**
- **Pure Swift** using AppKit, ApplicationServices, and Foundation
- **No Karabiner**, Homebrew, or Swift packages
- **macOS `say`** for speech (system voice)

### 🖥️ **Always on**
- **Talk Keys.app** at `~/Applications/Talk Keys.app` (menu-bar-less, `LSUIElement`)
- **LaunchAgent** `com.stevederico.talk-keys` starts at login and respawns
- **CLI** at `scripts/talk-keys` (dotfiles links this to `~/.local/bin/talk-keys`)

<br />

## 📖 How It Works

Right Option is a modifier. Carbon `RegisterEventHotKey` cannot bind a modifier alone, so Talk Keys installs a session `CGEventTap`.

1. **flagsChanged** on keycode `61` (`kVK_RightOption`): press starts an “alone” wait; any other keyDown while held cancels it.
2. **Release with no other key** copies the front app selection (`Cmd+C` via Accessibility) if needed, then reads the pasteboard.
3. **`/usr/bin/say`** speaks that text. A second Right Option tap runs `pkill -x say`.
4. **Right Command** (`54`) hold ~200ms with no other key posts **Fn-D** (start Dictation). Release posts Fn-D again (stop). A Command chord cancels the timer.

`listenOnly` taps can “succeed” with no events when TCC is missing. Talk Keys uses **`.defaultTap`** (returns nil without Accessibility) and keeps Option+key passthrough.

```swift
if type == .flagsChanged && keycode == 61 {
    // alone tap → speak; chord → ignore
}
```

Warp: enable **copy on select** (already in this machine’s Warp config) so a drag-select is on the clipboard before the tap.

<br />

## 🛠️ CLI

Linked to `~/.local/bin/talk-keys` by `~/.dotfiles/setup.sh`.

| Command | What it does |
|---|---|
| `talk-keys install` | Build app if source is newer, load LaunchAgent |
| `talk-keys restart` | Reload agent **without** rebuilding (keeps TCC grants) |
| `talk-keys start` | Same as restart |
| `talk-keys stop` | Unload the agent |
| `talk-keys status` | LaunchAgent + process + last log lines |
| `talk-keys doctor` | Status plus what a good log looks like |
| `talk-keys build` | Compile only |
| `talk-keys uninstall` | Unload agent, remove app + plist |

Env overrides:

| Variable | Default |
|---|---|
| `TALK_KEYS_ROOT` | repo root (directory above `scripts/`) |
| `TALK_KEYS_APP` | `~/Applications/Talk Keys.app` |

<br />

## ⚙️ Permissions

macOS treats keyboard taps and synthetic `Cmd+C` as two different TCC services.

| Pane | API | Why |
|---|---|---|
| **Accessibility** | `AXIsProcessTrusted` | Post `Cmd+C`; create a `.defaultTap` |
| **Input Monitoring** | `CGPreflightListenEventAccess` | Read key events system-wide |

Without Input Monitoring the daemon can look “armed” and still never see Right Option (the Warp / Grok failure mode).

On first launch with either grant missing, Talk Keys shows **Talk Keys Needs Permission** and opens the Settings panes. After you toggle, wait for:

```
talk-keys permissions AX=true ListenEvent=true
talk-keys: Right Option tap + Right Command hold armed
```

Recompile / re-sign changes the app CDHash and **drops both grants**. `talk-keys restart` does not rebuild on purpose. After a real `install` rebuild, toggle Talk Keys off/on in both panes, then `talk-keys restart`.

Also allow the agent in **Login Items** if macOS asks.

<br />

## 🔐 Privacy

Talk Keys is a local LaunchAgent. No network. No analytics. No account.

It **does** install a session keyboard tap (Input Monitoring) and may post `Cmd+C` or **Fn-D** (Accessibility). Right Option tap speaks local `say` audio. Right Command hold starts **macOS Dictation** (Apple’s service, into the focused field). Talk Keys does not upload audio itself.

Source of truth: `Sources/talk-keys.swift`.

<br />

## 🗂️ Layout

```
talk-keys/
├── Sources/talk-keys.swift          # daemon (event tap + say)
├── Resources/Info.plist             # bundle id com.stevederico.talk-keys
├── Resources/AppIcon.icns           # Finder / Login Items icon (Talku)
├── docs/characters/talku.jpg        # mascot master
├── docs/characters/talku-banner.jpg # README banner
├── scripts/talk-keys                # build / launchctl CLI
├── scripts/build-icons.sh           # talku.jpg → icns + banner
├── launchd/com.stevederico.talk-keys.plist
├── CHANGELOG.md
└── LICENSE
```

Runtime:

| Piece | Path |
|---|---|
| App | `~/Applications/Talk Keys.app` |
| Binary | `~/Applications/Talk Keys.app/Contents/MacOS/talk-keys` |
| Agent | `~/Library/LaunchAgents/com.stevederico.talk-keys.plist` |
| Log | `/tmp/talk-keys.log` |
| Legacy symlink | `~/.cache/talk-keys` → app binary |

Launchd runs `/usr/bin/open -W -n -g -a Talk Keys.app` so the process inherits the **app’s** TCC identity. Pointing launchd at the Mach-O inside `Contents/MacOS` often yields `AX=false`.

<br />

## 🧩 Tech Stack

| Technology | Version | Purpose |
|---|---|---|
| **Swift** | Apple Swift (`xcrun swiftc`) | Daemon |
| **AppKit** | system | Accessory app, permission alert |
| **ApplicationServices** | system | Event tap, Accessibility, ListenEvent |
| **say** | `/usr/bin/say` | Speech |
| **launchd** | macOS 13+ | Login + KeepAlive |

No Package.swift. No CocoaPods. No Homebrew.

<br />

## 🧪 Logs

```bash
tail -f /tmp/talk-keys.log
```

Healthy tap:

```
talk-keys permissions AX=true ListenEvent=true
talk-keys: Right Option tap + Right Command hold armed
right-option down
right-option alone → speak
speak 128 chars
right-command hold → dictate start
right-command hold → dictate stop
```

| Line | Meaning |
|---|---|
| `AX=false` / `ListenEvent=false` | Grant missing; tap will not see keys |
| `tap not created` | Accessibility off |
| `empty` | Nothing selected and clipboard empty |
| `right-option chord (ignored)` | You held Option and pressed another key |
| `stop` | Second tap killed `say` |

<br />

## 🔧 Troubleshooting

**Tap does nothing in Warp or Grok**
- `talk-keys status` must show `AX=true ListenEvent=true` **and** `Right Option tap + Right Command hold armed`
- Toggle Talk Keys in Accessibility **and** Input Monitoring, then `talk-keys restart` (not `install`)
- Drag-select in Warp (`copy_on_select`); a keyboard caret is not a selection

**It worked, then died after I pulled**
- `install` rebuilt the binary and TCC dropped. Re-grant both panes, `talk-keys restart`

**Option+S / accents broke**
- Only a **bare** Right Option tap speaks. Left Option is untouched. Warp still maps Left Option to Alt.

**Login Items blocked it**
- System Settings → General → Login Items → allow Talk Keys

**Duplicate processes**
- `talk-keys restart` unloads the agent and `pkill -x talk-keys`

<br />

## 🔗 Related

- **[Snap Cat](https://github.com/stevederico/snapcat)** — sibling macOS utility; mascot **Snapu**
- This repo is standalone. `./scripts/talk-keys install` is enough. A local dotfiles tree may also link the CLI.

<br />

## 📄 License

[MIT License](LICENSE)

<br />

<div align="center">
  <sub>Built with Swift and macOS say. No Karabiner. Starring Talku.</sub>
</div>
