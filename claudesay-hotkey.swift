// claudesay-hotkey — a global mute key that works from any app.
//
// Registers one system-wide hotkey (default ⌃⌥⌘M) and runs
// `claudesay.sh --toggle-mute` when it fires.
//
// Uses Carbon's RegisterEventHotKey rather than a CGEventTap on purpose: an
// event tap needs Accessibility permission, which means a System Settings trip
// and a scary "this app can read all your keystrokes" dialog for something whose
// only job is to mute a notifier. RegisterEventHotKey needs no permission at all
// and cannot observe any key but the one it claims.
//
//   claudesay-hotkey <path-to-claudesay.sh> [keycode] [modifier-mask]
//
// Built and installed by `claudesay.sh --install-hotkey`.

import AppKit
import Carbon.HIToolbox

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: claudesay-hotkey <claudesay.sh> [keycode] [modmask]\n".data(using: .utf8)!)
    exit(2)
}

let hookPath = args[1]
let keyCode = UInt32(args.count > 2 ? (UInt32(args[2]) ?? UInt32(kVK_ANSI_M)) : UInt32(kVK_ANSI_M))
let modifiers = UInt32(args.count > 3
    ? (UInt32(args[3]) ?? UInt32(controlKey | optionKey | cmdKey))
    : UInt32(controlKey | optionKey | cmdKey))

func toggleMute() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [hookPath, "--toggle-mute"]
    // The point of the key is to stop a voice now; never block the event
    // handler waiting on it.
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    try? p.run()
}

var hotKeyRef: EventHotKeyRef?
var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed))

InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
    toggleMute()
    return noErr
}, 1, &eventType, nil, nil)

let hotKeyID = EventHotKeyID(signature: OSType(0x434C4459 /* 'CLDY' */), id: 1)
let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                 GetApplicationEventTarget(), 0, &hotKeyRef)

guard status == noErr else {
    FileHandle.standardError.write(
        "claudesay-hotkey: could not register the hotkey (status \(status)). "
        .data(using: .utf8)!)
    FileHandle.standardError.write(
        "Another app probably owns that combination — pick a different one.\n"
        .data(using: .utf8)!)
    exit(1)
}

FileHandle.standardError.write(
    "claudesay-hotkey: listening (keycode \(keyCode), modmask \(modifiers))\n".data(using: .utf8)!)

// A run loop is required for hotkey events to be delivered. Accessory policy
// keeps it out of the Dock and the app switcher — it is a daemon, not an app.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
