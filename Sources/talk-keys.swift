// talk-keys — Menubar: pick speak (tap) + dictate (hold) modifiers.
// Defaults: Control tap speaks; Right Command hold dictates.
// Dictation uses Speech, then pastes into the focused app (incl. Warp/Grok PTYs).
import AppKit
import ApplicationServices
import AVFoundation
import Darwin
import Foundation
import Speech

private let leftControlKeyCode: Int64 = 59
private let rightControlKeyCode: Int64 = 62
private let leftOptionKeyCode: Int64 = 58
private let rightOptionKeyCode: Int64 = 61
private let leftCommandKeyCode: Int64 = 55
private let rightCommandKeyCode: Int64 = 54
private let fnKeyCode: Int64 = 63
private let escapeKeyCode: Int64 = 53
private let holdToDictate: TimeInterval = 0.2
private let recordTimeout: TimeInterval = 5
private let myPid = Int64(getpid())

private var speakModDown = false
private var speakModAlone = false
private var dictateModDown = false
private var dictateModAlone = false
private var isDictating = false
private var dictateHoldWork: DispatchWorkItem?
private var eventTap: CFMachPort?
private var recordTarget: RecordTarget = .none
private var recordDeadline: Date?
private var recordDownCode: Int64?

enum RecordTarget {
    case none
    case speak
    case dictate
}

enum HotKeyConfig {
    private static let ud = UserDefaults.standard
    private static let speakKey = "speakKeyCode"
    private static let dictateKey = "dictateKeyCode"
    /// false → match both Control keys until user picks one in the menubar.
    private static let speakExactKey = "speakExact"
    private static let dictateExactKey = "dictateExact"

    static var speakKeyCode: Int64 {
        get {
            let v = ud.object(forKey: speakKey) as? Int ?? Int(rightControlKeyCode)
            return Int64(v)
        }
        set {
            ud.set(Int(newValue), forKey: speakKey)
            ud.set(true, forKey: speakExactKey)
        }
    }

    static var dictateKeyCode: Int64 {
        get {
            let v = ud.object(forKey: dictateKey) as? Int ?? Int(rightCommandKeyCode)
            return Int64(v)
        }
        set {
            ud.set(Int(newValue), forKey: dictateKey)
            ud.set(true, forKey: dictateExactKey)
        }
    }

    static var speakExact: Bool { ud.bool(forKey: speakExactKey) }
    static var dictateExact: Bool { ud.bool(forKey: dictateExactKey) }

    static func isSpeakKey(_ code: Int64) -> Bool {
        if speakExact { return code == speakKeyCode }
        return code == leftControlKeyCode || code == rightControlKeyCode
    }

    static func isDictateKey(_ code: Int64) -> Bool {
        if dictateExact { return code == dictateKeyCode }
        return code == rightCommandKeyCode
    }

    static func displayName(for code: Int64) -> String {
        switch code {
        case leftControlKeyCode: return "Left ⌃"
        case rightControlKeyCode: return "Right ⌃"
        case leftOptionKeyCode: return "Left ⌥"
        case rightOptionKeyCode: return "Right ⌥"
        case leftCommandKeyCode: return "Left ⌘"
        case rightCommandKeyCode: return "Right ⌘"
        case fnKeyCode: return "fn"
        default: return "Key \(code)"
        }
    }

    static func speakLabel() -> String {
        if !speakExact { return "⌃ (L/R)" }
        return displayName(for: speakKeyCode)
    }

    static func dictateLabel() -> String {
        if !dictateExact { return "Right ⌘" }
        return displayName(for: dictateKeyCode)
    }

    static func isBindableModifier(_ code: Int64) -> Bool {
        switch code {
        case leftControlKeyCode, rightControlKeyCode,
             leftOptionKeyCode, rightOptionKeyCode,
             leftCommandKeyCode, rightCommandKeyCode,
             fnKeyCode:
            return true
        default:
            return false
        }
    }

    static func modifierMask(for code: Int64) -> CGEventFlags? {
        switch code {
        case leftControlKeyCode, rightControlKeyCode: return .maskControl
        case leftOptionKeyCode, rightOptionKeyCode: return .maskAlternate
        case leftCommandKeyCode, rightCommandKeyCode: return .maskCommand
        case fnKeyCode: return .maskSecondaryFn
        default: return nil
        }
    }

