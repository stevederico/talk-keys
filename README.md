<div align="center">
  <img src="docs/characters/talku-banner.jpg" width="100%" alt="Talku">
  <h1 align="center" style="border-bottom: none; margin-bottom: 0;">Talk Keys</h1>
  <h3 align="center" style="margin-top: 0; font-weight: normal;">
    menubar picks your keys · control tap speaks · right command hold dictates
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

Turn on **Talk Keys** in **both** panes (not optional):

1. System Settings → Privacy & Security → **Accessibility**
2. System Settings → Privacy & Security → **Input Monitoring**

Accessibility off → `tap not created`. Input Monitoring off → the tap never sees your hotkeys. If the toggles were already on from an older build, turn them **off then on**. Then:

```bash
talk-keys restart
```

`talk-keys status` must show `AX=true ListenEvent=true` and `speak=… dictate=… armed`. Toggles do not attach to the already-running process until restart.

macOS will ask to allow a Background Item named **open**. That **is** Talk Keys (launchd runs `/usr/bin/open` so TCC sticks to the app). Allow it. Deny it and Talk Keys will not start at login.

Look for the **ear** icon in the menu bar. Defaults: tap **Control** (left or right) to speak; hold **Right Command** to dictate. Use **Set Speak Key…** / **Set Dictate Key…** if your board has no Option (e.g. `space · ⌘ · fn · ctrl`).

Allow **Microphone** and **Speech Recognition** when prompted. Hold types into Warp, Grok, and other PTYs (system Dictation only fills AppKit text views).

<br />

## ✨ What's Included

### 🗣️ **Speak on a modifier tap**
- **Control alone** (left or right by default) speaks the current highlight (or the clipboard)
- Rebind any modifier from the menubar (**Set Speak Key…**)
- **Second tap** stops playback (`afplay` / `say`)
- Modifier+key chords are ignored for speak
- Speaks via **dottie-talk koko** when available; else Apple `say`

### 🎙️ **Hold to dictate**
- **Hold Right Command ~200ms** records; words **type as they are recognized**; release finalizes
- Uses Apple **Speech** (on-device when available), then pastes into the front app (Warp / Grok)
- **Cmd+C / Cmd+V** and other Right Command chords are unchanged (hold timer cancels)

### 🍡 **Talku**
- **Yuru-chara mascot** for the product (same idea as Snap Cat’s Snapu)
- **App icon** and README banner are Talku on white, flat 2D sticker art

### 🔒 **No third-party remappers**
- **Pure Swift** using AppKit, ApplicationServices, and Foundation
- **No Karabiner**, Homebrew, or Swift packages
- **macOS `say`** fallback when dottie-talk/koko is down; prefers local **koko** TTS (`:1314`)
- **Dictate** still Apple Speech (not parakeet)

### 🖥️ **Always on**
- **Talk Keys.app** at `~/Applications/Talk Keys.app` (menu-bar-less, `LSUIElement`)
- **LaunchAgent** `com.stevederico.talk-keys` starts at login and respawns
- **Login Items** lists this as **open**, not Talk Keys. Leave it on.
- **CLI** at `scripts/talk-keys` (put it on PATH)

<br />

## 📖 How It Works

Speak/dictate keys are modifiers. Carbon `RegisterEventHotKey` cannot bind a modifier alone, so Talk Keys installs a session `CGEventTap`.

1. **flagsChanged** on keycode `61` (`kVK_RightOption`): press starts an “alone” wait; any other keyDown while held cancels it.
2. **Release with no other key** reads AX selected text, then the pasteboard. In a browser it may post `Cmd+C` to the front app. In Ghostty / Warp / other terminals it does **not** copy — Grok’s Copied toast already filled the pasteboard, and a synthetic `Cmd+C` overwrites it with the page URL.
3. Speaks via **dottie-talk** koko (`POST :1314/v1/audio/speech` → `afplay`). If koko is down, Talk Keys starts `~/Projects/dottie-talk/ensure-tts.js` (or `bin/koko`) once, then falls back to `/usr/bin/say`. A second speak-key tap stops playback. URL-only strings and full-window AX dumps are skipped.
4. **Right Command** (`54`) hold ~200ms starts Speech recognition. New words are pasted into the front app (Warp PTY), not typed as HID unicode.

`listenOnly` taps can “succeed” with no events when TCC is missing. Talk Keys uses **`.defaultTap`** (returns nil without Accessibility) and keeps Option+key passthrough.

```swift
if type == .flagsChanged && keycode == 61 {
    // alone tap → speak; chord → ignore
}
```

Warp: enable **copy on select** (already in this machine’s Warp config) so a drag-select is on the clipboard before the tap.

<br />

## 🛠️ CLI

```bash
ln -sfn "$(pwd)/scripts/talk-keys" ~/.local/bin/talk-keys
```

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

Without Input Monitoring the daemon can look “armed” and still never see hotkeys (the Warp / Grok failure mode). Accessibility off is louder: `tap not created`.

