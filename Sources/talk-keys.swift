// talk-keys — Option tap (left or right) speaks the highlight.
// Right Command hold dictates. Dictation uses Speech (on-device when it can),
// then pastes into the focused app (Warp/Grok PTYs ignore macOS Dictation).
import AppKit
import ApplicationServices
import AVFoundation
import Darwin
import Foundation
import Speech

private let rightOptionKeyCode: Int64 = 61 // kVK_RightOption
private let leftOptionKeyCode: Int64 = 58 // kVK_Option
private let rightCommandKeyCode: Int64 = 54 // kVK_RightCommand
private let holdToDictate: TimeInterval = 0.2
private let myPid = Int64(getpid())

private var optionDown = false
private var optionAlone = false
private var rightCommandDown = false
private var rightCommandAlone = false
private var isDictating = false
private var dictateHoldWork: DispatchWorkItem?
private var eventTap: CFMachPort?

func sayRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-xq", "say"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func clipboardString() -> String {
    (NSPasteboard.general.string(forType: .string) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Address-bar / Chrome-no-selection copy, or a full AX dump of the window.
func isJunkSpeak(_ s: String) -> Bool {
    if s.isEmpty { return true }
    if s.count > 4000 { return true }
    if s.contains(where: \.isWhitespace) { return false }
    return s.hasPrefix("http://") || s.hasPrefix("https://")
}

func isTerminalFront() -> Bool {
    switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
    case "com.mitchellh.ghostty",
         "dev.warp.Warp-Stable",
         "dev.warp.Warp",
         "com.googlecode.iterm2",
         "com.apple.Terminal",
         "net.kovidgoyal.kitty",
         "com.github.wez.wezterm",
         "org.alacritty":
        return true
    default:
        return false
    }
}

func axSelectedText() -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != pid_t(getpid()) else { return nil }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused,
          CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    let el = unsafeBitCast(focused, to: AXUIElement.self)
    var selected: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selected) == .success
    else { return nil }
    let s = (selected as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if s.isEmpty { return nil }
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
       let v = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       v == s, s.count > 80
    {
        return nil
    }
    if isJunkSpeak(s) { return nil }
    return s
}