    static func modifierIsDown(code: Int64, flags: CGEventFlags) -> Bool {
        guard let mask = modifierMask(for: code) else { return false }
        return flags.contains(mask)
    }
}

final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var speakTitleItem: NSMenuItem?
    private var dictateTitleItem: NSMenuItem?
    private var recordTimeoutWork: DispatchWorkItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "ear", accessibilityDescription: "Talk Keys") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "TK"
            }
            button.toolTip = "Talk Keys"
        }
        let menu = NSMenu()
        let speakTitle = NSMenuItem(title: "Speak Key: \(HotKeyConfig.speakLabel())", action: nil, keyEquivalent: "")
        speakTitle.isEnabled = false
        menu.addItem(speakTitle)
        speakTitleItem = speakTitle

        let dictateTitle = NSMenuItem(title: "Dictate Key: \(HotKeyConfig.dictateLabel())", action: nil, keyEquivalent: "")
        dictateTitle.isEnabled = false
        menu.addItem(dictateTitle)
        dictateTitleItem = dictateTitle

        menu.addItem(NSMenuItem(
            title: "Set Speak Key…",
            action: #selector(setSpeakKey),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Set Dictate Key…",
            action: #selector(setDictateKey),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(NSMenuItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Talk Keys",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        for entry in menu.items where entry.action != nil {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
        refreshTitles()
    }

    func refreshTitles() {
        speakTitleItem?.title = "Speak Key: \(HotKeyConfig.speakLabel())"
        dictateTitleItem?.title = "Dictate Key: \(HotKeyConfig.dictateLabel())"
        statusMenuItem?.title = statusText()
        if recordTarget != .none {
            let which = recordTarget == .speak ? "speak" : "dictate"
            statusMenuItem?.title = "Recording \(which) — tap a modifier (Esc cancel)"
        }
    }

    private func statusText() -> String {
        let p = permissionState()
        if eventTap != nil, p.ax, p.listen {
            return "Status: armed"
        }
        if !p.ax { return "Status: need Accessibility" }
        if !p.listen { return "Status: need Input Monitoring" }
        return "Status: tap not armed"
    }

    @objc private func setSpeakKey() {
        beginRecord(.speak)
    }

    @objc private func setDictateKey() {
        beginRecord(.dictate)
    }

    @objc private func openAccessibility() {
        openPrivacyPane("Privacy_Accessibility")
        openPrivacyPane("Privacy_ListenEvent")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func beginRecord(_ target: RecordTarget) {
        cancelRecordTimeout()
        recordTarget = target
        recordDownCode = nil
        recordDeadline = Date().addingTimeInterval(recordTimeout)
        let work = DispatchWorkItem { [weak self] in
            guard recordTarget == target else { return }
            log("record: timeout")
            recordTarget = .none
            recordDownCode = nil
            self?.refreshTitles()
        }
        recordTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recordTimeout, execute: work)
        log("record: waiting for \(target == .speak ? "speak" : "dictate") modifier")
        refreshTitles()
    }

    func cancelRecording(reason: String) {
        cancelRecordTimeout()
        if recordTarget != .none {
            log("record: \(reason)")
        }
        recordTarget = .none
        recordDownCode = nil
        recordDeadline = nil
        refreshTitles()
    }

    private func cancelRecordTimeout() {
        recordTimeoutWork?.cancel()
        recordTimeoutWork = nil
    }

    func finishRecording(code: Int64) {
        guard HotKeyConfig.isBindableModifier(code) else {
            cancelRecording(reason: "unsupported key \(code)")
            return
        }
        switch recordTarget {
        case .speak:
            if HotKeyConfig.isDictateKey(code) && HotKeyConfig.dictateExact {
                cancelRecording(reason: "same as dictate key")
                return
            }
            if !HotKeyConfig.dictateExact && code == rightCommandKeyCode {
                cancelRecording(reason: "same as dictate key")
                return
            }
            HotKeyConfig.speakKeyCode = code
            log("record: speak → \(HotKeyConfig.displayName(for: code))")
        case .dictate:
            if HotKeyConfig.isSpeakKey(code) {
                cancelRecording(reason: "same as speak key")
                return
            }
            HotKeyConfig.dictateKeyCode = code
            log("record: dictate → \(HotKeyConfig.displayName(for: code))")
        case .none:
            return
        }
        cancelRecordTimeout()
        recordTarget = .none
        recordDownCode = nil
        recordDeadline = nil
        refreshTitles()
    }
}

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