On first launch with either grant missing, Talk Keys shows **Talk Keys Needs Permission** and opens the Settings panes. Toggle Talk Keys off/on in **both** panes, then `talk-keys restart`. The running process keeps `AX=false` until it relaunches. Wait for:

```
talk-keys permissions AX=true ListenEvent=true
talk-keys: speak=⌃ (L/R) dictate=Right ⌘ armed
```

Recompile / re-sign changes the app CDHash and **drops both grants**. `talk-keys restart` does not rebuild on purpose. After a real `install` rebuild, toggle Talk Keys off/on in both panes, then `talk-keys restart`.

**Login Items:** System Settings → General → Login Items & Extensions → Allow in the Background. The item is named **open** (not Talk Keys). Allow it. `AssociatedBundleIdentifiers` does not rename it.

<br />

## 🔐 Privacy

Talk Keys is a local LaunchAgent. No network. No analytics. No account.

It **does** install a session keyboard tap (Input Monitoring), may post `Cmd+C`, and uses the **microphone** for hold-to-dictate. Speech is on-device when the recognizer supports it. Transcripts are typed locally. No Talk Keys network.

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

Launchd runs `/usr/bin/open -W -n -a Talk Keys.app` so the process inherits the **app’s** TCC identity. Pointing launchd at the Mach-O inside `Contents/MacOS` often yields `AX=false`. That is also why Background Items shows **open**. Do not pass `-g` or the TCC prompt stays hidden.

<br />

## 🧩 Tech Stack

| Technology | Version | Purpose |
|---|---|---|
| **Swift** | Apple Swift (`xcrun swiftc`) | Daemon |
| **AppKit** | system | Accessory app, permission alert |
| **ApplicationServices** | system | Event tap, Accessibility, ListenEvent |
| **say** | `/usr/bin/say` | Speech |
| **launchd** | macOS 13+ | Login start (no KeepAlive — Quit stays quit) |

No Package.swift. No CocoaPods. No Homebrew.

<br />

## 🧪 Logs

```bash
tail -f /tmp/talk-keys.log
```

Healthy tap:

```
talk-keys permissions AX=true ListenEvent=true
talk-keys: speak=⌃ (L/R) dictate=Right ⌘ armed
right-option down
right-option alone → speak
speak clip 128 chars «hello from grok»
right-command hold → dictate start
right-command hold → dictate stop
```

| Line | Meaning |
|---|---|
| `AX=false` / `ListenEvent=false` | Grant missing, or grants not yet picked up (restart) |
| `tap not created` | Accessibility off; Input Monitoring is a separate pane |
| `empty` | Nothing selected, clipboard empty, or only a URL / full-window dump |
| `right-option chord (ignored)` | You held Option and pressed another key |
| `stop` | Second tap killed `say` |

<br />

## 🔧 Troubleshooting

**It says https://x.com / reads the screen**
- Grok in-app copy already put the text on the pasteboard. An old Talk Keys then sent `Cmd+C` and Chrome/Brave with no native selection copied the page URL.
- 0.26.0 skips URL-only and full-window AX dumps, and never `Cmd+C` in terminals. Rebuild, re-grant both TCC panes, `talk-keys restart`.

**Tap does nothing (including Warp / Grok)**
- `talk-keys status` must show `AX=true ListenEvent=true` **and** `speak=… dictate=… armed`
- Menubar ear icon: **Set Speak Key…** / **Set Dictate Key…** to rebind
- Need **both** Accessibility and Input Monitoring. One pane is not enough.
- Toggle Talk Keys off/on in both panes, then `talk-keys restart` (not `install`)
- Drag-select in Warp (`copy_on_select`); a keyboard caret is not a selection
- In Grok: copy first (toast Copied), then tap the speak key. Shift-drag is the terminal’s native copy.

**Tap does nothing after install (AX=false)**
- The permission alert used to block the main thread and stay hidden (`open -g`). 0.27.0 opens both panes and polls. Toggle Talk Keys **off then on** in Accessibility **and** Input Monitoring, then `talk-keys restart`.

**It worked, then died after I pulled**
- `install` rebuilt the binary and TCC dropped. Re-grant both panes, `talk-keys restart`

**Option+S / accents broke**
- Only a **bare** speak-key tap speaks. Defaults are Control (no Option required). Boards like `space · ⌘ · fn · ctrl` use **Right ⌃** for speak and **Right ⌘** hold for dictate.

**Login Items shows open / I denied it**
- That item **is** Talk Keys. Re-enable **open** under Allow in the Background, then `talk-keys restart`
- It will not start at the next login until that toggle is on

**Duplicate processes**
- `talk-keys restart` unloads the agent and `pkill -x talk-keys`

<br />

## 🔗 Related

- **[Snap Cat](https://github.com/stevederico/snapcat)** — sibling macOS utility; mascot **Snapu**
- This repo is standalone. `./scripts/talk-keys install` is enough. Symlink `scripts/talk-keys` onto PATH for the CLI.

<br />

## 📄 License

[MIT License](LICENSE)

<br />

<div align="center">
  <sub>Built with Swift and macOS say. No Karabiner. Starring Talku.</sub>
</div>