func pressCopy() {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false) else { return }
    down.flags = .maskCommand
    up.flags = .maskCommand
    if let pid = targetPid() {
        down.postToPid(pid)
        up.postToPid(pid)
    } else {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

func speak(_ text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    let pipe = Pipe()
    p.standardInput = pipe
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    if let data = text.data(using: .utf8) {
        try? pipe.fileHandleForWriting.write(contentsOf: data)
    }
    try? pipe.fileHandleForWriting.close()
}

func cancelDictateHold() {
    dictateHoldWork?.cancel()
    dictateHoldWork = nil
}

func targetPid() -> pid_t? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    if pid == pid_t(getpid()) { return nil }
    return pid
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    if let pid = targetPid() {
        down.postToPid(pid)
        up.postToPid(pid)
    } else {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

func pasteToFront(_ string: String) {
    guard !string.isEmpty else { return }
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(string, forType: .string)
    postKey(0x09, flags: .maskCommand)
}

func replayRightCommandDown() {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let e = CGEvent(keyboardEventSource: src, virtualKey: 0x36, keyDown: true) else { return }
    e.flags = .maskCommand
    e.post(tap: .cghidEventTap)
}

func typeUTF16(_ string: String) {
    pasteToFront(string)
}

func backspaceChars(_ n: Int) {
    guard n > 0 else { return }
    for _ in 0..<n { postKey(0x33) }
}

func streamDictate(_ next: String, typed: inout String) {
    if next == typed { return }
    let prefix = zip(typed, next).prefix(while: { $0 == $1 }).count
    backspaceChars(typed.count - prefix)
    let suffix = String(next.dropFirst(prefix))
    if !suffix.isEmpty {
        let pid = targetPid() ?? 0
        log("dictate +\(suffix) pid=\(pid)")
        pasteToFront(suffix)
    }
    typed = next
}

final class DictateEngine {
    static let shared = DictateEngine()

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    private var typed = ""
    private var live = false
    /// Bumps on stop so late mic/speech callbacks never start after release.
    private var epoch: UInt64 = 0

    func start() {
        lastText = ""
        typed = ""
        live = false
        let startEpoch = epoch
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            guard mic else {
                log("dictate: microphone denied — enable Talk Keys in Privacy → Microphone")
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard self.epoch == startEpoch else { return }
                    guard status == .authorized, let recognizer = self.recognizer, recognizer.isAvailable else {
                        log("dictate: speech not authorized (\(status.rawValue))")
                        return
                    }
                    self.begin(recognizer, startEpoch: startEpoch)
                }
            }
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer, startEpoch: UInt64) {
        guard epoch == startEpoch else { return }
        task?.cancel()
        task = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device when available, but do not require it — BT mics often
        // return empty transcripts when requiresOnDeviceRecognition is forced.
        self.request = request
        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log("dictate: bad input format rate=\(format.sampleRate) ch=\(format.channelCount)")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            log("dictate: audio \(error.localizedDescription)")
            return
        }
        guard epoch == startEpoch else {
            audioEngine.stop()
            input.removeTap(onBus: 0)
            return
        }
        live = true
        log("right-command hold → dictate start (stream) \(Int(format.sampleRate))Hz")
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.live else { return }
                if let result {
                    let next = result.bestTranscription.formattedString
                    self.lastText = next
                    streamDictate(next, typed: &self.typed)
                }
                if let error {
                    log("dictate: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        epoch &+= 1
        live = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        streamDictate(lastText, typed: &typed)
        log("right-command hold → dictate stop «\(typed)»")
        lastText = ""
        typed = ""
    }
}

func startDictation() {
    guard !isDictating else { return }
    isDictating = true
    DictateEngine.shared.start()
}

func stopDictation() {
    guard isDictating else { return }
    isDictating = false
    DictateEngine.shared.stop()
}

func scheduleDictateHold() {
    cancelDictateHold()
    let work = DispatchWorkItem {
        if rightCommandDown && rightCommandAlone {
            startDictation()
        }
    }
    dictateHoldWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + holdToDictate, execute: work)
}

func speakNow(_ text: String, via: String) {
    let preview = text.prefix(60).replacingOccurrences(of: "\n", with: " ")
    log("speak \(via) \(text.count) chars «\(preview)»")
    speak(text)
}

func handleHotKey() {
    if sayRunning() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", "say"]
        try? p.run()
        p.waitUntilExit()
        log("stop")
        return
    }
    let before = clipboardString()
    let ax = axSelectedText()
    // Grok/Warp already copied. Cmd+C here overwrites with the page URL or nothing.
    if isTerminalFront() {
        if !isJunkSpeak(before) {
            speakNow(before, via: "clip")
            return
        }
        if let ax {
            speakNow(ax, via: "AX")
            return
        }
        log("empty")
        return
    }
    if let ax {
        speakNow(ax, via: "AX")
        return
    }
    if AXIsProcessTrusted() {
        pressCopy()
        Thread.sleep(forTimeInterval: 0.25)
    }
    let after = clipboardString()
    if !isJunkSpeak(after) {
        let via = after == before ? "clip" : "copied"
        speakNow(after, via: via)
        return
    }
    if !isJunkSpeak(before) {
        speakNow(before, via: "clip")
        return
    }
    log("empty")
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("talk-keys tap re-enabled")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let srcPid = event.getIntegerValueField(.eventSourceUnixProcessID)
    if srcPid == myPid {
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)

    // Left Command only (right Command is dictate).
    if type == .flagsChanged && keycode == 55 {
        if event.flags.contains(.maskCommand) { log("left-command (ignored — use Right Command)") }
        return Unmanaged.passUnretained(event)
    }

    // Either Option — some boards have no Right ⌥ (space · ⌘ · fn · ctrl).
    if type == .flagsChanged && (keycode == rightOptionKeyCode || keycode == leftOptionKeyCode) {
        let side = keycode == rightOptionKeyCode ? "right" : "left"
        let down = event.flags.contains(.maskAlternate)
        if down && !optionDown {
            optionDown = true
            optionAlone = true
            log("\(side)-option down")
        } else if !down && optionDown {
            optionDown = false
            if optionAlone {
                log("\(side)-option alone → speak")
                DispatchQueue.main.async { handleHotKey() }
            } else {
                log("\(side)-option chord (ignored)")
            }
            optionAlone = false
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .flagsChanged && keycode == rightCommandKeyCode {
        if !rightCommandDown {
            rightCommandDown = true
            rightCommandAlone = true
            log("right-command down")
            DispatchQueue.main.async { scheduleDictateHold() }
            return nil
        }
        rightCommandDown = false
        cancelDictateHold()
        let wasChord = !rightCommandAlone
        let dictating = isDictating
        rightCommandAlone = false
        if dictating {
            DispatchQueue.main.async { stopDictation() }
            return nil
        }
        if wasChord {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    if type == .keyDown {
        if optionDown {
            optionAlone = false
        }
        if rightCommandDown && !isDictating {
            rightCommandAlone = false
            cancelDictateHold()
            replayRightCommandDown()
        }
    }

    return Unmanaged.passUnretained(event)
}

func openPrivacyPane(_ anchor: String) {
    let urls = [
        "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
    ]
    for s in urls {
        if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
    }
}

let mask =
    (1 << CGEventType.flagsChanged.rawValue)
    | (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.tapDisabledByTimeout.rawValue)
    | (1 << CGEventType.tapDisabledByUserInput.rawValue)

func createTap() -> CFMachPort? {
    CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: eventTapCallback,
        userInfo: nil
    )
}

func log(_ s: String) {
    fputs(s + "\n", stderr)
    fflush(stderr)
}

func armTap() {
    if let existing = eventTap {
        CGEvent.tapEnable(tap: existing, enable: true)
        return
    }
    guard let tap = createTap() else {
        log("talk-keys: tap not created (need Accessibility)")
        return
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("talk-keys: Option tap (L/R) + Right Command hold armed")
}

func permissionState() -> (ax: Bool, listen: Bool) {
    (AXIsProcessTrusted(), CGPreflightListenEventAccess())
}

func promptIfNeeded() {
    let p = permissionState()
    log("talk-keys permissions AX=\(p.ax) ListenEvent=\(p.listen)")
    if p.ax && p.listen {
        armTap()
        return
    }
    // Do not runModal: that blocked the retry timer, and open -g hid the alert.
    openPrivacyPane("Privacy_Accessibility")
    openPrivacyPane("Privacy_ListenEvent")
    _ = CGRequestListenEventAccess()
    _ = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    )
    armTap()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async {
    promptIfNeeded()
    if eventTap == nil {
        var last = ""
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            let p = permissionState()
            if p.ax && p.listen {
                armTap()
                if eventTap != nil { t.invalidate() }
                return
            }
            let line = "AX=\(p.ax) ListenEvent=\(p.listen)"
            if line != last {
                log("talk-keys waiting \(line) — toggle Talk Keys off/on in both panes")
                last = line
            }
        }
    }
}
app.run()
