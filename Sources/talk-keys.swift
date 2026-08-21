// talk-keys — Right Option tap speaks the highlight. Right Command hold dictates.
// Dictation uses Speech (on-device when it can), then types into the focused app
// (Warp/Grok PTYs ignore macOS Dictation’s NSText insert).
import AppKit
import ApplicationServices
import AVFoundation
import Darwin
import Foundation
import Speech

private let rightOptionKeyCode: Int64 = 61 // kVK_RightOption
private let rightCommandKeyCode: Int64 = 54 // kVK_RightCommand
private let holdToDictate: TimeInterval = 0.2
private let myPid = Int64(getpid())

private var rightOptionDown = false
private var rightOptionAlone = false
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

func pressCopy() {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false) else { return }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
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

func hidSource() -> CGEventSource? {
    CGEventSource(stateID: .privateState)
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    guard let src = hidSource(),
          let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func replayRightCommandDown() {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let e = CGEvent(keyboardEventSource: src, virtualKey: 0x36, keyDown: true) else { return }
    e.flags = .maskCommand
    e.post(tap: .cghidEventTap)
}

private let letterKeys: [Character: CGKeyCode] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
    "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
    "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
    "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23,
    "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
    "-": 0x1B, "=": 0x18, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C,
]

func typeUTF16(_ string: String) {
    guard !string.isEmpty else { return }
    for ch in string {
        if ch == " " { postKey(0x31); continue }
        if ch == "\n" { postKey(0x24); continue }
        if let lower = ch.lowercased().first, let code = letterKeys[lower] {
            postKey(code, flags: ch.isUppercase ? .maskShift : [])
            continue
        }
        guard let src = hidSource(),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        let units = Array(String(ch).utf16)
        units.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: p)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: p)
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
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
        fputs("dictate +\(suffix)\n", stderr)
        typeUTF16(suffix)
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

    func start() {
        lastText = ""
        typed = ""
        live = false
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            guard mic else {
                fputs("dictate: microphone denied\n", stderr)
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard status == .authorized, let recognizer = self.recognizer, recognizer.isAvailable else {
                        fputs("dictate: speech not authorized (\(status.rawValue))\n", stderr)
                        return
                    }
                    self.begin(recognizer)
                }
            }
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer) {
        task?.cancel()
        task = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            fputs("dictate: audio \(error.localizedDescription)\n", stderr)
            return
        }
        live = true
        fputs("right-command hold → dictate start (stream)\n", stderr)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.live else { return }
                if let result {
                    let next = result.bestTranscription.formattedString
                    self.lastText = next
                    streamDictate(next, typed: &self.typed)
                }
                if let error {
                    fputs("dictate: \(error.localizedDescription)\n", stderr)
                }
            }
        }
    }

    func stop() {
        live = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        streamDictate(lastText, typed: &typed)
        fputs("right-command hold → dictate stop «\(typed)»\n", stderr)
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

func handleHotKey() {
    if sayRunning() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", "say"]
        try? p.run()
        p.waitUntilExit()
        fputs("stop\n", stderr)
        return
    }
    if AXIsProcessTrusted() {
        pressCopy()
        Thread.sleep(forTimeInterval: 0.2)
    }
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    guard !text.isEmpty else {
        fputs("empty\n", stderr)
        return
    }
    fputs("speak \(text.count) chars\n", stderr)
    speak(text)
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        fputs("talk-keys tap re-enabled\n", stderr)
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

    if type == .flagsChanged && keycode == rightOptionKeyCode {
        // Distinguish press vs release via Alternate flag for this key.
        let optionDown = event.flags.contains(.maskAlternate)
        if optionDown && !rightOptionDown {
            rightOptionDown = true
            rightOptionAlone = true
            fputs("right-option down\n", stderr)
        } else if !optionDown && rightOptionDown {
            rightOptionDown = false
            if rightOptionAlone {
                fputs("right-option alone → speak\n", stderr)
                DispatchQueue.main.async { handleHotKey() }
            } else {
                fputs("right-option chord (ignored)\n", stderr)
            }
            rightOptionAlone = false
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .flagsChanged && keycode == rightCommandKeyCode {
        if !rightCommandDown {
            rightCommandDown = true
            rightCommandAlone = true
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
        if rightOptionDown {
            rightOptionAlone = false
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

func armTap() {
    if let existing = eventTap {
        CGEvent.tapEnable(tap: existing, enable: true)
        return
    }
    guard let tap = createTap() else {
        fputs("talk-keys: tap not created (need Accessibility)\n", stderr)
        return
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    fputs("talk-keys: Right Option tap + Right Command hold armed\n", stderr)
}

func promptIfNeeded() {
    let ax = AXIsProcessTrusted()
    let listen = CGPreflightListenEventAccess()
    fputs("talk-keys permissions AX=\(ax) ListenEvent=\(listen)\n", stderr)
    if ax && listen {
        armTap()
        return
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Talk Keys Needs Permission"
    alert.informativeText = "Turn on Talk Keys in Accessibility and Input Monitoring, then click OK."
    alert.addButton(withTitle: "Open Settings")
    _ = alert.runModal()
    openPrivacyPane("Privacy_Accessibility")
    openPrivacyPane("Privacy_ListenEvent")
    _ = CGRequestListenEventAccess()
    _ = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    )
    NSApp.setActivationPolicy(.accessory)
    armTap()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async {
    promptIfNeeded()
    if eventTap == nil {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            if AXIsProcessTrusted() && CGPreflightListenEventAccess() {
                armTap()
                if eventTap != nil { t.invalidate() }
            }
        }
    }
}
app.run()