func replayDictateKeyDown() {
    let code = CGKeyCode(HotKeyConfig.dictateKeyCode)
    guard let src = CGEventSource(stateID: .hidSystemState),
          let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let mask = HotKeyConfig.modifierMask(for: HotKeyConfig.dictateKeyCode)
    else { return }
    e.flags = mask
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
        log("dictate start (stream) \(Int(format.sampleRate))Hz")
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
        log("dictate stop «\(typed)»")
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
        if dictateModDown && dictateModAlone {
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

private func handleRecording(type: CGEventType, keycode: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .keyDown && keycode == escapeKeyCode {
        DispatchQueue.main.async {
            StatusItemController.shared.cancelRecording(reason: "cancelled")
        }
        return nil
    }
    guard type == .flagsChanged, HotKeyConfig.isBindableModifier(keycode) else {
        return Unmanaged.passUnretained(event)
    }
    let down = HotKeyConfig.modifierIsDown(code: keycode, flags: event.flags)
    if down {
        recordDownCode = keycode
        return Unmanaged.passUnretained(event)
    }
    if let pressed = recordDownCode, pressed == keycode {
        DispatchQueue.main.async {
            StatusItemController.shared.finishRecording(code: keycode)
        }
        recordDownCode = nil
        return Unmanaged.passUnretained(event)
    }
    return Unmanaged.passUnretained(event)
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

    if recordTarget != .none {
        if let deadline = recordDeadline, Date() > deadline {
            DispatchQueue.main.async {
                StatusItemController.shared.cancelRecording(reason: "timeout")
            }
        } else {
            return handleRecording(type: type, keycode: keycode, event: event)
        }
    }

    if type == .flagsChanged && HotKeyConfig.isSpeakKey(keycode) {
        let down = HotKeyConfig.modifierIsDown(code: keycode, flags: event.flags)
        if down && !speakModDown {
            speakModDown = true
            speakModAlone = true
            log("speak-key down \(HotKeyConfig.displayName(for: keycode))")
        } else if !down && speakModDown {
            speakModDown = false
            if speakModAlone {
                log("speak-key alone → speak")
                DispatchQueue.main.async { handleHotKey() }
            } else {
                log("speak-key chord (ignored)")
            }
            speakModAlone = false
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .flagsChanged && HotKeyConfig.isDictateKey(keycode) {
        let down = HotKeyConfig.modifierIsDown(code: keycode, flags: event.flags)
        if down && !dictateModDown {
            dictateModDown = true
            dictateModAlone = true
            log("dictate-key down \(HotKeyConfig.displayName(for: keycode))")
            DispatchQueue.main.async { scheduleDictateHold() }
            return nil
        }
        if !down && dictateModDown {
            dictateModDown = false
            cancelDictateHold()
            let wasChord = !dictateModAlone
            let dictating = isDictating
            dictateModAlone = false
            if dictating {
                DispatchQueue.main.async { stopDictation() }
                return nil
            }
            if wasChord {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }
        return nil
    }

    if type == .keyDown {
        if speakModDown {
            speakModAlone = false
        }
        if dictateModDown && !isDictating {
            dictateModAlone = false
            cancelDictateHold()
            replayDictateKeyDown()
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
        DispatchQueue.main.async { StatusItemController.shared.refreshTitles() }
        return
    }
    guard let tap = createTap() else {
        log("talk-keys: tap not created (need Accessibility)")
        DispatchQueue.main.async { StatusItemController.shared.refreshTitles() }
        return
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("talk-keys: speak=\(HotKeyConfig.speakLabel()) dictate=\(HotKeyConfig.dictateLabel()) armed")
    DispatchQueue.main.async { StatusItemController.shared.refreshTitles() }
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
    StatusItemController.shared.install()
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
                StatusItemController.shared.refreshTitles()
            }
        }
    }
}
app.run()
