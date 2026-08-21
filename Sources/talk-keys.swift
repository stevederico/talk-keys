// talk-keys — tap Right Option to speak the current highlight. Second tap stops.
// Needs Input Monitoring (ListenEvent) for the CGEventTap, and Accessibility to
// send Cmd+C when the pasteboard is empty. Modifier-alone cannot use Carbon hotkeys.
import AppKit
import ApplicationServices
import Foundation

private let rightOptionKeyCode: Int64 = 61 // kVK_RightOption

private var rightOptionDown = false
private var rightOptionAlone = false
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

    if type == .keyDown && rightOptionDown {
        rightOptionAlone = false
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
    fputs("talk-keys: Right Option tap armed\n", stderr)
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
